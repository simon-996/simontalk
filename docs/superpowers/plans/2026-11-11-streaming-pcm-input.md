# Streaming PCM Input Implementation Plan

**Goal:** Provide a bounded, mute-safe 16 kHz PCM16 browser capture component for the later authenticated realtime transport.

**Architecture:** An AudioWorklet converts an already-authorized audio graph to 100 ms little-endian mono frames with three-message backpressure. A main-thread owner gates delivery by generation and sequence, handles synchronous mute/dispose and delayed module initialization, and never acquires or owns the user's microphone or network.

**Tech Stack:** Browser AudioWorklet, Web Audio, vanilla JavaScript and Node test runner.

- [x] Create deterministic worklet and main-thread tests: conversion, no audible output, partial frame discard, bounded acknowledgement, mute/late messages, async setup cancellation and failure cleanup; run and verify missing implementation fails.
- [x] Implement `apps/client/web/streaming_pcm_input_worklet.js` and `streaming_pcm_input.js` with the exact lifecycle and privacy boundaries in the input design.
- [x] Verify actual browser with only a synthetic local audio source, test mute/re-enable and post-stop callback suppression; record no samples and use zero-gain output.
- [x] Run web tests/build and update evidence/HANDOFF; continue toward authenticated transport and never infer upstream termination or open production admission from component tests.
