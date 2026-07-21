import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import 'detail_screen.dart';
import 'person_form.dart';

class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  static const _avatarColors = [
    Color(0xFFC65F43), Color(0xFF5E7D5A), Color(0xFFB98A2F),
    Color(0xFF5C6E8C), Color(0xFF8C5C7E),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final people = db.peopleList();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('People', style: t.textTheme.headlineMedium),
                const SizedBox(height: 2),
                Text('Tap a person — see every conversation.',
                    style: t.textTheme.bodyMedium
                        ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: people.isEmpty
                ? Center(
                    child: Text('No people yet.\nTag someone after a recording.',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyLarge?.copyWith(
                            color: t.colorScheme.onSurfaceVariant, height: 1.6)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 120),
                    itemCount: people.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final p = people[i];
                      return Card(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => PersonScreen(person: p)));
                            onChanged();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(children: [
                              Container(
                                width: 52, height: 52,
                                decoration: BoxDecoration(
                                  color: _avatarColors[i % _avatarColors.length],
                                  borderRadius: BorderRadius.circular(19),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800),
                                ),
                              ),
                              const SizedBox(width: 15),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name,
                                      style: t.textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w700)),
                                  Text(
                                      p.subtitle ??
                                          '${p.convoCount} conversation${p.convoCount == 1 ? '' : 's'}',
                                      style: t.textTheme.bodySmall?.copyWith(
                                          color: t.colorScheme.onSurfaceVariant)),
                                ],
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// FR-10 + FR-12: Brief · Facts · Conversations.
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.person});
  final Person person;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  static const _kindIcon = {
    'commitment': Icons.assignment_turned_in_outlined,
    'decision': Icons.gavel_outlined,
    'fact': Icons.lightbulb_outline,
    'thread': Icons.forum_outlined,
  };
  static const _kindLabel = {
    'commitment': 'Commitment',
    'decision': 'Decision',
    'fact': 'Fact',
    'thread': 'Open thread',
  };

  /// Edit the full contact card (name, company, role, email, notes).
  Future<void> _edit() async {
    await showPersonForm(context, existingId: widget.person.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final person = db.getPerson(widget.person.id) ?? widget.person;
    final convos = db.personConversations(person.id);
    final facts = db.personFacts(person.id);
    final brief = db.brief(person.id);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(person.name, style: t.textTheme.headlineSmall),
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit contact',
              onPressed: _edit,
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Brief'),
            Tab(text: 'Facts'),
            Tab(text: 'Talks'),
          ]),
        ),
        body: TabBarView(children: [
          // ---- Brief (FR-12): offline, deterministic, <1s ----
          ListView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 40),
            children: [
              if (person.subtitle != null ||
                  person.email != null ||
                  person.notes != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (person.subtitle != null)
                          Text(person.subtitle!,
                              style: t.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        if (person.email != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(person.email!,
                                style: t.textTheme.bodyMedium),
                          ),
                        if (person.notes != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(person.notes!,
                                style: t.textTheme.bodyMedium?.copyWith(
                                    color: t.colorScheme.onSurfaceVariant,
                                    height: 1.4)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Card(
                child: ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(brief.lastMet == null
                      ? 'Never met on record'
                      : 'Last met ${DateFormat('EEEE d MMM y').format(brief.lastMet!)}'),
                  subtitle: Text('${convos.length} conversation'
                      '${convos.length == 1 ? '' : 's'} on record'),
                ),
              ),
              const SizedBox(height: 10),
              if (brief.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No open items. Facts appear here after extraction runs '
                    '(add your API key in Settings).',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(
                        color: t.colorScheme.onSurfaceVariant, height: 1.5),
                  ),
                ),
              ...brief.items.map((f) => Card(
                    child: ListTile(
                      leading: Icon(_kindIcon[f.kind],
                          color: t.colorScheme.primary),
                      title: Text(f.text),
                      subtitle: Text(
                        '${_kindLabel[f.kind]}'
                        '${f.dueHint != null ? ' · due ${f.dueHint}' : ''}'
                        ' · ${DateFormat('d MMM y').format(f.happenedAt)}',
                      ),
                    ),
                  )),
            ],
          ),
          // ---- Facts timeline (FR-10/FR-13): newest first, superseded struck ----
          facts.isEmpty
              ? Center(
                  child: Text('No facts yet.',
                      style: t.textTheme.bodyLarge?.copyWith(
                          color: t.colorScheme.onSurfaceVariant)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 40),
                  itemCount: facts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final f = facts[i];
                    return Card(
                      child: ListTile(
                        leading: Icon(_kindIcon[f.kind],
                            color: f.superseded
                                ? t.colorScheme.onSurfaceVariant
                                : t.colorScheme.primary),
                        title: Text(
                          f.text,
                          style: f.superseded
                              ? const TextStyle(
                                  decoration: TextDecoration.lineThrough)
                              : null,
                        ),
                        subtitle: Text(
                          '${DateFormat('d MMM y').format(f.happenedAt)}'
                          ' · ${f.conversationTitle}'
                          '${f.superseded ? ' · superseded' : ''}',
                        ),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => DetailScreen(
                                    conversationId: f.conversationId))),
                      ),
                    );
                  },
                ),
          // ---- Conversations ----
          convos.isEmpty
              ? Center(
                  child: Text('Nothing yet.',
                      style: t.textTheme.bodyLarge?.copyWith(
                          color: t.colorScheme.onSurfaceVariant)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 40),
                  itemCount: convos.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final c = convos[i];
                    return Card(
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24)),
                        title: Text(c.title,
                            style: t.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        subtitle: Text(DateFormat('d MMM y · HH:mm')
                            .format(c.happenedAt)),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    DetailScreen(conversationId: c.id))),
                      ),
                    );
                  },
                ),
        ]),
      ),
    );
  }
}
