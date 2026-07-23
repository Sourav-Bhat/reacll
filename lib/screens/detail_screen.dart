import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import '../services/extraction_service.dart';
import '../services/transcription_service.dart';
import '../services/voice_id_service.dart';
import 'audio_bar.dart';
import 'people_screen.dart';
import 'person_form.dart';
import 'tag_screen.dart';

/// W13: a conversation opens to two tabs — Memory (structured breakdown) and
/// Transcript.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.conversationId});
  final int conversationId;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  @override
  void initState() {
    super.initState();
    TranscriptionService.instance.addListener(_onTx);
    ExtractionService.instance.addListener(_onTx);
    VoiceIdService.instance.addListener(_onTx);
  }

  @override
  void dispose() {
    TranscriptionService.instance.removeListener(_onTx);
    ExtractionService.instance.removeListener(_onTx);
    VoiceIdService.instance.removeListener(_onTx);
    super.dispose();
  }

  void _onTx() {
    if (mounted) setState(() {});
  }

  // ---------------- person picker + actions ----------------

  Future<int?> _pickPerson(String title) {
    final people = db.peopleList();
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ...people.map((p) => ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(p.name),
                  subtitle: p.subtitle != null ? Text(p.subtitle!) : null,
                  onTap: () => Navigator.pop(context, p.id),
                )),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('New contact…'),
              onTap: () async {
                final id = await showPersonForm(context);
                if (context.mounted) Navigator.pop(context, id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _answerSpeaker(Clarification q) async {
    final personId = await _pickPerson(q.question);
    if (personId != null && q.speakerLabel != null) {
      VoiceIdService.instance
          .enrollSpeaker(db, widget.conversationId, q.speakerLabel!, personId);
      db.answerClarification(q.id, db.personName(personId));
      setState(() {});
    }
  }

  Future<void> _assignFact(Fact f) async {
    final personId = await _pickPerson('Assign to…');
    if (personId != null) {
      db.linkFactPerson(f.id, personId);
      db.tagPerson(widget.conversationId, personId, role: 'mentioned');
      setState(() {});
    }
  }

  Future<void> _answerClarification(int id) async {
    final ctl = TextEditingController();
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add context'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Type your answer…')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (answer != null && answer.trim().isNotEmpty) {
      ExtractionService.instance
          .answerAsFact(db, id, widget.conversationId, answer.trim());
      setState(() {});
    }
  }

  Future<void> _deleteConversation() async {
    final t = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
            'Removes the recording, transcript and everything extracted from '
            'it. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      db.deleteConversation(widget.conversationId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _editNotes(String? current) async {
    final ctl = TextEditingController(text: current ?? '');
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notes'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 6,
          decoration: const InputDecoration(
              hintText: 'Your own notes about this conversation…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != null) {
      db.setConversationNotes(widget.conversationId, saved);
      setState(() {});
    }
  }

  // ---------------- small building blocks ----------------

  Widget _sectionHeader(ThemeData t, String label, Color color) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Text(label.toUpperCase(),
              style: t.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5,
                  color: t.colorScheme.onSurfaceVariant)),
        ]),
      );

  Widget _factRow(ThemeData t, Fact f) {
    final who = f.resolvedName ?? f.personName;
    return InkWell(
      onTap: () => _assignFact(f),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: t.colorScheme.surface,
            border: Border.all(color: t.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((f.kind == 'commitment' ? '☐  ' : '') + f.text,
                  style: t.textTheme.bodyMedium?.copyWith(height: 1.45)),
              if (who != null || f.dueHint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    if (who != null)
                      Text('— $who',
                          style: t.textTheme.labelMedium?.copyWith(
                              color: t.colorScheme.primary,
                              fontWeight: FontWeight.w700)),
                    if (f.dueHint != null)
                      Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: const Color(0xFFF5EBD6),
                              borderRadius: BorderRadius.circular(10)),
                          child: Text('due ${f.dueHint}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFB98A2F)))),
                  ]),
                ),
            ]),
          ),
          const SizedBox(width: 6),
          Icon(f.resolvedName != null ? Icons.person : Icons.person_add_alt,
              size: 16,
              color: f.resolvedName != null
                  ? t.colorScheme.secondary
                  : t.colorScheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  // ---------------- tabs ----------------

  Widget _transcriptTab(
      ThemeData t, ConversationDetail d, bool busy, List<Artifact> failed) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 40),
      children: [
        // Listen back to the recorded/imported audio.
        Builder(builder: (context) {
          final audio = d.artifacts
              .where((a) =>
                  (a.kind == 'recording' || a.kind == 'imported_audio') &&
                  a.filePath != null)
              .toList();
          if (audio.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: AudioBar(path: audio.first.filePath!),
          );
        }),
        if (busy)
          Card(
            child: ListTile(
              leading: const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              title: const Text('Transcribing on your phone…'),
              subtitle: const Text('Your audio never leaves the device.'),
            ),
          ),
        ...failed.map((a) => Card(
              child: ListTile(
                isThreeLine: TranscriptionService.instance.lastError != null,
                leading: Icon(Icons.error_outline, color: t.colorScheme.error),
                title: const Text('Transcription failed'),
                subtitle: TranscriptionService.instance.lastError != null
                    ? Text(TranscriptionService.instance.lastError!,
                        style: t.textTheme.bodySmall)
                    : null,
                trailing: SizedBox(
                  width: 85,
                  child: FilledButton.tonal(
                    onPressed: () async {
                      await TranscriptionService.instance.retry(db, a.id);
                      if (mounted) setState(() {});
                    },
                    child: const Text('Retry'),
                  ),
                ),
              ),
            )),
        if (d.transcriptText.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Full transcript',
                  style: t.textTheme.labelMedium
                      ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: d.transcriptText));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Transcript copied')));
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.only(left: 14),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: t.colorScheme.primary.withValues(alpha: .35),
                    width: 2.5),
              ),
            ),
            child: Text(d.transcriptText,
                style: t.textTheme.bodyLarge?.copyWith(height: 1.65)),
          ),
        ] else if (!busy && failed.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 30),
            child: Text('No transcript yet.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodyLarge
                    ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }

  Widget _memoryTab(
      ThemeData t, ConversationDetail d, bool busy, List<Artifact> failed) {
    final facts = db.conversationFacts(d.id);
    List<Fact> byKind(String k) => facts.where((f) => f.kind == k).toList();
    final decisions = byKind('decision');
    final commitments = byKind('commitment');
    final threads = byKind('thread');
    final keyfacts = byKind('fact');
    final clars = db.openClarifications(d.id);
    final speakers = db.conversationSpeakers(d.id);
    final extractStatus = db.extractionStatus(d.id);
    final hasMemory =
        d.summary != null || facts.isNotEmpty || clars.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 40),
      children: [
        // meta + bucket + tags
        Text(
          '${DateFormat('EEE d MMM y · HH:mm').format(d.happenedAt)}'
          '${d.durationSec > 0 ? ' · ${(d.durationSec / 60).round()} min' : ''}',
          style: t.textTheme.bodyMedium
              ?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (d.bucket != null)
            Chip(
              label: Text(d.bucket!),
              backgroundColor: const Color(0xFFF5EBD6),
              labelStyle: const TextStyle(
                  color: Color(0xFFB98A2F), fontWeight: FontWeight.w700),
              visualDensity: VisualDensity.compact,
            ),
          ...d.topics.map((tp) => Chip(
                label: Text('#$tp'),
                backgroundColor: Colors.transparent,
                side: BorderSide(color: t.colorScheme.outlineVariant),
                labelStyle: TextStyle(color: t.colorScheme.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
              )),
        ]),

        // participants
        const SizedBox(height: 8),
        if (d.people.isNotEmpty || d.mentioned.isNotEmpty)
          Text('Attended',
              style: t.textTheme.labelMedium
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          ...d.people.map((p) => GestureDetector(
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PersonScreen(person: p)));
                  setState(() {});
                },
                child: Chip(
                  label: Text(p.label),
                  backgroundColor: t.colorScheme.surfaceContainerHighest,
                  labelStyle: TextStyle(
                      color: t.colorScheme.primary, fontWeight: FontWeight.w700),
                  visualDensity: VisualDensity.compact,
                ),
              )),
          ActionChip(
            label: const Text('Edit tags'),
            avatar: const Icon(Icons.edit, size: 16),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TagScreen(conversationId: d.id)));
              setState(() {});
            },
            visualDensity: VisualDensity.compact,
          ),
        ]),
        if (d.mentioned.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Mentioned',
              style: t.textTheme.labelMedium
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: d.mentioned
                .map((p) => GestureDetector(
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PersonScreen(person: p)));
                        setState(() {});
                      },
                      child: Chip(
                        avatar: const Icon(Icons.alternate_email, size: 14),
                        label: Text(p.label),
                        backgroundColor: t.colorScheme.surface,
                        side: BorderSide(color: t.colorScheme.outlineVariant),
                        labelStyle: TextStyle(
                            color: t.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600),
                        visualDensity: VisualDensity.compact,
                      ),
                    ))
                .toList(),
          ),
        ],

        // notes
        const SizedBox(height: 14),
        InkWell(
          onTap: () => _editNotes(d.notes),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.sticky_note_2_outlined,
                  size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  (d.notes == null || d.notes!.isEmpty)
                      ? 'Add your notes…'
                      : d.notes!,
                  style: t.textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                      color: (d.notes == null || d.notes!.isEmpty)
                          ? t.colorScheme.onSurfaceVariant
                          : t.colorScheme.onSurface),
                ),
              ),
              Icon(Icons.edit, size: 15, color: t.colorScheme.onSurfaceVariant),
            ]),
          ),
        ),

        // transcription status
        if (busy) ...[
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              title: const Text('Transcribing on your phone…'),
              subtitle: const Text('Memory appears once the transcript is ready.'),
            ),
          ),
        ],

        // speakers
        if (speakers.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: speakers.map((s) {
              final mins = (s.talkMs / 60000).round();
              final label = s.name ?? 'Speaker ${s.label + 1}';
              final known = s.name != null;
              return Chip(
                avatar: Icon(
                    known ? Icons.verified_user_outlined : Icons.help_outline,
                    size: 16,
                    color: known
                        ? t.colorScheme.secondary
                        : t.colorScheme.onSurfaceVariant),
                label: Text('$label · ${mins}m'),
                backgroundColor: known
                    ? const Color(0xFFE4EBE0)
                    : t.colorScheme.surfaceContainerHighest,
                labelStyle:
                    t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],

        // clarifications
        if (clars.isNotEmpty) ...[
          _sectionHeader(t, 'Clarifications needed · ${clars.length}',
              const Color(0xFF4E6B4A)),
          ...clars.map((q) => Card(
                color: const Color(0xFFE6EDE2),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(q.question,
                          style: t.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (q.reason != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(q.reason!,
                              style: t.textTheme.bodySmall?.copyWith(
                                  color: t.colorScheme.onSurfaceVariant)),
                        ),
                      Row(children: [
                        TextButton(
                            onPressed: () => q.kind == 'speaker'
                                ? _answerSpeaker(q)
                                : _answerClarification(q.id),
                            child: Text(q.kind == 'speaker'
                                ? 'Pick person'
                                : 'Answer')),
                        TextButton(
                            onPressed: () {
                              db.dismissClarification(q.id);
                              setState(() {});
                            },
                            child: const Text('Dismiss')),
                      ]),
                    ],
                  ),
                ),
              )),
        ],

        // summary
        if (d.summary != null) ...[
          _sectionHeader(t, 'Summary', const Color(0xFF1D1C18)),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.colorScheme.surface,
              border: Border(
                  left: BorderSide(color: t.colorScheme.primary, width: 3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(d.summary!,
                style: t.textTheme.bodyMedium?.copyWith(height: 1.6)),
          ),
        ],

        // decisions / commitments / threads / facts
        if (decisions.isNotEmpty) ...[
          _sectionHeader(t, 'Decisions · ${decisions.length}',
              const Color(0xFF5C6E8C)),
          ...decisions.map((f) => _factRow(t, f)),
        ],
        if (commitments.isNotEmpty) ...[
          _sectionHeader(t, 'Commitments & actions · ${commitments.length}',
              const Color(0xFFB98A2F)),
          ...commitments.map((f) => _factRow(t, f)),
        ],
        if (threads.isNotEmpty) ...[
          _sectionHeader(
              t, 'Open threads · ${threads.length}', const Color(0xFFB4472F)),
          ...threads.map((f) => _factRow(t, f)),
        ],
        if (keyfacts.isNotEmpty) ...[
          _sectionHeader(t, 'Key facts', const Color(0xFF8B857A)),
          ...keyfacts.map((f) => _factRow(t, f)),
        ],

        // empty / offline hint
        if (!hasMemory && !busy && d.transcriptText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              extractStatus == 'running'
                  ? 'Extracting memory…'
                  : (extractStatus == 'skipped' || extractStatus == null)
                      ? 'No memory yet. Add an AI key in Settings to extract '
                          'the summary, decisions, commitments and open threads.'
                      : extractStatus == 'failed'
                          ? 'Extraction failed — check your AI key in Settings.'
                          : 'No memory extracted for this conversation.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(
                  color: t.colorScheme.onSurfaceVariant, height: 1.5),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = db.detail(widget.conversationId);
    final busy = d.artifacts
        .any((a) => a.status == 'pending' || a.status == 'transcribing');
    final failed = d.artifacts.where((a) => a.status == 'failed').toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(d.title,
              style: t.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete conversation',
              onPressed: _deleteConversation,
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Memory'), Tab(text: 'Transcript')],
          ),
        ),
        body: TabBarView(children: [
          _memoryTab(t, d, busy, failed),
          _transcriptTab(t, d, busy, failed),
        ]),
      ),
    );
  }
}
