import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'migrations.dart';
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
    _prepare(db);
    _instance = RecallDb._(db);
    return _instance!;
  }

  /// Fresh install → create schema. Existing install on an older schema →
  /// rebuild from scratch (data is disposable/reloadable — the agreed
  /// reset-not-migrate approach). The Settings API key is preserved.
  /// Migration runner (see db/migrations.dart). Fresh installs get the latest
  /// baseline in one shot; existing databases replay only the migrations they
  /// are missing, one version at a time.
  static void _prepare(Database db) {
    final hasCore = db
        .select("SELECT 1 FROM sqlite_master "
            "WHERE type='table' AND name='people'")
        .isNotEmpty;

    if (!hasCore) {
      // Fresh install → latest schema directly, stamped at the current version.
      db.execute(createSchema);
      db.execute('PRAGMA user_version = $schemaVersion');
      return;
    }

    // Existing DB. Determine its current version. Pre-framework builds never
    // stamped user_version (it reads 0), so infer a baseline from the schema
    // shape: a people.company column means it is already at v4.
    var from =
        (db.select('PRAGMA user_version').first['user_version'] as int?) ?? 0;
    if (from == 0) {
      final cols = db
          .select('PRAGMA table_info(people)')
          .map((r) => r['name'] as String)
          .toSet();
      from = cols.contains('company') ? 4 : 3;
      db.execute('PRAGMA user_version = $from');
    }

    // Replay each missing migration in order.
    for (var v = from + 1; v <= schemaVersion; v++) {
      final migrate = migrations[v];
      if (migrate == null) {
        throw StateError('No migration registered for schema v$v '
            '(add it to db/migrations.dart)');
      }
      migrate(db);
      db.execute('PRAGMA user_version = $v');
    }
  }

  /// Test-only constructor (in-memory).
  static RecallDb openInMemory() {
    final db = sqlite3.openInMemory();
    db.execute(createSchema);
    db.execute('PRAGMA user_version = $schemaVersion');
    return RecallDb._(db);
  }

  /// Wipe all conversations, people and topics (keeps the API key). Used by the
  /// Settings "reset local data" action before reloading the sample.
  void resetLocalData() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('DELETE FROM conversations');
    _db.execute('DELETE FROM voice_prints');
    _db.execute('DELETE FROM people');
    _db.execute('DELETE FROM topics');
    _db.execute("DELETE FROM settings WHERE key = 'sample_loaded'");
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

  /// W12: delete a conversation and everything hanging off it (artifacts,
  /// transcripts, facts, segments, tags…) via ON DELETE CASCADE.
  void deleteConversation(int id) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('DELETE FROM conversations WHERE id = ?', [id]);
  }

  /// W4: personal notes on a conversation.
  void setConversationNotes(int id, String notes) {
    _db.execute('UPDATE conversations SET notes = ? WHERE id = ?',
        [notes.trim().isEmpty ? null : notes.trim(), id]);
  }

  /// W1: the owner ("Me") — always a participant. Created once, id cached in
  /// settings, tagged on every new recording/import.
  int mePersonId() {
    final saved = getSetting('me_person_id');
    if (saved != null) {
      final exists = _db.select('SELECT 1 FROM people WHERE id = ?', [int.parse(saved)]);
      if (exists.isNotEmpty) return int.parse(saved);
    }
    final id = createPerson(name: 'Me');
    setSetting('me_person_id', '$id');
    return id;
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
        bucket: r['bucket'] as String?,
      );

  /// W7/W13: store the AI summary + conversation type/bucket.
  void setConversationMemory(int id, {String? summary, String? bucket}) {
    if (summary != null) {
      _db.execute('UPDATE conversations SET summary = ? WHERE id = ?',
          [_nn(summary), id]);
    }
    if (bucket != null) {
      _db.execute('UPDATE conversations SET bucket = ? WHERE id = ?',
          [_nn(bucket), id]);
    }
  }

  ConversationDetail detail(int id) {
    final c = _db.select(
        'SELECT id, title, happened_at, duration_sec, notes, summary, bucket '
        'FROM conversations WHERE id = ?',
        [id]).first;
    List<Person> peopleByRole(String role) => _db
        .select(
            'SELECT p.id, p.name, p.company, p.role FROM people p '
            'JOIN conversation_people cp ON cp.person_id = p.id '
            'WHERE cp.conversation_id = ? AND cp.role = ? '
            'ORDER BY p.name COLLATE NOCASE',
            [id, role])
        .map((r) => Person(
              id: r['id'] as int,
              name: r['name'] as String,
              company: r['company'] as String?,
              role: r['role'] as String?,
            ))
        .toList();
    final people = peopleByRole('attendee');
    final mentioned = peopleByRole('mentioned');
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
      notes: c['notes'] as String?,
      summary: c['summary'] as String?,
      bucket: c['bucket'] as String?,
      people: people,
      mentioned: mentioned,
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

  /// W9: a killed app can leave an artifact stuck on 'transcribing' forever.
  /// Reset any such artifacts to 'pending' so the queue retries them.
  void resetStuckTranscriptions() {
    _db.execute(
        "UPDATE artifacts SET status = 'pending' WHERE status = 'transcribing'");
  }

  /// W5: point an artifact at its decoded 16 kHz WAV so diarization can read it.
  void updateArtifactPath(int artifactId, String path) {
    _db.execute(
        'UPDATE artifacts SET file_path = ? WHERE id = ?', [path, artifactId]);
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

  static String? _nn(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  /// Quick create-or-get by name (fallback path). With duplicate names allowed,
  /// prefer [createPerson]/[getPerson] + the picker for disambiguation.
  int upsertPerson(String name) {
    final n = name.trim();
    final existing =
        _db.select('SELECT id FROM people WHERE name = ? COLLATE NOCASE', [n]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    _db.execute('INSERT INTO people (name) VALUES (?)', [n]);
    return _db.lastInsertRowId;
  }

  /// Create a full contact. Names are not unique — two "Ravi"s can coexist.
  int createPerson({
    required String name,
    String? company,
    String? role,
    String? email,
    String? notes,
  }) {
    _db.execute(
        'INSERT INTO people (name, company, role, email, notes) '
        'VALUES (?, ?, ?, ?, ?)',
        [name.trim(), _nn(company), _nn(role), _nn(email), _nn(notes)]);
    return _db.lastInsertRowId;
  }

  Person? getPerson(int id) {
    final r = _db.select(
        'SELECT id, name, company, role, email, notes FROM people WHERE id = ?',
        [id]);
    if (r.isEmpty) return null;
    final row = r.first;
    return Person(
      id: row['id'] as int,
      name: row['name'] as String,
      company: row['company'] as String?,
      role: row['role'] as String?,
      email: row['email'] as String?,
      notes: row['notes'] as String?,
    );
  }

  void updatePerson(int id, {
    required String name,
    String? company,
    String? role,
    String? email,
    String? notes,
  }) {
    _db.execute(
        'UPDATE people SET name=?, company=?, role=?, email=?, notes=? WHERE id=?',
        [name.trim(), _nn(company), _nn(role), _nn(email), _nn(notes), id]);
  }

  /// Tag a person on a conversation. role 'attendee' (in the room) or
  /// 'mentioned' (merely referenced). attendee always wins if both apply.
  void tagPerson(int conversationId, int personId, {String role = 'attendee'}) {
    _db.execute(
        'INSERT INTO conversation_people (conversation_id, person_id, role) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(conversation_id, person_id) DO UPDATE SET role = '
        "CASE WHEN conversation_people.role = 'attendee' "
        "OR excluded.role = 'attendee' THEN 'attendee' ELSE 'mentioned' END",
        [conversationId, personId, role]);
  }

  void untagPerson(int conversationId, int personId) {
    _db.execute(
        'DELETE FROM conversation_people WHERE conversation_id = ? AND person_id = ?',
        [conversationId, personId]);
  }

  /// Explicit merge (user-chosen), e.g. to fold a whisper-mangled duplicate
  /// into the correct contact. Moves everything from [fromId] into [intoId].
  void mergePerson(int fromId, int intoId) {
    if (fromId == intoId) return;
    _db.execute('UPDATE facts SET person_id = ? WHERE person_id = ?', [intoId, fromId]);
    _db.execute('UPDATE segments SET person_id = ? WHERE person_id = ?', [intoId, fromId]);
    _db.execute(
        'UPDATE voice_prints SET person_id = ? WHERE person_id = ?', [intoId, fromId]);
    // Move tags, keeping the strongest role (attendee > mentioned).
    _db.execute(
        'INSERT INTO conversation_people (conversation_id, person_id, role) '
        'SELECT conversation_id, ?, role FROM conversation_people WHERE person_id = ? '
        'ON CONFLICT(conversation_id, person_id) DO UPDATE SET role = '
        "CASE WHEN conversation_people.role = 'attendee' OR excluded.role = 'attendee' "
        "THEN 'attendee' ELSE 'mentioned' END",
        [intoId, fromId]);
    _db.execute('DELETE FROM conversation_people WHERE person_id = ?', [fromId]);
    _db.execute('DELETE FROM people WHERE id = ?', [fromId]);
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
              company: r['company'] as String?,
              role: r['role'] as String?,
              convoCount: (r['convo_count'] as int?) ?? 0,
            ))
        .toList();
  }

  /// Conversations a person ATTENDED (Talks tab). Mentions surface via facts.
  List<ConversationSummary> personConversations(int personId) {
    return _db
        .select(personConvosSql, [personId])
        .where((r) => (r['role'] as String?) == 'attendee')
        .map((r) => ConversationSummary(
              id: r['id'] as int,
              title: r['title'] as String,
              happenedAt: DateTime.parse(r['happened_at'] as String),
              durationSec: (r['duration_sec'] as int?) ?? 0,
              peopleNames: '',
              busy: false,
            ))
        .toList();
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
