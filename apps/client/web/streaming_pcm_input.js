(() => {
  'use strict';

  // The caller owns microphone authorization, the stream, context and network.
  function create(context, stream, onChunk, onError) {
    if (!context || context.sampleRate !== 16000 || context.state !== 'running' ||
        typeof context.audioWorklet?.addModule !== 'function' ||
        typeof context.addEventListener !== 'function' ||
        typeof context.removeEventListener !== 'function' ||
        typeof stream?.getTracks !== 'function' || typeof stream.getAudioTracks !== 'function' ||
        typeof onChunk !== 'function' || typeof onError !== 'function' ||
        typeof AudioWorkletNode !== 'function') {
      throw new TypeError('Invalid PCM input configuration');
    }
    let closed = false, started = false, muted = true, epoch = 0, lastSequence = 0;
    let track, source, node, gain, timeout;
    const listeners = [];
    let resolveStopped;
    const stopped = new Promise(resolve => { resolveStopped = resolve; });

    function listen(target, name, callback) {
      target.addEventListener(name, callback);
      const remove = () => target.removeEventListener(name, callback);
      if (closed) remove(); else listeners.push(remove);
    }

    function stop() {
      if (closed) return;
      closed = true;
      clearTimeout(timeout);
      resolveStopped(false);
      for (const remove of listeners.splice(0)) { try { remove(); } catch (_) {} }
      if (node?.port) {
        node.port.onmessage = null;
        node.port.onmessageerror = null;
        try { node.port.postMessage({kind: 'stop'}); } catch (_) {}
        try { node.port.close(); } catch (_) {}
      }
      try { source?.disconnect(); } catch (_) {}
      try { node?.disconnect(); } catch (_) {}
      try { gain?.disconnect(); } catch (_) {}
    }

    function fail(reason) {
      if (closed) return;
      stop();
      try { onError(reason); } catch (_) { /* Owner failures cannot reopen capture. */ }
    }

    function checkDevice() {
      if (track.readyState === 'live' && !track.muted) return true;
      fail('device_lost');
      return false;
    }

    function message({data}) {
      if (closed) return;
      try {
        if (!checkDevice()) return;
        if (context.state !== 'running') { fail('capture_failed'); return; }
        if (!data || typeof data !== 'object' || data.kind !== 'audio' ||
            !Number.isSafeInteger(data.epoch) || data.epoch < 0 || data.epoch > epoch ||
            !Number.isSafeInteger(data.sequence) || data.sequence !== lastSequence + 1 ||
            !(data.pcm instanceof ArrayBuffer) || data.pcm.byteLength !== 3200) {
          fail('capture_failed'); return;
        }
        lastSequence = data.sequence;
        if (data.epoch === epoch && !muted) {
          const result = onChunk(new Uint8Array(data.pcm));
          if (result && typeof result.then === 'function') {
            Promise.resolve(result).catch(() => {});
            fail('capture_failed'); return;
          }
        }
        if (!closed) node.port.postMessage({kind: 'ack', epoch: data.epoch, sequence: data.sequence});
      } catch (_) { fail('capture_failed'); }
    }

    async function start() {
      if (started || closed) return false;
      started = true;
      try {
        const tracks = stream.getTracks();
        const audio = stream.getAudioTracks();
        if (document.hidden || tracks.length !== 1 || audio.length !== 1 ||
            tracks[0] !== audio[0] || audio[0].kind !== 'audio') {
          fail('capture_failed'); return false;
        }
        track = audio[0];
        if (!checkDevice()) return false;
        const moduleUrl = new URL('streaming_pcm_input_worklet.js', document.baseURI);
        if (moduleUrl.origin !== window.location.origin) { fail('capture_failed'); return false; }
        listen(document, 'visibilitychange', () => { if (document.hidden) fail('background'); });
        listen(window, 'pagehide', () => fail('background'));
        listen(context, 'statechange', () => { if (context.state !== 'running') fail('capture_failed'); });
        listen(track, 'ended', () => fail('device_lost'));
        listen(track, 'mute', () => fail('device_lost'));
        const loading = Promise.resolve(context.audioWorklet.addModule(moduleUrl.href)).then(() => true, () => false);
        const deadline = new Promise(resolve => { timeout = setTimeout(() => resolve(false), 5000); });
        const loaded = await Promise.race([loading, stopped, deadline]);
        clearTimeout(timeout);
        if (closed) return false;
        if (!loaded || document.hidden || context.state !== 'running') {
          fail('capture_failed'); return false;
        }
        if (!checkDevice()) return false;
        const createdSource = context.createMediaStreamSource(stream);
        if (closed) { try { createdSource.disconnect(); } catch (_) {} return false; }
        source = createdSource;
        const createdNode = new AudioWorkletNode(context, 'simontalk-pcm-input');
        if (closed) {
          try { createdNode.port.postMessage({kind: 'stop'}); } catch (_) {}
          try { createdNode.port.close(); } catch (_) {}
          try { createdNode.disconnect(); } catch (_) {}
          return false;
        }
        node = createdNode;
        const createdGain = context.createGain();
        if (closed) { try { createdGain.disconnect(); } catch (_) {} return false; }
        gain = createdGain;
        gain.gain.value = 0;
        node.port.onmessage = message;
        node.port.onmessageerror = () => fail('capture_failed');
        listen(node, 'processorerror', () => fail('capture_failed'));
        if (closed) return false;
        node.port.postMessage({kind: 'mode', epoch, muted});
        if (closed) return false;
        source.connect(node);
        if (closed) return false;
        node.connect(gain);
        if (closed) return false;
        gain.connect(context.destination);
        if (closed || context.state !== 'running') {
          if (!closed) fail('capture_failed');
          return false;
        }
        return checkDevice();
      } catch (_) { fail('capture_failed'); return false; }
    }

    function setMuted(value) {
      if (closed || typeof value !== 'boolean') return false;
      if (value === muted) return true;
      if (epoch >= Number.MAX_SAFE_INTEGER) { fail('capture_failed'); return false; }
      muted = value;
      epoch++;
      if (node) {
        try { node.port.postMessage({kind: 'mode', epoch, muted}); }
        catch (_) { fail('capture_failed'); return false; }
      }
      return !closed;
    }

    return { start, setMuted, stop };
  }

  window.simontalkStreamingPcmInput = { create };
})();
