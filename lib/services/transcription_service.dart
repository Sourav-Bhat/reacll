import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ggml/whisper_ggml.dart';

import '../db/database.dart';
import 'extraction_service.dart';
import 'voice_id_service.dart';

/// FR-5: on-device whisper.cpp transcription queue.
/// Picks up 'pending' audio artifacts one at a time; audio never leaves the device.
class TranscriptionService extends ChangeNotifier {
  TranscriptionService._();
  static final TranscriptionService instance = TranscriptionService._();

  final WhisperController _whisper = WhisperController();

  static const settingModel = 'whisper_model'; // 'tiny' | 'base' | 'small'

  /// tiny = fast default (recommended by whisper_ggml); base/small are slower
  /// but more accurate. Settings lets the user switch.
  WhisperModel model = WhisperModel.tiny;
  String language = 'en';

  void setModel(String name) {
    switch (name) {
      case 'base':
        model = WhisperModel.base;
        break;
      case 'small':
        model = WhisperModel.small;
        break;
      default:
        model = WhisperModel.tiny;
    }
  }

  bool _running = false;
  int? activeArtifactId;
  String? lastError;

  Future<void> ensureModelReady() async {
    // whisper_ggml downloads the model on first use; warm it explicitly so
    // the first real transcription isn't surprisingly slow.
    try {
      await _whisper.downloadModel(model);
    } catch (_) {
      // Non-fatal: transcribe() will retry the download.
    }
  }

  /// Decode any audio file to 16 kHz mono 16-bit WAV (whisper-native) using
  /// ffmpeg-kit. Paths are quoted so filenames with spaces (e.g. "ESG - Andy")
  /// don't break the command. Returns the WAV path, or null on failure.
  Future<String?> _toWav16k(String inputPath) async {
    try {
      final dir = await mediaDir(); // persist so diarization can reuse it (W5)
      final out =
          p.join(dir.path, 'dec_${DateTime.now().millisecondsSinceEpoch}.wav');
      final session = await FFmpegKit.execute(
          '-y -i "$inputPath" -ar 16000 -ac 1 -c:a pcm_s16le "$out"');
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc) && File(out).existsSync()) return out;
      final log = (await session.getOutput()) ?? '';
      final lines =
          log.split('\n').where((l) => l.trim().isNotEmpty).toList();
      lastError = 'Audio decode failed (ffmpeg): '
          '${lines.isNotEmpty ? lines.last : 'return code $rc'}';
      return null;
    } catch (e) {
      lastError = 'Audio decode error: $e';
      return null;
    }
  }

  /// Drain the pending queue. Safe to call repeatedly (no-op if running).
  Future<void> pump(RecallDb db) async {
    if (_running) return;
    _running = true;
    // W9: recover any job left 'transcribing' by a killed session (no pump is
    // running here, so anything still 'transcribing' is stale) -> retry it.
    db.resetStuckTranscriptions();
    notifyListeners();
    try {
      while (true) {
        final pending = db.pendingAudioArtifacts();
        if (pending.isEmpty) break;
        final a = pending.first;
        activeArtifactId = a.id;
        db.setArtifactStatus(a.id, 'transcribing');
        notifyListeners();
        try {
          // whisper.cpp only reads 16 kHz mono WAV. Our own recordings already
          // are; imported audio (m4a/mp3/…) must be decoded first.
          var audioPath = a.filePath!;
          if (a.kind != 'recording' ||
              !audioPath.toLowerCase().endsWith('.wav')) {
            final wav = await _toWav16k(audioPath);
            if (wav == null) {
              throw Exception(lastError ?? 'Could not decode audio to WAV');
            }
            audioPath = wav;
            // W5: repoint the artifact at the decoded wav so diarization can read it.
            db.updateArtifactPath(a.id, wav);
          }
          final result = await _whisper.transcribe(
            model: model,
            audioPath: audioPath,
            lang: language,
          );
          final text = result?.transcription.text.trim() ?? '';
          if (text.isEmpty) {
            db.setArtifactStatus(a.id, 'failed');
            lastError = 'Empty transcription for artifact ${a.id}';
          } else {
            db.addTranscript(a.id, a.conversationId, text);
            db.setArtifactStatus(a.id, 'done');
            // Phase 2: hand the finished transcript to the extraction queue.
            db.queueExtraction(a.conversationId);
            // W5: diarize ALL audio now that imports are decoded to 16k wav —
            // produces "Who was Speaker N?" clarifications to confirm speakers.
            db.queueDiarization(a.id);
          }
        } catch (e) {
          db.setArtifactStatus(a.id, 'failed');
          lastError = e.toString();
        }
        activeArtifactId = null;
        notifyListeners();
      }
    } finally {
      _running = false;
      activeArtifactId = null;
      notifyListeners();
      // Chain: transcripts ready -> extract facts (no-op without API key)
      // and diarize recordings (no-op if nothing queued).
      // ignore: unawaited_futures
      ExtractionService.instance.pump(db);
      // ignore: unawaited_futures
      VoiceIdService.instance.pump(db);
    }
  }

  /// AC (US-5): failure surfaces a retry, never silent loss.
  Future<void> retry(RecallDb db, int artifactId) async {
    db.setArtifactStatus(artifactId, 'pending');
    await pump(db);
  }

  bool get isRunning => _running;
}
