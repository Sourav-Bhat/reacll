import 'package:flutter/material.dart';

import '../main.dart';

/// FR-6: exactly two questions — who + what — completable in <=10s, skippable.
class TagScreen extends StatefulWidget {
  const TagScreen({super.key, required this.conversationId});
  final int conversationId;

  @override
  State<TagScreen> createState() => _TagScreenState();
}

class _TagScreenState extends State<TagScreen> {
  final Set<int> _selected = {};
  final _topicCtl = TextEditingController();

  @override
  void dispose() {
    _topicCtl.dispose();
    super.dispose();
  }

  Future<void> _newPerson() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New person'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text),
              child: const Text('Add')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      final id = db.upsertPerson(name);
      setState(() => _selected.add(id));
    }
  }

  void _save({bool skip = false}) {
    if (!skip) {
      for (final pid in _selected) {
        db.tagPerson(widget.conversationId, pid);
      }
      final topic = _topicCtl.text.trim();
      if (topic.isNotEmpty) {
        db.updateConversation(widget.conversationId, title: topic);
        db.tagTopic(widget.conversationId, db.upsertTopic(topic));
      }
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(skip ? 'Saved — tag it anytime' : 'Saved & tagged ✓'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final people = db.peopleList();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 40),
          children: [
            Text('Saved ✓', style: t.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('Two quick questions — ten seconds.',
                style: t.textTheme.bodyMedium
                    ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            Text('1 · Who did you talk to?',
                style: t.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                ...people.map((p) => FilterChip(
                      label: Text(p.name),
                      selected: _selected.contains(p.id),
                      onSelected: (sel) => setState(() =>
                          sel ? _selected.add(p.id) : _selected.remove(p.id)),
                      selectedColor: t.colorScheme.primary,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _selected.contains(p.id)
                            ? Colors.white
                            : t.colorScheme.primary,
                      ),
                      backgroundColor: t.colorScheme.surfaceContainerHighest,
                      showCheckmark: false,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    )),
                ActionChip(
                  label: const Text('＋ New person'),
                  onPressed: _newPerson,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text('2 · What was it about?', style: t.textTheme.headlineSmall),
            const SizedBox(height: 12),
            TextField(
              controller: _topicCtl,
              decoration: const InputDecoration(
                hintText: 'e.g.  Vendor pricing call',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18))),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 30),
            FilledButton(onPressed: _save, child: const Text('Done')),
            const SizedBox(height: 11),
            OutlinedButton(
                onPressed: () => _save(skip: true),
                child: const Text('Skip — I’ll do it later')),
          ],
        ),
      ),
    );
  }
}
