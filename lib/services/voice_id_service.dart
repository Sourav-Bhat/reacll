import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../db/database.dart';

/// Phase 3 (FR-14/15/16): on-device diarization + voice identity.
/// Everything runs locally via sherpa-onnx; audio never leaves the device.
class VoiceIdService extends ChangeNotifier {
  VoiceIdService._();
  static final VoiceIdService instance = VoiceIdService._();

  // ---- FR-16 thresholds (S-3 spike may tune these) ----
  static const double autoIdThreshold = 0.60; // >= : auto-link + tag
  static const double confirmThreshold = 0.40; // in [confirm, auto): ask
  static const int minClusterMs = 4000; // ignore tiny clusters (noise)

  // Models (k2-fsa release assets). Downloaded once, ~90 MB total.
  static const _segUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';
  static const _embUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx';

  bool _running = false;
  bool get isRunning => _running;
  String? lastError;

  // ---------------- pure matching math (unit-tested via Python mirror) ----------------

  static double cosine(Float32List a, Float32List b) {
    assert(a.length == b.length);
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    final denom = _sqrt(na) * _sqrt(nb);
    return dot / denom;
  }

  static double _sqrt(double x) {
    // Newton's method — avoids importing dart:math into this hot loop file.
    if (x <= 0) return 0;
    double g = x;
    for (var i = 0; i < 24; i++) {
      g = 0.5 * (g + x / g);
    }
    return g;
  }

  /// Best match for a cluster embedding against enrolled prints.
  /// Returns (personId, score) of the best-scoring print, or (null, best).
  static (int?, double) matchPrints(
      Float32List emb, List<(int, Float32List)> prints) {
    int? best;
    double bestScore = -1;
    for (final (personId, print_) in prints) {
      if (print_.length != emb.length) continue;
      final s = cosine(emb, print_);
      if (s > bestScore) {
        bestScore = s;
        best = personId;
      }
    }
    return (best, bestScore);
  }

  /// Mean of segment embeddings weighted by duration.
  static Float32List meanEmbedding(List<(Float32List, int)> parts) {
    final dim = parts.first.$1.length;
    final acc = List<double>.filled(dim, 0);
    var total = 0;
    for (final (e, ms) in parts) {
      for (var i = 0; i < dim; i++) {
        acc[i] += e[i] * ms;
      }
      total += ms;
    }
    final out = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      out[i] = total == 0 ? 0 : acc[i] / total;
    }
    return out;
  }

  static Uint8List embToBlob(Float32List e) => e.buffer.asUint8List().sublist(0);
  static Float32List blobToEmb(Uint8List b, int dim) =>
      b.buffer.asFloat32List(b.offsetInBytes, dim);

  // ---------------- 16-bit PCM mono wav reader (our recorder's format) ----------------

  static Float32List readWavMono16(Uint8List bytes) {
    // Find the 'data' chunk (RIFF little-endian).
    final bd = ByteData.sublistView(bytes);
    var off = 12;
    while (off + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(off, off + 4));
      final size = bd.getUint32(off + 4, Endian.little);
      if (id == 'data') {
        final n = size ~/ 2;
        final out = Float32List(n);
        for (var i = 0; i < n; i++) {
          out[i] = bd.getInt16(off + 8 + i * 2, Endian.little) / 32768.0;
        }
        return out;
      }
      off += 8 + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('No data chunk in wav');
  }

  // ---------------- model management ----------------

  Future<Directory> _modelDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'models'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<(String, String)?> _ensureModels() async {
    final dir = await _modelDir();
    final segPath = p.join(dir.path, 'pyannote-segmentation-3-0.onnx');
    final embPath = p.join(dir.path, 'eres2net-base-sv-16k.onnx');
    try {
      if (!File(embPath).existsSync()) {
        final r = await http.get(Uri.parse(_embUrl));
        if (r.statusCode != 200) throw Exception('embedding model HTTP ${r.statusCode}');
        await File(embPath).writeAsBytes(r.bodyBytes);
      }
      if (!File(segPath).existsSync()) {
        final r = await http.get(Uri.parse(_segUrl));
        if (r.statusCode != 200) throw Exception('segmentation model HTTP ${r.statusCode}');
        final tar = BZip2Decoder().decodeBytes(r.bodyBytes);
        final files = TarDecoder().decodeBytes(tar);
        final onnx = files.files.firstWhere((f) => f.name.endsWith('model.onnx'));
        await File(segPath).writeAsBytes(onnx.content as List<int>);
      }
      return (segPath, embPath);
    } catch (e) {
      lastError = 'Model download failed: $e';
      return null;
    }
  }

  // ---------------- pipeline (FR-14 -> FR-16) ----------------

  /// Diarize all pending 'recording' artifacts. Never blocks transcripts:
  /// any failure -> status 'failed'/'skipped' and we move on.
  Future<void> pump(RecallDb db) async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      final pending = db.pendingDiarizations();
      if (pending.isEmpty) return;
      final models = await _ensureModels();
      for (final a in pending) {
        if (models == null) {
          db.setDiarizationStatus(a.id, 'skipped', error: lastError);
          continue;
        }
        db.setDiarizationStatus(a.id, 'running');
        notifyListeners();
        try {
          await _diarizeArtifact(db, a.id, a.conversationId, a.filePath!,
              models.$1, models.$2);
          db.setDiarizationStatus(a.id, 'done');
        } catch (e) {
          db.setDiarizationStatus(a.id, 'failed', error: e.toString());
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _diarizeArtifact(RecallDb db, int artifactId, int convId,
      String wavPath, String segModel, String embModel) async {
    sherpa.initBindings();
    final samples = readWavMono16(await File(wavPath).readAsBytes());

    final sd = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote:
              sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(model: segModel),
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(model: embModel),
        clustering: sherpa.FastClusteringConfig(numClusters: -1, threshold: 0.5),
        minDurationOn: 0.3,
        minDurationOff: 0.5,
      ),
    );
    final segs = sd.process(samples: samples);
    sd.free();

    if (segs.isEmpty) return;

    // Store segments; group by speaker for cluster embeddings.
    final bySpeaker = <int, List<(int, int)>>{};
    for (final s in segs) {
      final startMs = (s.start * 1000).round();
      final endMs = (s.end * 1000).round();
      db.addSegment(artifactId, convId, s.speaker, startMs, endMs);
      bySpeaker.putIfAbsent(s.speaker, () => []).add((startMs, endMs));
    }

    // Compute a duration-weighted mean embedding per speaker cluster.
    final ex = sherpa.SpeakerEmbeddingExtractor(
        config: sherpa.SpeakerEmbeddingExtractorConfig(model: embModel));
    final prints = db.voicePrints();
    for (final entry in bySpeaker.entries) {
      final parts = <(Float32List, int)>[];
      var totalMs = 0;
      for (final (s0, s1) in entry.value) {
        final ms = s1 - s0;
        if (ms < 1000) continue; // too short to embed reliably
        final st = ex.createStream();
        st.acceptWaveform(
            samples: Float32List.sublistView(
                samples, (s0 * 16).clamp(0, samples.length),
                (s1 * 16).clamp(0, samples.length)),
            sampleRate: 16000);
        st.inputFinished();
        parts.add((ex.compute(st), ms));
        st.free();
        totalMs += ms;
      }
      if (parts.isEmpty || totalMs < minClusterMs) continue;
      final mean = meanEmbedding(parts);
      db.addSpeakerCluster(convId, entry.key, embToBlob(mean), mean.length, totalMs);

      // FR-16: match against enrolled prints.
      final (personId, score) = matchPrints(mean, prints);
      if (personId != null && score >= autoIdThreshold) {
        db.linkSpeaker(convId, entry.key, personId, score);
        db.tagPerson(convId, personId); // auto-tag the conversation
      } else if (personId != null && score >= confirmThreshold) {
        db.addClarification(convId,
            'Was Speaker ${entry.key + 1} ${db.personName(personId)}?',
            reason: 'Voice match ${(score * 100).round()}% — please confirm',
            kind: 'speaker', speakerLabel: entry.key);
      } else {
        db.addClarification(convId, 'Who was Speaker ${entry.key + 1}?',
            reason: 'New voice — answering enrolls it for future recordings',
            kind: 'speaker', speakerLabel: entry.key);
      }
    }
    ex.free();
  }

  /// FR-15: enrollment through the clarification answer. Stores the cluster
  /// embedding as a voice print, links segments, tags the conversation.
  void enrollSpeaker(RecallDb db, int conversationId, int speakerLabel,
      int personId) {
    final cluster = db.speakerCluster(conversationId, speakerLabel);
    if (cluster != null) {
      db.addVoicePrint(personId, cluster.$1, cluster.$2,
          sourceConversationId: conversationId);
    }
    db.linkSpeaker(conversationId, speakerLabel, personId, 1.0);
    db.tagPerson(conversationId, personId);
  }

  /// W15: read-a-paragraph enrollment. Computes one embedding over a clean
  /// single-speaker wav clip and stores it as a voice print. Returns an error
  /// string, or null on success. (Same embedding path as diarization.)
  Future<String?> enrollFromWav(RecallDb db, int personId, String wavPath) async {
    try {
      final models = await _ensureModels();
      if (models == null) return lastError ?? 'Voice models unavailable';
      sherpa.initBindings();
      final samples = readWavMono16(await File(wavPath).readAsBytes());
      if (samples.length < 16000) return 'Too short — record at least a sentence.';
      final ex = sherpa.SpeakerEmbeddingExtractor(
          config: sherpa.SpeakerEmbeddingExtractorConfig(model: models.$2));
      final st = ex.createStream();
      st.acceptWaveform(samples: samples, sampleRate: 16000);
      st.inputFinished();
      final emb = ex.compute(st);
      st.free();
      ex.free();
      db.addVoicePrint(personId, embToBlob(emb), emb.length);
      return null;
    } catch (e) {
      return 'Enrollment failed: $e';
    }
  }
}
