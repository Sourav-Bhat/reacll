import 'package:flutter/material.dart';

import '../main.dart';
import '../services/extraction_service.dart';
import '../services/sample_data.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _keyCtl;
  bool _sampleLoaded = false;

  @override
  void initState() {
    super.initState();
    _keyCtl = TextEditingController(
        text: db.getSetting(ExtractionService.settingApiKey) ?? '');
    _sampleLoaded = SampleData.isLoaded(db);
  }

  @override
  void dispose() {
    _keyCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text('Settings', style: t.textTheme.headlineSmall),
          backgroundColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 40),
        children: [
          Text('Understanding (Phase 2)', style: t.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Recall sends transcript TEXT (never audio) to the Claude API to '
            'extract commitments, decisions and facts. Leave empty to keep '
            'everything fully offline — recording, transcription and search '
            'work without it.',
            style: t.textTheme.bodyMedium
                ?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _keyCtl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Anthropic API key',
              hintText: 'sk-ant-…',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18)),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              db.setSetting(
                  ExtractionService.settingApiKey, _keyCtl.text.trim());
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Saved')));
              // Anything skipped earlier can now be extracted.
              // ignore: unawaited_futures
              ExtractionService.instance.pump(db);
            },
            child: const Text('Save'),
          ),
          const SizedBox(height: 34),
          const Divider(),
          const SizedBox(height: 12),
          Text('Sample data', style: t.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Loads one real imported conversation (an ESG phase-2 meeting, '
            'transcribed on-device) plus its extracted commitments, decisions, '
            'facts and threads — so you can try the full app on real content '
            'without recording first. Safe to tap once.',
            style: t.textTheme.bodyMedium
                ?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _sampleLoaded
                ? null
                : () {
                    final added = SampleData.load(db);
                    setState(() => _sampleLoaded = true);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(added
                            ? 'Sample conversation loaded — see Talks'
                            : 'Sample data was already loaded')));
                  },
            icon: Icon(_sampleLoaded ? Icons.check : Icons.science_outlined),
            label: Text(_sampleLoaded
                ? 'Sample data loaded'
                : 'Load sample data'),
          ),
        ],
      ),
    );
  }
}
