import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_sip_client/simple_sip_client.dart';

import '../config/sip_settings.dart';

class MultiSpeakerPagingPage extends StatefulWidget {
  const MultiSpeakerPagingPage({super.key});

  static const routeName = '/multi-paging';

  @override
  State<MultiSpeakerPagingPage> createState() => _MultiSpeakerPagingPageState();
}

class _MultiSpeakerPagingPageState extends State<MultiSpeakerPagingPage> {
  final _client = SipMultiPagingClient(config: sipConfig);
  final _selectedExtensions = speakerTargets.values.toSet();
  final _logs = <String>[];

  StreamSubscription<String>? _eventSubscription;
  SipMultiPagingSession? _session;
  Codec _codec = Codec.pcma;
  bool _busy = false;
  bool _registered = false;

  bool get _streaming => _session?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _eventSubscription = _client.events.stream.listen(_log);
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    unawaited(_session?.stop());
    unawaited(_client.dispose());
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

  Future<void> _startPaging() => _run(() async {
    final targets = speakerTargets.entries
        .where((entry) => _selectedExtensions.contains(entry.value))
        .map(
          (entry) => SipPagingTarget(label: entry.key, extension: entry.value),
        )
        .toList();

    final session = await _client.startPageExtensions(
      targets: targets,
      codec: _codec,
    );
    _session = session;
    _log(
      'Started ${session.connectedTargets.length}/${targets.length} speaker(s)',
    );
    for (final failure in session.failedTargets) {
      _log(
        'SKIPPED ${failure.target.label} '
        '(${failure.target.extension}): ${failure.error}',
      );
    }
    if (mounted) setState(() {});

    unawaited(
      session.completed.then(
        (_) => _clearCompletedSession(session),
        onError: (Object error, StackTrace stackTrace) {
          _log('STREAM ERROR: $error');
          _clearCompletedSession(session);
        },
      ),
    );
  });

  Future<void> _stopPaging() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    if (mounted) setState(() {});
    await session.stop();
  }

  void _clearCompletedSession(SipMultiPagingSession session) {
    if (!mounted || !identical(_session, session)) return;
    setState(() => _session = null);
  }

  void _toggleTarget(String extension, bool selected) {
    setState(() {
      if (selected) {
        _selectedExtensions.add(extension);
      } else {
        _selectedExtensions.remove(extension);
      }
    });
  }

  void _selectAll(bool selected) {
    setState(() {
      _selectedExtensions.clear();
      if (selected) _selectedExtensions.addAll(speakerTargets.values);
    });
  }

  void _log(String message) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
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
        title: const Text('SIP Multi-speaker Paging'),
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
                      SizedBox(width: 420, child: controls),
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
    final allSelected =
        _selectedExtensions.length == speakerTargets.length &&
        speakerTargets.isNotEmpty;
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
        Row(
          children: [
            Text('Speakers', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(
              onPressed: _busy || _streaming
                  ? null
                  : () => _selectAll(!allSelected),
              child: Text(allSelected ? 'Clear all' : 'Select all'),
            ),
          ],
        ),
        for (final target in speakerTargets.entries)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(target.key),
            subtitle: Text('Extension ${target.value}'),
            value: _selectedExtensions.contains(target.value),
            onChanged: _busy || _streaming
                ? null
                : (selected) => _toggleTarget(target.value, selected ?? false),
          ),
        const SizedBox(height: 12),
        if (activeSession != null)
          FilledButton.icon(
            onPressed: _busy ? null : () => _run(_stopPaging),
            icon: const Icon(Icons.stop),
            label: Text(
              'Stop ${activeSession.connectedTargets.length} speaker(s)',
            ),
          )
        else
          FilledButton.icon(
            onPressed: _busy || !_registered || _selectedExtensions.isEmpty
                ? null
                : _startPaging,
            icon: const Icon(Icons.mic),
            label: Text('Start ${_selectedExtensions.length} speaker(s)'),
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
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText(
            _logs[index],
            style: const TextStyle(
              color: Color(0xffd1d5db),
              fontFamily: 'Consolas',
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
