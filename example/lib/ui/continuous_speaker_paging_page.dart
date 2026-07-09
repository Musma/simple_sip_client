import 'package:flutter/material.dart';
import 'package:simple_sip_client/simple_sip_client.dart';

import '../config/sip_settings.dart';
import 'speaker_paging_app.dart';

class ContinuousSpeakerPagingPage extends StatefulWidget {
  const ContinuousSpeakerPagingPage({super.key});

  @override
  State<ContinuousSpeakerPagingPage> createState() =>
      _ContinuousSpeakerPagingPageState();
}

class _ContinuousSpeakerPagingPageState
    extends State<ContinuousSpeakerPagingPage> {
  final _client = SipPagingClient(config: sipConfig);
  final _logs = <String>[];
  SipPagingSession? _session;
  Codec _codec = Codec.pcma;
  bool _busy = false;
  bool _registered = false;

  bool get _streaming => _session?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _client.events.stream.listen(_log);
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) {
      session.stop();
    }
    _client.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (error) {
      _log('ERROR: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() => _run(() async {
    _registered = await _client.register();
    if (mounted) setState(() {});
  });

  Future<void> _unregister() => _run(() async {
    await _stopPaging();
    await _client.unregister();
    _registered = false;
    if (mounted) setState(() {});
  });

  Future<void> _startPaging(String label, String extension) => _run(() async {
    final session = await _client.startPageExtension(
      label: label,
      extension: extension,
      codec: _codec,
    );
    _session = session;
    if (mounted) setState(() {});
    session.completed.whenComplete(() {
      if (!mounted) return;
      setState(() {
        if (identical(_session, session)) _session = null;
      });
    });
  });

  Future<void> _stopPaging() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    if (mounted) setState(() {});
    await session.stop();
  }

  void _log(String message) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[$stamp] $message');
      if (_logs.length > 150) _logs.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SIP Continuous Paging'),
        actions: [
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => Navigator.of(
                    context,
                  ).pushNamed(TimedSpeakerPagingPage.routeName),
            icon: const Icon(Icons.timer_outlined),
            label: const Text('Timed'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Chip(
                avatar: Icon(
                  _registered ? Icons.check_circle : Icons.radio_button_off,
                  size: 18,
                ),
                label: Text(_registered ? 'Registered' : 'Not registered'),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          final controls = _buildControls();
          final logs = _buildLogs();
          return Padding(
            padding: const EdgeInsets.all(24),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 400, child: controls),
                      const SizedBox(width: 24),
                      Expanded(child: logs),
                    ],
                  )
                : ListView(
                    children: [
                      controls,
                      const SizedBox(height: 24),
                      SizedBox(height: 360, child: logs),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildControls() {
    final activeSession = _session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Asterisk ${sipConfig.server}:${sipConfig.port}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text('${sipConfig.username}@${sipConfig.domain}'),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || _registered ? null : _register,
                icon: const Icon(Icons.login),
                label: const Text('Register'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy || !_registered ? null : _unregister,
                icon: const Icon(Icons.logout),
                label: const Text('Unregister'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SegmentedButton<Codec>(
          segments: const [
            ButtonSegment(value: Codec.pcma, label: Text('PCMA')),
            ButtonSegment(value: Codec.pcmu, label: Text('PCMU')),
          ],
          selected: {_codec},
          onSelectionChanged: _busy || _streaming
              ? null
              : (value) => setState(() => _codec = value.first),
        ),
        const SizedBox(height: 18),
        if (activeSession != null) ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _run(_stopPaging),
            icon: const Icon(Icons.stop),
            label: Text('Stop ${activeSession.label}'),
          ),
        ] else ...[
          for (final target in speakerTargets.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FilledButton.icon(
                onPressed: _busy || !_registered
                    ? null
                    : () => _startPaging(target.key, target.value),
                icon: const Icon(Icons.mic),
                label: Text('Start ${target.key} (${target.value})'),
              ),
            ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _buildLogs() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff111827),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              _logs[index],
              style: const TextStyle(
                color: Color(0xffd1d5db),
                fontFamily: 'Consolas',
                fontSize: 13,
              ),
            ),
          );
        },
      ),
    );
  }
}
