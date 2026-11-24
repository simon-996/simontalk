'use strict';
const assert = require('node:assert/strict');
const vm = require('node:vm');

async function exercise(script, mismatch = false, failHold = false, wrongOrder = false, lateSpeech = false, wrongItem = false, noSignal = false) {
  const log = {textContent: ''};
  const button = {disabled: false, addEventListener(_, cb) { this.run = cb; }};
  const audio = {muted: false};
  const document = {getElementById: (id) => id === 'run' ? button : log,
    createElement: () => audio};
  const track = {enabled: true, readyState: 'live', stop() { this.readyState = 'ended'; }};
  const input = {getTracks: () => [track], getAudioTracks: () => [track]};
  const navigator = {mediaDevices: {getUserMedia: async () => input}};
  let speech, receive, configured, held = 0, stopped = 0, closed = 0, evidence, sampleSignal, level = 0;
  const calls = [], timers = [];
  class AudioContext {
    async resume() {}
    async decodeAudioData() { return {}; }
    createMediaStreamDestination() { return {stream: input}; }
    createConstantSource() { return {offset: {}, connect() {}, start() {}, stop() {}, disconnect() {}}; }
    createBufferSource() { speech = {connect() {}, disconnect() {}, start() {}, stop() {}}; return speech; }
    createMediaStreamSource() { return {connect() {}, disconnect() {}}; }
    createAnalyser() { return {fftSize: 2048, connect() {}, disconnect() {}, getFloatTimeDomainData(data) { data.fill(level); }}; }
    createGain() { return {gain:{value: 1}, connect() {}, disconnect() {}}; }
    get destination() { return {}; }
    async close() { closed++; }
  }
  const transport = {
    async start(exchange, observe, onEvent) {
      document.createElement('audio');
      const peer = new window.RTCPeerConnection();
      peer.emitTrack({kind:'audio'});
      await exchange('v=0\r\n');
      receive = onEvent;
      receive(JSON.stringify({type:'session.created', session:{id:'private-session',model:'qwen3.8-omni-flash-realtime'}}),'ch');
      receive(JSON.stringify({type:'session.updated', session:{...configured,id:'private-session',model:'qwen3.8-omni-flash-realtime'}}),'ch');
      return null;
    },
    async activate() {return null;},
    send(json) { const value = JSON.parse(json); calls.push(value.type); if (value.type === 'session.update') configured = value.session; return null; },
    holdPlayback() { calls.push('hold'); held++; return failHold ? 'media_failed' : null; },
    stop() { stopped++; },
  };
  class Peer {
    addEventListener(name, callback) { if (name === 'track') this.ontrack = callback; }
    emitTrack(track) { this.ontrack?.({track}); }
  }
  const window = {RTCPeerConnection:Peer,MediaStream:class {},simontalkRealtime:{create:()=>transport},addEventListener(){}};
  const fetch = async (path, options={}) => {
    if (path === '/synthetic.wav') return {ok:true,arrayBuffer:async()=>new ArrayBuffer(4)};
    if (path === '/exchange') return {ok:true,json:async()=>({answer:'v=0'})};
    if (path === '/evidence') {evidence=JSON.parse(options.body); return {status:204};}
    throw Error('unexpected path');
  };
  const sandbox = {window,document,navigator,AudioContext,fetch,performance:{now:()=>100},
    setTimeout: (fn,ms) => {if(ms===3000) timers.push(fn); return 1;}, clearTimeout(){},
    setInterval: fn => {sampleSignal=fn; return 1;}, clearInterval(){},console};
  vm.runInNewContext(script, sandbox);
  await button.run();
  await Promise.resolve();
  const emit = event => receive(JSON.stringify(event),'ch');
  emit({type:'response.created',response:{id:'private-response'}});
  assert.equal(typeof sampleSignal, 'function', 'remote audio signal analyser must be installed');
  if (noSignal) {
    sampleSignal();
    emit({type:'response.done',response:{id:'private-response',status:'completed'}});
    for (const fn of timers) await fn();
    await new Promise(setImmediate);
    assert.equal(evidence.reason,'response_before_audio');
    assert.equal(evidence.audio_started,false);
    assert.equal(evidence.cancel_sent,false);
    assert.equal(held,0); assert.equal(stopped,1); assert.equal(track.readyState,'ended');
    return;
  }
  level = 0.125; sampleSignal();
  if (lateSpeech) emit({type:'response.done',response:{id:'private-response',status:'completed'}});
  emit({type:'input_audio_buffer.speech_started',item_id:'private-item'});
  emit({type:'input_audio_buffer.speech_started',item_id:'private-item'});
  if (!failHold) {
    sampleSignal();
    if (!lateSpeech) emit({type:'response.done',response:{id:mismatch?'wrong-response':'private-response',status:'cancelled',usage:{input_tokens:12,output_tokens:3,total_tokens:15}}});
    if (!mismatch) {
      level = 0; sampleSignal();
      if (wrongItem) emit({type:'input_audio_buffer.speech_stopped',item_id:'different-item'});
      else if (wrongOrder) emit({type:'input_audio_buffer.committed',item_id:'private-item'});
      else {
        emit({type:'input_audio_buffer.speech_stopped',item_id:'private-item'});
        emit({type:'input_audio_buffer.committed',item_id:'private-item'});
        emit({type:'conversation.item.input_audio_transcription.completed',item_id:'private-item',transcript:'private transcript'});
        speech.onended();
        for (const fn of timers) await fn();
      }
    }
  }
  await new Promise(setImmediate);
  assert.ok(evidence, `missing evidence for mismatch=${mismatch} failHold=${failHold}: ${log.textContent}`);
  assert.equal(stopped,1); assert.equal(closed,1); assert.equal(track.readyState,'ended');
  assert.equal(audio.muted,true); assert.equal(held,lateSpeech ? 0 : 1);
  assert.ok(!JSON.stringify(evidence).includes('private-'));
  assert.ok(!JSON.stringify(evidence).includes('private transcript'));
  if (lateSpeech) {
    assert.equal(evidence.reason,'observation_complete');
    assert.equal(evidence.response_status,'completed');
    assert.equal(evidence.speech_before_response_done,false);
    assert.equal(evidence.cancel_sent,false);
    assert.equal(calls.filter(x=>x==='response.cancel').length,0);
  } else if (failHold) {
    assert.equal(evidence.reason,'hold_failed');
    assert.equal(calls.filter(x=>x==='response.cancel').length,0);
  } else {
    assert.ok(calls.indexOf('hold') < calls.indexOf('response.cancel'));
    assert.equal(calls.filter(x=>x==='response.cancel').length,1);
    if (mismatch) assert.equal(evidence.reason,'response_mismatch');
    else if (wrongOrder) assert.equal(evidence.reason,'speech_order_invalid');
    else if (wrongItem) assert.equal(evidence.reason,'speech_item_mismatch');
    else {
      assert.equal(evidence.reason,'observation_complete');
      assert.equal(evidence.response_status,'cancelled');
      assert.equal(evidence.speech_item_matched,true);
      assert.equal(evidence.speech_before_response_done,true);
      assert.equal(evidence.input_live_at_hold,true);
      assert.equal(evidence.output_muted_at_hold,true);
      assert.equal(evidence.signal.before_cancel.over_threshold,1);
      assert.equal(evidence.signal.after_cancel.over_threshold,1);
      assert.equal(evidence.signal.after_done.over_threshold,0);
      assert.equal(evidence.usage.total_tokens,15);
    }
  }
}
(async()=>{let script='';for await(const chunk of process.stdin) script+=chunk;
  await exercise(script); await exercise(script,true); await exercise(script,false,true); await exercise(script,false,false,true); await exercise(script,false,false,false,true); await exercise(script,false,false,false,false,true); await exercise(script,false,false,false,false,false,true);
})().catch(error=>{console.error(error);process.exitCode=1;});
