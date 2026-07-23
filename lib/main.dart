import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'db/database.dart';
import 'screens/home_shell.dart';
import 'services/import_service.dart';
import 'services/local_llm_service.dart';
import 'services/transcription_service.dart';
import 'theme.dart';

late RecallDb db;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await RecallDb.open();
  // W14: flutter_gemma must be initialized before any on-device model use.
  // Pass a saved HF token (only needed for gated models like Gemma).
  try {
    FlutterGemma.initialize(
      huggingFaceToken: db.getSetting(LocalLlmService.settingHfToken) ?? '',
      maxDownloadRetries: 5,
    );
  } catch (_) {
    // Non-fatal: local provider just won't be available until fixed.
  }
  await ImportService.instance.init();
  // Warm the whisper model in the background; don't block first frame.
  // ignore: unawaited_futures
  TranscriptionService.instance.ensureModelReady();
  // Pick up anything left half-done from a previous session.
  // ignore: unawaited_futures
  TranscriptionService.instance.pump(db);
  runApp(const RecallApp());
}

class RecallApp extends StatelessWidget {
  const RecallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Recall',
      debugShowCheckedModeBanner: false,
      theme: recallTheme(Brightness.light),
      darkTheme: recallTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
