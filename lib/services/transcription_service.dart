import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// tiny = fast first-run default; user can switch to small in settings later.
  WhisperModel model = WhisperModel.base;
  String language = 'en';

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

  /// Drain the pending queue. Safe to call repeatedly (no-op if running).
  Future<void> pump(RecallDb db) async {
    if (_running) return;
    _running = true;
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
          final result = await _whisper.transcribe(
            model: model,
            audioPath: a.filePath!,
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
            // Phase 3: diarize our own wav recordings (imported audio formats
            // are not diarized in v3 — documented limitation).
            if (a.kind == 'recording') db.queueDiarization(a.id);
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
