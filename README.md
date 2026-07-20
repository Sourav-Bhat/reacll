# Recall — Phases 1 + 2 + 3 (complete)

Personal conversation memory. Record any conversation you're in, import your
Google Recorder archive, transcribe **on-device** with whisper.cpp, tag people
and topics in 10 seconds, and search everything. Audio never leaves your phone.

## What's implemented (Phase 1 / FR-1..FR-8)

| FR | Feature | Where |
|----|---------|-------|
| FR-1 | 1-tap recording, pause/resume, wav 16 kHz mono | `services/recorder_service.dart`, `screens/record_screen.dart` |
| FR-2 | Audio import: share-sheet + file picker | `services/import_service.dart` |
| FR-3 | Transcript import: shared text/files + paste | `services/import_service.dart`, `screens/add_screen.dart` |
| FR-4 | Conversations hold many artifacts; new-vs-existing picker | `screens/attach_picker.dart`, `db/schema.dart` |
| FR-5 | On-device whisper.cpp queue with retry | `services/transcription_service.dart` |
| FR-6 | 2-question tag flow (who/what), skippable, editable later | `screens/tag_screen.dart` |
| FR-7 | FTS5 search, person filter, highlighted snippets | `db/schema.dart`, `screens/search_screen.dart` |
| FR-8 | AES-256-GCM encrypted backup (PBKDF2, 150k iters) | `services/backup_service.dart` |

## Phase 2 — the understanding layer (FR-9..FR-13)

| FR | Feature | Where |
|----|---------|-------|
| FR-9 | Structured extraction (commitments/decisions/facts/threads) via Claude API — transcript TEXT only, audio never leaves the phone | `services/extraction_service.dart` |
| FR-10 | Person pages: Brief · Facts · Talks tabs | `screens/people_screen.dart` |
| FR-11 | Clarification loop: ≤3 confidence-triggered questions, answers write back as facts | `extraction_service.dart`, `screens/detail_screen.dart` |
| FR-12 | Pre-meeting brief: offline, deterministic, <1s — last met, open commitments, decisions, threads | `db/schema.dart` (briefSql), person page |
| FR-13 | Temporal facts: newest-first, superseded shown struck-through, never deleted | `facts` table + supersede support |

Setup: Settings (gear icon on home) → paste an Anthropic API key. Without a key
the app stays fully offline — extraction is simply marked 'skipped' and can be
re-run later. Facts are only auto-filed to a person on an exact name match at
confidence ≥ 0.75; anything uncertain becomes a clarification question instead
(never filed to the wrong person).

## Phase 3 — voice identity (FR-14..FR-16)

| FR | Feature | Where |
|----|---------|-------|
| FR-14 | On-device speaker diarization (sherpa-onnx: pyannote segmentation + eres2net embeddings); segments + one embedding per speaker cluster | `services/voice_id_service.dart` |
| FR-15 | Voice enrollment through the clarification loop — answer "Who was Speaker 2?" once with the person picker, that voice is enrolled forever | `voice_id_service.dart` (enrollSpeaker), `detail_screen.dart` |
| FR-16 | Cross-session auto-ID: cosine ≥0.60 auto-links + tags the conversation; 0.40–0.60 asks to confirm; below stays "Speaker N". Never a silent mislabel. | thresholds in `voice_id_service.dart` |

Notes:
- Models (~90 MB) download once on first diarization from k2-fsa GitHub releases;
  failure → status 'skipped', transcripts unaffected.
- v3 diarizes the app's own wav recordings; imported m4a/mp3 are transcribed but
  not diarized (needs a decode step — Phase 3.1 candidate).
- Speaker chips show on the conversation screen: name + talk minutes for enrolled
  voices, "Speaker N" for unknowns.
- **Spike S-3 still matters:** the 0.60/0.40 thresholds are validated on synthetic
  embeddings; tune them on your real far-field recordings (see test/voice_id_test.py
  for the calibration model).

## Tests

`python3 test/voice_id_test.py` — 18 checks: cosine matching + thresholds on
synthetic speakers calibrated to realistic embedding similarity (same-speaker
~0.72, strangers ~orthogonal), 100-trial precision (100%) and false-accept (0)
runs, enrollment behaviour, duration-weighted means, wav parsing, and the exact
Phase-3 SQL (speaker aggregation, blob roundtrip, cascades, queue idempotency).

`python3 test/sql_contract_test.py` — 28 checks executing the exact shipped SQL
against real SQLite: FTS5 search/triggers/stemming/person-filters, 700-transcript
scale test (<1 ms), fact timelines, supersede semantics, brief assembly,
clarification lifecycle, extraction-queue idempotency, and the LLM JSON contract
(clean/fenced/prose/garbage fixtures + store-filter rules).

## Build & install (your machine)

```bash
# prerequisites: Flutter SDK (3.22+), Android Studio w/ SDK 34, a phone in developer mode
cd recall_app
flutter create . --platforms=android   # generates gradle wrapper etc. around this source
flutter pub get
flutter run --release                  # or: flutter build apk --release
```

Notes:
- `flutter create .` will NOT overwrite `lib/` or `pubspec.yaml`; it fills in the
  missing Android scaffolding. Our `AndroidManifest.xml` must be merged over the
  generated one (keep our permissions, intent filters, and the record service entry).
- If the build complains about `com.llfbandit.record.RecordService`, delete that
  `<service>` block and consult the record package's background-recording doc:
  https://github.com/llfbandit/record/blob/master/doc/bg_recording.md
- First transcription downloads the whisper model (~150 MB for `base`). On-device
  transcription of a 30-min meeting takes minutes, not seconds — it runs in the
  background; the conversation shows a spinner until done.
- `minSdkVersion 26` recommended in `android/app/build.gradle`.

## The two spikes (run before trusting the app daily)

- **S-1 (quality):** record a real meeting with the phone on the table, let the app
  transcribe with `base`, then change `TranscriptionService.model` to `WhisperModel.small`
  and compare. If far-field quality is unusable → mic placement or bigger model.
- **S-2 (already half-proven):** this codebase IS the Flutter+whisper spike; if
  `whisper_ggml` misbehaves on your device, the fallback per plan is native Android.

## Architecture (deliberately boring)

```
record/import → artifact(pending) → whisper queue → transcript → FTS5
                                                      tags → people/topics
UI: Talks · People · Add  +  mic FAB  (matches approved HTML prototype)
State: plain singletons + setState. No Riverpod/Bloc — Phase 1 doesn't need it.
```

Phase 2 (extraction, person pages with facts, briefs, clarification loop) and
Phase 3 (voice-ID; note `transcribe(diarize:)` already exists in whisper_ggml)
attach cleanly: transcripts are canonical, conversations are the spine.
