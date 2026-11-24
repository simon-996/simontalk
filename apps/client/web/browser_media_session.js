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
    let response, item, quarantined = false;
    function releaseTracks() {
      const owned = stream;
      stream = null;
      if (owned) for (const track of owned.getTracks()) track.stop();
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
      for (const context of [inputContext, outputContext]) {
        if (context) release(() => context.close().catch(() => {}));
      }
      release(() => socket.close());
      onClosed(reason);
    }
    function current() {
      if (phase === 'closed') return false;
      if (!isCurrent()) finish('account_changed');
      else if (document.hidden) background();
      return phase !== 'closed';
    }
    function background() { finish('background'); }
    function visibility() { if (document.hidden) background(); }
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
        output = window.simontalkStreamingPcmOutput.createResponseRouter(outputContext, 24000);
        capture = window.simontalkStreamingPcmInput.create(inputContext, stream,
          pcm => { if (current()) sender?.send(pcm); }, finish);
        if (!await capture.start() || !current()) { finish('capture_failed'); return; }
        sender = window.simontalkPcmSender.create(socket, capture, releaseTracks, finish);
        if (!current() || !sender.setMuted(false)) { finish('capture_failed'); return; }
        phase = 'active';
        clearTimeout(timer);
        onEvent('active', '');
      } catch (_) { finish('capture_failed'); }
    }
    function providerEvent(event) {
      switch (event.type) {
        case 'response.created':
          if (response || !id(event.response?.id)) throw new Error();
          response = event.response.id;
          break;
        case 'response.output_item.added':
          if (!response || response !== event.response_id || item || quarantined ||
              event.output_index !== 0 || event.item?.type !== 'message' ||
              event.item.role !== 'assistant' || !id(event.item.id) ||
              !output.start(response, event.item.id)) throw new Error();
          item = event.item.id;
          break;
        case 'response.audio.delta':
          if (!response || event.response_id !== response) throw new Error();
          if (!quarantined && (!item || output.appendQwenDelta(event) !== 'appended')) throw new Error();
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
          void activate();
        } else if (phase === 'active' && message.kind === 'quarantine' &&
                   response && message.response_id === response && !quarantined) {
          quarantined = true;
          if (item && !output.stop(response)) throw new Error();
          onEvent('quarantine', response);
        } else if (phase === 'active' && message.kind === 'provider_event' &&
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
      setMuted: muted => current() && phase === 'active' && sender.setMuted(muted),
    };
  }

  window.simontalkBrowserMedia = { open };
})();
