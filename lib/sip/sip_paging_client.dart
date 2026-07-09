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

class SipPagingSession {
  SipPagingSession._({
    required this.label,
    required this.extension,
    required this._stop,
    required this.completed,
  });

  final String label;
  final String extension;
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

class SipPagingClient {
  SipPagingClient({required this.config});

  final SipConfig config;
  final events = StreamController<String>.broadcast();
  final _random = Random.secure();
  final _microphone = MicrophonePcmSource();
  RawDatagramSocket? _sipSocket;
  Stream<RawSocketEvent>? _sipEvents;
  InternetAddress? _localAddress;
  SipPagingSession? _activeSession;
  int _cseq = 1;

  Future<void> dispose() async {
    await _activeSession?.stop();
    _sipSocket?.close();
    await _microphone.dispose();
    await events.close();
  }

  Future<bool> register() => _register(expires: null);

  Future<bool> unregister() => _register(expires: 0);

  Future<bool> _register({required int? expires}) async {
    final socket = await _sip();
    final callId = _token(20);
    final uri = 'sip:${config.domain}';
    final action = expires == 0 ? 'UNREGISTER' : 'REGISTER';
    _emit('Sending $action');

    await _sendRegister(socket, uri, callId, expires: expires);

    var response = await _wait(callId);
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
      response = await _wait(callId);
    }

    if (response.statusCode != 200) {
      throw SipException('$action failed: ${response.statusLine}');
    }
    _emit('$action accepted');
    return true;
  }

  Future<void> _sendRegister(
    RawDatagramSocket socket,
    String uri,
    String callId, {
    required int? expires,
    String? authorization,
  }) async {
    await _send(
      socket,
      '${_line('REGISTER', uri)}${_headers(method: 'REGISTER', uri: uri, callId: callId, branch: _branch(), cseq: _cseq++, authorization: authorization, expires: expires)}\r\n',
    );
  }

  Future<void> pageExtension({
    required String label,
    required String extension,
    required Codec codec,
    required Duration duration,
  }) async {
    final session = await startPageExtension(
      label: label,
      extension: extension,
      codec: codec,
    );

    try {
      await Future<void>.delayed(duration);
    } finally {
      await session.stop();
      await session.completed;
    }
  }

  Future<SipPagingSession> startPageExtension({
    required String label,
    required String extension,
    required Codec codec,
  }) async {
    if (_activeSession?.isActive ?? false) {
      throw const SipException('A paging session is already active');
    }

    final sip = await _sip();
    final rtp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final local = await _local();
    final uri = 'sip:$extension@${config.domain}';
    final callId = _token(22);
    final fromTag = _token(10);
    final sdp = _sdp(local.address, rtp.port, codec);

    try {
      _emit('Calling $label ($extension)');
      var inviteCseq = _cseq++;
      await _send(
        sip,
        '${_line('INVITE', uri)}${_headers(method: 'INVITE', uri: uri, callId: callId, branch: _branch(), cseq: inviteCseq, fromTag: fromTag, toUser: extension, contentType: 'application/sdp', contentLength: utf8.encode(sdp).length)}\r\n$sdp',
      );

      var response = await _waitFinal(callId);
      if (response.statusCode == 401 || response.statusCode == 407) {
        final challenge =
            response.headers[response.statusCode == 407
                ? 'proxy-authenticate'
                : 'www-authenticate'];
        if (challenge == null) {
          throw const SipException('INVITE auth challenge is missing');
        }

        await _ack(sip, response, uri, callId, fromTag, extension, inviteCseq);
        inviteCseq = _cseq++;
        await _send(
          sip,
          '${_line('INVITE', uri)}${_headers(method: 'INVITE', uri: uri, callId: callId, branch: _branch(), cseq: inviteCseq, fromTag: fromTag, toUser: extension, authorization: _auth(challenge, 'INVITE', uri, response.statusCode == 407), contentType: 'application/sdp', contentLength: utf8.encode(sdp).length)}\r\n$sdp',
        );
        response = await _waitFinal(callId);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _ack(sip, response, uri, callId, fromTag, extension, inviteCseq);
        throw SipException('INVITE failed: ${response.statusLine}');
      }

      await _ack(sip, response, uri, callId, fromTag, extension, inviteCseq);
      final remote = _remoteRtp(response.body);
      final stop = Completer<void>();
      late SipPagingSession session;
      final completed =
          _runPageSession(
            rtp: rtp,
            sip: sip,
            response: response,
            uri: uri,
            callId: callId,
            fromTag: fromTag,
            extension: extension,
            label: label,
            codec: codec,
            remoteAddress: InternetAddress(remote.address),
            remotePort: remote.port,
            stop: stop.future,
          ).whenComplete(() {
            if (identical(_activeSession, session)) _activeSession = null;
          });
      session = SipPagingSession._(
        label: label,
        extension: extension,
        stop: () async {
          if (!stop.isCompleted) stop.complete();
          await completed;
        },
        completed: completed,
      );
      _activeSession = session;
      return session;
    } catch (_) {
      rtp.close();
      rethrow;
    }
  }

  Future<void> _runPageSession({
    required RawDatagramSocket rtp,
    required RawDatagramSocket sip,
    required SipResponse response,
    required String uri,
    required String callId,
    required String fromTag,
    required String extension,
    required String label,
    required Codec codec,
    required InternetAddress remoteAddress,
    required int remotePort,
    required Future<void> stop,
  }) async {
    try {
      _emit('Streaming microphone ${codec.rtpName} to $extension');
      await _streamMicrophone(rtp, remoteAddress, remotePort, codec, stop);
      await _bye(sip, response, uri, callId, fromTag, extension);
      _emit('Finished $label ($extension)');
    } finally {
      rtp.close();
    }
  }

  Future<RawDatagramSocket> _sip() async {
    if (_sipSocket != null) return _sipSocket!;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sipSocket = socket;
    _sipEvents = socket.asBroadcastStream();
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
    _localAddress = selected;
    return selected;
  }

  Future<void> _send(RawDatagramSocket socket, String message) async {
    socket.send(
      utf8.encode(message),
      InternetAddress(config.server),
      config.port,
    );
  }

  Future<SipResponse> _waitFinal(String callId) async {
    while (true) {
      final response = await _wait(callId);
      if (response.statusCode >= 200) return response;
    }
  }

  Future<SipResponse> _wait(String callId) async {
    final socket = await _sip();
    final socketEvents = _sipEvents;
    if (socketEvents == null) {
      throw const SipException('SIP socket event stream is not ready');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 8));

    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final event = await socketEvents
          .timeout(remaining)
          .firstWhere((event) => event == RawSocketEvent.read);
      if (event != RawSocketEvent.read) continue;

      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final text = utf8.decode(datagram!.data, allowMalformed: true);
        if (!text.startsWith('SIP/2.0')) continue;

        final response = SipResponse.parse(text);
        if (response.headers['call-id'] == callId) {
          _emit(response.statusLine);
          return response;
        }
      }
    }

    throw TimeoutException('Timed out waiting for SIP response');
  }

  Future<void> _ack(
    RawDatagramSocket socket,
    SipResponse invite,
    String uri,
    String callId,
    String fromTag,
    String toUser,
    int cseq,
  ) async {
    await _send(
      socket,
      '${_line('ACK', uri)}${_dialogHeaders(socket, invite, callId, fromTag, toUser, 'ACK', cseq: cseq)}\r\n',
    );
  }

  Future<void> _bye(
    RawDatagramSocket socket,
    SipResponse invite,
    String uri,
    String callId,
    String fromTag,
    String toUser,
  ) async {
    await _send(
      socket,
      '${_line('BYE', uri)}${_dialogHeaders(socket, invite, callId, fromTag, toUser, 'BYE')}\r\n',
    );
    await _wait(callId);
  }

  String _dialogHeaders(
    RawDatagramSocket socket,
    SipResponse invite,
    String callId,
    String fromTag,
    String toUser,
    String method, {
    int? cseq,
  }) {
    return 'Via: SIP/2.0/UDP ${_localAddress!.address}:${socket.port};branch=${_branch()};rport\r\n'
        'Max-Forwards: 70\r\n'
        'From: <sip:${config.username}@${config.domain}>;tag=$fromTag\r\n'
        'To: ${invite.headers['to'] ?? '<sip:$toUser@${config.domain}>'}\r\n'
        'Call-ID: $callId\r\n'
        'CSeq: ${cseq ?? _cseq++} $method\r\n'
        'Contact: <sip:${config.username}@${_localAddress!.address}:${socket.port};transport=udp>\r\n'
        'Content-Length: 0\r\n';
  }

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
      ..write('User-Agent: flutter-windows-sip-pager\r\n')
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
      's=Speaker page\r\n'
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
        port = int.tryParse(line.split(RegExp(r'\s+'))[1]);
      }
    }
    if (address == null || port == null) {
      throw const SipException('Remote SDP has no RTP endpoint');
    }
    return (address: address, port: port);
  }

  Future<void> _streamMicrophone(
    RawDatagramSocket socket,
    InternetAddress address,
    int port,
    Codec codec,
    Future<void> stop,
  ) async {
    final stream = await _microphone.start();
    final ssrc = _random.nextInt(0xffffffff);
    var seq = _random.nextInt(0xffff);
    var timestamp = _random.nextInt(0xffffffff);
    const samplesPerPacket = 160;
    const bytesPerPacket = samplesPerPacket * 2;
    final pcmBuffer = BytesBuilder(copy: false);
    var stopped = false;
    unawaited(stop.then((_) => stopped = true));

    try {
      await for (final chunk in stream) {
        if (stopped) return;
        pcmBuffer.add(chunk);

        while (pcmBuffer.length >= bytesPerPacket) {
          if (stopped) return;

          final bytes = pcmBuffer.takeBytes();
          final packetPcm = Uint8List.sublistView(bytes, 0, bytesPerPacket);
          if (bytes.length > bytesPerPacket) {
            pcmBuffer.add(Uint8List.sublistView(bytes, bytesPerPacket));
          }

          final packet = Uint8List(12 + samplesPerPacket);
          packet[0] = 0x80;
          packet[1] = codec.payloadType;
          packet[2] = (seq >> 8) & 0xff;
          packet[3] = seq & 0xff;
          packet[4] = (timestamp >> 24) & 0xff;
          packet[5] = (timestamp >> 16) & 0xff;
          packet[6] = (timestamp >> 8) & 0xff;
          packet[7] = timestamp & 0xff;
          packet[8] = (ssrc >> 24) & 0xff;
          packet[9] = (ssrc >> 16) & 0xff;
          packet[10] = (ssrc >> 8) & 0xff;
          packet[11] = ssrc & 0xff;

          for (var i = 0; i < samplesPerPacket; i++) {
            final byteIndex = i * 2;
            final sample = _applyMicrophoneGain(
              _pcm16LittleEndianToInt(
                packetPcm[byteIndex],
                packetPcm[byteIndex + 1],
              ),
            );
            packet[12 + i] = codec == Codec.pcma
                ? _aLaw(sample)
                : _uLaw(sample);
          }

          socket.send(packet, address, port);
          seq = (seq + 1) & 0xffff;
          timestamp = (timestamp + samplesPerPacket) & 0xffffffff;
        }
      }
    } finally {
      await _microphone.stop();
    }
  }

  int _pcm16LittleEndianToInt(int lowByte, int highByte) {
    final value = lowByte | (highByte << 8);
    return value >= 0x8000 ? value - 0x10000 : value;
  }

  int _applyMicrophoneGain(int sample) {
    final amplified = (sample * config.microphoneGain).round();
    return amplified.clamp(-32768, 32767);
  }

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
