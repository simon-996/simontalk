(() => {
  'use strict';
  const uuid = '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}';
  const mediaPath = new RegExp('^/v1/practice-sessions/'+uuid+'/connections/'+uuid+
    '/media/'+uuid+'/[1-9][0-9]{0,9}$');
  const id = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value);

  function open(path, consumeProof, isCurrent, onEvent, onClosed) {
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
    if (!mediaPath.test(path) || document.hidden || !isCurrent() ||
        !(location.protocol === 'https:' || (local && location.protocol === 'http:'))) {
      throw new Error('media_unavailable');
    }
    const url = new URL(path, location.origin);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const socket = new WebSocket(url.href);
    let phase = 'connecting', timer, stream, inputContext, outputContext, capture, sender, output;
    let response = null, item = null, responseDone = false, lastSettled = null;
    let quarantined = false, quarantineDelivered = false, desiredMuted = false;
    let responsePlaying = false, interruptRequested = false;
    let slowPaceRequested = false, slowPaceConfirmed = false;
    const seenResponses = new Set();
    function releaseTracks() {
      const owned = stream;
      stream = null;
      if (owned) for (const track of owned.getTracks()) track.stop();
    }
    function releaseContexts(release) {
      if (outputContext) {
        release(() => outputContext.removeEventListener('statechange', outputStateChanged));
      }
      for (const context of [inputContext, outputContext]) {
        if (context) release(() => context.close().catch(() => {}));
      }
      inputContext = outputContext = null;
    }
    function finish(reason) {
      if (phase === 'closed') return;
      phase = 'closed';
      clearTimeout(timer);
      socket.onopen = socket.onclose = socket.onmessage = socket.onerror = null;
      window.removeEventListener('pagehide', background);
      document.removeEventListener('visibilitychange', visibility);
      consumeProof = null;
      function release(action) {
        try { action(); } catch (_) { reason = 'media_release_failed'; }
      }
      release(() => output?.dispose());
      release(() => sender?.stop());
      release(() => capture?.stop());
      release(releaseTracks);
      releaseContexts(release);
      output = null;
      release(() => socket.close());
      onClosed(reason);
    }
    function current() {
      if (phase === 'closed') return false;
      if (!isCurrent()) finish('account_changed');
      else if (document.hidden) background();
      else if (output && outputContext.state !== 'running') finish('playback_failed');
      return phase !== 'closed';
    }
    function background() { finish('background'); }
    function visibility() { if (document.hidden) background(); }
    function outputStateChanged() {
      if (outputContext && outputContext.state !== 'running' && current()) {
        finish('playback_failed');
      }
    }
    async function activate() {
      try {
        const granted = await navigator.mediaDevices.getUserMedia({audio:true, video:false});
        if (!current()) { for (const track of granted.getTracks()) track.stop(); return; }
        stream = granted;
        inputContext = new AudioContext({sampleRate:16000});
        outputContext = new AudioContext();
        await Promise.all([inputContext,outputContext].map(context =>
          context.state === 'running' ? undefined : context.resume()));
        if (!current()) return;
        outputContext.addEventListener('statechange', outputStateChanged);
        outputStateChanged();
        if (!current()) return;
        output = window.simontalkStreamingPcmOutput.createResponseRouter(outputContext, 24000);
        capture = window.simontalkStreamingPcmInput.create(inputContext, stream,
          pcm => { if (current()) sender?.send(pcm); }, finish);
        if (!await capture.start() || !current()) { finish('capture_failed'); return; }
        sender = window.simontalkPcmSender.create(socket, capture, releaseTracks, finish);
        if (!current() || !sender.setMuted(desiredMuted)) { finish('capture_failed'); return; }
        phase = 'active';
        clearTimeout(timer);
        onEvent('active', '');
      } catch (error) {
        const name = error?.name;
        finish(name === 'NotAllowedError' || name === 'SecurityError'
          ? 'microphone_denied'
          : name === 'NotFoundError' || name === 'OverconstrainedError'
          ? 'no_device'
          : 'capture_failed');
      }
    }
    function settleResponse(target) {
      if (!current() || phase !== 'active' || quarantined ||
          response !== target || !responseDone) {
        return;
      }
      response = null;
      item = null;
      responseDone = false;
      responsePlaying = false;
      lastSettled = target;
      onEvent('playback', 'idle');
      if (!current()) return;
      if (!sender.sendSettled(target)) finish('transport_failed');
    }
    function providerEvent(event) {
      switch (event.type) {
        case 'response.created':
          if (quarantined || response || !id(event.response?.id) ||
              seenResponses.has(event.response.id) || seenResponses.size >= 64) {
            throw new Error();
          }
          seenResponses.add(event.response.id);
          response = event.response.id;
          item = null;
          responseDone = false;
          responsePlaying = false;
          onEvent('provider_event', JSON.stringify(event));
          if (current() && phase === 'active' && !quarantined) onEvent('playback', 'waiting');
          return;
        case 'response.output_item.added':
          if (!response || response !== event.response_id || responseDone || item ||
              event.output_index !== 0 || event.item?.type !== 'message' ||
              event.item.role !== 'assistant' || !id(event.item.id) ||
              (phase === 'active' && !quarantined && !output.start(response, event.item.id))) {
            throw new Error();
          }
          item = event.item.id;
          break;
        case 'response.audio.delta':
          if (quarantined) {
            if (event.response_id !== (response || lastSettled)) throw new Error();
            return;
          }
          if (!response || event.response_id !== response || responseDone) throw new Error();
          if (phase === 'active') {
            if (!item || output.appendQwenDelta(event) !== 'appended') throw new Error();
            if (!responsePlaying) {
              responsePlaying = true;
              onEvent('playback', 'playing');
            }
          }
          return;
        case 'response.done':
          if (!response || event.response?.id !== response || responseDone) throw new Error();
          responseDone = true;
          onEvent('provider_event', JSON.stringify(event));
          if (!current()) return;
          if (phase === 'active' && !quarantined && event.response?.status === 'completed') {
            const finished = response;
            if (item) {
              if (!output.complete(finished, () => settleResponse(finished), () => {
                if (current() && phase === 'active' && response === finished && !quarantined) {
                  finish('playback_failed');
                }
              })) throw new Error();
            } else {
              settleResponse(finished);
            }
          }
          return;
      }
      onEvent('provider_event', JSON.stringify(event));
    }
    socket.onopen = () => {
      if (!current()) return;
      try {
        socket.send(consumeProof());
        consumeProof = null;
        phase = 'authenticating';
      } catch (_) { finish('authentication_failed'); }
    };
    socket.onmessage = ({data}) => {
      if (!current()) return;
      try {
        if (typeof data !== 'string' || data.length > 131072) throw new Error();
        const message = JSON.parse(data);
        if (phase === 'authenticating' && message.kind === 'ready' && Object.keys(message).length === 1) {
          phase = 'acquiring';
          clearTimeout(timer);
          timer = setTimeout(() => finish('capture_timeout'), 30000);
          onEvent('ready', '');
          if (!current()) return;
          void activate();
        } else if ((phase === 'active' || phase === 'draining') && message.kind === 'quarantine' &&
                   !quarantineDelivered && id(message.response_id) &&
                   (message.response_id === response ||
                    (response === null && message.response_id === lastSettled))) {
          quarantineDelivered = true;
          responsePlaying = false;
          if (!quarantined && phase === 'active' && message.response_id === response && item &&
              !output.stop(response)) {
            throw new Error();
          }
          quarantined = true;
          onEvent('quarantine', message.response_id);
        } else if ((phase === 'active' || phase === 'draining') &&
                   message.kind === 'pace_updated' &&
                   message.pace === 'slow' &&
                   Object.keys(message).length === 2 &&
                   slowPaceRequested &&
                   !slowPaceConfirmed) {
          slowPaceConfirmed = true;
          if (phase === 'active') onEvent('pace_updated', 'slow');
        } else if ((phase === 'active' || phase === 'draining') && message.kind === 'provider_event' &&
                   typeof message.event?.type === 'string') {
          providerEvent(message.event);
        } else throw new Error();
      } catch (_) { finish('protocol_failed'); }
    };
    socket.onclose = socket.onerror = () => finish('transport_closed');
    window.addEventListener('pagehide', background);
    document.addEventListener('visibilitychange', visibility);
    timer = setTimeout(() => finish('connection_timeout'), 15000);
    return {
      stop: () => finish('local_closed'),
      setMuted: muted => {
        if (!current() || typeof muted !== 'boolean' || phase === 'draining') return false;
        desiredMuted = muted;
        return phase === 'active' ? sender.setMuted(muted) : true;
      },
      requestSlowPace: () => {
        if (!current() || phase !== 'active' || quarantined || slowPaceRequested) return false;
        slowPaceRequested = true;
        return sender.sendSlowPace();
      },
      interruptPlayback: () => {
        if (!current() || phase !== 'active' || quarantined || interruptRequested ||
            desiredMuted || !response) {
          return false;
        }
        interruptRequested = true;
        responsePlaying = false;
        if (item && !output.stop(response)) {
          finish('protocol_failed');
          return false;
        }
        quarantined = true;
        return sender.sendInterrupt();
      },
      holdPlayback: () => {
        if (!current() || phase !== 'active') return false;
        if (!quarantined && response && item && !output.stop(response)) {
          finish('protocol_failed');
          return false;
        }
        quarantined = true;
        return phase === 'active';
      },
      beginDrain: () => {
        if (!current()) return false;
        if (phase === 'draining') return true;
        if (phase !== 'active') return false;
        phase = 'draining';
        let failed = false;
        const release = action => { try { action(); } catch (_) { failed = true; } };
        const previousOutput = output;
        output = null;
        release(() => previousOutput?.dispose());
        if (!sender.drain()) failed = true;
        releaseContexts(release);
        if (failed) { finish('media_release_failed'); return false; }
        return phase === 'draining';
      },
    };
  }

  window.simontalkBrowserMedia = { open };
})();
