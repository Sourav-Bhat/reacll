import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Versioned schema migrations (Alembic/Prisma-style, keyed by PRAGMA
/// user_version).
///
/// How it works:
///   • A FRESH install runs [createSchema] once (the latest baseline) and is
///     stamped at [schemaVersion] — it never replays these.
///   • An EXISTING database replays only the migrations it is missing, in
///     order, each bumping user_version by one.
///
/// To add a schema change in future:
///   1. bump `schemaVersion` in schema.dart (e.g. 4 -> 5)
///   2. update `createSchema` so fresh installs get the new shape
///   3. add an entry below keyed by the NEW version (e.g. 5:)
///   4. keep it ADDITIVE — `ALTER TABLE ... ADD COLUMN`, `CREATE TABLE IF NOT
///      EXISTS`, new indexes. Avoid dropping/rewriting so existing data
///      survives. (SQLite can't drop a column/constraint in place; if you ever
///      truly must, rebuild that one table with a copy, don't wipe the DB.)
///
/// The key `n` upgrades a database currently at version `n-1` to version `n`.
final Map<int, void Function(Database db)> migrations = {
  // v3 -> v4: full contact cards + attendee/mentioned split.
  //
  // This one is a deliberate one-time rebuild (the previous schema had a
  // UNIQUE(name) constraint we had to remove, which SQLite can't ALTER away,
  // and the data was still disposable). It is the LAST destructive migration —
  // everything from here on is additive so real data is preserved.
  4: (db) {
    db.execute('PRAGMA foreign_keys = OFF');
    for (final t in const [
      'transcript_fts', 'conversation_people', 'conversation_topics',
      'segments', 'speaker_clusters', 'diarizations', 'clarifications',
      'facts', 'extractions', 'transcripts', 'artifacts', 'voice_prints',
      'topics', 'conversations', 'people'
    ]) {
      db.execute('DROP TABLE IF EXISTS $t');
    }
    db.execute("DELETE FROM settings WHERE key = 'sample_loaded'");
    db.execute(createSchema); // recreate at the v4 shape
  },

  // v4 -> v5: personal notes on a conversation (additive).
  // Defensive: the v4 rebuild recreates via createSchema (latest shape), which
  // already has `notes`, so only add the column if it's missing. Follow this
  // guard pattern for every future ADD COLUMN migration.
  5: (db) {
    final cols = db
        .select('PRAGMA table_info(conversations)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('notes')) {
      db.execute('ALTER TABLE conversations ADD COLUMN notes TEXT');
    }
  },

  // v5 -> v6: AI summary + conversation type/bucket (additive, guarded).
  6: (db) {
    final cols = db
        .select('PRAGMA table_info(conversations)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains('summary')) {
      db.execute('ALTER TABLE conversations ADD COLUMN summary TEXT');
    }
    if (!cols.contains('bucket')) {
      db.execute('ALTER TABLE conversations ADD COLUMN bucket TEXT');
    }
  },
};
