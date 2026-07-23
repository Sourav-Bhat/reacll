import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/recorder_service.dart';
import '../services/transcription_service.dart';
import 'tag_screen.dart';

/// FR-1: big timer, pause/resume, stop -> saves artifact -> tag flow.
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  final _rec = RecorderService.instance;
  Timer? _ticker;
  bool _paused = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _rec.start();
      _ticker = Timer.periodic(
          const Duration(seconds: 1), (_) => setState(() {}));
    } catch (e) {
      setState(() => _error = 'Microphone permission is needed to record.\n$e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _clock {
    final d = _rec.elapsed;
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _stopAndSave() async {
    _ticker?.cancel();
    final (path, duration) = await _rec.stop();
    if (!mounted) return;
    if (path == null) {
      Navigator.of(context).pop();
      return;
    }
    final convId = db.createConversation(durationSec: duration.inSeconds);
    db.tagPerson(convId, db.mePersonId()); // W1: I'm always in my own recordings
    db.addArtifact(convId, 'recording', filePath: path, status: 'pending');
    // Transcribe in background; user goes straight to the 10-second tag flow.
    // ignore: unawaited_futures
    TranscriptionService.instance.pump(db);
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => TagScreen(conversationId: convId)),
    );
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    await _rec.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Back')),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 148,
                          height: 148,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              t.colorScheme.primary,
                              t.colorScheme.primary.withValues(alpha: .75),
                            ]),
                            borderRadius: BorderRadius.circular(56),
                          ),
                          child: Icon(
                              _paused ? Icons.pause : Icons.mic,
                              size: 56, color: Colors.white),
                        ),
                        const SizedBox(height: 28),
                        Text(_clock,
                            style: t.textTheme.displayMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontFeatures: const [])),
                        const SizedBox(height: 14),
                        Text(
                          _paused
                              ? 'Paused'
                              : 'Recording…\nPut the phone on the table and talk normally.',
                          textAlign: TextAlign.center,
                          style: t.textTheme.bodyLarge?.copyWith(
                              color: t.colorScheme.onSurfaceVariant,
                              height: 1.5),
                        ),
                        const SizedBox(height: 22),
                        IconButton.filledTonal(
                          iconSize: 30,
                          onPressed: () async {
                            if (_paused) {
                              await _rec.resume();
                            } else {
                              await _rec.pause();
                            }
                            setState(() => _paused = !_paused);
                          },
                          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 0, 26, 40),
                    child: Row(children: [
                      Expanded(
                        child: OutlinedButton(
                            onPressed: _cancel, child: const Text('Cancel')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                            onPressed: _stopAndSave,
                            child: const Text('■ Stop & Save')),
                      ),
                    ]),
                  ),
                ],
              ),
      ),
    );
  }
}
