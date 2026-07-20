import 'package:flutter/material.dart';

import '../main.dart';
import '../services/backup_service.dart';
import '../services/import_service.dart';
import '../services/transcription_service.dart';
import 'attach_picker.dart';
import 'tag_screen.dart';

/// FR-2/FR-3 manual entry points + FR-8 backup.
class AddScreen extends StatelessWidget {
  const AddScreen({super.key, required this.onImported});
  final VoidCallback onImported;

  Future<void> _importAudio(BuildContext context) async {
    final item = await ImportService.instance.pickAudioFile();
    if (item == null || !context.mounted) return;
    await _attachAndTag(context, item);
  }

  Future<void> _pasteTranscript(BuildContext context) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste transcript'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 10,
          decoration: const InputDecoration(
              hintText: 'Paste the transcript text here…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('Import')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    await _attachAndTag(
        context,
        IncomingItem(
            kind: 'text', text: text, suggestedTitle: 'Imported transcript'));
  }

  Future<void> _attachAndTag(BuildContext context, IncomingItem item) async {
    final existingId = await showAttachPicker(context, db);
    if (!context.mounted) return;
    final (convId, needsTx) =
        ImportService.instance.attach(db, item, conversationId: existingId);
    if (needsTx) {
      // ignore: unawaited_futures
      TranscriptionService.instance.pump(db);
    }
    if (existingId == null) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TagScreen(conversationId: convId)));
    }
    onImported();
  }

  Future<void> _backup(BuildContext context) async {
    final ctl = TextEditingController();
    final pass = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
              hintText: 'Choose a passphrase you will remember'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('Encrypt')),
        ],
      ),
    );
    if (pass == null || pass.length < 6) {
      if (context.mounted && pass != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Passphrase must be at least 6 characters.')));
      }
      return;
    }
    final path =
        await BackupService.instance.export(db.databasePath(), pass);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Encrypted backup saved:\n$path\n'
            'Share it to Google Drive from your files app.'),
        duration: const Duration(seconds: 6),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget tile(IconData ic, Color bg, String title, String sub,
            VoidCallback onTap) =>
        Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Container(
                  width: 54, height: 54,
                  decoration: BoxDecoration(
                      color: bg, borderRadius: BorderRadius.circular(19)),
                  child: Icon(ic, color: t.colorScheme.primary, size: 26),
                ),
                const SizedBox(width: 17),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: t.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(sub,
                          style: t.textTheme.bodySmall?.copyWith(
                              color: t.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        );

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 120),
        children: [
          Text('Add', style: t.textTheme.headlineMedium),
          const SizedBox(height: 2),
          Text('Bring in old recordings or notes.',
              style: t.textTheme.bodyMedium
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 18),
          tile(Icons.music_note, t.colorScheme.surfaceContainerHighest,
              'Audio file', 'From Google Recorder, Voice Memos…',
              () => _importAudio(context)),
          const SizedBox(height: 12),
          tile(Icons.description_outlined, const Color(0xFFE4EBE0),
              'Paste a transcript', 'Copied from Teams, or any text',
              () => _pasteTranscript(context)),
          const SizedBox(height: 12),
          tile(Icons.lock_outline, t.colorScheme.surfaceContainerHighest,
              'Encrypted backup', 'One file, AES-256 — put it in Drive',
              () => _backup(context)),
          const SizedBox(height: 30),
          Center(
            child: Text(
              'Everything you add becomes searchable.\nYour app · your phone · your data.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(
                  color: t.colorScheme.onSurfaceVariant, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
