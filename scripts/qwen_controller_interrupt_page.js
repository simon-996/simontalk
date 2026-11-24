(() => {
  'use strict';
  const button = document.getElementById('run'), log = document.getElementById('log');
  button.disabled = true;
  const observeOnly = new URLSearchParams(location.search).get('observe') === '1';
  const originalGet = navigator.mediaDevices.getUserMedia;
  const originalCreate = document.createElement;
  const originalPeer = window.RTCPeerConnection;
  const originalFactory = window.simontalkRealtime.create;
  const state = {reason: null, exchanges: 0, sends: {create: 0, cancel: 0}, holds: 0, releases: 0,
    response_status: null, usage: null, events: [], snapshots: [], first_started: false, second_started: false,
    interrupted_before_done: false, second_final: false, input_live_at_hold: null, output_muted_at_hold: null,
    remote_signal_seen: false, error: null};
  let resolveStart, stop, deadline, context, stream, oscillator, buffer, audio, signalTimer, analyser, signalSource, silentGain;
  state.observe_only = observeOnly;
  let deferred = false, diagnosticItem;
  let originalResponse, responseDone = false, assistantItem = false, secondItem, firstItem, completed = false, startUsed = false, currentEvent = null;
  const note = type => { state.events.push({type, at_ms: Math.round(performance.now())}); log.textContent = state.events.map(x => `${x.at_ms} ${x.type}`).join('\n'); };
  const safeUsage = value => {
    if (!value || typeof value !== 'object') return null;
    const out = {};
    for (const key of ['input_tokens', 'output_tokens', 'total_tokens']) if (Number.isSafeInteger(value[key]) && value[key] >= 0) out[key] = value[key];
    for (const key of ['input_tokens_details', 'output_tokens_details']) {
      const part = {};
      for (const field of ['text_tokens', 'audio_tokens']) if (Number.isSafeInteger(value[key]?.[field]) && value[key][field] >= 0) part[field] = value[key][field];
      if (Object.keys(part).length) out[key] = part;
    }
    return Object.keys(out).length ? out : null;
  };
  function stopNow(reason) { if (state.reason) return; state.reason = reason; note('stopping'); if (stop) stop(); else finish(); }
  async function finish() {
    if (completed) return; completed = true; clearTimeout(deadline); clearInterval(signalTimer);
    try { signalSource?.disconnect(); analyser?.disconnect(); silentGain?.disconnect(); oscillator?.stop(); oscillator?.disconnect(); } catch (_) {}
    try { stream?.getTracks().forEach(t => t.stop()); } catch (_) {}
    navigator.mediaDevices.getUserMedia = originalGet; document.createElement = originalCreate;
    window.RTCPeerConnection = originalPeer; window.simontalkRealtime.create = originalFactory;
    if (context) await context.close().catch(() => {});
    try { const r = await fetch('/evidence', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(state)}); note(r.status === 204 ? 'evidence_saved' : 'evidence_failed'); }
    catch (_) { note('evidence_failed'); }
  }
  function play(which) {
    if (state.reason || state[`${which}_started`]) return;
    const source = context.createBufferSource(); source.buffer = buffer; source.connect(context._probeDestination);
    state[`${which}_started`] = true; source.start(); note(`${which}_synthetic_started`);
  }
  function maybeSecond() { if (assistantItem && !responseDone && state.remote_signal_seen) play('second'); }
  function observeEvent(raw) {
    let e; try { e = JSON.parse(raw); } catch (_) { state.error = 'invalid_event'; stopNow('invalid_event'); return; }
    const type = e.type;
    if (type === 'input_audio_buffer.speech_started' && !firstItem) firstItem = e.item_id;
    if (observeOnly && state.second_started && type === 'conversation.item.input_audio_transcription.delta' && e.item_id !== firstItem && !deferred) { deferred = true; diagnosticItem = e.item_id; state.diagnostic_deferred = true; note('diagnostic_deferral'); setTimeout(() => stopNow('diagnostic_observation_complete'), 8000); }
    if (deferred && e.item_id === diagnosticItem) { if (type === 'input_audio_buffer.speech_started') state.diagnostic_speech_started = true; if (type === 'input_audio_buffer.speech_stopped') state.diagnostic_speech_stopped = true; if (type === 'input_audio_buffer.committed') state.diagnostic_committed = true; if (type === 'conversation.item.input_audio_transcription.completed') state.diagnostic_final = true; }
    currentEvent = typeof type === 'string' && /^[a-z_]+(?:\.[a-z_]+)*$/.test(type) && type.length <= 100 ? type : 'invalid_event_type';
    note(currentEvent);
    state.last_event_shape = {type: currentEvent, same_as_first_input: typeof e.item_id === 'string' && e.item_id === firstItem, item_created_matches_first: typeof e.item?.id === 'string' && e.item.id === firstItem, event_id_present: typeof e.event_id === 'string' && e.event_id.length > 0, item_id_present: typeof e.item_id === 'string' && e.item_id.length > 0, response_id_present: typeof e.response_id === 'string' && e.response_id.length > 0, output_index_zero: e.output_index === 0, content_index_zero: e.content_index === 0, text_is_string: typeof e.text === 'string', stash_is_string: typeof e.stash === 'string', delta_is_string: typeof e.delta === 'string', transcript_is_string: typeof e.transcript === 'string'};
    if (type === 'response.created') originalResponse = e.response?.id;
    if (type === 'response.output_item.added' && e.response_id === originalResponse) { assistantItem = true; maybeSecond(); }
    if (type === 'input_audio_buffer.speech_started' && state.second_started && !secondItem) { secondItem = e.item_id; state.interrupted_before_done = !!originalResponse && !responseDone; }
    if (type === 'conversation.item.input_audio_transcription.completed' && secondItem && e.item_id === secondItem) state.second_final = true;
    if (type === 'response.done' && e.response?.id === originalResponse) { responseDone = true; state.response_status = ['completed','cancelled','failed','incomplete'].includes(e.response.status) ? e.response.status : null; state.usage = safeUsage(e.response.usage); }
    if (type === 'error') state.error = 'provider_error';
  }
  window.simontalkRealtime.create = function() {
    const real = originalFactory();
    return new Proxy(real, {get(target, prop) {
      if (prop === 'start') return (exchange, observation, event, cancel) => target.start(exchange, observation, (raw, channel) => { observeEvent(raw); if (!deferred) event(raw, channel); }, cancel);
      if (prop === 'send') return (raw, channel) => { try { const type = JSON.parse(raw).type; if (type === 'response.create') state.sends.create++; if (type === 'response.cancel') state.sends.cancel++; } catch (_) {} return target.send(raw, channel); };
      if (prop === 'holdPlayback') return () => { state.holds++; state.input_live_at_hold = !!stream?.getAudioTracks()[0]?.enabled && stream.getAudioTracks()[0].readyState === 'live'; state.output_muted_at_hold = audio?.muted === true; note('hold'); return target.holdPlayback(); };
      if (prop === 'releasePlayback') return () => { state.releases++; return target.releasePlayback(); };
      const value = target[prop]; return typeof value === 'function' ? value.bind(target) : value;
    }});
  };
  window.probe = {
    waitForStart: () => new Promise(resolve => { resolveStart = resolve; button.disabled = false; }),
    exchange: async offer => { state.exchanges++; if (state.exchanges !== 1) throw Error('exchange_limit'); const r = await fetch('/exchange', {method:'POST', headers:{'Content-Type':'application/sdp'}, body:offer}); if (!r.ok) throw Error('exchange_failed'); return (await r.json()).answer; },
    update: raw => {
      const snapshot = JSON.parse(raw); state.snapshots.push(snapshot);
      if (snapshot.phase === 'active' && !state.first_started) play('first');
      if (snapshot.phase === 'localClosed' && !state.reason) { state.event_at_closure = currentEvent; stopNow('controller_closed'); }
      if (state.second_final && state.response_status && snapshot.final_users >= 2) setTimeout(() => stopNow('observation_complete'), 1000);
    },
    setStop: callback => { stop = callback; if (state.reason) stop(); },
    finished: finish,
  };
  button.addEventListener('click', async () => {
    if (startUsed) return; startUsed = true; button.disabled = true; deadline = setTimeout(() => stopNow('deadline'), 45000);
    try {
      context = new AudioContext(); await context.resume();
      const r = await fetch('/synthetic.wav'); if (!r.ok) throw Error('audio_fetch');
      buffer = await context.decodeAudioData(await r.arrayBuffer());
      const destination = context.createMediaStreamDestination(); context._probeDestination = destination; stream = destination.stream;
      oscillator = context.createConstantSource(); oscillator.offset.value = 0; oscillator.connect(destination); oscillator.start();
      navigator.mediaDevices.getUserMedia = async () => stream;
      document.createElement = function(tag, ...args) { const el = originalCreate.call(document, tag, ...args); if (String(tag).toLowerCase() === 'audio') { el.muted = true; audio = el; } return el; };
      window.RTCPeerConnection = new Proxy(originalPeer, {construct(target, args) {
        const peer = Reflect.construct(target, args);
        peer.addEventListener('track', ({track}) => {
          if (track.kind !== 'audio' || signalSource) return;
          try {
            signalSource = context.createMediaStreamSource(new MediaStream([track])); analyser = context.createAnalyser(); analyser.fftSize = 2048;
            silentGain = context.createGain(); silentGain.gain.value = 0; signalSource.connect(analyser); analyser.connect(silentGain); silentGain.connect(context.destination);
            const data = new Float32Array(analyser.fftSize);
            signalTimer = setInterval(() => { analyser.getFloatTimeDomainData(data); let sum = 0; for (const x of data) sum += x*x; if (Math.sqrt(sum/data.length) >= 0.001) { state.remote_signal_seen = true; maybeSecond(); } }, 50);
          } catch (_) { stopNow('analysis_failed'); }
        });
        return peer;
      }});
      note('prepared'); resolveStart(true);
    } catch (_) { state.error = 'preparation_failed'; if (resolveStart) resolveStart(false); stopNow('preparation_failed'); }
  });
  window.addEventListener('pagehide', () => stopNow('page_hidden'));
})();
