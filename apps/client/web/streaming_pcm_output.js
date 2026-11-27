(() => {
  'use strict';

  const outputClockPollMs = 25;
  const outputClockWaitMs = 1000;

  // Estimates only. This component does not produce playback evidence.
  function create(context, sampleRate) {
    if (!context || context.state !== 'running' || typeof context.addEventListener !== 'function' ||
        typeof context.removeEventListener !== 'function' ||
        !Number.isInteger(sampleRate) || sampleRate < 8000 || sampleRate > 48000) {
      throw new TypeError('Invalid audio configuration');
    }
    const chunks = [];
    const hasOutputClock = typeof context.getOutputTimestamp === 'function';
    let stopped = false;
    let completed = false;
    let settled = false;
    let onSettledCallback = null;
    let onUnavailableCallback = null;
    let clockDeadline = null;
    let clockTimer = null;
    let invalidClock = false;
    let releaseFailed = false;
    let lastOutputTime = null;
    let lastGraphTime = null;
    let lastPerformanceTime = null;
    let frozen = null;

    function readOutputTime() {
      if (invalidClock) return null;
      try {
        const timestamp = context.getOutputTimestamp();
        // The audio graph can advance during the timestamp query.
        const graphTime = context.currentTime;
        const outputTime = timestamp.contextTime;
        if (context.state !== 'running' || !Number.isFinite(graphTime) || graphTime < 0 ||
            !Number.isFinite(outputTime) || outputTime < 0 || outputTime > graphTime ||
            !Number.isFinite(timestamp.performanceTime) || timestamp.performanceTime < 0 ||
            (lastOutputTime !== null && outputTime < lastOutputTime) ||
            (lastGraphTime !== null && graphTime < lastGraphTime) ||
            (lastPerformanceTime !== null && timestamp.performanceTime < lastPerformanceTime)) {
          invalidClock = true;
          return null;
        }
        lastOutputTime = outputTime;
        lastGraphTime = graphTime;
        lastPerformanceTime = timestamp.performanceTime;
        return outputTime;
      } catch (_) {
        invalidClock = true;
        return null;
      }
    }

    function estimate() {
      if (stopped) return frozen;
      const outputTime = readOutputTime();
      if (outputTime === null) return null;
      return chunks.reduce((total, chunk) =>
        total + Math.max(0, Math.min(outputTime, chunk.end) - chunk.start), 0);
    }

    function checkSettled() {
      if (stopped || settled || !completed || !chunks.every((chunk) => chunk.ended)) return;
      const last = chunks.at(-1);
      if (last && hasOutputClock) {
        clockDeadline ??= performance.now() + outputClockWaitMs;
        const outputTime = readOutputTime();
        if (stopped) return;
        const now = performance.now();
        if (!Number.isFinite(clockDeadline) || !Number.isFinite(now) ||
            outputTime === null || now >= clockDeadline) {
          fail();
          return;
        }
        if (outputTime < last.end) {
          clockTimer = setTimeout(() => {
            clockTimer = null;
            checkSettled();
          }, Math.min(outputClockPollMs, clockDeadline - now));
          return;
        }
      }
      settled = true;
      try { context.removeEventListener('statechange', stateChanged); } catch (_) {}
      const callback = onSettledCallback;
      onSettledCallback = null;
      onUnavailableCallback = null;
      if (callback) callback();
    }

    function release(measure = false) {
      if (stopped) return !releaseFailed;
      frozen = measure ? estimate() : null;
      stopped = true;
      if (clockTimer !== null) {
        clearTimeout(clockTimer);
        clockTimer = null;
      }
      onSettledCallback = null;
      onUnavailableCallback = null;
      try { context.removeEventListener('statechange', stateChanged); } catch (_) { releaseFailed = true; }
      for (const chunk of chunks) {
        if (!chunk.ended) {
          try { chunk.node.stop(); } catch (_) { releaseFailed = true; }
        }
        try { chunk.node.disconnect(); } catch (_) { releaseFailed = true; }
      }
      chunks.length = 0;
      if (releaseFailed) frozen = null;
      return !releaseFailed;
    }

    function stop() {
      release(true);
      return frozen;
    }

    function fail() {
      const callback = onUnavailableCallback;
      invalidClock = true;
      releaseFailed = true;
      release();
      if (callback) callback();
      return false;
    }

    function stateChanged() {
      if (context.state !== 'running') fail();
    }

    function finish(onSettled, onUnavailable) {
      if (stopped || completed || invalidClock || context.state !== 'running' ||
          typeof onSettled !== 'function') {
        return fail();
      }
      completed = true;
      onSettledCallback = onSettled;
      onUnavailableCallback = onUnavailable;
      checkSettled();
      return !stopped;
    }

    function append(bytes) {
      if (stopped) return false;
      if (completed) return fail();
      if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0 || bytes.byteLength % 2 ||
          bytes.byteLength > sampleRate * 2 || chunks.length >= 256 ||
          context.state !== 'running' || !Number.isFinite(context.currentTime)) return fail();
      const length = bytes.byteLength / 2;
      let node;
      try {
        const buffer = context.createBuffer(1, length, sampleRate);
        const channel = buffer.getChannelData(0);
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        for (let i = 0; i < length; i++) channel[i] = view.getInt16(i * 2, true) / 32768;
        node = context.createBufferSource();
        node.buffer = buffer;
        node.connect(context.destination);
        const now = context.currentTime;
        if (stopped || context.state !== 'running' || !Number.isFinite(now) || now < 0) {
          if (!stopped) fail();
          try { node.disconnect(); } catch (_) { /* Best effort release. */ }
          return false;
        }
        // Allow a render quantum for scheduling; preparation time is not played audio.
        const start = Math.max(now + 0.05, chunks.at(-1)?.end ?? now);
        const end = start + length / sampleRate;
        if (end - now > 10.05) {
          try { node.disconnect(); } catch (_) { /* Best effort release. */ }
          return fail();
        }
        const chunk = { start, end, node, ended: false };
        node.onended = () => {
          if (chunk.ended) return;
          chunk.ended = true;
          try { node.disconnect(); } catch (_) {}
          checkSettled();
        };
        chunks.push(chunk);
        node.start(start);
        if (stopped) return false;
        if (context.state !== 'running' || !Number.isFinite(context.currentTime) ||
            context.currentTime > start) return fail();
        return true;
      } catch (_) {
        if (node && !chunks.some((chunk) => chunk.node === node)) {
          try { node.disconnect(); } catch (_) { /* Ignore release error. */ }
        }
        return fail();
      }
    }

    context.addEventListener('statechange', stateChanged);
    return { append, estimateSeconds: estimate, finish, release, stop };
  }

  // Routes already-authorized PCM to exactly one explicitly started response.
  // This is local audio isolation, not a context or upstream termination grant.
  function createResponseRouter(context, sampleRate) {
    if (!context || context.state !== 'running' ||
        typeof context.addEventListener !== 'function' ||
        typeof context.removeEventListener !== 'function' ||
        !Number.isInteger(sampleRate) || sampleRate < 8000 || sampleRate > 48000) {
      throw new TypeError('Invalid audio configuration');
    }
    const responses = new Set();
    const items = new Set();
    const events = new Set();
    let active = null;
    let closed = false;
    let busy = false;

    // Reject malformed Unicode and bound opaque provider identifiers by UTF-8 bytes.
    function validId(value) {
      if (typeof value !== 'string' || value.length === 0 || value.length > 256) return false;
      let bytes = 0;
      for (const character of value) {
        const code = character.codePointAt(0);
        if (code === 0 || (code >= 0xd800 && code <= 0xdfff)) return false;
        bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
        if (bytes > 256) return false;
      }
      return true;
    }

    function close() {
      if (closed) return;
      closed = true;
      const previous = active;
      active = null;
      if (previous) {
        try { previous.player.release(); } catch (_) { /* Best effort release. */ }
      }
    }

    function start(responseId, itemId) {
      if (closed) return false;
      if (busy || active || !validId(responseId) || !validId(itemId) ||
          responses.has(responseId) || items.has(itemId) || responses.size >= 64) {
        close();
        return false;
      }
      busy = true;
      let player;
      try {
        player = create(context, sampleRate);
        if (closed) { player.release(); return false; }
        responses.add(responseId);
        items.add(itemId);
        active = { responseId, itemId, player, eventCount: 0, completing: false };
        return true;
      } catch (_) {
        if (player) { try { player.release(); } catch (_) {} }
        close();
        return false;
      } finally { busy = false; }
    }

    function append(event) {
      if (closed) return 'rejected';
      if (busy) { close(); return 'rejected'; }
      busy = true;
      try {
        if (!event || typeof event !== 'object' || !validId(event.responseId)) {
          close(); return 'rejected';
        }
        if (responses.has(event.responseId) && event.responseId !== active?.responseId) {
          return 'stale';
        }
        if (!active || active.completing || event.responseId !== active.responseId ||
            event.itemId !== active.itemId || !validId(event.eventId) ||
            event.outputIndex !== 0 || event.contentIndex !== 0 ||
            events.has(event.eventId) || active.eventCount >= 256) {
          close(); return 'rejected';
        }
        events.add(event.eventId);
        active.eventCount++;
        const player = active.player;
        if (!player.append(event.bytes) || closed || active?.player !== player) {
          close(); return 'rejected';
        }
        return 'appended';
      } catch (_) {
        close(); return 'rejected';
      } finally { busy = false; }
    }

    // Accept only a decoded Qwen audio event from an already-authenticated,
    // configured channel. Never logs or persists provider audio or identifiers.
    function appendQwenDelta(event) {
      if (closed) return 'rejected';
      if (busy) { close(); return 'rejected'; }
      busy = true;
      let chunk;
      try {
        if (!event || typeof event !== 'object' || event.type !== 'response.audio.delta' ||
            !validId(event.response_id)) {
          close(); return 'rejected';
        }
        if (responses.has(event.response_id) && event.response_id !== active?.responseId) {
          return 'stale';
        }
        const encoded = event.delta;
        if (!active || active.completing || event.response_id !== active.responseId ||
            event.item_id !== active.itemId ||
            !validId(event.event_id) || events.has(event.event_id) || active.eventCount >= 256 ||
            event.output_index !== 0 || event.content_index !== 0 ||
            typeof encoded !== 'string' || encoded.length === 0 ||
            encoded.length > Math.ceil(sampleRate * 2 / 3) * 4 ||
            !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
          close(); return 'rejected';
        }
        const binary = atob(encoded);
        if (binary.length === 0 || binary.length % 2 || binary.length > sampleRate * 2 ||
            btoa(binary) !== encoded) {
          close(); return 'rejected';
        }
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        chunk = {
          responseId: event.response_id, itemId: event.item_id, eventId: event.event_id,
          outputIndex: event.output_index, contentIndex: event.content_index, bytes,
        };
      } catch (_) {
        close(); return 'rejected';
      } finally { busy = false; }
      if (closed) return 'rejected';
      return append(chunk);
    }

    function complete(responseId, onSettled, onUnavailable = () => {}) {
      if (closed) return false;
      if (busy || !validId(responseId) || typeof onSettled !== 'function' ||
          typeof onUnavailable !== 'function' ||
          !active || active.responseId !== responseId || active.completing) {
        close(); return false;
      }
      busy = true;
      const target = active;
      target.completing = true;
      let notifySync = false;
      let ready = false;
      try {
        const ok = target.player.finish(() => {
          if (closed || active !== target) return;
          active = null;
          if (ready) onSettled(); else notifySync = true;
        }, () => {
          if (closed || active !== target) return;
          close();
          onUnavailable();
        });
        if (!ok) { close(); return false; }
      } catch (_) {
        close(); return false;
      } finally {
        busy = false;
        ready = true;
      }
      if (notifySync && !closed) onSettled();
      return !closed;
    }

    function stop(responseId) {
      if (closed) return false;
      if (busy || !validId(responseId)) { close(); return false; }
      if (responses.has(responseId) && responseId !== active?.responseId) return false;
      if (!active || responseId !== active.responseId) { close(); return false; }
      busy = true;
      const previous = active;
      try {
        if (!previous.player.release() || closed) {
          close(); return false;
        }
        active = null;
        return true;
      } catch (_) {
        close(); return false;
      } finally { busy = false; }
    }

    return { start, append, appendQwenDelta, complete, stop, dispose: close };
  }

  window.simontalkStreamingPcmOutput = { create, createResponseRouter };
})();
