import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../db/database.dart';

/// FR-1: one-tap recording, pause/resume, wav 16 kHz mono (whisper-native).
class RecorderService {
  RecorderService._();
  static final RecorderService instance = RecorderService._();

  final AudioRecorder _rec = AudioRecorder();
  DateTime? _startedAt;
  Duration _pausedAccum = Duration.zero;
  DateTime? _pauseStartedAt;
  String? _currentPath;

  bool get isActive => _startedAt != null;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    if (!await _rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final dir = await mediaDir();
    _currentPath = p.join(
        dir.path, 'rec_${DateTime.now().millisecondsSinceEpoch}.wav');
    // wav/16k/mono: exactly what whisper.cpp wants — no conversion step later.
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _currentPath!,
    );
    _startedAt = DateTime.now();
    _pausedAccum = Duration.zero;
    _pauseStartedAt = null;
  }

  Future<void> pause() async {
    await _rec.pause();
    _pauseStartedAt = DateTime.now();
  }

  Future<void> resume() async {
    await _rec.resume();
    if (_pauseStartedAt != null) {
      _pausedAccum += DateTime.now().difference(_pauseStartedAt!);
      _pauseStartedAt = null;
    }
  }

  Duration get elapsed {
    if (_startedAt == null) return Duration.zero;
    final pausedNow = _pauseStartedAt != null
        ? DateTime.now().difference(_pauseStartedAt!)
        : Duration.zero;
    return DateTime.now().difference(_startedAt!) - _pausedAccum - pausedNow;
  }

  /// Stops and returns (filePath, duration). Null path if cancelled/failed.
  Future<(String?, Duration)> stop() async {
    final d = elapsed;
    final path = await _rec.stop();
    _startedAt = null;
    _currentPath = null;
    return (path, d);
  }

  Future<void> cancel() async {
    await _rec.cancel();
    _startedAt = null;
    _currentPath = null;
  }

  Future<Amplitude> amplitude() =>
      _rec.getAmplitude();

  void dispose() => _rec.dispose();
}
