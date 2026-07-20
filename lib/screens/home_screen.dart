import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import 'detail_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final convos = db.homeList();
    final t = Theme.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Recall', style: t.textTheme.headlineMedium),
                      const SizedBox(height: 2),
                      Text('Your conversations, remembered.',
                          style: t.textTheme.bodyMedium?.copyWith(
                              color: t.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton.outlined(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const SettingsScreen())),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
            child: GestureDetector(
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SearchScreen()));
                onChanged();
              },
              child: Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: t.colorScheme.surface,
                  borderRadius: BorderRadius.circular(27),
                  border: Border.all(
                      color: t.colorScheme.onSurface.withValues(alpha: .08)),
                ),
                child: Row(children: [
                  Icon(Icons.search, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Text('Search anything… “budget”, “Priya”',
                      style: t.textTheme.bodyLarge?.copyWith(
                          color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
          Expanded(
            child: convos.isEmpty
                ? _Empty(theme: t)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 120),
                    itemCount: convos.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) =>
                        _ConvoCard(c: convos[i], onChanged: onChanged),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.theme});
  final ThemeData theme;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            'No conversations yet.\n\nTap the mic to record your first one, '
            'or use Add to bring in your Google Recorder archive.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
          ),
        ),
      );
}

class _ConvoCard extends StatelessWidget {
  const _ConvoCard({required this.c, required this.onChanged});
  final ConversationSummary c;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final date = DateFormat('d MMM · HH:mm').format(c.happenedAt);
    final dur = c.durationSec > 0 ? ' · ${(c.durationSec / 60).round()} min' : '';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DetailScreen(conversationId: c.id)));
          onChanged();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(c.title,
                      style: t.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (c.busy)
                  const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
              const SizedBox(height: 4),
              Text('$date$dur',
                  style: t.textTheme.bodySmall
                      ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (c.peopleNames.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: c.peopleNames.split(', ').map((n) => Chip(
                        label: Text(n),
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                        labelStyle: t.textTheme.labelMedium?.copyWith(
                            color: t.colorScheme.primary,
                            fontWeight: FontWeight.w700),
                        visualDensity: VisualDensity.compact,
                      )).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
