'use strict';
const assert = require('node:assert/strict');
const vm = require('node:vm');

async function run(page, rejectEvidence) {
  const scripts = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]);
  const log = { textContent: '尚未运行' };
  const button = { disabled: false, addEventListener: (_, cb) => { button.run = cb; } };
  const audio = { muted: false };
  const document = {
    getElementById: (id) => id === 'run' ? button : log,
    createElement: (tag) => tag === 'audio' ? audio : {},
  };
  let stopped = 0, trackStopped = 0, contextClosed = 0, evidence, level = 0;
  let sampleAudio;
  const track = { stop: () => { trackStopped++; } };
  const navigator = { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [track] }) } };
  class AudioContext {
    async resume() {}
    createMediaStreamDestination() { return { stream: { getTracks: () => [track] } }; }
    createConstantSource() { return { offset: {}, connect() {}, start() {}, stop() {}, disconnect() {} }; }
    createMediaStreamSource() { return {connect() {}, disconnect() {}}; }
    createAnalyser() { return {fftSize: 32, connect() {}, disconnect() {}, getFloatTimeDomainData(data) { data.fill(level); }}; }
    createGain() { return {gain: {value: 1}, connect() {}, disconnect() {}}; }
    get destination() { return {}; }
    async close() { contextClosed++; }
  }
  const transport = {
    async start(exchange, observe, receive) {
      document.createElement('audio');
      const peer = new window.RTCPeerConnection();
      peer.emitTrack({kind: 'audio'});
      observe('transport_connected', '');
      await exchange('v=0\r\n');
      receive(JSON.stringify({type:'session.created'}), 'channel-1');
      receive(JSON.stringify({type:'session.updated'}), 'channel-1');
      await Promise.resolve();
      await Promise.resolve();
      observe('playback_playing', '');
      assert.equal(timers.length, 0, 'playing before the response must not schedule early shutdown');
      sampleAudio();
      receive(JSON.stringify({type:'response.created'}), 'channel-1');
      level = 0.125;
      sampleAudio();
      receive(JSON.stringify({type:'response.done', response: {status: 'completed', usage: {input_tokens: 42, output_tokens: 7, input_tokens_details: {text_tokens: 40, audio_tokens: 2}, output_tokens_details: {text_tokens: 3, audio_tokens: 4}}}}), 'channel-1');
      sampleAudio();
      return null;
    },
    send() { return null; },
    async activate() { return null; },
    stop() { stopped++; },
  };
  class Peer {
    async getStats() { return new Map([['audio', {type:'inbound-rtp', kind:'audio', bytesReceived: 1234}]]); }
    addEventListener(name, callback) { if (name === 'track') this.ontrack = callback; }
    emitTrack(track) { this.ontrack?.({track}); }
  }
  const window = { RTCPeerConnection: Peer, MediaStream: class { constructor(tracks) { this.tracks = tracks; } }, simontalkRealtime: { supported: true, create: () => transport }, addEventListener() {} };
  const fetch = async (path, options) => {
    if (path === '/exchange') return { status: 200, json: async () => ({answer: 'v=0'}) };
    if (path === '/evidence') {
      evidence = JSON.parse(options.body);
      if (rejectEvidence) throw new Error('evidence unavailable');
      return {status: 204};
    }
    throw new Error('unexpected fetch');
  };
  const timers = [];
  const sandbox = { window, document, navigator, AudioContext, fetch, performance: { now: () => 100 },
    setTimeout: (fn, delay) => { if (delay < 45000) timers.push(fn); return 1; }, clearTimeout() {},
    setInterval: (fn) => { sampleAudio = fn; return 1; }, clearInterval() {},
    console };
  for (const script of scripts) vm.runInNewContext(script, sandbox);
  await button.run();
  for (const timer of timers) { await timer(); await Promise.resolve(); }
  assert.equal(audio.muted, true, 'probe must mute the actual output audio element');
  assert.equal(stopped, 1, 'transport must stop even if evidence upload fails');
  assert.equal(trackStopped, 1, 'synthetic input must stop');
  assert.equal(contextClosed, 1, 'audio context must close');
  assert.equal(evidence.reason, 'response_done', 'probe must wait for the response terminal event');
  assert.equal(evidence.inbound_audio_bytes, 1234, 'capture aggregate received audio without content');
  assert.equal(evidence.audio_signal.before_response.samples, 1);
  assert.equal(evidence.audio_signal.before_response.over_threshold, 0);
  assert.equal(evidence.audio_signal.during_response.samples, 1);
  assert.equal(evidence.audio_signal.during_response.over_threshold, 1);
  assert.equal(evidence.audio_signal.after_response.over_threshold, 1);
  assert.equal(evidence.response_status, 'completed');
  assert.equal(evidence.usage.input_tokens_details.audio_tokens, 2);
  assert.equal(evidence.usage.output_tokens_details.audio_tokens, 4);
  assert.equal(evidence.playback.playing, 1, 'string callback must be recorded');
  assert.ok(evidence.observations.some((entry) => entry.code === 'transport_connected'));
}

(async () => {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  await run(input, false);
  await run(input, true);
})().catch((error) => { console.error(error); process.exitCode = 1; });
