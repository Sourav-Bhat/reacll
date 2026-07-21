import 'package:flutter/material.dart';

import '../main.dart';

/// Add or edit a full contact (name + company + role + email + notes).
/// Company disambiguates same names (two "Ravi"s). Returns the person id on
/// save, or null if cancelled.
Future<int?> showPersonForm(BuildContext context, {int? existingId}) {
  final existing = existingId != null ? db.getPerson(existingId) : null;
  final name = TextEditingController(text: existing?.name ?? '');
  final company = TextEditingController(text: existing?.company ?? '');
  final role = TextEditingController(text: existing?.role ?? '');
  final email = TextEditingController(text: existing?.email ?? '');
  final notes = TextEditingController(text: existing?.notes ?? '');

  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final t = Theme.of(context);
      return Padding(
        padding: EdgeInsets.only(
          left: 22,
          right: 22,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(existing == null ? 'New contact' : 'Edit contact',
                  style: t.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Company/circle keeps two people with the same name apart.',
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _field(name, 'Name',
                  cap: TextCapitalization.words, autofocus: existing == null),
              _field(company, 'Company / circle  (e.g. Sonnetix, Friends)'),
              _field(role, 'Role  (optional)'),
              _field(email, 'Email  (optional)',
                  keyboard: TextInputType.emailAddress,
                  cap: TextCapitalization.none),
              _field(notes, 'Notes  (optional)', maxLines: 3),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final n = name.text.trim();
                  if (n.isEmpty) return;
                  final int id;
                  if (existingId != null) {
                    db.updatePerson(existingId,
                        name: n,
                        company: company.text,
                        role: role.text,
                        email: email.text,
                        notes: notes.text);
                    id = existingId;
                  } else {
                    id = db.createPerson(
                        name: n,
                        company: company.text,
                        role: role.text,
                        email: email.text,
                        notes: notes.text);
                  }
                  Navigator.pop(context, id);
                },
                child: Text(existing == null ? 'Add' : 'Save'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _field(
  TextEditingController c,
  String label, {
  TextCapitalization cap = TextCapitalization.sentences,
  TextInputType? keyboard,
  int maxLines = 1,
  bool autofocus = false,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      autofocus: autofocus,
      textCapitalization: cap,
      keyboardType: keyboard,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
  );
}
