import '../db/database.dart';
import 'extraction_service.dart';

/// E-2: "Ask your memory" — retrieval-augmented Q&A grounded in the user's own
/// conversations. v1 retrieval = full-text hits + person-scoped conversations;
/// synthesis via the user's selected provider (Anthropic/Gemini), text only.
class AskCitation {
  final int conversationId;
  final String title;
  final DateTime happenedAt;
  const AskCitation(this.conversationId, this.title, this.happenedAt);
}

class AskResult {
  final String answer;
  final List<AskCitation> citations;
  const AskResult(this.answer, this.citations);
}

class AskService {
  AskService._();
  static final AskService instance = AskService._();

  static const _system = '''
You are the user's personal memory assistant. Answer the question using ONLY the
CONVERSATION RECORDS provided — these are the user's own recorded conversations.
Rules:
- Use only the records; never invent facts.
- Cite the conversation title + date in brackets after claims, e.g. [ESG Phase 2 — 25 Jun].
- If the records don't contain the answer, say you don't have that in your memory yet.
- Be concise and direct; prefer specifics (who, what, when) over generalities.
''';

  Future<AskResult> ask(RecallDb db, String question) async {
    final convIds = <int>{};

    // 1. full-text hits over transcripts
    for (final h in db.search(question).take(6)) {
      convIds.add(h.conversationId);
    }

    // 2. person-scoped: any known person named in the question
    final ql = question.toLowerCase();
    for (final p in db.peopleList()) {
      if (p.name.length >= 3 && ql.contains(p.name.toLowerCase())) {
        for (final c in db.personConversations(p.id)) {
          convIds.add(c.id);
        }
      }
    }

    if (convIds.isEmpty) {
      return const AskResult(
          "I couldn't find anything about that in your conversations yet.",
          <AskCitation>[]);
    }

    // assemble context (cap at 6 conversations)
    final chosen = convIds.take(6).toList();
    final citations = <AskCitation>[];
    final buf = StringBuffer();
    for (final id in chosen) {
      final d = db.detail(id);
      citations.add(AskCitation(id, d.title, d.happenedAt));
      final people = d.people.map((p) => p.name).join(', ');
      buf.writeln(
          '=== ${d.title} — ${_fmt(d.happenedAt)}${people.isNotEmpty ? ' (with $people)' : ''} ===');
      if (d.summary != null) buf.writeln('Summary: ${d.summary}');
      for (final f in db.conversationFacts(id)) {
        final who = f.resolvedName ?? f.personName;
        buf.writeln('- (${f.kind}) ${f.text}'
            '${who != null ? ' — $who' : ''}'
            '${f.dueHint != null ? ' [due ${f.dueHint}]' : ''}');
      }
      final tx = d.transcriptText;
      if (tx.isNotEmpty) {
        buf.writeln('Excerpt: ${tx.length > 600 ? '${tx.substring(0, 600)}…' : tx}');
      }
      buf.writeln();
    }

    final user = 'QUESTION: $question\n\nCONVERSATION RECORDS:\n$buf';
    final answer =
        await ExtractionService.instance.complete(db, system: _system, user: user);
    return AskResult(answer.trim(), citations);
  }

  String _fmt(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}
