import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import 'detail_screen.dart';

/// FR-7: live full-text search with optional person filter and highlighted snippets.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctl = TextEditingController();
  int? _personFilter;
  List<SearchHit> _hits = [];

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _run() {
    setState(() => _hits = db.search(_ctl.text, personId: _personFilter));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final people = db.peopleList().where((p) => p.convoCount > 0).toList();
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              child: Text('Search', style: t.textTheme.headlineMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
              child: TextField(
                controller: _ctl,
                autofocus: true,
                onChanged: (_) => _run(),
                decoration: InputDecoration(
                  hintText: 'Type a word or a name…',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(27)),
                ),
              ),
            ),
            if (people.isNotEmpty)
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                  children: people.map((p) {
                    final on = _personFilter == p.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(p.name),
                        selected: on,
                        showCheckmark: false,
                        selectedColor: t.colorScheme.primary,
                        labelStyle: TextStyle(
                            color: on ? Colors.white : t.colorScheme.primary,
                            fontWeight: FontWeight.w600),
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                        onSelected: (_) {
                          setState(() => _personFilter = on ? null : p.id);
                          _run();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            Expanded(
              child: _hits.isEmpty
                  ? Center(
                      child: Text(
                        _ctl.text.trim().length < 2
                            ? 'Search across every conversation you\'ve ever saved.'
                            : 'No matches for “${_ctl.text.trim()}”.',
                        style: t.textTheme.bodyLarge?.copyWith(
                            color: t.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(22, 14, 22, 30),
                      itemCount: _hits.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) => _HitCard(h: _hits[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HitCard extends StatelessWidget {
  const _HitCard({required this.h});
  final SearchHit h;

  /// snippet() wraps matches in [ ] — render them highlighted.
  List<TextSpan> _spans(BuildContext context, String s) {
    final t = Theme.of(context);
    final spans = <TextSpan>[];
    final re = RegExp(r'\[([^\]]*)\]');
    int last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      spans.add(TextSpan(
        text: m.group(1),
        style: TextStyle(
          backgroundColor: const Color(0xFFE8C15C),
          color: const Color(0xFF211D19),
          fontWeight: FontWeight.w700,
        ),
      ));
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DetailScreen(conversationId: h.conversationId))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${h.title} · ${DateFormat('d MMM y').format(h.happenedAt)}',
                style: t.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              RichText(
                text: TextSpan(
                  style: t.textTheme.bodyMedium?.copyWith(height: 1.5),
                  children: _spans(context, h.snippet),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
