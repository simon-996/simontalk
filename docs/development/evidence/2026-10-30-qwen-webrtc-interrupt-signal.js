(() => {
  'use strict';
  const run = document.getElementById('run'), log = document.getElementById('log');
  const originalCreate = document.createElement, originalGet = navigator.mediaDevices.getUserMedia;
  const originalPeerConnection = window.RTCPeerConnection;
  const events = [];
  const state = {
    reason: null, response_status: null, usage: null, speech_started: false,
    speech_stopped: false, input_committed: false, transcript_final: false,
    speech_item_matched: null, speech_before_response_done: false,
    hold_result: null, cancel_sent: false, cancel_result: null,
    input_live_at_hold: null, output_muted_at_hold: null, audio_started: false,
    audio_ended: false, unexpected_response: false, remote_error: false,
    signal: {threshold_rms: 0.001, before_cancel: {samples:0, over_threshold:0, peak_rms:0},
      after_cancel: {samples:0, over_threshold:0, peak_rms:0}, after_done: {samples:0, over_threshold:0, peak_rms:0}, error:null},
  };
  const known = new Set(['session.created', 'session.updated', 'response.created', 'response.done',
    'input_audio_buffer.speech_started', 'input_audio_buffer.speech_stopped', 'input_audio_buffer.committed',
    'conversation.item.input_audio_transcription.completed', 'error']);
  let context, input, oscillator, speech, transport, audio, deadline, channel, sessionId, responseId, itemId;
  let signalSource, analyser, silentGain, signalTimer;
  let done = false, configured = false, responseDone = false, replyRequested = false;
  const now = () => Math.round(performance.now());
  function note(type) { events.push({at: now(), type}); log.textContent = events.map(e => `${e.at}ms ${e.type}`).join('\n'); }
  const settings = {
    modalities: ['text', 'audio'], max_tokens: 128, enable_search: false, voice: 'Tina',
    instructions: 'You are a friendly English conversation partner. Speak slowly and count from one to twenty in English.',
    input_audio_transcription: {model: 'qwen3-asr-flash-realtime'},
    turn_detection: {type: 'server_vad', threshold: 0.2, silence_duration_ms: 600, create_response: false, interrupt_response: false},
  };
  function sameSettings(s) {
    return s && s.id === sessionId && s.model === 'qwen3.8-omni-flash-realtime' &&
      Array.isArray(s.modalities) && s.modalities.length === 2 && s.modalities.includes('text') && s.modalities.includes('audio') &&
      s.max_tokens === settings.max_tokens && s.enable_search === false && s.voice === settings.voice &&
      s.instructions === settings.instructions && s.input_audio_transcription?.model === settings.input_audio_transcription.model &&
      Object.entries(settings.turn_detection).every(([key, value]) => s.turn_detection?.[key] === value) &&
      (!Object.hasOwn(s, 'tools') || (Array.isArray(s.tools) && s.tools.length === 0));
  }
  function safeUsage(value) {
    if (!value || typeof value !== 'object') return null;
    const out = {};
    for (const key of ['input_tokens', 'output_tokens', 'total_tokens']) {
      if (Number.isSafeInteger(value[key]) && value[key] >= 0) out[key] = value[key];
    }
    for (const key of ['input_tokens_details', 'output_tokens_details']) {
      const part = {};
      for (const field of ['text_tokens', 'audio_tokens']) {
        if (Number.isSafeInteger(value[key]?.[field]) && value[key][field] >= 0) part[field] = value[key][field];
      }
      if (Object.keys(part).length) out[key] = part;
    }
    return Object.keys(out).length ? out : null;
  }
  function observeRemoteAudio(track) {
    if (done || signalSource || track.kind !== 'audio') return;
    try {
      signalSource = context.createMediaStreamSource(new window.MediaStream([track]));
      analyser = context.createAnalyser(); analyser.fftSize = 2048;
      silentGain = context.createGain(); silentGain.gain.value = 0;
      signalSource.connect(analyser); analyser.connect(silentGain); silentGain.connect(context.destination);
      const data = new Float32Array(analyser.fftSize);
      signalTimer = setInterval(() => {
        try {
          analyser.getFloatTimeDomainData(data);
          let sum = 0; for (const value of data) sum += value * value;
          const rms = Math.sqrt(sum / data.length);
          const phase = responseDone ? 'after_done' : state.cancel_sent ? 'after_cancel' : 'before_cancel';
          const sample = state.signal[phase]; sample.samples++;
          sample.peak_rms = Math.max(sample.peak_rms, rms);
          if (rms >= state.signal.threshold_rms) sample.over_threshold++;
          if (responseId && !responseDone && !state.audio_started && rms >= state.signal.threshold_rms) {
            state.audio_started = true;
            speech.start(); note('synthetic_speech_started');
          }
        } catch (_) { state.signal.error = 'sampling_failed'; void finish('analysis_failed'); }
      }, 50);
    } catch (_) { state.signal.error = 'analysis_unavailable'; void finish('analysis_failed'); }
  }
  async function finish(reason) {
    if (done) return;
    done = true; state.reason = reason; clearTimeout(deadline);
    clearInterval(signalTimer);
    try { signalSource?.disconnect(); analyser?.disconnect(); silentGain?.disconnect(); } catch (_) {}
    try { speech?.stop(); } catch (_) {}
    try { speech?.disconnect(); } catch (_) {}
    try { oscillator?.stop(); oscillator?.disconnect(); } catch (_) {}
    try { transport?.stop(); } catch (_) {}
    try { input?.getTracks().forEach(track => track.stop()); } catch (_) {}
    document.createElement = originalCreate; navigator.mediaDevices.getUserMedia = originalGet;
    window.RTCPeerConnection = originalPeerConnection;
    if (context) await context.close().catch(() => {});
    try {
      const res = await fetch('/evidence', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({...state, events})});
      log.textContent += res.status === 204 ? `\n结束：${reason}` : '\n结束：证据写入失败';
    } catch (_) { log.textContent += '\n结束：证据写入失败'; }
  }
  function send(value) {
    const error = transport.send(JSON.stringify(value), channel);
    if (error !== null) { void finish('send_failed'); return false; }
    return true;
  }
  function receive(json, id) {
    if (done) return;
    let event;
    try { event = JSON.parse(json); } catch (_) { void finish('invalid_event'); return; }
    if (!event || typeof event.type !== 'string') { void finish('invalid_event'); return; }
    const type = event.type;
    if (known.has(type)) note(type);
    if (channel && id !== channel) { void finish('wrong_channel'); return; }
    if (type === 'error') { state.remote_error = true; void finish('provider_error'); return; }
    if (type === 'session.created') {
      if (sessionId || !event.session || event.session.model !== 'qwen3.8-omni-flash-realtime' || typeof event.session.id !== 'string' || !event.session.id) { void finish('session_invalid'); return; }
      sessionId = event.session.id; channel = id;
      send({type: 'session.update', session: settings});
    } else if (type === 'session.updated') {
      if (configured || !sameSettings(event.session)) { void finish('configuration_invalid'); return; }
      configured = true;
      transport.activate(channel).then(error => {
        if (done) return;
        if (error !== null) { void finish('activation_failed'); return; }
        if (!send({type: 'conversation.item.create', item: {type:'message', role:'user', content:[{type:'input_text', text:'Count slowly from one to twenty.'}]}})) return;
        replyRequested = true;
        send({type:'response.create'});
      }).catch(() => { void finish('activation_failed'); });
    } else if (type === 'response.created') {
      if (!configured || !replyRequested || responseId || !event.response || typeof event.response.id !== 'string' || !event.response.id) {
        state.unexpected_response = true; void finish('unexpected_response'); return;
      }
      responseId = event.response.id;
    } else if (type === 'input_audio_buffer.speech_started') {
      if (typeof event.item_id !== 'string' || !event.item_id || (itemId && itemId !== event.item_id)) { void finish('speech_item_invalid'); return; }
      if (itemId) return;
      itemId = event.item_id; state.speech_started = true;
      state.speech_before_response_done = Boolean(responseId && !responseDone);
      if (!state.speech_before_response_done) return;
      state.hold_result = transport.holdPlayback();
      state.input_live_at_hold = Boolean(input?.getAudioTracks()[0]?.enabled && input.getAudioTracks()[0].readyState === 'live');
      state.output_muted_at_hold = audio?.muted === true;
      note('hold_attempted');
      if (state.hold_result !== null) { void finish('hold_failed'); return; }
      state.cancel_sent = true;
      state.cancel_result = transport.send('{"type":"response.cancel"}', channel);
      note('cancel_attempted');
      if (state.cancel_result !== null) void finish('cancel_send_failed');
    } else if (type === 'input_audio_buffer.speech_stopped' || type === 'input_audio_buffer.committed' || type === 'conversation.item.input_audio_transcription.completed') {
      if (!itemId || event.item_id !== itemId) { state.speech_item_matched = false; void finish('speech_item_mismatch'); return; }
      if ((type === 'input_audio_buffer.committed' && !state.speech_stopped) ||
          (type === 'conversation.item.input_audio_transcription.completed' && !state.input_committed)) {
        void finish('speech_order_invalid'); return;
      }
      state.speech_item_matched = true;
      if (type === 'input_audio_buffer.speech_stopped') state.speech_stopped = true;
      if (type === 'input_audio_buffer.committed') state.input_committed = true;
      if (type === 'conversation.item.input_audio_transcription.completed') state.transcript_final = true;
    } else if (type === 'response.done') {
      if (!responseId || responseDone || event.response?.id !== responseId) { void finish('response_mismatch'); return; }
      responseDone = true;
      if (['completed', 'cancelled', 'failed', 'incomplete'].includes(event.response.status)) state.response_status = event.response.status;
      state.usage = safeUsage(event.response.usage);
      if (!state.audio_started) setTimeout(() => finish('response_before_audio'), 3000);
    }
  }
  run.addEventListener('click', async () => {
    run.disabled = true; note('probe_started');
    deadline = setTimeout(() => finish('deadline'), 35000);
    try {
      context = new AudioContext(); await context.resume(); if (done) return;
      const response = await fetch('/synthetic.wav'); if (!response.ok) { await finish('synthetic_fetch_failed'); return; }
      const bytes = await response.arrayBuffer(); if (done) return;
      const buffer = await context.decodeAudioData(bytes); if (done) return;
      const destination = context.createMediaStreamDestination(); input = destination.stream;
      oscillator = context.createConstantSource(); oscillator.offset.value = 0; oscillator.connect(destination); oscillator.start();
      speech = context.createBufferSource(); speech.buffer = buffer; speech.connect(destination);
      speech.onended = () => { if (!done) { state.audio_ended = true; note('synthetic_speech_ended'); setTimeout(() => finish('observation_complete'), 3000); } };
      navigator.mediaDevices.getUserMedia = async () => input;
      document.createElement = function(tag, ...args) { const value = originalCreate.call(document, tag, ...args); if (String(tag).toLowerCase() === 'audio') { value.muted = true; audio = value; } return value; };
      window.RTCPeerConnection = new Proxy(originalPeerConnection, {construct(target, args) {
        const peer = Reflect.construct(target, args);
        peer.addEventListener('track', ({track}) => observeRemoteAudio(track));
        return peer;
      }});
      transport = window.simontalkRealtime.create();
      const started = await transport.start(async offer => {
        const res = await fetch('/exchange', {method:'POST', headers:{'Content-Type':'application/sdp'}, body:offer});
        if (!res.ok) throw Error('exchange_failed');
        const body = await res.json(); return body.answer;
      }, () => {}, receive, () => {});
      if (!done && started !== null) await finish('start_failed');
    } catch (_) { await finish('probe_error'); }
  });
  window.addEventListener('pagehide', () => { if (!done) void finish('page_hidden'); });
})();
