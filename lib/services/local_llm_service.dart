import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../db/database.dart';

/// W14: fully on-device LLM via flutter_gemma (MediaPipe LiteRT-LM). When the
/// provider is 'local', extraction/summary/Ask run here — nothing (not even
/// transcript text) leaves the phone.
///
/// Note: this is the heaviest native integration; the exact flutter_gemma API
/// (model URL, response type) may need one on-device iteration to finalize.
class LocalLlmService extends ChangeNotifier {
  LocalLlmService._();
  static final LocalLlmService instance = LocalLlmService._();

  static const settingModelUrl = 'gemma_model_url';
  static const settingHfToken = 'gemma_hf_token';
  static const settingInstalled = 'gemma_installed';

  /// A small, ungated Gemma 3 1B build (users can paste a different URL/token).
  static const defaultModelUrl =
      'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q8_ekv1280.task';

  double? downloadProgress; // 0..1 while downloading, null otherwise
  bool get isDownloading => downloadProgress != null;
  String? lastError;

  bool isInstalled(RecallDb db) => db.getSetting(settingInstalled) == '1';

  /// Download + install the model once. Returns true on success.
  Future<bool> download(RecallDb db) async {
    final urlSetting = db.getSetting(settingModelUrl)?.trim();
    final url = (urlSetting != null && urlSetting.isNotEmpty)
        ? urlSetting
        : defaultModelUrl;
    final token = db.getSetting(settingHfToken)?.trim();
    lastError = null;
    downloadProgress = 0;
    notifyListeners();
    try {
      void onProg(dynamic p) {
        downloadProgress = ((p.percentage as num?) ?? 0).toDouble() / 100.0;
        notifyListeners();
      }

      if (token != null && token.isNotEmpty) {
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromNetwork(url, token: token)
            .withProgress(onProg)
            .install();
      } else {
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromNetwork(url)
            .withProgress(onProg)
            .install();
      }
      db.setSetting(settingInstalled, '1');
      downloadProgress = null;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = 'Model download failed: $e';
      downloadProgress = null;
      notifyListeners();
      return false;
    }
  }

  /// Run one completion on-device. Returns raw model text.
  Future<String> complete(RecallDb db,
      {required String system, required String user}) async {
    if (!isInstalled(db)) {
      throw Exception('On-device Gemma model not downloaded (Settings → Local).');
    }
    final model = await FlutterGemma.getActiveModel(maxTokens: 2048);
    try {
      final chat = await model.createChat(systemInstruction: system);
      await chat.addQueryChunk(Message.text(text: user, isUser: true));
      final response = await chat.generateChatResponse();
      return response.toString();
    } finally {
      await model.close();
    }
  }
}
