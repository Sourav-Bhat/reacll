import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import '../services/extraction_service.dart';
import '../services/transcription_service.dart';
import '../services/voice_id_service.dart';
import 'tag_screen.dart';

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
    // Refresh when transcription/extraction/diarization finishes.
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

  /// FR-15: speaker question -> person picker -> enrollment.
  Future<void> _answerSpeaker(Clarification q) async {
    final people = db.peopleList();
    final personId = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          children: [
            Text(q.question,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ...people.map((p) => ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(p.name),
                  onTap: () => Navigator.pop(context, p.id),
                )),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('New person…'),
              onTap: () async {
                final ctl = TextEditingController();
                final name = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('New person'),
                    content: TextField(controller: ctl, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, ctl.text),
                          child: const Text('Add')),
                    ],
                  ),
                );
                if (context.mounted) {
                  Navigator.pop(context,
                      (name != null && name.trim().isNotEmpty)
                          ? db.upsertPerson(name)
                          : null);
                }
              },
            ),
          ],
        ),
      ),
    );
    if (personId != null && q.speakerLabel != null) {
      VoiceIdService.instance
          .enrollSpeaker(db, widget.conversationId, q.speakerLabel!, personId);
      db.answerClarification(q.id, db.personName(personId));
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
            decoration:
                const InputDecoration(hintText: 'Type your answer…')),
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

  void _onTx() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = db.detail(widget.conversationId);
    final busy = d.artifacts.any((a) =>
        a.status == 'pending' || a.status == 'transcribing');
    final failed = d.artifacts.where((a) => a.status == 'failed').toList();

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 40),
        children: [
          Text(d.title, style: t.textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            '${DateFormat('EEEE d MMM y · HH:mm').format(d.happenedAt)}'
            '${d.durationSec > 0 ? ' · ${(d.durationSec / 60).round()} min' : ''}',
            style: t.textTheme.bodyMedium
                ?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...d.people.map((p) => Chip(
                    label: Text(p.name),
                    backgroundColor: t.colorScheme.surfaceContainerHighest,
                    labelStyle: TextStyle(
                        color: t.colorScheme.primary,
                        fontWeight: FontWeight.w700),
                    visualDensity: VisualDensity.compact,
                  )),
              ActionChip(
                label: const Text('Edit tags'),
                avatar: const Icon(Icons.edit, size: 16),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          TagScreen(conversationId: d.id)));
                  setState(() {});
                },
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (busy)
            Card(
              child: ListTile(
                leading: const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                title: const Text('Transcribing on your phone…'),
                subtitle: const Text('Your audio never leaves the device.'),
              ),
            ),
          ...failed.map((a) => Card(
                child: ListTile(
                  leading:
                      Icon(Icons.error_outline, color: t.colorScheme.error),
                  title: const Text('Transcription failed'),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      await TranscriptionService.instance.retry(db, a.id);
                      setState(() {});
                    },
                    child: const Text('Retry'),
                  ),
                ),
              )),
          // ---- Phase 3: who spoke (FR-14/FR-16) ----
          Builder(builder: (context) {
            final speakers = db.conversationSpeakers(d.id);
            if (speakers.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
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
                    labelStyle: t.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            );
          }),
          // ---- Phase 2: clarification questions (FR-11, max 3, dismissible) ----
          ...db.openClarifications(d.id).map((q) => Card(
                color: t.colorScheme.surfaceContainerHighest,
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
          // ---- Phase 2: extracted facts for this conversation (FR-9) ----
          Builder(builder: (context) {
            final facts = db.conversationFacts(d.id);
            if (facts.isEmpty) return const SizedBox.shrink();
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Extracted',
                        style: t.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    ...facts.map((f) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('· ',
                                  style: TextStyle(
                                      color: t.colorScheme.primary,
                                      fontWeight: FontWeight.w800)),
                              Expanded(
                                child: Text(
                                  (f.kind == 'commitment' ? '☐ ' : '') +
                                      f.text +
                                      ((f.resolvedName ?? f.personName) != null
                                          ? ' — ${f.resolvedName ?? f.personName}'
                                          : ''),
                                  style: t.textTheme.bodyMedium
                                      ?.copyWith(height: 1.4),
                                ),
                              ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            );
          }),
          if (d.transcriptText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.only(left: 14),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                      color: t.colorScheme.primary.withValues(alpha: .35),
                      width: 2.5),
                ),
              ),
              child: SelectableText(
                d.transcriptText,
                style: t.textTheme.bodyLarge?.copyWith(height: 1.65),
              ),
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
      ),
    );
  }
}
