import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';
import 'local_llm_service.dart';

/// FR-9 + W6/W7/W8/W13/W14: structured extraction (TEXT ONLY — audio never
/// leaves the device). Produces a summary, a conversation type/bucket, typed
/// facts and clarification questions, via the user's chosen PRIMARY provider,
/// falling back to a SECONDARY provider if the primary fails. Providers:
/// Anthropic (Claude), Google (Gemini), or fully-local (Gemma/Qwen on-device).
class ExtractionService extends ChangeNotifier {
  ExtractionService._();
  static final ExtractionService instance = ExtractionService._();

  // Settings keys.
  static const settingProvider = 'ai_provider'; // primary
  static const settingSecondary = 'ai_provider_secondary'; // fallback | 'none'
  static const settingApiKey = 'anthropic_api_key';
  static const settingGeminiKey = 'gemini_api_key';

  static const _anthropicEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicModel = 'claude-haiku-4-5';
  static const _geminiModel = 'gemini-2.0-flash';

  static const maxQuestions = 3;
  static const linkConfidence = 0.75;

  bool _running = false;
  bool get isRunning => _running;

  static const _systemPrompt = '''
You extract structured memory from a conversation transcript for a personal
recall app, so the user never has to re-read the transcript. Reply with ONLY a
JSON object, no prose, matching:
{"summary":str,"bucket":str,
"facts":[{"kind":"commitment|decision|fact|thread","text":str,
"person":str|null,"due":str|null,"confidence":num 0..1}],
"questions":[{"question":str,"reason":str}]}

Rules:
- summary: 2-4 sentences capturing what the conversation was about and its outcome.
- bucket: the single best conversation TYPE from exactly this list: "1:1",
  "Standup", "Planning", "Brainstorm", "Decision/Review", "Kickoff", "Retro",
  "Interview", "Vendor/Sales", "User-research", "Status update", "Deep-dive",
  "Personal", "Other".
- commitment: someone agreed to do something. person = who owes it; due = when.
- decision: something was decided. fact: a durable fact about a person/topic.
- thread: an open question or unresolved topic to follow up.
- Extract only what is genuinely useful for recall; quality over quantity.
- Use a name only if it appears in the transcript; otherwise null.
- questions: at MOST 3, ONLY where ambiguity blocks filing something important.
  If nothing important is ambiguous, return an empty questions list.
''';

  // ---------------- provider chain ----------------

  /// Ordered providers to try: primary, then a distinct secondary if set.
  List<String> _chain(RecallDb db) {
    final primary = db.getSetting(settingProvider) ?? 'anthropic';
    final secondary = db.getSetting(settingSecondary);
    return [
      primary,
      if (secondary != null &&
          secondary.isNotEmpty &&
          secondary != 'none' &&
          secondary != primary)
        secondary,
    ];
  }

  bool _configured(RecallDb db, String provider) {
    switch (provider) {
      case 'local':
        return LocalLlmService.instance.isInstalled(db);
      case 'gemini':
        return (db.getSetting(settingGeminiKey) ?? '').isNotEmpty;
      default:
        return (db.getSetting(settingApiKey) ?? '').isNotEmpty;
    }
  }

  /// One completion with a specific provider (throws if not configured).
  Future<String> _completeWith(
      RecallDb db, String provider, String system, String user) async {
    if (provider == 'local') {
      return LocalLlmService.instance.complete(db, system: system, user: user);
    }
    final key = provider == 'gemini'
        ? db.getSetting(settingGeminiKey)
        : db.getSetting(settingApiKey);
    if (key == null || key.isEmpty) {
      throw Exception(
          'No ${provider == 'gemini' ? 'Gemini' : 'Anthropic'} API key set');
    }
    return provider == 'gemini'
        ? _rawGemini(key, system, user)
        : _rawClaude(key, system, user);
  }

  /// Public single-shot completion (Ask / RAG). Primary → secondary fallback.
  Future<String> complete(RecallDb db,
      {required String system, required String user}) async {
    Object? lastErr;
    for (final p in _chain(db)) {
      try {
        return await _completeWith(db, p, system, user);
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? Exception('No AI provider configured (Settings).');
  }

  // ---------------- extraction queue ----------------

  Future<void> pump(RecallDb db) async {
    if (_running) return;
    final chain = _chain(db);
    final configured = chain.where((p) => _configured(db, p)).toList();
    _running = true;
    notifyListeners();
    try {
      for (final convId in db.pendingExtractions()) {
        if (configured.isEmpty) {
          db.setExtractionStatus(convId, 'skipped',
              error: 'No AI provider configured');
          continue;
        }
        db.setExtractionStatus(convId, 'running');
        notifyListeners();
        try {
          final detail = db.detail(convId);
          if (detail.transcriptText.trim().isEmpty) {
            db.setExtractionStatus(convId, 'skipped', error: 'No transcript');
            continue;
          }
          final userMsg = 'Transcript:\n\n${detail.transcriptText}';
          Map<String, dynamic>? json;
          Object? err;
          for (final p in configured) {
            try {
              json = parseModelJson(
                  await _completeWith(db, p, _systemPrompt, userMsg));
              err = null;
              break;
            } catch (e) {
              err = e;
            }
          }
          if (json == null) throw err ?? Exception('Extraction failed');
          _store(db, convId, json);
          db.setExtractionStatus(convId, 'done');
        } catch (e) {
          db.setExtractionStatus(convId, 'failed', error: e.toString());
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  // ---------------- raw provider calls ----------------

  Future<String> _rawClaude(String apiKey, String system, String user) async {
    final resp = await http
        .post(
          Uri.parse(_anthropicEndpoint),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'model': _anthropicModel,
            'max_tokens': 2000,
            'system': system,
            'messages': [
              {'role': 'user', 'content': user}
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) {
      throw Exception('Anthropic ${resp.statusCode}: ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return ((body['content'] as List).first
        as Map<String, dynamic>)['text'] as String;
  }

  Future<String> _rawGemini(String apiKey, String system, String user) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$_geminiModel:generateContent?key=$apiKey';
    final resp = await http
        .post(
          Uri.parse(url),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'system_instruction': {
              'parts': [
                {'text': system}
              ]
            },
            'contents': [
              {
                'parts': [
                  {'text': user}
                ]
              }
            ],
            'generationConfig': {'maxOutputTokens': 2048},
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) {
      throw Exception('Gemini ${resp.statusCode}: ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final cand = (body['candidates'] as List).first as Map<String, dynamic>;
    final parts = (cand['content'] as Map<String, dynamic>)['parts'] as List;
    return (parts.first as Map<String, dynamic>)['text'] as String;
  }

  /// Robust parse: tolerates code fences and stray prose around the JSON.
  static Map<String, dynamic> parseModelJson(String raw) {
    var s = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('No JSON object in model reply');
    }
    final obj = jsonDecode(s.substring(start, end + 1));
    if (obj is! Map<String, dynamic>) {
      throw const FormatException('Model reply is not a JSON object');
    }
    return obj;
  }

  static const _kinds = {'commitment', 'decision', 'fact', 'thread'};
  static const _buckets = {
    '1:1', 'Standup', 'Planning', 'Brainstorm', 'Decision/Review', 'Kickoff',
    'Retro', 'Interview', 'Vendor/Sales', 'User-research', 'Status update',
    'Deep-dive', 'Personal', 'Other'
  };

  void _store(RecallDb db, int convId, Map<String, dynamic> json) {
    final summary = (json['summary'] as String?)?.trim();
    var bucket = (json['bucket'] as String?)?.trim();
    if (bucket != null && !_buckets.contains(bucket)) bucket = 'Other';
    db.setConversationMemory(convId, summary: summary, bucket: bucket);

    final byName = <String, List<int>>{};
    for (final p in db.peopleList()) {
      byName.putIfAbsent(p.name.toLowerCase(), () => []).add(p.id);
    }

    for (final f in (json['facts'] as List? ?? const [])) {
      if (f is! Map) continue;
      final kind = (f['kind'] as String?)?.toLowerCase();
      final text = (f['text'] as String?)?.trim();
      if (kind == null || !_kinds.contains(kind)) continue;
      if (text == null || text.isEmpty) continue;
      final rawName = (f['person'] as String?)?.trim();
      final conf = (f['confidence'] is num)
          ? (f['confidence'] as num).toDouble().clamp(0.0, 1.0)
          : 0.5;
      int? personId;
      if (rawName != null && rawName.isNotEmpty && conf >= linkConfidence) {
        final matches = byName[rawName.toLowerCase()];
        if (matches != null && matches.length == 1) personId = matches.first;
      }
      db.addFact(
        conversationId: convId,
        kind: kind,
        text: text,
        personId: personId,
        personName: rawName,
        dueHint: (f['due'] as String?)?.trim(),
        confidence: conf,
      );
    }

    var count = 0;
    for (final q in (json['questions'] as List? ?? const [])) {
      if (q is! Map || count >= maxQuestions) break;
      final question = (q['question'] as String?)?.trim();
      if (question == null || question.isEmpty) continue;
      db.addClarification(convId, question, reason: (q['reason'] as String?));
      count++;
    }
  }

  /// FR-11 write-back: an answered clarification becomes a structured fact.
  void answerAsFact(RecallDb db, int clarificationId, int conversationId,
      String answer) {
    db.answerClarification(clarificationId, answer);
    db.addFact(
      conversationId: conversationId,
      kind: 'fact',
      text: answer,
      confidence: 1.0,
    );
  }
}
