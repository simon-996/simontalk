(() => {
  'use strict';
  const supported = window.isSecureContext &&
    typeof window.navigator.mediaDevices?.getUserMedia === 'function' &&
    typeof window.AudioContext === 'function';

  function create() {
    let started = false;
    let stopped = false;
    let stream;
    let context;
    let source;
    let timer;
    const listeners = [];

    function listen(target, name, callback) {
      target.addEventListener(name, callback);
      listeners.push(() => target.removeEventListener(name, callback));
    }

    function stopTracks(value) {
      for (const track of value.getTracks()) track.stop();
    }

    function stop() {
      if (stopped) return;
      stopped = true;
      if (timer !== undefined) clearInterval(timer);
      for (const remove of listeners.splice(0)) remove();
      source?.disconnect();
      if (stream) { stopTracks(stream); stream = undefined; }
      if (context) {
        const closing = context;
        context = undefined;
        // Closing is asynchronous; track.stop() above releases capture now.
        try { closing.close().catch(() => {}); } catch (_) { /* Already closed. */ }
      }
    }

    return {
      stop,
      async start(onLevel, onInterrupted) {
        if (started || stopped) return 'unavailable';
        started = true;
        if (!supported) return 'unsupported';
        if (document.hidden) return 'background';
        const interrupt = (reason) => {
          if (stopped) return;
          stop();
          onInterrupted(reason);
        };
        listen(document, 'visibilitychange', () => {
          if (document.hidden) interrupt('background');
        });
        listen(window, 'pagehide', () => interrupt('background'));
        try {
          // Both calls begin in the explicit user gesture, before any await.
          context = new window.AudioContext();
          const resumed = context.resume();
          resumed.catch(() => {});
          const requested = window.navigator.mediaDevices.getUserMedia({ audio: true, video: false })
            .then((value) => {
              if (stopped) stopTracks(value);
              else stream = value;
              return value;
            });
          await Promise.all([requested, resumed]);
          if (stopped) return null;
          if (context.state !== 'running' ||
              !stream.getAudioTracks().some((track) => track.readyState === 'live')) {
            stop();
            return 'unavailable';
          }
          for (const track of stream.getTracks()) {
            listen(track, 'ended', () => interrupt('device_lost'));
          }
          listen(context, 'statechange', () => {
            if (!stopped && context.state !== 'running') interrupt('device_lost');
          });
          const analyser = context.createAnalyser();
          analyser.fftSize = 1024;
          const samples = new Uint8Array(analyser.fftSize);
          source = context.createMediaStreamSource(stream);
          source.connect(analyser); // No connection to speakers, recorder or network.
          timer = setInterval(() => {
            if (stopped) return;
            if (context.state !== 'running') { interrupt('device_lost'); return; }
            try {
              analyser.getByteTimeDomainData(samples);
              let sum = 0;
              for (const sample of samples) sum += ((sample - 128) / 128) ** 2;
              onLevel(Math.min(1, Math.sqrt(sum / samples.length) * 4));
            } catch (_) { interrupt('device_lost'); }
          }, 100);
          return null;
        } catch (error) {
          const cancelled = stopped;
          stop();
          if (cancelled) return null;
          switch (error?.name) {
            case 'NotAllowedError': case 'SecurityError': return 'permission_denied';
            case 'NotFoundError': case 'OverconstrainedError': return 'no_device';
            case 'NotReadableError': case 'AbortError': return 'device_busy';
            default: return 'unavailable';
          }
        }
      },
    };
  }

  window.simontalkMicrophone = { supported, create };
  window.simontalkMicrophoneFailed = false;
  window.dispatchEvent(new Event('simontalk-microphone-ready'));
})();
