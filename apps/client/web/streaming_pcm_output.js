(() => {
  'use strict';

  // Estimates only. This component does not produce playback evidence.
  function create(context, sampleRate) {
    if (!context || context.state !== 'running' || typeof context.addEventListener !== 'function' ||
        typeof context.removeEventListener !== 'function' ||
        !Number.isInteger(sampleRate) || sampleRate < 8000 || sampleRate > 48000) {
      throw new TypeError('Invalid audio configuration');
    }
    const chunks = [];
    let stopped = false;
    let invalidClock = false;
    let lastOutputTime = null;
    let lastGraphTime = null;
    let lastPerformanceTime = null;
    let frozen = null;

    function estimate() {
      if (stopped) return frozen;
      if (invalidClock) return null;
      try {
        const graphTime = context.currentTime;
        const timestamp = context.getOutputTimestamp();
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
        return chunks.reduce((total, chunk) =>
          total + Math.max(0, Math.min(outputTime, chunk.end) - chunk.start), 0);
      } catch (_) {
        invalidClock = true;
        return null;
      }
    }

    function stop() {
      if (stopped) return frozen;
      frozen = estimate();
      stopped = true;
      try { context.removeEventListener('statechange', stateChanged); } catch (_) { frozen = null; }
      for (const chunk of chunks) {
        try { chunk.node.stop(); } catch (_) { frozen = null; }
        try { chunk.node.disconnect(); } catch (_) { frozen = null; }
      }
      chunks.length = 0;
      return frozen;
    }

    function fail() {
      invalidClock = true;
      stop();
      return false;
    }

    function stateChanged() {
      if (context.state !== 'running') fail();
    }

    function append(bytes) {
      if (stopped) return false;
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
        chunks.push({ start, end, node });
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
    return { append, estimateSeconds: estimate, stop };
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
        try { previous.player.stop(); } catch (_) { /* Best effort release. */ }
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
        if (closed) { player.stop(); return false; }
        responses.add(responseId);
        items.add(itemId);
        active = { responseId, itemId, player, eventCount: 0 };
        return true;
      } catch (_) {
        if (player) { try { player.stop(); } catch (_) {} }
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
        if (!active || event.responseId !== active.responseId ||
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
        if (!active || event.response_id !== active.responseId || event.item_id !== active.itemId ||
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

    function stop(responseId) {
      if (closed) return false;
      if (busy || !validId(responseId)) { close(); return false; }
      if (responses.has(responseId) && responseId !== active?.responseId) return false;
      if (!active || responseId !== active.responseId) { close(); return false; }
      busy = true;
      const previous = active;
      try {
        const result = previous.player.stop();
        if (closed || result === null || !Number.isFinite(result) || result < 0) {
          close(); return false;
        }
        active = null;
        return true;
      } catch (_) {
        close(); return false;
      } finally { busy = false; }
    }

    return { start, append, appendQwenDelta, stop, dispose: close };
  }

  window.simontalkStreamingPcmOutput = { create, createResponseRouter };
})();
