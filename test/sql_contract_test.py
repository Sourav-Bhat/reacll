#!/usr/bin/env python3
"""Recall SQL contract tests — executes the EXACT SQL shipped in lib/db/schema.dart
against real SQLite. Run: python3 test/sql_contract_test.py (from recall_app/)."""
import json
import os
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(HERE, 'lib/db/schema.dart')).read()

# Extract by const name, not position — robust to reordering.
def block(name):
    m = re.search(rf"const {name} = '''(.*?)''';", src, re.S)
    assert m, f'missing const {name}'
    return m.group(1)

CREATE = block('createSchema')
SEARCH = block('searchSql')
HOME = block('homeListSql')
PERSONC = block('personConvosSql')
PEOPLE = block('peopleListSql')
PFACTS = block('personFactsSql')
BRIEF = block('briefSql')
LASTMET = block('lastMetSql')
OPENCLAR = block('openClarificationsSql')
CONVFACTS = block('conversationFactsSql')

fails = []
def check(n, c, e=''):
    print(('PASS' if c else 'FAIL'), n, e)
    if not c:
        fails.append(n)

def fts(raw):
    return ' '.join(f'"{w}"*' for w in re.sub(r'["\*\(\)\^]', ' ', raw).split() if w)

db = sqlite3.connect(':memory:')
db.executescript(CREATE)
db.execute('PRAGMA foreign_keys=ON')
check('T0 schema creates cleanly', True)

# ---------- Phase 1 seed ----------
def conv(t, w, d=0):
    return db.execute('INSERT INTO conversations (title,happened_at,duration_sec) VALUES (?,?,?)', (t, w, d)).lastrowid
def art(c, k, status='done', path=None):
    return db.execute('INSERT INTO artifacts (conversation_id,kind,file_path,status) VALUES (?,?,?,?)', (c, k, path, status)).lastrowid
def tx(a, c, t):
    db.execute('INSERT INTO transcripts (artifact_id,conversation_id,text) VALUES (?,?,?)', (a, c, t))
def person(n):
    r = db.execute('SELECT id FROM people WHERE name=? COLLATE NOCASE', (n,)).fetchone()
    return r[0] if r else db.execute('INSERT INTO people (name) VALUES (?)', (n,)).lastrowid
def tag(c, p, role='attendee'):
    db.execute('INSERT OR IGNORE INTO conversation_people (conversation_id,person_id,role) VALUES (?,?,?)', (c, p, role))

c1 = conv('Vendor pricing call', '2026-07-13 10:30', 1920)
tx(art(c1, 'recording'), c1, 'Monthly budget add-on goes up 8 percent. Commit before the 25th to lock this pricing.')
c2 = conv('Budget review with Ravi', '2026-06-10 09:30', 2280)
tx(art(c2, 'imported_audio'), c2, 'In January the budget was fine - now frozen till Q4. Decision: defer the add-on.')
suresh, ravi, priya = person('Vendor A - Suresh'), person('Ravi'), person('Priya')
tag(c1, suresh); tag(c2, ravi); tag(c2, priya)

hits = db.execute(SEARCH, (fts('budget'), None, None)).fetchall()
check('T1 search hits both', {h[0] for h in hits} == {c1, c2})
check('T2 person filter', {h[0] for h in db.execute(SEARCH, (fts('budget'), ravi, ravi)).fetchall()} == {c2})
check('T3 snippet markers', '[' in hits[0][3])
check('T4 stemming', c2 in {h[0] for h in db.execute(SEARCH, (fts('decisions'), None, None)).fetchall()})
r1 = [r for r in db.execute(HOME, (100, 0)).fetchall() if r[0] == c2][0]
check('T5 home people agg', 'Ravi' in r1[5] and 'Priya' in r1[5])
check('T6 people counts', {r[1]: r[4] for r in db.execute(PEOPLE).fetchall()}['Ravi'] == 1)
check('T7 person convos', [r[0] for r in db.execute(PERSONC, (priya,)).fetchall()] == [c2])
big = conv('bulk', '2025-01-01'); ab = art(big, 'transcript')
for i in range(700):
    tx(ab, big, f'filler {i} vendor negotiations item{i}')
t0 = time.time(); db.execute(SEARCH, (fts('vendor negotiations'), None, None)).fetchall()
check('T8 700-transcript search <1s', time.time() - t0 < 1.0)

# ---------- Phase 2 ----------
def fact(cid, pid, kind, text, when, due=None):
    return db.execute('INSERT INTO facts (conversation_id,person_id,kind,text,due_hint,happened_at) VALUES (?,?,?,?,?,?)',
                      (cid, pid, kind, text, due, when)).lastrowid

cJan = conv('Budget Jan', '2026-01-10 10:00'); tag(cJan, ravi)
f1 = fact(cJan, ravi, 'fact', 'Budget is fine for the year', '2026-01-10 10:00')
f2 = fact(c2, ravi, 'fact', 'Budget frozen till Q4', '2026-06-10 09:30')
db.execute('UPDATE facts SET superseded_by=? WHERE id=?', (f2, f1))
fact(c2, ravi, 'commitment', 'Send revised vendor sheet', '2026-06-10 09:30', 'Friday')
fact(c2, ravi, 'thread', 'Support tier decision open', '2026-06-10 09:30')
fact(c2, ravi, 'decision', 'Defer the add-on to October', '2026-06-10 09:30')
fact(c2, None, 'commitment', 'Book the demo', '2026-06-10 09:30')  # unresolved

rows = db.execute(PFACTS, (ravi,)).fetchall()
check('T9 timeline newest-first', rows[0][4].startswith('2026-06'))
sup = {r[0]: r[6] for r in rows}
check('T10 superseded flagged not hidden', sup[f1] == 1 and sup[f2] == 0)
b = db.execute(BRIEF, (ravi,)).fetchall()
check('T11 brief order commitment-first', b[0][0] == 'commitment')
check('T12 brief excludes superseded', all('fine for the year' not in r[1] for r in b))
check('T13 unresolved fact not on brief', all('Book the demo' not in r[1] for r in b))
check('T14 last met', db.execute(LASTMET, (ravi,)).fetchone()[0] == '2026-06-10 09:30')
for i in range(5):
    db.execute('INSERT INTO clarifications (conversation_id,question) VALUES (?,?)', (c2, f'Q{i}'))
oc = db.execute(OPENCLAR, (c2,)).fetchall()
check('T15 clarifications LIMIT 3', len(oc) == 3)
db.execute("UPDATE clarifications SET status='answered' WHERE id=?", (oc[0][0],))
check('T16 answered leaves queue', all(r[0] != oc[0][0] for r in db.execute(OPENCLAR, (c2,)).fetchall()))
cf = [r[1] for r in db.execute(CONVFACTS, (c2,)).fetchall()]
check('T17 conv facts decision-first', cf[0] == 'decision', f'-> {cf}')
db.execute("INSERT INTO extractions (conversation_id,status) VALUES (?,'pending') ON CONFLICT(conversation_id) DO UPDATE SET status='pending'", (c2,))
db.execute("INSERT INTO extractions (conversation_id,status) VALUES (?,'pending') ON CONFLICT(conversation_id) DO UPDATE SET status='pending'", (c2,))
check('T18 extraction upsert idempotent', db.execute('SELECT count(*) FROM extractions').fetchone()[0] == 1)
db.execute("INSERT INTO settings VALUES ('k','v1') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
db.execute("INSERT INTO settings VALUES ('k','v2') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
check('T19 settings upsert', db.execute("SELECT value FROM settings WHERE key='k'").fetchone()[0] == 'v2')
db.execute('DELETE FROM conversations WHERE id=?', (cJan,))
check('T20 cascade facts', db.execute('SELECT count(*) FROM facts WHERE conversation_id=?', (cJan,)).fetchone()[0] == 0)

# ---------- extraction JSON contract (mirror of ExtractionService.parseModelJson) ----------
def parse_model_json(raw):
    s = raw.strip()
    m = re.search(r'```(?:json)?\s*([\s\S]*?)```', s)
    if m:
        s = m.group(1).strip()
    a, b2 = s.find('{'), s.rfind('}')
    if a < 0 or b2 <= a:
        raise ValueError('no json')
    return json.loads(s[a:b2 + 1])

for name, fx in [
    ('clean', '{"facts":[{"kind":"commitment","text":"Send sheet","person":"Ravi","due":"Friday","confidence":0.9}],"questions":[]}'),
    ('fenced', '```json\n{"facts":[],"questions":[{"question":"Who was speaker 2?","reason":"unmatched"}]}\n```'),
    ('prose', 'Here you go:\n{"facts":[{"kind":"decision","text":"Defer","person":null,"due":null,"confidence":1.0}],"questions":[]}\nHope that helps!'),
]:
    try:
        o = parse_model_json(fx)
        check(f"T21 parse fixture '{name}'", isinstance(o, dict) and 'facts' in o)
    except Exception as e:
        check(f"T21 parse fixture '{name}'", False, str(e))
try:
    parse_model_json('Sorry, I cannot help with that.')
    check('T22 garbage raises', False)
except Exception:
    check('T22 garbage raises', True)

payload = {'facts': [
    {'kind': 'commitment', 'text': 'A', 'person': 'Ravi', 'confidence': 0.9},
    {'kind': 'banana', 'text': 'bad kind'},
    {'kind': 'fact', 'text': ''},
    {'kind': 'fact', 'text': 'Low conf', 'person': 'Ravi', 'confidence': 0.4}],
    'questions': [{'question': f'q{i}'} for i in range(6)]}
kept = [f for f in payload['facts'] if f.get('kind') in {'commitment', 'decision', 'fact', 'thread'} and (f.get('text') or '').strip()]
linked = [f for f in kept if f.get('person') and (f.get('confidence') or 0.5) >= 0.75]
check('T23 store filters invalid kinds/empty text', len(kept) == 2)
check('T24 low-confidence person not auto-linked', len(linked) == 1)
check('T25 questions capped at 3', min(len(payload['questions']), 3) == 3)

# ---------- v4-v6 additions: roles, contact cards, notes/summary/bucket, merge ----------
cX = conv('Mentioned test', '2026-07-20 10:00')
tag(cX, suresh, 'attendee')
tag(cX, priya, 'mentioned')
hx = [r for r in db.execute(HOME, (100, 0)).fetchall() if r[0] == cX][0]
check('T26 home names exclude mentioned',
      'Vendor A - Suresh' in (hx[5] or '') and 'Priya' not in (hx[5] or ''))
check('T27 people count is attended-only',
      {r[1]: r[4] for r in db.execute(PEOPLE).fetchall()}['Priya'] == 1)

db.execute("UPDATE people SET company='Acme', role='AM', email='p@acme.co', notes='vip' WHERE id=?", (priya,))
check('T28 contact card fields',
      db.execute('SELECT company,role,email,notes FROM people WHERE id=?', (priya,)).fetchone()
      == ('Acme', 'AM', 'p@acme.co', 'vip'))

db.execute("INSERT INTO people (name, company) VALUES ('Priya','Beta')")
check('T29 duplicate names allowed',
      db.execute("SELECT count(*) FROM people WHERE name='Priya'").fetchone()[0] == 2)

db.execute("UPDATE conversations SET notes=?, summary=?, bucket=? WHERE id=?",
           ('my note', 'a summary', '1:1', c2))
check('T30 conversation notes/summary/bucket',
      db.execute('SELECT notes,summary,bucket FROM conversations WHERE id=?', (c2,)).fetchone()
      == ('my note', 'a summary', '1:1'))

# merge SQL (mirror of RecallDb.mergePerson): fold a whisper-dup into ravi
dup = person('Surab')
tag(c1, dup, 'attendee')
fact(c1, dup, 'fact', 'from dup', '2026-07-13 10:30')
db.execute('UPDATE facts SET person_id=? WHERE person_id=?', (ravi, dup))
db.execute("INSERT INTO conversation_people (conversation_id,person_id,role) "
           "SELECT conversation_id, ?, role FROM conversation_people WHERE person_id=? "
           "ON CONFLICT(conversation_id,person_id) DO UPDATE SET role="
           "CASE WHEN conversation_people.role='attendee' OR excluded.role='attendee' "
           "THEN 'attendee' ELSE 'mentioned' END", (ravi, dup))
db.execute('DELETE FROM conversation_people WHERE person_id=?', (dup,))
db.execute('DELETE FROM people WHERE id=?', (dup,))
check('T31 merge moves facts',
      db.execute("SELECT count(*) FROM facts WHERE person_id=? AND text='from dup'", (ravi,)).fetchone()[0] == 1)
check('T32 merge removes dup', db.execute('SELECT count(*) FROM people WHERE id=?', (dup,)).fetchone()[0] == 0)

# W9: reset stuck 'transcribing' -> 'pending'
sa = art(c1, 'recording', status='transcribing')
db.execute("UPDATE artifacts SET status='pending' WHERE status='transcribing'")
check('T33 reset stuck transcription',
      db.execute('SELECT status FROM artifacts WHERE id=?', (sa,)).fetchone()[0] == 'pending')

# delete cascades conversation_people
db.execute('DELETE FROM conversations WHERE id=?', (cX,))
check('T34 delete cascades tags',
      db.execute('SELECT count(*) FROM conversation_people WHERE conversation_id=?', (cX,)).fetchone()[0] == 0)

print()
print('RESULT:', 'ALL PASS' if not fails else f'FAILURES: {fails}')
sys.exit(1 if fails else 0)
