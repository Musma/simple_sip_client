import 'package:flutter/material.dart';
import 'package:simple_sip_client/simple_sip_client.dart';

import '../config/sip_settings.dart';

class SpeakerPagingPage extends StatefulWidget {
  const SpeakerPagingPage({super.key});

  @override
  State<SpeakerPagingPage> createState() => _SpeakerPagingPageState();
}

class _SpeakerPagingPageState extends State<SpeakerPagingPage> {
  final _client = SipPagingClient(config: sipConfig);
  final _logs = <String>[];
  bool _busy = false;
  bool _registered = false;
  int _seconds = 5;
  Codec _codec = Codec.pcma;

  @override
  void initState() {
    super.initState();
    _client.events.stream.listen(_log);
  }

  @override
  void dispose() {
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
  });

  Future<void> _page(String label, String extension) => _run(
    () => _client.pageExtension(
      label: label,
      extension: extension,
      codec: _codec,
      duration: Duration(seconds: _seconds),
    ),
  );

  Future<void> _pageAll() => _run(() async {
    for (final target in speakerTargets.entries) {
      await _client.pageExtension(
        label: target.key,
        extension: target.value,
        codec: _codec,
        duration: Duration(seconds: _seconds),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  });

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
        title: const Text('SIP Speaker Control'),
        actions: [
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
        FilledButton.icon(
          onPressed: _busy ? null : _register,
          icon: const Icon(Icons.login),
          label: const Text('Register'),
        ),
        const SizedBox(height: 18),
        SegmentedButton<Codec>(
          segments: const [
            ButtonSegment(value: Codec.pcma, label: Text('PCMA')),
            ButtonSegment(value: Codec.pcmu, label: Text('PCMU')),
          ],
          selected: {_codec},
          onSelectionChanged: _busy
              ? null
              : (value) => setState(() => _codec = value.first),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Icon(Icons.timer_outlined),
            Expanded(
              child: Slider(
                value: _seconds.toDouble(),
                min: 1,
                max: 20,
                divisions: 19,
                label: '$_seconds sec',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _seconds = value.round()),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text('${_seconds}s', textAlign: TextAlign.end),
            ),
          ],
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _busy ? null : _pageAll,
          icon: const Icon(Icons.mic),
          label: const Text('Mic to 1001 - 1004'),
        ),
        const SizedBox(height: 12),
        for (final target in speakerTargets.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _page(target.key, target.value),
              icon: const Icon(Icons.mic),
              label: Text('${target.key} (${target.value})'),
            ),
          ),
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
          debugPrint('log: ${_logs[index]}');
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
