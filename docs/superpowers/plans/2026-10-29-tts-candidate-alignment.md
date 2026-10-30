# TTS candidate alignment implementation plan

> **For agentic workers:** Execute locally in this session under the user's continuing authorization; do not commit or deploy without separate instruction.

**Goal:** Build a fail-closed text-to-audio candidate mapper grounded in a real TTS observation.

**Architecture:** A pure bounded Python function ignores provider index fields, performs exact monotonic text matching with a single punctuation-space exception, validates audio times and returns immutable UTF-8 boundary offsets. It never reports playback or changes admission.

**Tech Stack:** Python 3.13, pytest, Ruff, existing API package.

---

### Task 1: Candidate mapper

**Files:** Create `services/api/src/simontalk_api/tts_candidate_alignment.py`; test in `services/api/tests/test_tts_candidate_alignment.py`.

- [x] Write failing tests for the real synthetic sample, UTF-8 boundaries, mismatch/injection, timestamp and audio range rejection, size bounds and immutability.
- [x] Implement the smallest pure mapper with stable errors and no logging, using no provider indices.
- [x] Run targeted pytest, Ruff and the same mapper on the redacted real sample; verify every returned byte offset decodes to an original prefix.

### Task 2: Integrate evidence and handoff

**Files:** Update `docs/development/2026-10-29-qwen-tts-timestamp-verification.md`, `docs/architecture/2026-10-21-playback-evidence.md`, and `HANDOFF.md`.

- [x] Record real output, costs, failed mappings and explicit distinction between audio timing and verified playback.
- [x] Run focused tests, link/JSON and `git diff --check`; retain existing work and do not perform another paid call.
