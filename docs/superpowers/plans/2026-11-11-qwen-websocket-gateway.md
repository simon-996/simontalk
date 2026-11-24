# Qwen WebSocket Candidate Gateway Implementation Plan

**Goal:** Add a bounded, server-owned Qwen WebSocket attempt for later authenticated media integration, default disabled.

**Architecture:** One immutable settings object validates fixed Beijing destination and model. One attempt owns one no-redirect open and one connection; the connection accepts bounded JSON text and implements fail-closed concurrency and cancellation-safe local close. All persistent ownership, provider-event validation, downstream authentication, context and trusted remote termination remain with later components.

**Tech Stack:** Python 3.13, asyncio, pinned websockets 15.0.1, pytest.

- [x] Test exact configuration before network, one attempt, redirect rejection, bounded JSON frames and sanitised failure with synthetic secrets; run tests to confirm missing behavior.
- [x] Implement fixed endpoint, no proxy/compression/retry, bounded open/send, and idempotent shielded close that aborts local transport on failure.
- [x] Test concurrent send/receive, cancellation, close re-entry, and errors without raw provider data; verify no later operation can reuse failed or closed connection.
- [x] Run isolated tests and real vendor one-connection handshake only if local tests pass; capture no personal content or credentials and do not interpret local closure as remote termination.
- [x] Record evidence and continue to authenticated downstream transport. Never change admission or release unknown without independent evidence.
