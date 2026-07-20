#!/usr/bin/env python3
"""Phase-3 voice-ID tests: (a) exact Phase-3 SQL from schema.dart against real
SQLite; (b) Python mirror of VoiceIdService matching math (cosine, weighted
mean, thresholds, enrollment) validated with synthetic speaker embeddings.
Run: python3 test/voice_id_test.py (from recall_app/)."""
import math
import os
import random
import re
import sqlite3
import struct
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(HERE, 'lib/db/schema.dart')).read()

def block(name):
    m = re.search(rf"const {name} = '''(.*?)''';", src, re.S)
    assert m, f'missing const {name}'
    return m.group(1)

CREATE = block('createSchema')
SPEAKERS = block('conversationSpeakersSql')
PRINTS = block('voicePrintsSql')
OPENCLAR = block('openClarificationsSql')

fails = []
def check(n, c, e=''):
    print(('PASS' if c else 'FAIL'), n, e)
    if not c:
        fails.append(n)

# ---------------- mirror of VoiceIdService math ----------------
AUTO, CONFIRM, MIN_MS = 0.60, 0.40, 4000

def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a)); nb = math.sqrt(sum(y * y for y in b))
    return 0 if na == 0 or nb == 0 else dot / (na * nb)

def match_prints(emb, prints):
    best, score = None, -1
    for pid, pr in prints:
        if len(pr) != len(emb):
            continue
        s = cosine(emb, pr)
        if s > score:
            best, score = pid, s
    return best, score

def mean_embedding(parts):
    dim = len(parts[0][0]); acc = [0.0] * dim; total = 0
    for e, ms in parts:
        for i in range(dim):
            acc[i] += e[i] * ms
        total += ms
    return [a / total if total else 0 for a in acc]

def decide(emb, prints):
    """Returns ('auto', pid) | ('confirm', pid) | ('unknown', None)."""
    pid, score = match_prints(emb, prints)
    if pid is not None and score >= AUTO:
        return ('auto', pid)
    if pid is not None and score >= CONFIRM:
        return ('confirm', pid)
    return ('unknown', None)

# Synthetic speakers calibrated to REALISTIC embedding behaviour:
# same-speaker cosine ~0.7-0.85, different-speaker ~0.0-0.15 (high-dim ~orthogonal).
# Noise norm n relative to unit signal gives same-speaker cosine ~ 1/(1+n^2)... so
# per-dim std = target_norm / sqrt(DIM).
random.seed(42)
DIM = 192
CLEAN = 0.60 / math.sqrt(DIM)   # same-speaker cosine ~0.75 (typical far-field)
NOISY = 1.00 / math.sqrt(DIM)   # degraded capture, cosine ~0.5 (confirm band)
def unit(v):
    n = math.sqrt(sum(x * x for x in v)); return [x / n for x in v]
def base_voice():
    return unit([random.gauss(0, 1) for _ in range(DIM)])
def sample(voice, noise):
    return unit([v + random.gauss(0, noise) for v in voice])

ravi, priya, stranger = base_voice(), base_voice(), base_voice()
prints = [(1, sample(ravi, CLEAN)), (1, sample(ravi, CLEAN)), (2, sample(priya, CLEAN))]

# T1: same speaker, typical capture -> auto
kind, pid = decide(sample(ravi, CLEAN), prints)
check('V1 same voice auto-identified', kind == 'auto' and pid == 1,
      f'-> cosine {match_prints(sample(ravi, CLEAN), prints)[1]:.2f}')

# T2: distinct stranger -> unknown (random high-dim vectors ~orthogonal)
kind, pid = decide(sample(stranger, CLEAN), prints)
check('V2 stranger falls to unknown', kind == 'unknown', f'-> {kind}')

# T3: degraded same-speaker -> confirm band or auto, NEVER misassigned to priya
kind, pid = decide(sample(ravi, NOISY), prints)
check('V3 degraded voice never misassigned', pid in (None, 1), f'-> {kind},{pid}')

# T4: precision over 100 trials (AC US-16: >=80%)
ok = 0
for _ in range(100):
    k, p = decide(sample(ravi, CLEAN), prints)
    if k == 'auto' and p == 1:
        ok += 1
check('V4 auto-ID precision >=80% (synthetic)', ok >= 80, f'-> {ok}%')

# T5: false-accept rate on 100 strangers
fa = sum(1 for _ in range(100) if decide(sample(base_voice(), CLEAN), prints)[0] == 'auto')
check('V5 false-accepts on strangers == 0', fa == 0, f'-> {fa}')

# T6: weighted mean leans toward longer segment
e1, e2 = [1.0] + [0.0] * (DIM - 1), [0.0, 1.0] + [0.0] * (DIM - 2)
m = mean_embedding([(e1, 9000), (e2, 1000)])
check('V6 duration-weighted mean', m[0] > m[1] and abs(m[0] - 0.9) < 1e-9)

# T7: zero vector safe
check('V7 zero-vector cosine safe', cosine([0.0] * DIM, ravi) == 0)

# T8: dimension-mismatched prints skipped
check('V8 dim mismatch skipped', match_prints(ravi, [(9, [1.0, 2.0])])[0] is None)

# T9: enrollment makes a previously-unknown voice auto-ID
kind, _ = decide(sample(stranger, CLEAN), prints)
assert kind == 'unknown'
prints2 = prints + [(3, sample(stranger, CLEAN))]  # enrollSpeaker equivalent
kind, pid = decide(sample(stranger, CLEAN), prints2)
check('V9 enrollment -> auto-ID next time', kind == 'auto' and pid == 3)

# ---------------- Phase-3 SQL ----------------
db = sqlite3.connect(':memory:')
db.executescript(CREATE)
db.execute('PRAGMA foreign_keys=ON')
conv = db.execute("INSERT INTO conversations (title,happened_at) VALUES ('Standup','2026-07-14 09:00')").lastrowid
art = db.execute("INSERT INTO artifacts (conversation_id,kind,status) VALUES (?, 'recording','done')", (conv,)).lastrowid
p_ravi = db.execute("INSERT INTO people (name) VALUES ('Ravi')").lastrowid

def blob(v):
    return struct.pack(f'<{len(v)}f', *v)

# segments: speaker 0 talks 10m (Ravi), speaker 1 talks 2m (unknown)
db.execute('INSERT INTO segments (artifact_id,conversation_id,speaker_label,person_id,match_confidence,start_ms,end_ms) VALUES (?,?,0,?,0.83,0,600000)', (art, conv, p_ravi))
db.execute('INSERT INTO segments (artifact_id,conversation_id,speaker_label,start_ms,end_ms) VALUES (?,?,1,600000,720000)', (art, conv))
rows = db.execute(SPEAKERS, (conv,)).fetchall()
check('V10 speakers ordered by talk time', rows[0][0] == 0 and rows[0][1] == 'Ravi' and rows[1][1] is None)
check('V11 talk_ms aggregation', rows[0][3] == 600000)

# voice prints roundtrip
emb = [0.5] * 192
db.execute('INSERT INTO voice_prints (person_id,embedding,dim,source_conversation_id) VALUES (?,?,?,?)', (p_ravi, blob(emb), 192, conv))
r = db.execute(PRINTS).fetchone()
back = list(struct.unpack('<192f', r[3]))
check('V12 embedding blob roundtrip', abs(back[0] - 0.5) < 1e-6 and r[4] == 192 and r[2] == 'Ravi')

# speaker clarification ordering: speaker questions first, still LIMIT 3
db.execute("INSERT INTO clarifications (conversation_id,question,kind) VALUES (?,?,'text')", (conv, 'T1'))
db.execute("INSERT INTO clarifications (conversation_id,question,kind,speaker_label) VALUES (?,?,'speaker',1)", (conv, 'Who was Speaker 2?'))
db.execute("INSERT INTO clarifications (conversation_id,question,kind) VALUES (?,?,'text')", (conv, 'T2'))
db.execute("INSERT INTO clarifications (conversation_id,question,kind) VALUES (?,?,'text')", (conv, 'T3'))
oc = db.execute(OPENCLAR, (conv,)).fetchall()
check('V13 speaker question ranked first', oc[0][4] == 'speaker' and oc[0][5] == 1)
check('V14 still capped at 3', len(oc) == 3)

# diarization queue idempotent
db.execute("INSERT INTO diarizations (artifact_id,status) VALUES (?,'pending') ON CONFLICT(artifact_id) DO UPDATE SET status='pending'", (art,))
db.execute("INSERT INTO diarizations (artifact_id,status) VALUES (?,'pending') ON CONFLICT(artifact_id) DO UPDATE SET status='pending'", (art,))
check('V15 diarization upsert idempotent', db.execute('SELECT count(*) FROM diarizations').fetchone()[0] == 1)

# cascade: deleting conversation clears segments/clusters; person delete clears prints
db.execute("INSERT INTO speaker_clusters VALUES (?,?,?,?,?)", (conv, 0, blob(emb), 192, 600000))
db.execute('DELETE FROM people WHERE id=?', (p_ravi,))
check('V16 person delete cascades voice prints', db.execute('SELECT count(*) FROM voice_prints').fetchone()[0] == 0)
db.execute('DELETE FROM conversations WHERE id=?', (conv,))
check('V17 conversation delete cascades segments+clusters',
      db.execute('SELECT count(*) FROM segments').fetchone()[0] == 0 and
      db.execute('SELECT count(*) FROM speaker_clusters').fetchone()[0] == 0)

# wav header parse mirror (readWavMono16): minimal RIFF with a junk chunk first
wav = b'RIFF' + struct.pack('<I', 0) + b'WAVE'
wav += b'fmt ' + struct.pack('<I', 16) + b'\x01\x00\x01\x00' + struct.pack('<I', 16000) + struct.pack('<I', 32000) + b'\x02\x00\x10\x00'
samples = [0, 16384, -16384, 32767]
wav += b'data' + struct.pack('<I', len(samples) * 2) + struct.pack(f'<{len(samples)}h', *samples)
def read_wav(bytes_):
    off = 12
    while off + 8 <= len(bytes_):
        cid = bytes_[off:off + 4]; size = struct.unpack('<I', bytes_[off + 4:off + 8])[0]
        if cid == b'data':
            n = size // 2
            return [x / 32768.0 for x in struct.unpack(f'<{n}h', bytes_[off + 8:off + 8 + size])]
        off += 8 + size + (size % 2)
    raise ValueError('no data chunk')
s = read_wav(wav)
check('V18 wav parser skips fmt, reads data', len(s) == 4 and abs(s[1] - 0.5) < 1e-4 and abs(s[3] - 0.99997) < 1e-3)

print()
print('RESULT:', 'ALL PASS' if not fails else f'FAILURES: {fails}')
sys.exit(1 if fails else 0)
