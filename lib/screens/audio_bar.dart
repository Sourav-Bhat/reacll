import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Compact playback bar for an audio artifact (recorded or imported).
class AudioBar extends StatefulWidget {
  const AudioBar({super.key, required this.path});
  final String path;

  @override
  State<AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<AudioBar> {
  final _player = AudioPlayer();
  Duration _dur = Duration.zero;
  Duration _pos = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.path));
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final maxMs = _dur.inMilliseconds.toDouble();
    final valMs =
        _pos.inMilliseconds.clamp(0, _dur.inMilliseconds).toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        IconButton(
          icon: Icon(
              _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              size: 34,
              color: t.colorScheme.primary),
          onPressed: _toggle,
        ),
        Expanded(
          child: Slider(
            value: maxMs > 0 ? valMs : 0,
            max: maxMs > 0 ? maxMs : 1,
            onChanged: (v) => _player.seek(Duration(milliseconds: v.round())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(_fmt(_pos), style: t.textTheme.labelSmall),
        ),
      ]),
    );
  }
}
