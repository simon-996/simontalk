# Unknown Playback Interruption Implementation Plan

> **For agentic workers:** Execute the bounded tasks below in this session; the current user explicitly requests continued implementation and existing changes must be preserved.

**Goal:** Safely quarantine a known in-flight response when its audible prefix is unknown, preserve the interrupting user turn, and prohibit a new reply.

**Architecture:** The controller grants a narrow, confirmed-channel capability for an existing assistant response, holds output without manufacturing a playback boundary, records a fixed tail deadline, and allows only a single bounded cancel. The Qwen candidate uses that capability for one overlapping user item and accepts its stopped/committed/final events; unknown playback cannot produce a context snapshot or unlock output.

**Tech Stack:** Flutter/Dart, existing WebRTC transport and Qwen guarded adapter, Flutter unit/widget tests.

---

### Task 1: Controller quarantine capability

**Files:** `apps/client/lib/features/realtime/realtime_session_protocol.dart`, `apps/client/lib/features/realtime/practice_media_controller.dart`, `apps/client/test/features/realtime/practice_media_drain_test.dart`.

- [x] Add failing tests invoking `callbacks.quarantineUnknownResponse(facts.responseId, 'channel-0')`; expect one output hold, unknown playback unchanged, no frozen prefix, no context candidate, one original cancel, retained user input, and no ordinary response after cancellation. Test wrong channel/unknown ID, repeated calls, fixed deadline, late cancellation, hold failure, reentrancy and dropping late playback updates.
- [x] Run `flutter test --no-pub test/features/realtime/practice_media_drain_test.dart`; verify the missing callback causes failure.
- [x] Add `void Function(String responseId, String channelId) quarantineUnknownResponse` to the callback and validate active phase, original channel and existing assistant response. Mark the response unknown and block context before invoking `holdPlayback`; use the existing monotonic tail deadline and do not call `freezeResponse` or write a freeze record. Refuse later playback alignment for that unknown response and cancel after the original cutoff.
- [x] Rerun the target test and fix any failures without weakening the unknown state or existing normal end behavior.

### Task 2: Qwen bounded overlapping user turn

**Files:** `apps/client/lib/features/realtime/qwen_guarded_protocol.dart`, `apps/client/test/features/realtime/qwen_guarded_protocol_test.dart`, `apps/client/test/features/realtime/qwen_guarded_controller_test.dart`.

- [x] Add failing protocol and real-controller/fake-transport tests for first speech and response, a second `speech_started` before that response ends, quarantine before one `response.cancel`, same-item stopped/committed/final, and original matching `response.done: cancelled`. Assert the original assistant playback remains unknown, the new user final is retained, and no second `response.create` or release occurs. Reject wrong items, unbound/finished responses, repeat speech, missing stop/commit and account/hold failures.
- [x] Run `flutter test --no-pub test/features/realtime/qwen_guarded_protocol_test.dart test/features/realtime/qwen_guarded_controller_test.dart`; verify failures reflect the prior single-turn stop.
- [x] Add a single `_interrupting` state only for a bound, live response; synchronously request quarantine, send the existing protected cancel once, accept that one user item, and accept only matching response completion. Retain fail-closed handling elsewhere, never fabricate playback alignment and never send a second reply.
- [x] Rerun controller and protocol tests, including existing drain/reentrancy tests. Resolve failures without interpreting cancellation as old-audio clearance or provider termination.

### Task 3: Verification and status

**Files:** `docs/architecture/2026-10-20-practice-completion-and-review-contract.md`, `docs/superpowers/specs/2026-10-29-qwen-guarded-protocol-design.md`, a dated development report and `HANDOFF.md`.

- [x] Run the relevant Flutter tests, full `flutter test --no-pub`, `flutter analyze --no-pub`, Dart format check, Web release build, and `git diff --check`; record actual counts and any skips. Run paid real-provider experiments only if the locally verified design needs a specific new observation under the existing budget.
- [x] Document that this is a bounded interim path: output remains held, no next reply or credible upstream termination, production admission remains closed. Preserve all pre-existing local changes and do not commit or push until the authorized complete feature is finished.
