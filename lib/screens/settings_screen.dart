import 'package:flutter/material.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../main.dart';
import '../services/extraction_service.dart';
import '../services/local_llm_service.dart';
import '../services/sample_data.dart';
import '../services/transcription_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _keyCtl;
  late final TextEditingController _geminiCtl;
  late final TextEditingController _hfTokenCtl;
  String _provider = 'anthropic';
  String _secondary = 'none';
  String _whisperModel = 'tiny';
  bool _sampleLoaded = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _keyCtl = TextEditingController(
        text: db.getSetting(ExtractionService.settingApiKey) ?? '');
    _geminiCtl = TextEditingController(
        text: db.getSetting(ExtractionService.settingGeminiKey) ?? '');
    _hfTokenCtl = TextEditingController(
        text: db.getSetting(LocalLlmService.settingHfToken) ?? '');
    _provider = db.getSetting(ExtractionService.settingProvider) ?? 'anthropic';
    _secondary = db.getSetting(ExtractionService.settingSecondary) ?? 'none';
    _whisperModel = db.getSetting(TranscriptionService.settingModel) ?? 'tiny';
    _sampleLoaded = SampleData.isLoaded(db);
    LocalLlmService.instance.addListener(_onLocal);
    PackageInfo.fromPlatform().then((i) {
      if (mounted) {
        setState(() => _version = 'v${i.version}+${i.buildNumber}');
      }
    });
  }

  void _onLocal() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    LocalLlmService.instance.removeListener(_onLocal);
    _keyCtl.dispose();
    _geminiCtl.dispose();
    _hfTokenCtl.dispose();
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
          Text('AI provider', style: t.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Recall sends transcript TEXT (never audio) to extract a summary, '
            'decisions, commitments and open threads. Leave the key empty to '
            'stay fully offline — recording, transcription and search still work.',
            style: t.textTheme.bodyMedium
                ?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 14),
          Text('Primary',
              style:
                  t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final o in const [
              ('anthropic', 'Anthropic'),
              ('gemini', 'Gemini'),
              ('local', 'Local')
            ])
              ChoiceChip(
                label: Text(o.$2),
                selected: _provider == o.$1,
                onSelected: (_) => setState(() => _provider = o.$1),
              ),
          ]),
          const SizedBox(height: 12),
          Text('Fallback (used if the primary fails)',
              style:
                  t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final o in const [
              ('none', 'None'),
              ('anthropic', 'Anthropic'),
              ('gemini', 'Gemini'),
              ('local', 'Local')
            ])
              ChoiceChip(
                label: Text(o.$2),
                selected: _secondary == o.$1,
                onSelected: (_) => setState(() => _secondary = o.$1),
              ),
          ]),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 12),
          Text('Anthropic (Claude)',
              style:
                  t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Anthropic API key',
              hintText: 'sk-ant-…',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
            ),
          ),
          const SizedBox(height: 16),
          Text('Google Gemini',
              style:
                  t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _geminiCtl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Gemini API key',
              hintText: 'AIza…',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
            ),
          ),
          const SizedBox(height: 16),
          Text('On-device (Local)',
              style:
                  t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              'Runs fully on-device — nothing (not even transcript text) leaves '
              'your phone. Pick a model and download it once.',
              style: t.textTheme.bodySmall?.copyWith(
                  color: t.colorScheme.onSurfaceVariant, height: 1.5)),
          const SizedBox(height: 12),
          Builder(builder: (_) {
              final local = LocalLlmService.instance;
              final selectedId = local.selectedModel(db).id;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...LocalLlmService.models.map((m) {
                    final on = m.id == selectedId;
                    return InkWell(
                      onTap: local.isDownloading
                          ? null
                          : () {
                              db.setSetting(
                                  LocalLlmService.settingModelId, m.id);
                              setState(() {});
                            },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: on
                                  ? t.colorScheme.primary
                                  : t.colorScheme.outlineVariant,
                              width: on ? 2 : 1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(children: [
                          Icon(
                              on
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 20,
                              color: on
                                  ? t.colorScheme.primary
                                  : t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.label,
                                    style: t.textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600)),
                                Text(m.size,
                                    style: t.textTheme.bodySmall?.copyWith(
                                        color: t.colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ]),
                      ),
                    );
                  }),
                  if (local.selectedModel(db).gated) ...[
                    const SizedBox(height: 2),
                    TextField(
                      controller: _hfTokenCtl,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText:
                            'Hugging Face token (free — this model is gated)',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18)),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (local.isDownloading) ...[
                    LinearProgressIndicator(value: local.downloadProgress),
                    const SizedBox(height: 6),
                    Text(
                        'Downloading… ${((local.downloadProgress ?? 0) * 100).round()}%',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall),
                  ] else ...[
                    if (local.isInstalled(db))
                      Text('✓ Model ready — extraction & Ask run offline.',
                          style: t.textTheme.bodySmall
                              ?.copyWith(color: t.colorScheme.primary)),
                    if (local.lastError != null)
                      Text(local.lastError!,
                          style: t.textTheme.bodySmall
                              ?.copyWith(color: t.colorScheme.error)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        db.setSetting(LocalLlmService.settingHfToken,
                            _hfTokenCtl.text.trim());
                        await LocalLlmService.instance.download(db);
                      },
                      icon: const Icon(Icons.download),
                      label: Text(local.isInstalled(db)
                          ? 'Re-download model'
                          : 'Download model'),
                    ),
                  ],
                ],
              );
            }),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              db.setSetting(ExtractionService.settingProvider, _provider);
              db.setSetting(ExtractionService.settingSecondary, _secondary);
              db.setSetting(
                  ExtractionService.settingApiKey, _keyCtl.text.trim());
              db.setSetting(
                  ExtractionService.settingGeminiKey, _geminiCtl.text.trim());
              db.setSetting(
                  LocalLlmService.settingHfToken, _hfTokenCtl.text.trim());
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Saved')));
              // ignore: unawaited_futures
              ExtractionService.instance.pump(db);
            },
            child: const Text('Save'),
          ),
          const SizedBox(height: 30),
          const Divider(),
          const SizedBox(height: 12),
          Text('Transcription', style: t.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Whisper runs on-device. Tiny is fastest; Small is most accurate but '
            'much slower. Long recordings still take several minutes — and a '
            'release build is ~5× faster than a debug build.',
            style: t.textTheme.bodySmall
                ?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            for (final o in const [
              ('tiny', 'Tiny — fastest'),
              ('base', 'Base'),
              ('small', 'Small — best')
            ])
              ChoiceChip(
                label: Text(o.$2),
                selected: _whisperModel == o.$1,
                onSelected: (_) {
                  setState(() => _whisperModel = o.$1);
                  db.setSetting(TranscriptionService.settingModel, o.$1);
                  TranscriptionService.instance.setModel(o.$1);
                  // ignore: unawaited_futures
                  TranscriptionService.instance.ensureModelReady();
                },
              ),
          ]),
          const SizedBox(height: 30),
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
          const SizedBox(height: 18),
          TextButton.icon(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reset local data?'),
                  content: const Text(
                      'Deletes all conversations, people and tags on this '
                      'device. Your API key is kept. This cannot be undone.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Reset')),
                  ],
                ),
              );
              if (ok == true) {
                db.resetLocalData();
                setState(() => _sampleLoaded = false);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Local data cleared — reload the sample above')));
                }
              }
            },
            icon: Icon(Icons.delete_outline, color: t.colorScheme.error),
            label: Text('Reset local data',
                style: TextStyle(color: t.colorScheme.error)),
          ),
          const SizedBox(height: 28),
          Center(
            child: Text(
              _version.isEmpty ? 'Recall' : 'Recall $_version',
              style: t.textTheme.bodySmall
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
