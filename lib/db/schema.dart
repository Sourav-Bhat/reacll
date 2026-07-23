/// Recall database schema — single source of truth.
/// The sandbox test harness executes this exact SQL against real SQLite,
/// so keep it standard SQL (no Dart interpolation).
library;

const schemaVersion = 5;

const createSchema = '''
PRAGMA foreign_keys = ON;

-- People are full contact records. Names are NOT globally unique — two
-- different "Ravi"s (different companies) can coexist and are disambiguated
-- by company/role. The UI picks the right one; the AI never auto-links an
-- ambiguous bare name.
CREATE TABLE IF NOT EXISTS people (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL COLLATE NOCASE,
  company     TEXT,
  role        TEXT,
  email       TEXT,
  notes       TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_people_name ON people(name COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS conversations (
  id            INTEGER PRIMARY KEY,
  title         TEXT NOT NULL DEFAULT 'Untitled conversation',
  happened_at   TEXT NOT NULL DEFAULT (datetime('now')),
  duration_sec  INTEGER NOT NULL DEFAULT 0,
  notes         TEXT,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- FR-4: a conversation holds many artifacts (recording / imported audio / transcript / note)
CREATE TABLE IF NOT EXISTS artifacts (
  id               INTEGER PRIMARY KEY,
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL CHECK (kind IN ('recording','imported_audio','transcript','note')),
  file_path        TEXT,
  status           TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','transcribing','done','failed')),
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_artifacts_conv ON artifacts(conversation_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_status ON artifacts(status);

CREATE TABLE IF NOT EXISTS transcripts (
  id               INTEGER PRIMARY KEY,
  artifact_id      INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  text             TEXT NOT NULL,
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_transcripts_conv ON transcripts(conversation_id);

-- role distinguishes who was actually in the room ('attendee') from people
-- merely referenced ('mentioned'). attendee always wins if both apply.
CREATE TABLE IF NOT EXISTS conversation_people (
  conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  person_id       INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  role            TEXT NOT NULL DEFAULT 'attendee'
                  CHECK (role IN ('attendee','mentioned')),
  PRIMARY KEY (conversation_id, person_id)
);

CREATE TABLE IF NOT EXISTS topics (
  id    INTEGER PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE COLLATE NOCASE
);

CREATE TABLE IF NOT EXISTS conversation_topics (
  conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  topic_id        INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, topic_id)
);

-- FR-7: full-text search (external-content FTS5 kept in sync by triggers)
CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
  text,
  content='transcripts',
  content_rowid='id',
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
  INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
  INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE OF text ON transcripts BEGIN
  INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES ('delete', old.id, old.text);
  INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
END;

-- ============ Phase 2: understanding layer ============

-- Extraction progress per conversation (FR-9).
CREATE TABLE IF NOT EXISTS extractions (
  conversation_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','done','failed','skipped')),
  error           TEXT,
  updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

-- FR-9/FR-13: typed, temporal facts. person_id nullable until resolved;
-- person_name keeps the raw extracted name so nothing lands on the wrong person.
CREATE TABLE IF NOT EXISTS facts (
  id               INTEGER PRIMARY KEY,
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  person_id        INTEGER REFERENCES people(id) ON DELETE SET NULL,
  person_name      TEXT,
  kind             TEXT NOT NULL CHECK (kind IN ('commitment','decision','fact','thread')),
  text             TEXT NOT NULL,
  due_hint         TEXT,
  confidence       REAL NOT NULL DEFAULT 1.0,
  happened_at      TEXT NOT NULL,
  superseded_by    INTEGER REFERENCES facts(id) ON DELETE SET NULL,
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','done','dismissed')),
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_facts_person ON facts(person_id, happened_at DESC);
CREATE INDEX IF NOT EXISTS idx_facts_conv ON facts(conversation_id);

-- FR-11: clarification questions, capped at 3 per conversation by the service.
-- kind 'speaker' (FR-15) carries the diarization cluster to enroll on answer.
CREATE TABLE IF NOT EXISTS clarifications (
  id               INTEGER PRIMARY KEY,
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  question         TEXT NOT NULL,
  reason           TEXT,
  kind             TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text','speaker')),
  speaker_label    INTEGER,
  fact_id          INTEGER REFERENCES facts(id) ON DELETE CASCADE,
  answer           TEXT,
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','answered','dismissed')),
  created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_clar_conv ON clarifications(conversation_id, status);

-- ============ Phase 3: voice identity ============

-- FR-14: diarization output — speaker-labelled time segments.
CREATE TABLE IF NOT EXISTS segments (
  id               INTEGER PRIMARY KEY,
  artifact_id      INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  speaker_label    INTEGER NOT NULL,
  person_id        INTEGER REFERENCES people(id) ON DELETE SET NULL,
  match_confidence REAL,
  start_ms         INTEGER NOT NULL,
  end_ms           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_segments_conv ON segments(conversation_id, start_ms);

-- FR-14/FR-15: one mean embedding per speaker cluster per conversation
-- (float32 little-endian BLOB). Enrollment copies these into voice_prints.
CREATE TABLE IF NOT EXISTS speaker_clusters (
  conversation_id  INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  speaker_label    INTEGER NOT NULL,
  embedding        BLOB NOT NULL,
  dim              INTEGER NOT NULL,
  total_ms         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (conversation_id, speaker_label)
);

-- Diarization progress per audio artifact (mirrors extractions).
CREATE TABLE IF NOT EXISTS diarizations (
  artifact_id  INTEGER PRIMARY KEY REFERENCES artifacts(id) ON DELETE CASCADE,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','running','done','failed','skipped')),
  error        TEXT,
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- FR-15/FR-16: enrolled voice prints, several per person over time.
CREATE TABLE IF NOT EXISTS voice_prints (
  id                     INTEGER PRIMARY KEY,
  person_id              INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  embedding              BLOB NOT NULL,
  dim                    INTEGER NOT NULL,
  source_conversation_id INTEGER REFERENCES conversations(id) ON DELETE SET NULL,
  created_at             TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_voice_prints_person ON voice_prints(person_id);

-- App settings (API key, whisper model, ...).
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

/// FR-10/FR-13: person timeline, newest first, superseded flagged not hidden.
const personFactsSql = '''
SELECT f.id, f.kind, f.text, f.due_hint, f.happened_at, f.status,
       f.superseded_by IS NOT NULL AS superseded,
       f.conversation_id, c.title AS conversation_title
FROM facts f
JOIN conversations c ON c.id = f.conversation_id
WHERE f.person_id = ?
ORDER BY f.happened_at DESC, f.id DESC;
''';

/// FR-12: brief blocks — open commitments, recent decisions, open threads.
const briefSql = '''
SELECT f.kind, f.text, f.due_hint, f.happened_at,
       f.superseded_by IS NOT NULL AS superseded
FROM facts f
WHERE f.person_id = ?
  AND f.status = 'open'
  AND f.superseded_by IS NULL
ORDER BY CASE f.kind
           WHEN 'commitment' THEN 0
           WHEN 'thread' THEN 1
           WHEN 'decision' THEN 2
           ELSE 3 END,
         f.happened_at DESC
LIMIT 30;
''';

/// Last-met date for a person — only meetings they actually attended.
const lastMetSql = '''
SELECT max(c.happened_at) FROM conversations c
JOIN conversation_people cp ON cp.conversation_id = c.id
WHERE cp.person_id = ? AND cp.role = 'attendee';
''';

/// Open clarifications for a conversation (FR-11 + FR-15 speaker questions).
const openClarificationsSql = '''
SELECT id, question, reason, fact_id, kind, speaker_label FROM clarifications
WHERE conversation_id = ? AND status = 'open'
ORDER BY CASE kind WHEN 'speaker' THEN 0 ELSE 1 END, id
LIMIT 3;
''';

/// FR-16: speaker summary per conversation — who spoke, resolved or not.
const conversationSpeakersSql = '''
SELECT s.speaker_label,
       p.name                    AS person_name,
       max(s.match_confidence)   AS confidence,
       sum(s.end_ms - s.start_ms) AS talk_ms
FROM segments s
LEFT JOIN people p ON p.id = s.person_id
WHERE s.conversation_id = ?
GROUP BY s.speaker_label, p.name
ORDER BY talk_ms DESC;
''';

/// All voice prints (loaded into memory for cosine matching).
const voicePrintsSql = '''
SELECT vp.id, vp.person_id, p.name, vp.embedding, vp.dim
FROM voice_prints vp JOIN people p ON p.id = vp.person_id;
''';

/// Facts extracted for a conversation (detail screen).
const conversationFactsSql = '''
SELECT f.id, f.kind, f.text, f.person_name, f.due_hint,
       p.name AS resolved_name
FROM facts f LEFT JOIN people p ON p.id = f.person_id
WHERE f.conversation_id = ?
ORDER BY CASE f.kind
           WHEN 'decision' THEN 0
           WHEN 'commitment' THEN 1
           WHEN 'thread' THEN 2
           ELSE 3 END, f.id;
''';

/// FR-7 search: hits across all conversations, optional person filter,
/// highlighted snippet, newest first.
const searchSql = '''
SELECT c.id            AS conversation_id,
       c.title         AS title,
       c.happened_at   AS happened_at,
       m.snip          AS snip,
       min(m.r)        AS rank
FROM (
  SELECT t.conversation_id AS cid,
         snippet(transcript_fts, 0, '[', ']', ' … ', 12) AS snip,
         rank AS r
  FROM transcript_fts
  JOIN transcripts t ON t.id = transcript_fts.rowid
  WHERE transcript_fts MATCH ?
  ORDER BY rank
  LIMIT 200
) m
JOIN conversations c ON c.id = m.cid
WHERE (? IS NULL OR c.id IN (
        SELECT conversation_id FROM conversation_people WHERE person_id = ?))
GROUP BY c.id, m.snip
ORDER BY rank, c.happened_at DESC
LIMIT 50;
''';

/// Home list: conversations with people names aggregated, newest first.
const homeListSql = '''
SELECT c.id, c.title, c.happened_at, c.duration_sec,
       (SELECT group_concat(p.name, ', ')
          FROM conversation_people cp JOIN people p ON p.id = cp.person_id
         WHERE cp.conversation_id = c.id AND cp.role = 'attendee') AS people_names,
       (SELECT count(*) FROM artifacts a
         WHERE a.conversation_id = c.id AND a.status IN ('pending','transcribing')) AS busy
FROM conversations c
ORDER BY c.happened_at DESC
LIMIT ? OFFSET ?;
''';

/// Person page: conversations, with the person's role in each (attended/mentioned).
const personConvosSql = '''
SELECT c.id, c.title, c.happened_at, c.duration_sec, cp.role
FROM conversations c
JOIN conversation_people cp ON cp.conversation_id = c.id
WHERE cp.person_id = ?
ORDER BY c.happened_at DESC;
''';

/// People list with attended-conversation counts and contact fields.
const peopleListSql = '''
SELECT p.id, p.name, p.company, p.role,
       count(cp.conversation_id) AS convo_count
FROM people p
LEFT JOIN conversation_people cp
       ON cp.person_id = p.id AND cp.role = 'attendee'
GROUP BY p.id
ORDER BY convo_count DESC, p.name COLLATE NOCASE;
''';
