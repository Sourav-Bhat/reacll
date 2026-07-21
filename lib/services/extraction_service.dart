import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';

/// FR-9 + FR-11: structured extraction via Claude API (TEXT ONLY — audio never
/// leaves the device), plus confidence-triggered clarification questions.
///
/// Contract with the model (strict JSON):
/// {
///   "facts": [{"kind":"commitment|decision|fact|thread", "text":"...",
///              "person":"name or null", "due":"free text or null",
///              "confidence":0.0-1.0}],
///   "questions": [{"question":"...", "reason":"..."}]   // max 3
/// }
class ExtractionService extends ChangeNotifier {
  ExtractionService._();
  static final ExtractionService instance = ExtractionService._();

  static const settingApiKey = 'anthropic_api_key';
  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _model = 'claude-haiku-4-5';
  static const maxQuestions = 3;
  static const linkConfidence = 0.75; // below this, don't auto-file to a person

  bool _running = false;
  bool get isRunning => _running;

  static const _systemPrompt = '''
You extract structured memory from a conversation transcript for a personal
recall app. Reply with ONLY a JSON object, no prose, matching:
{"facts":[{"kind":"commitment|decision|fact|thread","text":str,
"person":str|null,"due":str|null,"confidence":num 0..1}],
"questions":[{"question":str,"reason":str}]}

Rules:
- commitment: someone agreed to do something. person = who owes it.
- decision: something was decided. fact: a durable fact about a person/topic.
- thread: an open question or unresolved topic to follow up.
- Extract only what is genuinely useful for recall; quality over quantity.
- Use the speaker's name only if it appears in the transcript; otherwise null.
- questions: at MOST 3, ONLY where ambiguity blocks filing something important
  (unknown person for a commitment, missing deadline, unclear referent).
  If nothing important is ambiguous, return an empty questions list.
''';

  /// Drain all pending extractions. No-op without an API key (status 'skipped').
  Future<void> pump(RecallDb db) async {
    if (_running) return;
    final apiKey = db.getSetting(settingApiKey);
    _running = true;
    notifyListeners();
    try {
      for (final convId in db.pendingExtractions()) {
        if (apiKey == null || apiKey.isEmpty) {
          db.setExtractionStatus(convId, 'skipped',
              error: 'No API key configured');
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
          final json = await _callClaude(apiKey, detail.transcriptText);
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

  Future<Map<String, dynamic>> _callClaude(String apiKey, String transcript) async {
    final resp = await http
        .post(
          Uri.parse(_endpoint),
          headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': 2000,
            'system': _systemPrompt,
            'messages': [
              {'role': 'user', 'content': 'Transcript:\n\n$transcript'}
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw Exception('API ${resp.statusCode}: ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final text = ((body['content'] as List).first
        as Map<String, dynamic>)['text'] as String;
    return parseModelJson(text);
  }

  /// Robust parse: tolerates code fences and stray prose around the JSON.
  /// Static + pure so the sandbox test harness can validate it with fixtures.
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

  void _store(RecallDb db, int convId, Map<String, dynamic> json) {
    // Names are not unique now — index name -> all matching person ids.
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
      // Link only on a UNIQUE exact name match with decent confidence. If the
      // name is ambiguous (two "Ravi"s) or unknown, keep the raw name and let a
      // clarification resolve it — never file to the wrong person.
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
