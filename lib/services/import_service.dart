import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../db/database.dart';

/// One incoming item, normalized. Audio => needs transcription;
/// text => straight to transcripts (FR-3, skips whisper entirely).
class IncomingItem {
  final String kind; // 'audio' | 'text'
  final String? filePath; // audio file copied into app storage
  final String? text; // transcript text
  final String suggestedTitle;
  final DateTime? happenedAt; // W2: the file's real date, when known
  const IncomingItem({
    required this.kind,
    this.filePath,
    this.text,
    required this.suggestedTitle,
    this.happenedAt,
  });
}

/// FR-2 + FR-3: share-sheet and file-picker ingestion.
class ImportService {
  ImportService._();
  static final ImportService instance = ImportService._();

  final _controller = StreamController<IncomingItem>.broadcast();
  Stream<IncomingItem> get incoming => _controller.stream;
  StreamSubscription? _sub;

  static const _audioExt = {'.m4a', '.mp3', '.wav', '.aac', '.ogg', '.opus', '.flac'};

  /// Call once at app start: handles both cold-start share and while-running share.
  Future<void> init() async {
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    for (final f in initial) {
      await _handleShared(f);
    }
    ReceiveSharingIntent.instance.reset();
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen((files) async {
      for (final f in files) {
        await _handleShared(f);
      }
    });
  }

  Future<void> _handleShared(SharedMediaFile f) async {
    if (f.type == SharedMediaType.text) {
      final t = f.path; // for text shares, path carries the text payload
      if (t.trim().isNotEmpty) {
        _controller.add(IncomingItem(
          kind: 'text',
          text: t,
          suggestedTitle: 'Imported transcript',
        ));
      }
      return;
    }
    final ext = p.extension(f.path).toLowerCase();
    if (_audioExt.contains(ext)) {
      final when = await _fileDate(f.path);
      final copied = await _copyIntoMedia(f.path);
      _controller.add(IncomingItem(
        kind: 'audio',
        filePath: copied,
        suggestedTitle: p.basenameWithoutExtension(f.path),
        happenedAt: when,
      ));
    } else if (ext == '.txt' || ext == '.md' || ext == '.vtt' || ext == '.srt') {
      final text = await File(f.path).readAsString();
      _controller.add(IncomingItem(
        kind: 'text',
        text: text,
        suggestedTitle: p.basenameWithoutExtension(f.path),
        happenedAt: await _fileDate(f.path),
      ));
    }
  }

  /// Manual pick from the Add screen.
  Future<IncomingItem?> pickAudioFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = res?.files.single.path;
    if (path == null) return null;
    final when = await _fileDate(path);
    final copied = await _copyIntoMedia(path);
    return IncomingItem(
      kind: 'audio',
      filePath: copied,
      suggestedTitle: p.basenameWithoutExtension(path),
      happenedAt: when,
    );
  }

  /// W10: pick a transcript text file (.txt/.vtt/.srt/.md) from storage.
  Future<IncomingItem?> pickTranscriptFile() async {
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['txt', 'vtt', 'srt', 'md']);
    final path = res?.files.single.path;
    if (path == null) return null;
    final text = await File(path).readAsString();
    if (text.trim().isEmpty) return null;
    return IncomingItem(
      kind: 'text',
      text: text,
      suggestedTitle: p.basenameWithoutExtension(path),
      happenedAt: await _fileDate(path),
    );
  }

  /// The file's last-modified date, or null if unavailable.
  Future<DateTime?> _fileDate(String path) async {
    try {
      return await File(path).lastModified();
    } catch (_) {
      return null;
    }
  }

  Future<String> _copyIntoMedia(String src) async {
    final dir = await mediaDir();
    // Sanitize the name: spaces/special chars in the path break whisper_ggml's
    // internal ffmpeg conversion (unquoted command). Keep only safe chars.
    final safe = p.basename(src).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final dest =
        p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}_$safe');
    await File(src).copy(dest);
    return dest;
  }

  /// FR-4: attach an incoming item to a conversation (new or existing).
  /// Returns (conversationId, needsTranscription).
  (int, bool) attach(RecallDb db, IncomingItem item, {int? conversationId}) {
    final isNew = conversationId == null;
    final convId = conversationId ??
        db.createConversation(
            title: item.suggestedTitle, happenedAt: item.happenedAt);
    if (isNew) db.tagPerson(convId, db.mePersonId()); // W1: I'm always present
    if (item.kind == 'audio') {
      db.addArtifact(convId, 'imported_audio',
          filePath: item.filePath, status: 'pending');
      return (convId, true);
    } else {
      final artId =
          db.addArtifact(convId, 'transcript', status: 'done');
      db.addTranscript(artId, convId, item.text!);
      // Phase 2: imported transcripts go straight to extraction.
      db.queueExtraction(convId);
      return (convId, false);
    }
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
