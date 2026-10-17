(() => {
  'use strict';
  const encoder = new TextEncoder();
  const supported = window.isSecureContext &&
    typeof window.navigator.mediaDevices?.getUserMedia === 'function' &&
    typeof window.RTCPeerConnection === 'function' &&
    typeof window.MediaStream === 'function';
  const bytes = (value) => encoder.encode(value).length;
  const attempt = (action) => { try { action(); } catch (_) { /* Continue releasing other resources. */ } };

  function validEvent(json) {
    if (typeof json !== 'string' || json.length > 65536 || bytes(json) > 65536) return false;
    try {
      const value = JSON.parse(json);
      return value !== null && typeof value === 'object' && !Array.isArray(value);
    } catch (_) { return false; }
  }

  function create() {
    let started = false;
    let stopped = false;
    let connected = false;
    let active = false;
    let activating = false;
    let muted = false;
    let peer, stream, sender, audio, remoteStream, controlChannel;
    let permissionTimer, connectionTimer, configurationTimer, finishStart, finishIce;
    let finishClosed;
    const whenClosed = new Promise((resolve) => { finishClosed = resolve; });
    let observe = () => {}, receive = () => {}, cancel = () => {};
    let nextChannel = 0;
    const channels = new Map();
    const listeners = [];
    const playbackTimers = new Set();

    function listen(object, name, callback) {
      object.addEventListener(name, callback);
      listeners.push(() => object.removeEventListener(name, callback));
    }

    function report(code, detail = '') {
      if (stopped) return;
      try { observe(code, detail); } catch (_) { close('callback_failed'); }
    }

    function stopTracks(value) {
      for (const track of value?.getTracks() ?? []) attempt(() => track.stop());
    }

    function close(reason = 'cancelled') {
      if (stopped) return;
      stopped = true;
      finishClosed();
      active = false;
      connected = false;
      clearTimeout(permissionTimer);
      clearTimeout(connectionTimer);
      clearTimeout(configurationTimer);
      for (const timer of playbackTimers) clearTimeout(timer);
      playbackTimers.clear();
      for (const remove of listeners.splice(0)) attempt(remove);
      stopTracks(stream);
      stream = undefined;
      stopTracks(remoteStream);
      remoteStream = undefined;
      for (const channel of channels.values()) attempt(() => channel.close());
      channels.clear();
      attempt(() => peer?.close());
      if (audio) {
        attempt(() => audio.pause());
        audio.srcObject = null;
        attempt(() => audio.remove());
      }
      // This only cancels local signalling. It does not prove upstream billing stopped.
      if (started) attempt(cancel);
      finishIce?.(false);
      finishStart?.(reason);
      attempt(() => observe('local_closed', reason));
    }

    function checkConnected() {
      if (stopped || connected || peer.connectionState !== 'connected' ||
          ![...channels.values()].some((channel) => channel.readyState === 'open')) return;
      connected = true;
      clearTimeout(connectionTimer);
      configurationTimer = setTimeout(() => close('configuration_timeout'), 20000);
      finishStart?.(null);
      report('transport_connected');
    }

    function bindChannel(channel) {
      if (stopped) { attempt(() => channel.close()); return; }
      if ([...channels.values()].includes(channel)) return;
      // Bound the number of server-created channels held by an individual connection.
      if (nextChannel >= 8) { attempt(() => channel.close()); close('too_many_channels'); return; }
      const id = `channel-${nextChannel++}`;
      channels.set(id, channel);
      const opened = () => {
        if (stopped) return;
        checkConnected();
        report('channel_open', id);
      };
      listen(channel, 'open', opened);
      listen(channel, 'message', ({ data }) => {
        if (stopped) return;
        if (!validEvent(data)) { close('invalid_event'); return; }
        try { receive(data, id); } catch (_) { close('callback_failed'); }
      });
      listen(channel, 'error', () => close('event_channel_failed'));
      listen(channel, 'close', () => {
        if (stopped) return;
        channels.delete(id);
        if (id === controlChannel || (connected &&
            ![...channels.values()].some((value) => value.readyState === 'open'))) {
          close('event_channel_closed');
        }
      });
      if (channel.readyState === 'open') opened();
    }

    function playbackFailure(error) {
      if (stopped) return 'cancelled';
      if (error?.name !== 'NotAllowedError') {
        close('playback_failed');
        return 'playback_failed';
      }
      report('playback_blocked');
      return 'playback_blocked';
    }

    async function play() {
      if (stopped) return 'cancelled';
      if (!active || !remoteStream?.getTracks().length) return 'not_ready';
      let timer;
      try {
        const waiting = new Promise((resolve) => {
          timer = setTimeout(() => resolve('waiting'), 5000);
          playbackTimers.add(timer);
        });
        // Keep observing a late rejection even when the bounded wait has already returned.
        const playback = Promise.resolve(audio.play()).then(() => null, playbackFailure);
        const result = await Promise.race([playback, whenClosed, waiting]);
        if (!stopped && result === 'waiting') {
          report('playback_waiting');
          return 'playback_waiting';
        }
        return result === 'playback_failed' || result === 'playback_blocked'
          ? result : stopped ? 'cancelled' : null;
      } catch (error) {
        return playbackFailure(error);
      } finally { clearTimeout(timer); playbackTimers.delete(timer); }
    }

    async function begin(exchangeOffer) {
      try {
        const requested = window.navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
          video: false,
        }).then((value) => {
          if (stopped) stopTracks(value);
          else stream = value;
          return value;
        });
        await requested;
        if (stopped) return;
        clearTimeout(permissionTimer);
        const tracks = stream.getAudioTracks();
        if (tracks.length !== 1 || tracks[0].readyState !== 'live') {
          close('no_device'); return;
        }
        tracks[0].enabled = !muted;
        for (const track of stream.getTracks()) listen(track, 'ended', () => close('device_lost'));
        connectionTimer = setTimeout(() => close('connection_timeout'), 30000);
        peer = new window.RTCPeerConnection({ iceServers: [] });
        // Negotiate audio now; the real microphone is attached only after configuration confirmation.
        sender = peer.addTransceiver('audio', { direction: 'sendrecv' }).sender;
        remoteStream = new window.MediaStream();
        audio = document.createElement('audio');
        audio.autoplay = false;
        audio.playsInline = true;
        audio.srcObject = remoteStream;
        listen(audio, 'playing', () => report('playback_playing'));
        listen(audio, 'pause', () => report('playback_paused'));
        listen(audio, 'error', () => close('playback_failed'));
        listen(peer, 'track', ({ track }) => {
          if (stopped) { attempt(() => track.stop()); return; }
          if (track.kind !== 'audio') { attempt(() => track.stop()); return; }
          if (!remoteStream.getTracks().includes(track)) {
            remoteStream.addTrack(track);
            listen(track, 'ended', () => close('remote_media_ended'));
          }
          if (active) void play();
        });
        listen(peer, 'connectionstatechange', () => {
          if (stopped) return;
          if (['failed', 'disconnected', 'closed'].includes(peer.connectionState)) close('connection_lost');
          else checkConnected();
        });
        listen(peer, 'datachannel', ({ channel }) => bindChannel(channel));
        bindChannel(peer.createDataChannel('oai-events'));
        report('negotiating');
        if (stopped) return;
        const offer = await peer.createOffer();
        if (stopped) return;
        await peer.setLocalDescription(offer);
        if (stopped) return;
        const iceComplete = await new Promise((resolve) => {
          const check = () => {
            if (peer.iceGatheringState === 'complete') finishIce(true);
          };
          const remove = () => peer.removeEventListener('icegatheringstatechange', check);
          finishIce = (value) => { remove(); finishIce = undefined; resolve(value); };
          listen(peer, 'icegatheringstatechange', check);
          check();
        });
        if (stopped || !iceComplete) return;
        const sdp = peer.localDescription?.sdp;
        if (typeof sdp !== 'string' || bytes(sdp) > 262144 || !sdp.startsWith('v=0')) {
          close('invalid_sdp'); return;
        }
        const answer = await exchangeOffer(sdp);
        if (stopped) return;
        if (typeof answer !== 'string' || answer.length > 262144 ||
            bytes(answer) > 262144 || !/^v=0\r?\n/.test(answer.trim())) {
          close('invalid_sdp'); return;
        }
        await peer.setRemoteDescription({ type: 'answer', sdp: answer.trim().replace(/\r?\n/g, '\r\n') + '\r\n' });
        if (!stopped) checkConnected();
      } catch (error) {
        if (stopped) return;
        switch (error?.name) {
          case 'NotAllowedError': case 'SecurityError': close('permission_denied'); break;
          case 'NotFoundError': case 'OverconstrainedError': close('no_device'); break;
          case 'NotReadableError': close('device_busy'); break;
          default: close('connection_failed');
        }
      }
    }

    return {
      start(exchangeOffer, onObservation, onEvent, onCancel) {
        if (started || stopped) return Promise.resolve('already_started');
        started = true;
        observe = onObservation; receive = onEvent; cancel = onCancel;
        return new Promise((resolve) => {
          finishStart = (value) => { finishStart = undefined; resolve(value); };
          if (!supported) { close('unsupported'); return; }
          if (document.hidden) { close('background'); return; }
          listen(document, 'visibilitychange', () => { if (document.hidden) close('background'); });
          listen(window, 'pagehide', () => close('background'));
          permissionTimer = setTimeout(() => close('permission_timeout'), 20000);
          report('requesting_microphone');
          if (!stopped) void begin(exchangeOffer);
        });
      },
      async activate(channelId) {
        if (stopped) return 'cancelled';
        if (!connected) return 'not_connected';
        if (channels.get(channelId)?.readyState !== 'open') return 'invalid_channel';
        if (active) return channelId === controlChannel ? null : 'already_active';
        if (activating) return 'activation_in_progress';
        activating = true;
        controlChannel = channelId;
        try {
          await Promise.race([sender.replaceTrack(stream.getAudioTracks()[0]), whenClosed]);
          if (stopped) return 'cancelled';
          active = true;
          clearTimeout(configurationTimer);
          report('microphone_active');
          if (stopped) return 'cancelled';
          // play() can wait for the first remote packet. Microphone activation is already
          // complete; playback restrictions/failures are delivered through observations.
          if (remoteStream.getTracks().length) void play();
          return null;
        } catch (_) {
          if (stopped) return 'cancelled';
          close('media_failed');
          return 'media_failed';
        } finally { activating = false; }
      },
      send(json, channelId) {
        if (stopped) return 'cancelled';
        if (!connected) return 'not_connected';
        const channel = channels.get(channelId);
        if (channel?.readyState !== 'open') return 'invalid_channel';
        if (!validEvent(json)) return 'invalid_event';
        if (channel.bufferedAmount + bytes(json) > 262144) return 'backpressure';
        try { channel.send(json); return null; }
        catch (_) { close('event_channel_failed'); return 'event_channel_failed'; }
      },
      setMuted(value) {
        if (stopped) return;
        muted = value === true;
        for (const track of stream?.getAudioTracks() ?? []) track.enabled = !muted;
      },
      resumePlayback: play,
      stop: () => close(),
    };
  }

  window.simontalkRealtime = { supported, create };
  window.simontalkRealtimeFailed = false;
  window.dispatchEvent(new Event('simontalk-realtime-ready'));
})();
