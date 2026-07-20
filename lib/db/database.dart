import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'schema.dart';

/// Single-isolate data layer. All methods are synchronous (sqlite3 package),
/// cheap for our data sizes; heavy work (whisper) lives elsewhere.
class RecallDb {
  RecallDb._(this._db);
  static RecallDb? _instance;
  final Database _db;

  static Future<RecallDb> open() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'recall.db');
    final db = sqlite3.open(path);
    db.execute(createSchema);
    _instance = RecallDb._(db);
    return _instance!;
  }

  /// Test-only constructor (in-memory).
  static RecallDb openInMemory() {
    final db = sqlite3.openInMemory();
    db.execute(createSchema);
    return RecallDb._(db);
  }

  static String get dbFileName => 'recall.db';

  // ---------- conversations ----------

  int createConversation({String? title, DateTime? happenedAt, int durationSec = 0}) {
    _db.execute(
      'INSERT INTO conversations (title, happened_at, duration_sec) VALUES (?, ?, ?)',
      [
        title ?? 'Untitled conversation',
        (happenedAt ?? DateTime.now()).toIso8601String(),
        durationSec,
      ],
    );
    return _db.lastInsertRowId;
  }

  void updateConversation(int id, {String? title, int? durationSec}) {
    if (title != null) {
      _db.execute('UPDATE conversations SET title = ? WHERE id = ?', [title, id]);
    }
    if (durationSec != null) {
      _db.execute('UPDATE conversations SET duration_sec = ? WHERE id = ?', [durationSec, id]);
    }
  }

  List<ConversationSummary> homeList({int limit = 100, int offset = 0}) {
    final rows = _db.select(homeListSql, [limit, offset]);
    return rows.map(_summaryFromRow).toList();
  }

  ConversationSummary _summaryFromRow(Row r) => ConversationSummary(
        id: r['id'] as int,
        title: r['title'] as String,
        happenedAt: DateTime.parse(r['happened_at'] as String),
        durationSec: (r['duration_sec'] as int?) ?? 0,
        peopleNames: (r['people_names'] as String?) ?? '',
        busy: ((r['busy'] as int?) ?? 0) > 0,
      );

  ConversationDetail detail(int id) {
    final c = _db.select(
        'SELECT id, title, happened_at, duration_sec FROM conversations WHERE id = ?', [id]).first;
    final people = _db
        .select(
            'SELECT p.id, p.name FROM people p '
            'JOIN conversation_people cp ON cp.person_id = p.id '
            'WHERE cp.conversation_id = ? ORDER BY p.name COLLATE NOCASE',
            [id])
        .map((r) => Person(id: r['id'] as int, name: r['name'] as String))
        .toList();
    final topics = _db
        .select(
            'SELECT t.name FROM topics t JOIN conversation_topics ct ON ct.topic_id = t.id '
            'WHERE ct.conversation_id = ?',
            [id])
        .map((r) => r['name'] as String)
        .toList();
    final artifacts = _db
        .select(
            'SELECT id, conversation_id, kind, file_path, status FROM artifacts '
            'WHERE conversation_id = ? ORDER BY created_at',
            [id])
        .map((r) => Artifact(
              id: r['id'] as int,
              conversationId: r['conversation_id'] as int,
              kind: r['kind'] as String,
              filePath: r['file_path'] as String?,
              status: r['status'] as String,
            ))
        .toList();
    final text = _db
        .select(
            'SELECT text FROM transcripts WHERE conversation_id = ? ORDER BY created_at', [id])
        .map((r) => r['text'] as String)
        .join('\n\n');
    return ConversationDetail(
      id: c['id'] as int,
      title: c['title'] as String,
      happenedAt: DateTime.parse(c['happened_at'] as String),
      durationSec: (c['duration_sec'] as int?) ?? 0,
      people: people,
      topics: topics,
      artifacts: artifacts,
      transcriptText: text,
    );
  }

  // ---------- artifacts & transcripts ----------

  int addArtifact(int conversationId, String kind, {String? filePath, String status = 'pending'}) {
    _db.execute(
      'INSERT INTO artifacts (conversation_id, kind, file_path, status) VALUES (?, ?, ?, ?)',
      [conversationId, kind, filePath, status],
    );
    return _db.lastInsertRowId;
  }

  void setArtifactStatus(int artifactId, String status) {
    _db.execute('UPDATE artifacts SET status = ? WHERE id = ?', [status, artifactId]);
  }

  List<Artifact> pendingAudioArtifacts() {
    return _db
        .select("SELECT id, conversation_id, kind, file_path, status FROM artifacts "
            "WHERE status = 'pending' AND kind IN ('recording','imported_audio') "
            "ORDER BY created_at")
        .map((r) => Artifact(
              id: r['id'] as int,
              conversationId: r['conversation_id'] as int,
              kind: r['kind'] as String,
              filePath: r['file_path'] as String?,
              status: r['status'] as String,
            ))
        .toList();
  }

  /// FTS trigger indexes the text automatically.
  int addTranscript(int artifactId, int conversationId, String text) {
    _db.execute(
      'INSERT INTO transcripts (artifact_id, conversation_id, text) VALUES (?, ?, ?)',
      [artifactId, conversationId, text],
    );
    return _db.lastInsertRowId;
  }

  // ---------- people & topics ----------

  int upsertPerson(String name) {
    final n = name.trim();
    final existing = _db.select('SELECT id FROM people WHERE name = ? COLLATE NOCASE', [n]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    _db.execute('INSERT INTO people (name) VALUES (?)', [n]);
    return _db.lastInsertRowId;
  }

  void tagPerson(int conversationId, int personId) {
    _db.execute(
        'INSERT OR IGNORE INTO conversation_people (conversation_id, person_id) VALUES (?, ?)',
        [conversationId, personId]);
  }

  void untagPerson(int conversationId, int personId) {
    _db.execute(
        'DELETE FROM conversation_people WHERE conversation_id = ? AND person_id = ?',
        [conversationId, personId]);
  }

  int upsertTopic(String name) {
    final n = name.trim();
    final existing = _db.select('SELECT id FROM topics WHERE name = ? COLLATE NOCASE', [n]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    _db.execute('INSERT INTO topics (name) VALUES (?)', [n]);
    return _db.lastInsertRowId;
  }

  void tagTopic(int conversationId, int topicId) {
    _db.execute(
        'INSERT OR IGNORE INTO conversation_topics (conversation_id, topic_id) VALUES (?, ?)',
        [conversationId, topicId]);
  }

  List<Person> peopleList() {
    return _db
        .select(peopleListSql)
        .map((r) => Person(
              id: r['id'] as int,
              name: r['name'] as String,
              convoCount: (r['convo_count'] as int?) ?? 0,
            ))
        .toList();
  }

  List<ConversationSummary> personConversations(int personId) {
    return _db.select(personConvosSql, [personId]).map((r) => ConversationSummary(
          id: r['id'] as int,
          title: r['title'] as String,
          happenedAt: DateTime.parse(r['happened_at'] as String),
          durationSec: (r['duration_sec'] as int?) ?? 0,
          peopleNames: '',
          busy: false,
        )).toList();
  }

  // ---------- search (FR-7) ----------

  /// Sanitizes user input into an FTS5 prefix query:
  /// `budget pri` -> `"budget"* "pri"*`
  static String ftsQuery(String raw) {
    final words = raw
        .replaceAll(RegExp(r'["\*\(\)\^]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    return words.map((w) => '"$w"*').join(' ');
  }

  List<SearchHit> search(String raw, {int? personId}) {
    final q = ftsQuery(raw);
    if (q.isEmpty) return [];
    final rows = _db.select(searchSql, [q, personId, personId]);
    return rows
        .map((r) => SearchHit(
              conversationId: r['conversation_id'] as int,
              title: r['title'] as String,
              happenedAt: DateTime.parse(r['happened_at'] as String),
              snippet: r['snip'] as String,
            ))
        .toList();
  }

  // ---------- Phase 2: settings ----------

  String? getSetting(String key) {
    final r = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value]);
  }

  // ---------- Phase 2: extraction queue (FR-9) ----------

  void queueExtraction(int conversationId) {
    _db.execute(
        "INSERT INTO extractions (conversation_id, status) VALUES (?, 'pending') "
        "ON CONFLICT(conversation_id) DO UPDATE SET status='pending', error=NULL, "
        "updated_at=datetime('now')",
        [conversationId]);
  }

  List<int> pendingExtractions() {
    return _db
        .select("SELECT conversation_id FROM extractions WHERE status = 'pending'")
        .map((r) => r['conversation_id'] as int)
        .toList();
  }

  void setExtractionStatus(int conversationId, String status, {String? error}) {
    _db.execute(
        "UPDATE extractions SET status = ?, error = ?, updated_at = datetime('now') "
        "WHERE conversation_id = ?",
        [status, error, conversationId]);
  }

  String? extractionStatus(int conversationId) {
    final r = _db.select(
        'SELECT status FROM extractions WHERE conversation_id = ?', [conversationId]);
    return r.isEmpty ? null : r.first['status'] as String;
  }

  // ---------- Phase 2: facts (FR-9/FR-13) ----------

  int addFact({
    required int conversationId,
    required String kind,
    required String text,
    int? personId,
    String? personName,
    String? dueHint,
    double confidence = 1.0,
    DateTime? happenedAt,
  }) {
    final when = happenedAt ??
        DateTime.parse(_db.select(
                'SELECT happened_at FROM conversations WHERE id = ?',
                [conversationId]).first['happened_at'] as String);
    _db.execute(
        'INSERT INTO facts (conversation_id, person_id, person_name, kind, text, '
        'due_hint, confidence, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [conversationId, personId, personName, kind, text, dueHint,
         confidence, when.toIso8601String()]);
    return _db.lastInsertRowId;
  }

  void linkFactPerson(int factId, int personId) {
    _db.execute('UPDATE facts SET person_id = ? WHERE id = ?', [personId, factId]);
  }

  /// FR-13: newest fact supersedes an older one — flagged, never deleted.
  void supersedeFact({required int oldFactId, required int newFactId}) {
    _db.execute('UPDATE facts SET superseded_by = ? WHERE id = ?',
        [newFactId, oldFactId]);
  }

  void setFactStatus(int factId, String status) {
    _db.execute('UPDATE facts SET status = ? WHERE id = ?', [status, factId]);
  }

  List<Fact> personFacts(int personId) {
    return _db.select(personFactsSql, [personId]).map((r) => Fact(
          id: r['id'] as int,
          conversationId: r['conversation_id'] as int,
          kind: r['kind'] as String,
          text: r['text'] as String,
          dueHint: r['due_hint'] as String?,
          happenedAt: DateTime.parse(r['happened_at'] as String),
          superseded: (r['superseded'] as int) == 1,
          status: r['status'] as String,
          conversationTitle: r['conversation_title'] as String,
        )).toList();
  }

  List<Fact> conversationFacts(int conversationId) {
    return _db.select(conversationFactsSql, [conversationId]).map((r) => Fact(
          id: r['id'] as int,
          conversationId: conversationId,
          kind: r['kind'] as String,
          text: r['text'] as String,
          personName: r['person_name'] as String?,
          resolvedName: r['resolved_name'] as String?,
          dueHint: r['due_hint'] as String?,
          happenedAt: DateTime.now(),
        )).toList();
  }

  /// FR-12: offline deterministic brief blocks for a person.
  ({DateTime? lastMet, List<Fact> items}) brief(int personId) {
    final lm = _db.select(lastMetSql, [personId]).first.columnAt(0) as String?;
    final items = _db.select(briefSql, [personId]).map((r) => Fact(
          id: 0,
          conversationId: 0,
          kind: r['kind'] as String,
          text: r['text'] as String,
          dueHint: r['due_hint'] as String?,
          happenedAt: DateTime.parse(r['happened_at'] as String),
          superseded: (r['superseded'] as int) == 1,
        )).toList();
    return (lastMet: lm == null ? null : DateTime.parse(lm), items: items);
  }

  // ---------- Phase 2: clarifications (FR-11) ----------

  int addClarification(int conversationId, String question,
      {String? reason, int? factId, String kind = 'text', int? speakerLabel}) {
    _db.execute(
        'INSERT INTO clarifications (conversation_id, question, reason, fact_id, '
        'kind, speaker_label) VALUES (?, ?, ?, ?, ?, ?)',
        [conversationId, question, reason, factId, kind, speakerLabel]);
    return _db.lastInsertRowId;
  }

  List<Clarification> openClarifications(int conversationId) {
    return _db.select(openClarificationsSql, [conversationId]).map((r) =>
        Clarification(
          id: r['id'] as int,
          conversationId: conversationId,
          question: r['question'] as String,
          reason: r['reason'] as String?,
          factId: r['fact_id'] as int?,
          kind: r['kind'] as String,
          speakerLabel: r['speaker_label'] as int?,
        )).toList();
  }

  int openClarificationCount() =>
      _db.select("SELECT count(*) AS n FROM clarifications WHERE status='open'")
          .first['n'] as int;

  void answerClarification(int id, String answer) {
    _db.execute(
        "UPDATE clarifications SET answer = ?, status = 'answered' WHERE id = ?",
        [answer, id]);
  }

  void dismissClarification(int id) {
    _db.execute("UPDATE clarifications SET status = 'dismissed' WHERE id = ?", [id]);
  }

  // ---------- Phase 3: diarization queue (FR-14) ----------

  void queueDiarization(int artifactId) {
    _db.execute(
        "INSERT INTO diarizations (artifact_id, status) VALUES (?, 'pending') "
        "ON CONFLICT(artifact_id) DO UPDATE SET status='pending', error=NULL, "
        "updated_at=datetime('now')",
        [artifactId]);
  }

  List<Artifact> pendingDiarizations() {
    return _db
        .select("SELECT a.id, a.conversation_id, a.kind, a.file_path, a.status "
            "FROM artifacts a JOIN diarizations d ON d.artifact_id = a.id "
            "WHERE d.status = 'pending' AND a.file_path IS NOT NULL")
        .map((r) => Artifact(
              id: r['id'] as int,
              conversationId: r['conversation_id'] as int,
              kind: r['kind'] as String,
              filePath: r['file_path'] as String?,
              status: r['status'] as String,
            ))
        .toList();
  }

  void setDiarizationStatus(int artifactId, String status, {String? error}) {
    _db.execute(
        "UPDATE diarizations SET status = ?, error = ?, updated_at = datetime('now') "
        "WHERE artifact_id = ?",
        [status, error, artifactId]);
  }

  // ---------- Phase 3: segments, clusters, voice prints ----------

  void addSegment(int artifactId, int conversationId, int speakerLabel,
      int startMs, int endMs) {
    _db.execute(
        'INSERT INTO segments (artifact_id, conversation_id, speaker_label, '
        'start_ms, end_ms) VALUES (?, ?, ?, ?, ?)',
        [artifactId, conversationId, speakerLabel, startMs, endMs]);
  }

  void linkSpeaker(int conversationId, int speakerLabel, int personId,
      double confidence) {
    _db.execute(
        'UPDATE segments SET person_id = ?, match_confidence = ? '
        'WHERE conversation_id = ? AND speaker_label = ?',
        [personId, confidence, conversationId, speakerLabel]);
  }

  void addSpeakerCluster(int conversationId, int speakerLabel,
      List<int> embedding, int dim, int totalMs) {
    _db.execute(
        'INSERT OR REPLACE INTO speaker_clusters '
        '(conversation_id, speaker_label, embedding, dim, total_ms) '
        'VALUES (?, ?, ?, ?, ?)',
        [conversationId, speakerLabel, embedding, dim, totalMs]);
  }

  /// (embedding blob, dim) for one cluster, or null.
  (List<int>, int)? speakerCluster(int conversationId, int speakerLabel) {
    final r = _db.select(
        'SELECT embedding, dim FROM speaker_clusters '
        'WHERE conversation_id = ? AND speaker_label = ?',
        [conversationId, speakerLabel]);
    if (r.isEmpty) return null;
    return (r.first['embedding'] as List<int>, r.first['dim'] as int);
  }

  void addVoicePrint(int personId, List<int> embedding, int dim,
      {int? sourceConversationId}) {
    _db.execute(
        'INSERT INTO voice_prints (person_id, embedding, dim, source_conversation_id) '
        'VALUES (?, ?, ?, ?)',
        [personId, embedding, dim, sourceConversationId]);
  }

  /// All prints as (personId, Float32List) for in-memory matching.
  List<(int, Float32List)> voicePrints() {
    return _db.select(voicePrintsSql).map((r) {
      final blob = Uint8List.fromList(r['embedding'] as List<int>);
      final dim = r['dim'] as int;
      return (
        r['person_id'] as int,
        blob.buffer.asFloat32List(blob.offsetInBytes, dim)
      );
    }).toList();
  }

  String personName(int personId) =>
      _db.select('SELECT name FROM people WHERE id = ?', [personId])
          .first['name'] as String;

  /// Speaker summary for the detail screen (FR-16).
  List<({int label, String? name, double? confidence, int talkMs})>
      conversationSpeakers(int conversationId) {
    return _db.select(conversationSpeakersSql, [conversationId]).map((r) => (
          label: r['speaker_label'] as int,
          name: r['person_name'] as String?,
          confidence: r['confidence'] as double?,
          talkMs: (r['talk_ms'] as int?) ?? 0,
        )).toList();
  }

  // ---------- maintenance ----------

  String databasePath() => _db.select('PRAGMA database_list').first['file'] as String;

  void dispose() {
    _db.dispose();
    _instance = null;
  }
}

/// Where captured/imported media lives.
Future<Directory> mediaDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'media'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
