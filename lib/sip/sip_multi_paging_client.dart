import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_sip_client/audio/microphone_pcm_source.dart';
import 'package:simple_sip_client/config/sip_config.dart';
import 'package:simple_sip_client/sip/codec.dart';
import 'package:simple_sip_client/sip/sip_exception.dart';
import 'package:simple_sip_client/sip/sip_response.dart';

/// A speaker to call as part of a simultaneous paging session.
class SipPagingTarget {
  const SipPagingTarget({required this.label, required this.extension});

  final String label;
  final String extension;
}

/// A target that could not be connected while starting a group page.
class SipPagingTargetFailure {
  const SipPagingTargetFailure({required this.target, required this.error});

  final SipPagingTarget target;
  final Object error;
}

/// A running page to one or more SIP endpoints using one microphone capture.
class SipMultiPagingSession {
  SipMultiPagingSession._({
    required this.connectedTargets,
    required this.failedTargets,
    required this._stop,
    required this.completed,
  });

  final List<SipPagingTarget> connectedTargets;
  final List<SipPagingTargetFailure> failedTargets;
  final Future<void> completed;
  final Future<void> Function() _stop;
  bool _stopped = false;

  bool get isActive => !_stopped;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _stop();
  }
}

/// SIP paging client that sends one microphone stream to multiple speakers.
///
/// This class is independent from [SipPagingClient], so the existing single
/// target API remains unchanged. One instance supports one active group session
/// at a time.
class SipMultiPagingClient {
  SipMultiPagingClient({required this.config});

  final SipConfig config;
  final events = StreamController<String>.broadcast();
  final _random = Random.secure();
  final _microphone = MicrophonePcmSource();
  final Map<String, _SipResponseMailbox> _responses = {};

  RawDatagramSocket? _sipSocket;
  StreamSubscription<RawSocketEvent>? _sipSubscription;
  InternetAddress? _localAddress;
  SipMultiPagingSession? _activeSession;
  int _cseq = 1;
  bool _disposed = false;

  Future<bool> register() => _register(expires: null);

  Future<bool> unregister() => _register(expires: 0);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _activeSession?.stop();
    await _sipSubscription?.cancel();
    _sipSocket?.close();
    _responses.clear();
    await _microphone.dispose();
    await events.close();
  }

  Future<void> pageExtensions({
    required List<SipPagingTarget> targets,
    required Codec codec,
    required Duration duration,
  }) async {
    final session = await startPageExtensions(targets: targets, codec: codec);
    try {
      await Future<void>.delayed(duration);
    } finally {
      await session.stop();
      await session.completed;
    }
  }

  Future<SipMultiPagingSession> startPageExtensions({
    required List<SipPagingTarget> targets,
    required Codec codec,
  }) async {
    if (_disposed) throw StateError('SipMultiPagingClient is disposed');
    if (_activeSession?.isActive ?? false) {
      throw const SipException('A multi paging session is already active');
    }
    if (targets.isEmpty) {
      throw const SipException('At least one paging target is required');
    }
    final extensions = targets.map((target) => target.extension).toSet();
    if (extensions.length != targets.length) {
      throw const SipException('Paging target extensions must be unique');
    }

    final results = await Future.wait(
      targets.map((target) async {
        try {
          return (dialog: await _invite(target, codec), failure: null);
        } catch (error) {
          _emit('Failed ${target.label} (${target.extension}): $error');
          return (
            dialog: null,
            failure: SipPagingTargetFailure(target: target, error: error),
          );
        }
      }),
    );
    final dialogs = results
        .map((result) => result.dialog)
        .whereType<_PagingDialog>()
        .toList();
    final failures = results
        .map((result) => result.failure)
        .whereType<SipPagingTargetFailure>()
        .toList();

    if (dialogs.isEmpty) {
      throw SipException('No paging target could be connected');
    }

    final stop = Completer<void>();
    late SipMultiPagingSession session;
    final completed = _runGroup(dialogs, codec, stop.future).whenComplete(() {
      if (identical(_activeSession, session)) _activeSession = null;
    });
    session = SipMultiPagingSession._(
      connectedTargets: List.unmodifiable(dialogs.map((item) => item.target)),
      failedTargets: List.unmodifiable(failures),
      stop: () async {
        if (!stop.isCompleted) stop.complete();
        await completed;
      },
      completed: completed,
    );
    _activeSession = session;
    return session;
  }

  Future<_PagingDialog> _invite(SipPagingTarget target, Codec codec) async {
    final sip = await _sip();
    final rtp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final local = await _local();
    final uri = 'sip:${target.extension}@${config.domain}';
    final callId = _token(22);
    final fromTag = _token(10);
    final responses = _openResponseChannel(callId);
    final sdp = _sdp(local.address, rtp.port, codec);

    try {
      _emit('Calling ${target.label} (${target.extension})');
      var inviteCseq = _cseq++;
      await _send(
        sip,
        '${_line('INVITE', uri)}${_headers(method: 'INVITE', uri: uri, callId: callId, branch: _branch(), cseq: inviteCseq, fromTag: fromTag, toUser: target.extension, contentType: 'application/sdp', contentLength: utf8.encode(sdp).length)}\r\n$sdp',
      );
      var response = await responses.nextFinal();
      if (response.statusCode == 401 || response.statusCode == 407) {
        final challenge =
            response.headers[response.statusCode == 407
                ? 'proxy-authenticate'
                : 'www-authenticate'];
        if (challenge == null) {
          throw const SipException('INVITE auth challenge is missing');
        }
        await _ack(
          sip,
          response,
          uri,
          callId,
          fromTag,
          target.extension,
          inviteCseq,
        );
        inviteCseq = _cseq++;
        await _send(
          sip,
          '${_line('INVITE', uri)}${_headers(method: 'INVITE', uri: uri, callId: callId, branch: _branch(), cseq: inviteCseq, fromTag: fromTag, toUser: target.extension, authorization: _auth(challenge, 'INVITE', uri, response.statusCode == 407), contentType: 'application/sdp', contentLength: utf8.encode(sdp).length)}\r\n$sdp',
        );
        response = await responses.nextFinal();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _ack(
          sip,
          response,
          uri,
          callId,
          fromTag,
          target.extension,
          inviteCseq,
        );
        throw SipException('INVITE failed: ${response.statusLine}');
      }

      await _ack(
        sip,
        response,
        uri,
        callId,
        fromTag,
        target.extension,
        inviteCseq,
      );
      final remote = _remoteRtp(response.body);
      _emit('Connected ${target.label} (${target.extension})');
      return _PagingDialog(
        target: target,
        rtp: rtp,
        inviteResponse: response,
        responses: responses,
        uri: uri,
        callId: callId,
        fromTag: fromTag,
        remoteAddress: InternetAddress(remote.address),
        remotePort: remote.port,
        ssrc: _random.nextInt(0xffffffff),
        sequence: _random.nextInt(0xffff),
        timestamp: _random.nextInt(0xffffffff),
      );
    } catch (_) {
      rtp.close();
      await _closeResponseChannel(callId);
      rethrow;
    }
  }

  Future<void> _runGroup(
    List<_PagingDialog> dialogs,
    Codec codec,
    Future<void> stop,
  ) async {
    try {
      _emit('Streaming one microphone to ${dialogs.length} speaker(s)');
      await _streamMicrophone(dialogs, codec, stop);
    } finally {
      await Future.wait(dialogs.map(_finishDialog));
    }
  }

  Future<void> _finishDialog(_PagingDialog dialog) async {
    try {
      await _bye(await _sip(), dialog);
      _emit('Finished ${dialog.target.label} (${dialog.target.extension})');
    } catch (error) {
      _emit('BYE failed for ${dialog.target.extension}: $error');
    } finally {
      dialog.rtp.close();
      await _closeResponseChannel(dialog.callId);
    }
  }

  Future<void> _streamMicrophone(
    List<_PagingDialog> dialogs,
    Codec codec,
    Future<void> stop,
  ) async {
    final stream = await _microphone.start();
    final iterator = StreamIterator<Uint8List>(stream);
    final pcmBuffer = BytesBuilder(copy: false);
    const samplesPerPacket = 160;
    const bytesPerPacket = samplesPerPacket * 2;
    var stopped = false;
    unawaited(stop.then((_) => stopped = true));

    try {
      while (!stopped) {
        final hasNext = await Future.any<bool>([
          iterator.moveNext(),
          stop.then((_) => false),
        ]);
        if (!hasNext || stopped) break;
        pcmBuffer.add(iterator.current);

        while (pcmBuffer.length >= bytesPerPacket && !stopped) {
          final bytes = pcmBuffer.takeBytes();
          final packetPcm = Uint8List.sublistView(bytes, 0, bytesPerPacket);
          if (bytes.length > bytesPerPacket) {
            pcmBuffer.add(Uint8List.sublistView(bytes, bytesPerPacket));
          }
          final encoded = Uint8List(samplesPerPacket);
          for (var i = 0; i < samplesPerPacket; i++) {
            final byteIndex = i * 2;
            final sample = _applyMicrophoneGain(
              _pcm16LittleEndianToInt(
                packetPcm[byteIndex],
                packetPcm[byteIndex + 1],
              ),
            );
            encoded[i] = codec == Codec.pcma ? _aLaw(sample) : _uLaw(sample);
          }
          for (final dialog in dialogs) {
            dialog.rtp.send(
              _rtpPacket(dialog, codec, encoded),
              dialog.remoteAddress,
              dialog.remotePort,
            );
          }
        }
      }
    } finally {
      await iterator.cancel();
      await _microphone.stop();
    }
  }

  Uint8List _rtpPacket(_PagingDialog dialog, Codec codec, Uint8List encoded) {
    final packet = Uint8List(12 + encoded.length);
    packet[0] = 0x80;
    packet[1] = codec.payloadType;
    packet[2] = (dialog.sequence >> 8) & 0xff;
    packet[3] = dialog.sequence & 0xff;
    packet[4] = (dialog.timestamp >> 24) & 0xff;
    packet[5] = (dialog.timestamp >> 16) & 0xff;
    packet[6] = (dialog.timestamp >> 8) & 0xff;
    packet[7] = dialog.timestamp & 0xff;
    packet[8] = (dialog.ssrc >> 24) & 0xff;
    packet[9] = (dialog.ssrc >> 16) & 0xff;
    packet[10] = (dialog.ssrc >> 8) & 0xff;
    packet[11] = dialog.ssrc & 0xff;
    packet.setRange(12, packet.length, encoded);
    dialog.sequence = (dialog.sequence + 1) & 0xffff;
    dialog.timestamp = (dialog.timestamp + encoded.length) & 0xffffffff;
    return packet;
  }

  Future<bool> _register({required int? expires}) async {
    final socket = await _sip();
    final callId = _token(20);
    final uri = 'sip:${config.domain}';
    final action = expires == 0 ? 'UNREGISTER' : 'REGISTER';
    final responses = _openResponseChannel(callId);
    try {
      _emit('Sending $action');
      await _sendRegister(socket, uri, callId, expires: expires);
      var response = await responses.nextFinal();
      if (response.statusCode == 401 || response.statusCode == 407) {
        final challenge =
            response.headers[response.statusCode == 407
                ? 'proxy-authenticate'
                : 'www-authenticate'];
        if (challenge == null) {
          throw SipException('$action auth challenge is missing');
        }
        await _sendRegister(
          socket,
          uri,
          callId,
          expires: expires,
          authorization: _auth(
            challenge,
            'REGISTER',
            uri,
            response.statusCode == 407,
          ),
        );
        response = await responses.nextFinal();
      }
      if (response.statusCode != 200) {
        throw SipException('$action failed: ${response.statusLine}');
      }
      _emit('$action accepted');
      return true;
    } finally {
      await _closeResponseChannel(callId);
    }
  }

  Future<void> _sendRegister(
    RawDatagramSocket socket,
    String uri,
    String callId, {
    required int? expires,
    String? authorization,
  }) => _send(
    socket,
    '${_line('REGISTER', uri)}${_headers(method: 'REGISTER', uri: uri, callId: callId, branch: _branch(), cseq: _cseq++, authorization: authorization, expires: expires)}\r\n',
  );

  _SipResponseMailbox _openResponseChannel(String callId) {
    final mailbox = _SipResponseMailbox();
    _responses[callId] = mailbox;
    return mailbox;
  }

  Future<void> _closeResponseChannel(String callId) async {
    _responses.remove(callId)?.close();
  }

  Future<RawDatagramSocket> _sip() async {
    if (_sipSocket != null) return _sipSocket!;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sipSocket = socket;
    _sipSubscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final text = utf8.decode(datagram!.data, allowMalformed: true);
        if (!text.startsWith('SIP/2.0')) continue;
        final response = SipResponse.parse(text);
        final callId = response.headers['call-id'];
        final mailbox = callId == null ? null : _responses[callId];
        if (mailbox != null) {
          _emit(response.statusLine);
          mailbox.add(response);
        }
      }
    });
    _localAddress = await _local();
    _emit('UDP SIP socket bound on ${socket.port}');
    return socket;
  }

  Future<InternetAddress> _local() async {
    if (_localAddress != null) return _localAddress!;
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final addresses = interfaces
        .expand((interface) => interface.addresses)
        .where((address) => !address.isLoopback)
        .toList();
    final sameSubnet = addresses
        .where((address) => address.address.startsWith('192.168.5.'))
        .toList();
    final selected = sameSubnet.isNotEmpty
        ? sameSubnet.first
        : addresses.firstOrNull;
    if (selected == null) {
      throw const SipException('No IPv4 network interface found');
    }
    return _localAddress = selected;
  }

  Future<void> _send(RawDatagramSocket socket, String message) async {
    socket.send(
      utf8.encode(message),
      InternetAddress(config.server),
      config.port,
    );
  }

  Future<void> _ack(
    RawDatagramSocket socket,
    SipResponse invite,
    String uri,
    String callId,
    String fromTag,
    String toUser,
    int cseq,
  ) => _send(
    socket,
    '${_line('ACK', uri)}${_dialogHeaders(socket, invite, callId, fromTag, toUser, 'ACK', cseq: cseq)}\r\n',
  );

  Future<void> _bye(RawDatagramSocket socket, _PagingDialog dialog) async {
    await _send(
      socket,
      '${_line('BYE', dialog.uri)}${_dialogHeaders(socket, dialog.inviteResponse, dialog.callId, dialog.fromTag, dialog.target.extension, 'BYE')}\r\n',
    );
    final response = await dialog.responses.nextFinal();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SipException('BYE failed: ${response.statusLine}');
    }
  }

  String _dialogHeaders(
    RawDatagramSocket socket,
    SipResponse invite,
    String callId,
    String fromTag,
    String toUser,
    String method, {
    int? cseq,
  }) =>
      'Via: SIP/2.0/UDP ${_localAddress!.address}:${socket.port};branch=${_branch()};rport\r\n'
      'Max-Forwards: 70\r\n'
      'From: <sip:${config.username}@${config.domain}>;tag=$fromTag\r\n'
      'To: ${invite.headers['to'] ?? '<sip:$toUser@${config.domain}>'}\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: ${cseq ?? _cseq++} $method\r\n'
      'Contact: <sip:${config.username}@${_localAddress!.address}:${socket.port};transport=udp>\r\n'
      'Content-Length: 0\r\n';

  String _line(String method, String uri) => '$method $uri SIP/2.0\r\n';

  String _headers({
    required String method,
    required String uri,
    required String callId,
    required String branch,
    required int cseq,
    String? fromTag,
    String? toUser,
    String? authorization,
    String? contentType,
    int? expires,
    int contentLength = 0,
  }) {
    final local = _localAddress?.address ?? '0.0.0.0';
    final port = _sipSocket?.port ?? 0;
    final to = toUser == null
        ? '<sip:${config.username}@${config.domain}>'
        : '<sip:$toUser@${config.domain}>';
    final buffer = StringBuffer()
      ..write('Via: SIP/2.0/UDP $local:$port;branch=$branch;rport\r\n')
      ..write('Max-Forwards: 70\r\n')
      ..write(
        'From: <sip:${config.username}@${config.domain}>;tag=${fromTag ?? _token(10)}\r\n',
      )
      ..write('To: $to\r\n')
      ..write('Call-ID: $callId\r\n')
      ..write('CSeq: $cseq $method\r\n')
      ..write(
        'Contact: <sip:${config.username}@$local:$port;transport=udp>\r\n',
      )
      ..write('User-Agent: flutter-windows-sip-multi-pager\r\n')
      ..write('Allow: INVITE, ACK, BYE, CANCEL, OPTIONS, REGISTER\r\n');
    if (expires != null) buffer.write('Expires: $expires\r\n');
    if (authorization != null) buffer.write('$authorization\r\n');
    if (contentType != null) buffer.write('Content-Type: $contentType\r\n');
    buffer.write('Content-Length: $contentLength\r\n');
    return buffer.toString();
  }

  String _auth(String challenge, String method, String uri, bool proxy) {
    final params = _digestParams(challenge);
    final realm = params['realm'] ?? config.domain;
    final nonce = params['nonce'] ?? '';
    final qopAuth =
        params['qop']
            ?.split(',')
            .map((value) => value.trim())
            .contains('auth') ??
        false;
    const nc = '00000001';
    final cnonce = _token(12);
    final ha1 = _md5('${config.username}:$realm:${config.password}');
    final ha2 = _md5('$method:$uri');
    final response = qopAuth
        ? _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2')
        : _md5('$ha1:$nonce:$ha2');
    final buffer =
        StringBuffer(
          proxy ? 'Proxy-Authorization: Digest ' : 'Authorization: Digest ',
        )..write(
          'username="${config.username}", realm="$realm", nonce="$nonce", uri="$uri", response="$response", algorithm=MD5',
        );
    if (qopAuth) buffer.write(', qop=auth, nc=$nc, cnonce="$cnonce"');
    if (params['opaque'] != null) {
      buffer.write(', opaque="${params['opaque']}"');
    }
    return buffer.toString();
  }

  Map<String, String> _digestParams(String header) {
    final value = header.replaceFirst(
      RegExp('^Digest\\s+', caseSensitive: false),
      '',
    );
    final result = <String, String>{};
    for (final match in RegExp(
      r'(\w+)=("([^"]*)"|([^,]*))',
    ).allMatches(value)) {
      result[match.group(1)!.toLowerCase()] =
          match.group(3) ?? match.group(4)!.trim();
    }
    return result;
  }

  String _sdp(String ip, int port, Codec codec) =>
      'v=0\r\n'
      'o=${config.username} 0 0 IN IP4 $ip\r\n'
      's=Speaker group page\r\n'
      'c=IN IP4 $ip\r\n'
      't=0 0\r\n'
      'm=audio $port RTP/AVP ${codec.payloadType}\r\n'
      'a=rtpmap:${codec.payloadType} ${codec.rtpName}/8000\r\n'
      'a=sendonly\r\n';

  ({String address, int port}) _remoteRtp(String sdp) {
    String? address;
    int? port;
    for (final raw in const LineSplitter().convert(sdp.replaceAll('\r', ''))) {
      final line = raw.trim();
      if (line.startsWith('c=IN IP4 ')) address = line.substring(9);
      if (line.startsWith('m=audio ')) {
        final fields = line.split(RegExp(r'\s+'));
        if (fields.length > 1) port = int.tryParse(fields[1]);
      }
    }
    if (address == null || port == null) {
      throw const SipException('Remote SDP has no RTP endpoint');
    }
    return (address: address, port: port);
  }

  int _pcm16LittleEndianToInt(int lowByte, int highByte) {
    final value = lowByte | (highByte << 8);
    return value >= 0x8000 ? value - 0x10000 : value;
  }

  int _applyMicrophoneGain(int sample) =>
      (sample * config.microphoneGain).round().clamp(-32768, 32767);

  int _uLaw(int sample) {
    const bias = 0x84;
    var sign = 0;
    if (sample < 0) {
      sample = -sample;
      sign = 0x80;
    }
    sample = min(sample + bias, 32635);
    var exponent = 7;
    for (var mask = 0x4000; (sample & mask) == 0 && exponent > 0; mask >>= 1) {
      exponent--;
    }
    final mantissa = (sample >> (exponent + 3)) & 0x0f;
    return (~(sign | (exponent << 4) | mantissa)) & 0xff;
  }

  int _aLaw(int sample) {
    var sign = 0;
    if (sample < 0) {
      sample = -sample - 1;
      sign = 0x80;
    }
    sample = min(sample, 32635);
    int compressed;
    if (sample >= 256) {
      var exponent = 7;
      for (
        var mask = 0x4000;
        (sample & mask) == 0 && exponent > 0;
        mask >>= 1
      ) {
        exponent--;
      }
      compressed = (exponent << 4) | ((sample >> (exponent + 3)) & 0x0f);
    } else {
      compressed = sample >> 4;
    }
    return (compressed ^ (sign ^ 0x55)) & 0xff;
  }

  String _md5(String value) => md5.convert(utf8.encode(value)).toString();
  String _branch() => 'z9hG4bK${_token(18)}';

  String _token(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  void _emit(String message) {
    if (!events.isClosed) events.add(message);
  }
}

class _PagingDialog {
  _PagingDialog({
    required this.target,
    required this.rtp,
    required this.inviteResponse,
    required this.responses,
    required this.uri,
    required this.callId,
    required this.fromTag,
    required this.remoteAddress,
    required this.remotePort,
    required this.ssrc,
    required this.sequence,
    required this.timestamp,
  });

  final SipPagingTarget target;
  final RawDatagramSocket rtp;
  final SipResponse inviteResponse;
  final _SipResponseMailbox responses;
  final String uri;
  final String callId;
  final String fromTag;
  final InternetAddress remoteAddress;
  final int remotePort;
  final int ssrc;
  int sequence;
  int timestamp;
}

class _SipResponseMailbox {
  final List<SipResponse> _pending = [];
  final List<Completer<SipResponse>> _waiters = [];
  bool _closed = false;

  void add(SipResponse response) {
    if (_closed || response.statusCode < 200) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(response);
    } else {
      _pending.add(response);
    }
  }

  Future<SipResponse> nextFinal() async {
    if (_pending.isNotEmpty) return _pending.removeAt(0);
    if (_closed) throw StateError('SIP response mailbox is closed');
    final waiter = Completer<SipResponse>();
    _waiters.add(waiter);
    try {
      return await waiter.future.timeout(const Duration(seconds: 8));
    } finally {
      _waiters.remove(waiter);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final error = StateError('SIP response mailbox is closed');
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
    _pending.clear();
  }
}
