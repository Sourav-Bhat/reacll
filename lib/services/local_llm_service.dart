import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../db/database.dart';

/// One downloadable on-device model.
class LocalModel {
  final String id;
  final String label;
  final String size;
  final String url;
  final ModelType type;
  final bool gated; // true => needs a free Hugging Face token (Gemma license)
  const LocalModel(
      this.id, this.label, this.size, this.url, this.type, this.gated);
}

/// W14: fully on-device LLM via flutter_gemma (MediaPipe LiteRT-LM). When the
/// provider is 'local', extraction/summary/Ask run here — nothing leaves the
/// phone. Models are picked from a curated list and downloaded directly; the
/// defaults are ungated (no token, one tap), like the AI Edge Gallery.
class LocalLlmService extends ChangeNotifier {
  LocalLlmService._();
  static final LocalLlmService instance = LocalLlmService._();

  static const settingModelId = 'local_model_id';
  static const settingInstalledModel = 'local_installed_model';
  static const settingHfToken = 'gemma_hf_token';

  /// Curated, verified models. Qwen/SmolLM are Apache/MIT — ungated, so they
  /// download with NO token. Gemma is gated by Google's license (needs a free
  /// HF token), offered only for users who want it.
  static const models = <LocalModel>[
    LocalModel(
      'qwen05',
      'Qwen 2.5 · 0.5B — fast, balanced (recommended)',
      '~0.6 GB · no sign-in',
      'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
      ModelType.qwen,
      false,
    ),
    LocalModel(
      'qwen15',
      'Qwen 2.5 · 1.5B — best quality',
      '~1.6 GB · no sign-in',
      'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_seq128_q8_ekv1280.task',
      ModelType.qwen,
      false,
    ),
    LocalModel(
      'smol135',
      'SmolLM · 135M — tiny (low-end / testing)',
      '~0.15 GB · no sign-in',
      'https://huggingface.co/litert-community/SmolLM-135M-Instruct/resolve/main/SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task',
      ModelType.general,
      false,
    ),
    LocalModel(
      'gemma1b',
      'Gemma 3 · 1B — needs a free HF token',
      '~0.5 GB · sign-in',
      'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.task',
      ModelType.gemmaIt,
      true,
    ),
  ];

  double? downloadProgress; // 0..1 while downloading, null otherwise
  bool get isDownloading => downloadProgress != null;
  String? lastError;

  LocalModel selectedModel(RecallDb db) {
    final id = db.getSetting(settingModelId) ?? models.first.id;
    return models.firstWhere((m) => m.id == id, orElse: () => models.first);
  }

  bool isInstalled(RecallDb db) =>
      db.getSetting(settingInstalledModel) == selectedModel(db).id;

  Future<bool> download(RecallDb db) async {
    final m = selectedModel(db);
    final token = db.getSetting(settingHfToken)?.trim();
    lastError = null;
    downloadProgress = 0;
    notifyListeners();
    try {
      // Gated models (Gemma) need the HF token wired into the plugin before the
      // download request is made.
      if (m.gated && token != null && token.isNotEmpty) {
        try {
          FlutterGemma.initialize(
              huggingFaceToken: token, maxDownloadRetries: 5);
        } catch (_) {}
      }
      // flutter_gemma passes the percent (0-100) as a plain number.
      void onProg(dynamic p) {
        final pct = (p is num) ? p.toDouble() : 0.0;
        downloadProgress = (pct / 100.0).clamp(0.0, 1.0);
        notifyListeners();
      }

      if (m.gated && token != null && token.isNotEmpty) {
        await FlutterGemma.installModel(modelType: m.type)
            .fromNetwork(m.url, token: token)
            .withProgress(onProg)
            .install();
      } else {
        await FlutterGemma.installModel(modelType: m.type)
            .fromNetwork(m.url)
            .withProgress(onProg)
            .install();
      }
      db.setSetting(settingInstalledModel, m.id);
      downloadProgress = null;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = 'Download failed: $e';
      downloadProgress = null;
      notifyListeners();
      return false;
    }
  }

  /// Run one completion on-device. Returns raw model text.
  Future<String> complete(RecallDb db,
      {required String system, required String user}) async {
    if (!isInstalled(db)) {
      throw Exception('On-device model not downloaded (Settings → Local).');
    }
    final model = await FlutterGemma.getActiveModel(maxTokens: 2048);
    try {
      final chat = await model.createChat(systemInstruction: system);
      await chat.addQueryChunk(Message.text(text: user, isUser: true));
      // Stream the response and accumulate text tokens (documented API).
      final buffer = StringBuffer();
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) buffer.write(r.token);
      }
      return buffer.toString().trim();
    } finally {
      await model.close();
    }
  }
}
