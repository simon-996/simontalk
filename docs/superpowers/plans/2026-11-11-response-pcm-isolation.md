# Response PCM Isolation Implementation Plan

**Goal:** Bound decoded streaming audio to its explicitly authorized response and item while rejecting late or conflicting chunks.

**Architecture:** Extend `streaming_pcm_output.js` with an opt-in response router owning one existing per-response PCM player. The router tracks bounded retired responses and event IDs, refuses overlapping starts, drops late retired chunks and fails closed on identity, order, chunk or release errors. It never independently authorizes a subsequent response, context confirmation or production admission.

**Tech Stack:** Browser JavaScript, Web Audio, Node test runner, existing PCM player.

- [x] Add behavioral tests in `apps/client/test/web/streaming_pcm_output_test.mjs` for retirement, late old chunks, duplicates, wrong/unknown identities, local stop failure and reentrancy. Run and observe missing router failure.
- [x] Implement the minimal explicit router in `apps/client/web/streaming_pcm_output.js`; re-use the existing PCM player and bounded resource limits, never infer audible output.
- [x] Run target and full web JS tests, verify behavior in an actual browser with synthetic generated samples, and update evidence and HANDOFF. Preserve default closed admission and all existing work.
- [x] Continue to the next integration component; no commit or push until the authorized feature is complete.
