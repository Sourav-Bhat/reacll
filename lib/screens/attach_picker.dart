import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';

/// FR-4: "new conversation or add to existing" — shown on every import.
/// Returns null for "new conversation", or an existing conversation id.
Future<int?> showAttachPicker(BuildContext context, RecallDb db) async {
  final recents = db.homeList(limit: 10);
  if (recents.isEmpty) return null; // nothing to attach to — just create new
  if (!context.mounted) return null;

  return showModalBottomSheet<int?>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final t = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Where does this belong?',
                  style: t.textTheme.headlineSmall),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('New conversation'),
                onPressed: () => Navigator.pop(context, null),
              ),
              const SizedBox(height: 14),
              Text('…or add to a recent one:',
                  style: t.textTheme.bodyMedium
                      ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: recents
                      .map((c) => ListTile(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            title: Text(c.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(DateFormat('d MMM · HH:mm')
                                .format(c.happenedAt)),
                            onTap: () => Navigator.pop(context, c.id),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
