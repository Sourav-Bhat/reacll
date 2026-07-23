import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/recorder_service.dart';
import '../services/voice_id_service.dart';

/// W15: read-a-paragraph voice enrollment. Records a clean sample of one
/// person's voice and stores it as a voice print for future auto-ID.
class EnrollVoiceScreen extends StatefulWidget {
  const EnrollVoiceScreen({super.key, required this.person});
  final Person person;

  @override
  State<EnrollVoiceScreen> createState() => _EnrollVoiceScreenState();
}

class _EnrollVoiceScreenState extends State<EnrollVoiceScreen> {
  static const _paragraph =
      'The clearest way to be remembered is to speak plainly. '
      'This short sample lets Recall learn my voice, so the next time we talk '
      'it can tell who is speaking without me tagging every name by hand.';

  final _rec = RecorderService.instance;
  Timer? _ticker;
  bool _recording = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    if (_rec.isActive) _rec.cancel();
    super.dispose();
  }

  String get _clock {
    final d = _rec.elapsed;
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _start() async {
    try {
      await _rec.start();
      _ticker =
          Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
      setState(() {
        _recording = true;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Microphone permission is needed.\n$e');
    }
  }

  Future<void> _stopAndEnroll() async {
    _ticker?.cancel();
    setState(() {
      _recording = false;
      _busy = true;
    });
    final (path, _) = await _rec.stop();
    if (path == null) {
      setState(() {
        _busy = false;
        _error = 'Recording failed — try again.';
      });
      return;
    }
    final err =
        await VoiceIdService.instance.enrollFromWav(db, widget.person.id, path);
    if (!mounted) return;
    if (err == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice enrolled for ${widget.person.name}')));
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text('Enroll ${widget.person.name}’s voice'),
          backgroundColor: Colors.transparent),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Read this aloud clearly',
                style: t.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(_paragraph,
                  style: t.textTheme.titleMedium?.copyWith(height: 1.55)),
            ),
            const Spacer(),
            if (_error != null) ...[
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall
                      ?.copyWith(color: t.colorScheme.error)),
              const SizedBox(height: 12),
            ],
            if (_busy)
              Column(children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text('Learning the voice…',
                    style: t.textTheme.bodyMedium
                        ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ])
            else if (_recording) ...[
              Text(_clock,
                  textAlign: TextAlign.center,
                  style: t.textTheme.displaySmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Recording… read the whole paragraph, then stop.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium
                      ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _stopAndEnroll,
                icon: const Icon(Icons.stop),
                label: const Text('Stop & enroll'),
              ),
            ] else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.mic),
                label: const Text('Start recording'),
              ),
          ],
        ),
      ),
    );
  }
}
