import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

class MicrophonePcmSource {
  MicrophonePcmSource({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  Stream<Uint8List>? _stream;

  Future<Stream<Uint8List>> start({
    int sampleRate = 8000,
    int numChannels = 1,
  }) async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission was not granted');
    }

    _stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: numChannels,
      ),
    );
    return _stream!;
  }

  Future<void> stop() async {
    await _recorder.stop();
    _stream = null;
  }

  Future<void> dispose() async {
    await _recorder.dispose();
  }
}
