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

  window.simontalkStreamingPcmOutput = { create };
})();
