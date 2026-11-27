(() => {
  'use strict';
  const MAX_BUFFERED = 32768;

  // The caller has already authenticated and owns the actual media tracks.
  function create(socket, capture, releaseMedia, onFailure) {
    const eventTarget = target => target && typeof target.addEventListener === 'function' &&
      typeof target.removeEventListener === 'function';
    if (!eventTarget(socket) || !eventTarget(window) || !eventTarget(document) ||
        typeof socket.send !== 'function' || typeof socket.close !== 'function' ||
        typeof capture?.setMuted !== 'function' || typeof capture.stop !== 'function' ||
        typeof releaseMedia !== 'function' || typeof onFailure !== 'function' ||
        typeof window.simontalkPcmWire?.encode !== 'function') {
      throw new TypeError('Invalid PCM sender configuration');
    }
    let closed = false, draining = false, mediaReleased = false, muted = true, changing = false;
    let paceSent = false, interruptSent = false;
    let epoch = 0, sequence = 0;
    const listeners = [];

    function listen(target, name, callback) {
      target.addEventListener(name, callback);
      const remove = () => target.removeEventListener(name, callback);
      if (closed) remove(); else listeners.push(remove);
    }

    function canSend(size) {
      return socket.readyState === 1 && Number.isSafeInteger(socket.bufferedAmount) &&
        socket.bufferedAmount >= 0 && socket.bufferedAmount + size <= MAX_BUFFERED;
    }

    function releaseLocalMedia() {
      if (mediaReleased) return false;
      mediaReleased = true;
      let failed = false;
      try { if (capture.setMuted(true) !== true) failed = true; } catch (_) { failed = true; }
      try { capture.stop(); } catch (_) { failed = true; }
      try {
        const result = releaseMedia();
        if (result && typeof result.then === 'function') {
          Promise.resolve(result).catch(() => {});
          failed = true;
        } else if (result === false) failed = true;
      } catch (_) { failed = true; }
      return failed;
    }

    function finish(reason, sendStop) {
      if (closed) return;
      closed = true;
      draining = false;
      muted = true;
      let failed = releaseLocalMedia();
      for (const remove of listeners.splice(0)) { try { remove(); } catch (_) {} }
      if (sendStop) {
        try { if (canSend(32)) socket.send('{"kind":"stop"}'); } catch (_) { failed = true; }
      }
      try { socket.close(); } catch (_) { failed = true; }
      if (reason || failed) {
        try { onFailure(reason || 'transport_failed'); } catch (_) {}
      }
    }

    function setMuted(value) {
      if (closed || draining || typeof value !== 'boolean') return false;
      if (changing) { finish('transport_failed', false); return false; }
      if (value === muted) return true;
      changing = true;
      try {
        if (epoch >= 0xffffffff) { finish('transport_failed', false); return false; }
        if (value) {
          muted = true;
          if (capture.setMuted(true) !== true || closed) {
            if (!closed) finish('transport_failed', false);
            return false;
          }
        }
        if (!canSend(128)) { finish('transport_failed', false); return false; }
        const nextEpoch = epoch + 1;
        socket.send(JSON.stringify({kind:'mode', epoch:nextEpoch, muted:value}));
        if (closed) return false;
        epoch = nextEpoch;
        if (!value) {
          if (capture.setMuted(false) !== true || closed) {
            if (!closed) finish('transport_failed', false);
            return false;
          }
          muted = false;
        }
        return true;
      } catch (_) { finish('transport_failed', false); return false; }
      finally { changing = false; }
    }

    function drain() {
      if (closed) return false;
      if (draining) return true;
      if (changing) { finish('transport_failed', false); return false; }
      draining = true;
      muted = true;
      try {
        if (releaseLocalMedia() || closed || !canSend(32)) {
          finish('transport_failed', false);
          return false;
        }
        socket.send('{"kind":"drain"}');
        return !closed;
      } catch (_) { finish('transport_failed', false); return false; }
    }

    function send(pcm) {
      if (closed || draining || muted || changing) return false;
      try {
        if (sequence >= Number.MAX_SAFE_INTEGER || !canSend(3213)) {
          finish('transport_failed', false); return false;
        }
        const next = sequence + 1;
        const frame = window.simontalkPcmWire.encode(epoch, next, pcm);
        if (closed || draining || muted || changing || !canSend(3213)) {
          if (!closed && !draining && !muted && !changing) finish('transport_failed', false);
          return false;
        }
        sequence = next;
        socket.send(frame);
        return !closed;
      } catch (_) { finish('transport_failed', false); return false; }
    }

    function sendSettled(responseId) {
      if (closed || draining || changing || typeof responseId !== 'string' ||
          !/^[A-Za-z0-9_-]{1,128}$/.test(responseId)) {
        if (!closed && !draining) finish('transport_failed', false);
        return false;
      }
      try {
        const payload = JSON.stringify({kind: 'settled', response_id: responseId});
        if (!canSend(256)) { finish('transport_failed', false); return false; }
        socket.send(payload);
        return !closed;
      } catch (_) { finish('transport_failed', false); return false; }
    }

    function sendSlowPace() {
      if (closed || draining || changing || paceSent) {
        if (!closed && !draining) finish('transport_failed', false);
        return false;
      }
      paceSent = true;
      try {
        if (!canSend(64)) { finish('transport_failed', false); return false; }
        socket.send('{"kind":"pace","pace":"slow"}');
        return !closed;
      } catch (_) { finish('transport_failed', false); return false; }
    }

    function sendInterrupt() {
      if (closed || draining || muted || changing || interruptSent) {
        if (!closed && !draining) finish('transport_failed', false);
        return false;
      }
      interruptSent = true;
      try {
        if (!canSend(64)) { finish('transport_failed', false); return false; }
        socket.send('{"kind":"interrupt"}');
        return !closed;
      } catch (_) { finish('transport_failed', false); return false; }
    }

    const sender = {
      setMuted,
      send,
      sendSettled,
      sendSlowPace,
      sendInterrupt,
      drain,
      stop: () => finish(null, true),
    };
    try {
      listen(socket, 'error', () => finish('transport_failed', false));
      listen(socket, 'close', () => finish('transport_failed', false));
      listen(document, 'visibilitychange', () => { if (document.hidden) finish('background', false); });
      listen(window, 'pagehide', () => finish('background', false));
      if (closed) return sender;
      if (document.hidden || !canSend(0) || capture.setMuted(true) !== true) {
        finish('transport_failed', false);
      }
    } catch (_) { finish('transport_failed', false); }
    return sender;
  }

  window.simontalkPcmSender = { create };
})();
