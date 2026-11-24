# Early Transcript Interruption Implementation Plan

**Goal:** Preserve one validated new user item whose transcript delta precedes VAD start while isolating an in-flight response.

**Architecture:** The normalizer optionally starts a user item from a validated nonempty delta, atomically emits start and transcript, and deduplicates by the original event identity. The Qwen adapter invokes this path only for a new input on a bound, live reply; after normalizer validation it quarantines output, publishes the updates, and sends the existing bounded cancel. A later same-item VAD start is validated and deduplicated without a second cancel. No output release, new response, playback prefix or termination claim is introduced.

**Tech Stack:** Existing Dart normalizer, guarded protocol, Flutter tests and controller.

### Tasks

- [x] Add protocol and controller regressions for valid early delta, exact replay, late same-item VAD start, ordered final, completion/cancel race and invalid/empty/conflicting inputs; run them and confirm expected failure.
- [x] Extend `qwen_transcript_normalizer.dart` with explicitly opted-in creation from a validated nonempty delta; retain existing event identity and limits.
- [x] Extend `qwen_guarded_protocol.dart` to opt in only for a new item during the bound unfinished reply, quarantine before publishing and cancel at most once, and accept only matching late start/replay.
- [x] Run target tests, full relevant client checks and Web build. Keep default admission closed; run at most a bounded new real experiment only after local safeguards pass.
- [x] Record real observations, failure limits, test evidence and remaining steps in HANDOFF. Preserve existing uncommitted changes; do not push or deploy an incomplete feature.
