import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const sourceUrl = new URL('../../web/realtime_transport.js', import.meta.url);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const flush = () => new Promise(setImmediate);

function target(extra = {}) {
  const listeners = new Map();
  return {
    ...extra, listeners,
    addEventListener(name, callback) {
      listeners.set(name, [...(listeners.get(name) ?? []), callback]);
    },
    removeEventListener(name, callback) {
      listeners.set(name, (listeners.get(name) ?? []).filter((value) => value !== callback));
    },
    emit(name, event = {}) {
      for (const callback of [...(listeners.get(name) ?? [])]) callback(event);
    },
    dispatchEvent(event) { this.emit(event.type); },
  };
}

function environment({ secure = true, blockedPlayback = false, replaceWait = false, playbackError, playbackWait = false, onObservation = () => {} } = {}) {
  const permission = deferred();
  const answer = deferred();
  const replaced = deferred();
  const playback = deferred();
  const counters = { requests: 0, exchanges: 0, cancelled: 0, plays: 0, pauses: 0 };
  const timers = new Map();
  let timerId = 0;
  const track = target({ kind: 'audio', enabled: true, readyState: 'live', stops: 0,
    stop() { this.stops++; this.readyState = 'ended'; },
  });
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] };
  const peers = [];
  const audios = [];
  const channels = [];
  function channel(label = 'oai-events') {
    const value = target({ label, readyState: 'connecting', bufferedAmount: 0, sent: [], closes: 0,
      send(data) { this.sent.push(data); },
      close() { this.closes++; this.readyState = 'closed'; this.emit('close'); },
      open() { this.readyState = 'open'; this.emit('open'); },
      message(data) { this.emit('message', { data }); },
    });
    channels.push(value);
    return value;
  }
  class Peer {
    constructor(config) {
      assert.deepEqual(JSON.parse(JSON.stringify(config)), { iceServers: [] });
      Object.assign(this, target());
      this.connectionState = 'new'; this.iceGatheringState = 'new'; this.closes = 0;
      this.sender = { track: null, replacements: [], replaceTrack: async (value) => {
        this.sender.replacements.push(value);
        if (replaceWait) await replaced.promise;
        this.sender.track = value;
      } };
      peers.push(this);
    }
    addTransceiver(kind, options) {
      assert.equal(kind, 'audio'); assert.equal(options.direction, 'sendrecv');
      return { sender: this.sender };
    }
    createDataChannel(label) { return channel(label); }
    async createOffer() { return { type: 'offer', sdp: 'v=0\r\no=offer\r\n' }; }
    async setLocalDescription(offer) { this.localDescription = offer; }
    async setRemoteDescription(value) { this.remoteDescription = value; }
    completeIce() { this.iceGatheringState = 'complete'; this.emit('icegatheringstatechange'); }
    connect() { this.connectionState = 'connected'; this.emit('connectionstatechange'); }
    close() { this.closes++; this.connectionState = 'closed'; this.emit('connectionstatechange'); }
  }
  class MediaStream {
    constructor() { this.tracks = []; }
    addTrack(value) { this.tracks.push(value); }
    getTracks() { return this.tracks; }
  }
  const document = target({ hidden: false, createElement(kind) {
    assert.equal(kind, 'audio');
    const audio = target({ srcObject: null, removed: false,
      async play() {
        counters.plays++;
        if (playbackWait) return playback.promise;
        if (playbackError) throw Object.assign(new Error('private'), { name: playbackError });
        if (blockedPlayback) throw Object.assign(new Error('private'), { name: 'NotAllowedError' });
      },
      pause() { counters.pauses++; },
      remove() { this.removed = true; },
    });
    audios.push(audio); return audio;
  } });
  const window = target({ isSecureContext: secure, RTCPeerConnection: Peer, MediaStream,
    navigator: { mediaDevices: { getUserMedia(constraints) {
      counters.requests++;
      assert.equal(constraints.video, false);
      assert.equal(constraints.audio.echoCancellation, true);
      return permission.promise;
    } } },
  });
  vm.runInNewContext(readFileSync(sourceUrl, 'utf8'), {
    window, document, Event, TextEncoder,
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  const observations = [];
  const events = [];
  const transport = window.simontalkRealtime.create();
  const begin = () => transport.start(
    (offer) => { counters.exchanges++; assert.equal(offer, 'v=0\r\no=offer\r\n'); return answer.promise; },
    (code, detail) => { observations.push({ code, detail }); onObservation(code, detail); },
    (json, id) => events.push({ json, id }),
    () => { counters.cancelled++; },
  );
  async function negotiate() {
    const started = begin(); permission.resolve(stream); await flush();
    peers[0].completeIce(); await flush();
    answer.resolve('v=0\no=answer\n'); await flush();
    return { started };
  }
  async function connect() {
    const { started } = await negotiate();
    peers[0].connect(); channels[0].open();
    assert.equal(await started, null);
    return channels[0];
  }
  return { window, document, permission, answer, replaced, playback, counters, timers, track, stream,
    peers, audios, channels, channel, observations, events, transport, begin, negotiate, connect,
    fire(delay) { const entry = [...timers.entries()].find(([, value]) => value.delay === delay);
      assert.ok(entry, `missing ${delay}ms timer`); timers.delete(entry[0]); entry[1].callback(); },
  };
}

test('construction has no permission, connection, playback or network side effects', () => {
  const env = environment();
  assert.equal(env.counters.requests, 0); assert.equal(env.peers.length, 0);
  assert.equal(env.audios.length, 0); assert.equal(env.timers.size, 0);
});

test('SDP success alone is not connected and configuration gates microphone upload', async () => {
  const env = environment();
  const { started } = await env.negotiate();
  let resolved = false; started.then(() => { resolved = true; }); await flush();
  assert.equal(resolved, false); assert.equal(env.peers[0].sender.track, null);
  env.channels[0].open(); await flush(); assert.equal(resolved, false);
  env.peers[0].connect(); assert.equal(await started, null);
  assert.equal(env.peers[0].sender.track, null);
  env.channels[0].message('{"type":"session.created"}');
  const id = env.events[0].id;
  assert.equal(env.transport.send('{"type":"session.update"}', id), null);
  assert.equal(env.peers[0].sender.track, null);
  assert.equal(await env.transport.activate(id), null);
  assert.equal(env.peers[0].sender.track, env.track);
  assert.equal(env.counters.exchanges, 1);
  env.transport.stop();
});

test('server-created channel can supply events and receive configuration', async () => {
  const env = environment(); const { started } = await env.negotiate();
  env.peers[0].connect();
  const remote = env.channel('server'); remote.readyState = 'open';
  env.peers[0].emit('datachannel', { channel: remote });
  assert.equal(await started, null);
  remote.message('{"type":"session.created"}');
  const id = env.events[0].id;
  assert.equal(env.transport.send('{"type":"session.update"}', id), null);
  assert.deepEqual(remote.sent, ['{"type":"session.update"}']);
  assert.equal(env.channels[0].sent.length, 0);
  await env.transport.activate(id);
  env.channels[0].close();
  assert.equal(env.track.stops, 0);
  remote.close();
  assert.equal(env.track.stops, 1);
});

test('stop resolves pending start and late permission is immediately released', async () => {
  const env = environment(); const started = env.begin();
  env.transport.stop(); env.transport.stop();
  assert.equal(await started, 'cancelled');
  env.permission.resolve(env.stream); await flush();
  assert.equal(env.track.stops, 1); assert.equal(env.peers.length, 0);
  assert.equal(env.counters.cancelled, 1); assert.equal(env.timers.size, 0);
});

test('late SDP after stop never sets a remote description or reopens media', async () => {
  const env = environment(); const started = env.begin();
  env.permission.resolve(env.stream); await flush(); env.peers[0].completeIce(); await flush();
  env.transport.stop(); assert.equal(await started, 'cancelled');
  env.answer.resolve('v=0\r\n'); await flush();
  assert.equal(env.peers[0].remoteDescription, undefined);
  assert.equal(env.track.stops, 1); assert.equal(env.peers[0].closes, 1);
});

test('permission, connection and model configuration waits are bounded', async () => {
  const permission = environment(); const waiting = permission.begin(); permission.fire(20000);
  assert.equal(await waiting, 'permission_timeout');
  permission.permission.resolve(permission.stream); await flush(); assert.equal(permission.track.stops, 1);
  const connection = environment(); const { started } = await connection.negotiate(); connection.fire(30000);
  assert.equal(await started, 'connection_timeout'); assert.equal(connection.track.stops, 1);
  const configuration = environment(); await configuration.connect(); configuration.fire(20000);
  assert.equal(configuration.track.stops, 1);
  assert.ok(configuration.observations.some((event) => event.detail === 'configuration_timeout'));
});

for (const name of ['visibilitychange', 'pagehide', 'ended', 'connectionstatechange']) {
  test(`${name} stops capture, channels, playback, listeners and timers`, async () => {
    const env = environment(); await env.connect();
    await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
    if (name === 'visibilitychange') env.document.hidden = true;
    if (name === 'connectionstatechange') env.peers[0].connectionState = 'disconnected';
    (name === 'visibilitychange' ? env.document : name === 'pagehide' ? env.window :
      name === 'ended' ? env.track : env.peers[0]).emit(name);
    assert.equal(env.track.stops, 1); assert.equal(env.peers[0].closes, 1);
    assert.equal(env.channels[0].closes, 1); assert.equal(env.timers.size, 0);
    assert.equal(env.counters.cancelled, 1);
    for (const object of [env.window, env.document, env.track, env.peers[0], env.channels[0]]) {
      assert.equal([...object.listeners.values()].flat().length, 0);
    }
    assert.equal(env.audios[0].srcObject, null);
  });
}

test('muting remains independent of playback and survives configuration delay', async () => {
  const env = environment(); await env.connect();
  env.transport.setMuted(true);
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  await env.transport.activate(id); assert.equal(env.track.enabled, false);
  env.transport.setMuted(false); assert.equal(env.track.enabled, true);
  const remoteTrack = target({ kind: 'audio', stop() {} });
  env.peers[0].emit('track', { track: remoteTrack, streams: [] }); await flush();
  assert.equal(env.track.enabled, true); assert.equal(env.counters.plays, 1);
  env.transport.stop();
});

test('autoplay failure reports a recoverable playback restriction', async () => {
  const env = environment({ blockedPlayback: true }); await env.connect();
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  await flush();
  assert.ok(env.observations.some((event) => event.code === 'playback_blocked'));
  assert.equal(env.track.stops, 0);
  assert.equal(await env.transport.resumePlayback(), 'playback_blocked');
  env.transport.stop();
});

test('backpressure and invalid outgoing JSON never send or close the connection', async () => {
  const env = environment(); const channel = await env.connect();
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  channel.bufferedAmount = 262144;
  assert.equal(env.transport.send('{"type":"response.cancel"}', id), 'backpressure');
  channel.bufferedAmount = 0;
  for (const invalid of ['null', '[]', 'bad', '"text"', '{"text":"' + '中'.repeat(24000) + '"}']) {
    assert.equal(env.transport.send(invalid, id), 'invalid_event');
  }
  assert.equal(channel.sent.length, 0); assert.equal(env.track.stops, 0);
  env.transport.stop();
});

test('malformed incoming events close locally without exposing raw event data', async () => {
  const env = environment(); const channel = await env.connect();
  channel.message('secret invalid JSON');
  assert.equal(env.events.length, 0); assert.equal(env.track.stops, 1);
  assert.ok(!JSON.stringify(env.observations).includes('secret'));
});

test('cancel during replaceTrack cannot activate or play late media', async () => {
  const env = environment({ replaceWait: true }); await env.connect();
  const activating = env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.transport.stop(); env.replaced.resolve();
  assert.equal(await activating, 'cancelled'); assert.equal(env.track.stops, 1);
  assert.equal(env.counters.plays, 0);
  assert.equal(env.observations.filter((event) => event.code === 'microphone_active').length, 0);
});

test('insecure or background pages never request capture or create a connection', async () => {
  const insecure = environment({ secure: false }); assert.equal(await insecure.begin(), 'unsupported');
  assert.equal(insecure.counters.requests, 0);
  const hidden = environment(); hidden.document.hidden = true;
  assert.equal(await hidden.begin(), 'background'); assert.equal(hidden.counters.requests, 0);
});

test('stop settles activation even when the browser never resolves replaceTrack', async () => {
  const env = environment({ replaceWait: true }); await env.connect();
  const activating = env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  let settled = false; activating.then(() => { settled = true; });
  env.transport.stop(); await flush();
  assert.equal(settled, true);
  assert.equal(await activating, 'cancelled');
});

test('unsupported audio is a media failure, not a recoverable autoplay prompt', async () => {
  const env = environment({ playbackError: 'NotSupportedError' }); await env.connect();
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  const result = await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  assert.equal(result, null);
  await flush();
  assert.equal(env.track.stops, 1);
  assert.ok(env.observations.some((event) => event.detail === 'playback_failed'));
  assert.equal(env.observations.some((event) => event.code === 'playback_blocked'), false);
});

test('a later player error releases capture instead of silently continuing', async () => {
  const env = environment(); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.audios[0].emit('error');
  assert.equal(env.track.stops, 1);
  assert.ok(env.observations.some((event) => event.detail === 'playback_failed'));
});

test('microphone activation does not wait for the first remote audio packet', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  const activating = env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  let settled = false; activating.then(() => { settled = true; }); await flush();
  assert.equal(settled, true);
  assert.equal(await activating, null);
  assert.equal(env.peers[0].sender.track, env.track);
  env.transport.stop();
});

test('the player binds its remote stream only after the first audio track exists', async () => {
  const env = environment(); await env.connect();
  assert.equal(env.audios[0].srcObject, null);
  const remoteTrack = target({ kind: 'audio', stop() {} });
  env.peers[0].emit('track', { track: remoteTrack, streams: [] });
  assert.deepEqual(env.audios[0].srcObject.getTracks(), [remoteTrack]);
  env.transport.stop();
});

test('a remote stream binding failure closes media without escaping the track callback', async () => {
  const env = environment(); await env.connect();
  Object.defineProperty(env.audios[0], 'srcObject', {
    set(value) { if (value !== null) throw new Error('private media failure'); },
    get() { return null; },
  });
  const remoteTrack = target({ kind: 'audio', stops: 0, stop() { this.stops++; } });
  assert.doesNotThrow(() => env.peers[0].emit('track', { track: remoteTrack, streams: [] }));
  assert.equal(env.track.stops, 1);
  assert.equal(remoteTrack.stops, 1);
  assert.ok(env.observations.some((event) => event.detail === 'playback_failed'));
});

test('explicit playback resume has a bounded waiting result when media is silent', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  const resumed = env.transport.resumePlayback();
  for (const { callback, delay } of [...env.timers.values()]) if (delay === 5000) callback();
  let settled = false; resumed.then(() => { settled = true; }); await flush();
  assert.equal(settled, true);
  assert.equal(await resumed, 'playback_waiting');
  assert.equal(env.track.stops, 0);
  env.transport.stop();
});

test('playback denial arriving after the waiting deadline is still observed', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  env.fire(5000); await flush();
  assert.ok(env.observations.some((event) => event.code === 'playback_waiting'));
  env.playback.reject({ name: 'NotAllowedError' }); await flush();
  assert.ok(env.observations.some((event) => event.code === 'playback_blocked'));
  env.transport.stop();
});

test('playing event prevents an older pending timeout from reporting waiting', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  env.audios[0].emit('playing');
  env.fire(5000); await flush();
  assert.equal(env.observations.at(-1).code, 'playback_playing');
  assert.equal(env.observations.some((event) => event.code === 'playback_waiting'), false);
  env.transport.stop();
});

test('late denial from an earlier play cannot overwrite a successful resume', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  env.audios[0].play = async () => {};
  assert.equal(await env.transport.resumePlayback(), null);
  env.audios[0].emit('playing');
  env.playback.reject({ name: 'NotAllowedError' }); await flush();
  assert.equal(env.observations.at(-1).code, 'playback_playing');
  assert.equal(env.track.stops, 0);
  env.transport.stop();
});

test('a late non-permission playback failure still closes media after a resume', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  env.audios[0].play = async () => {};
  assert.equal(await env.transport.resumePlayback(), null);
  env.audios[0].emit('playing');
  env.playback.reject({ name: 'NotSupportedError' }); await flush();
  assert.equal(env.track.stops, 1);
  assert.ok(env.observations.some((event) => event.detail === 'playback_failed'));
});

test('a playing observation during a waiting callback supersedes its return value', async () => {
  let env;
  env = environment({ playbackWait: true, onObservation(code) {
    if (code === 'playback_waiting') env.audios[0].emit('playing');
  } });
  await env.connect();
  await env.transport.activate(env.observations.find((event) => event.code === 'channel_open').detail);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }), streams: [] });
  const resumed = env.transport.resumePlayback();
  const [id, timer] = [...env.timers.entries()].filter(([, value]) => value.delay === 5000).at(-1);
  env.timers.delete(id); timer.callback(); await flush();
  assert.equal(await resumed, null);
  assert.equal(env.observations.at(-1).code, 'playback_playing');
  env.transport.stop();
});

test('drain synchronously stops media and keeps only the confirmed event channel', async () => {
  const env = environment(); const control = await env.connect();
  const other = env.channel('other'); other.readyState = 'open';
  env.peers[0].emit('datachannel', { channel: other });
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  await env.transport.activate(id);
  const remote = target({ kind: 'audio', stops: 0, stop() { this.stops++; } });
  env.peers[0].emit('track', { track: remote }); await flush();
  assert.equal(env.counters.plays, 1);
  assert.equal(typeof env.transport.beginDrain, 'function');
  assert.equal(env.transport.beginDrain(), null);
  assert.equal(env.track.enabled, false); assert.equal(env.track.stops, 1);
  assert.equal(remote.stops, 1); assert.equal(env.counters.pauses, 1);
  assert.equal(env.audios[0].srcObject, null);
  assert.equal(env.peers[0].closes, 0); assert.equal(control.closes, 0);
  assert.equal(other.closes, 1); assert.equal(env.counters.cancelled, 0);
  control.message('{"type":"input.final"}');
  other.message('{"type":"other.final"}');
  assert.deepEqual(env.events, [{ json: '{"type":"input.final"}', id }]);
  assert.equal(env.transport.send('{"type":"response.cancel"}', id), null);
  assert.equal(env.transport.send('{"type":"response.cancel"}', 'channel-1'), 'invalid_channel');
  assert.deepEqual(control.sent, ['{"type":"response.cancel"}']);
  assert.equal(env.transport.beginDrain(), null);
  assert.equal(env.track.stops, 1); assert.equal(remote.stops, 1);
  assert.equal(env.counters.pauses, 1);
  env.transport.stop(); env.transport.stop();
  assert.equal(env.peers[0].closes, 1); assert.equal(control.closes, 1);
  assert.equal(env.counters.cancelled, 1); assert.equal(env.timers.size, 0);
  assert.equal(env.audios[0].removed, true);
});

test('drain prevents late media, new channels, activation and unmuting', async () => {
  const env = environment(); await env.connect();
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  await env.transport.activate(id);
  assert.equal(env.transport.beginDrain(), null);
  const remote = target({ kind: 'audio', stops: 0, stop() { this.stops++; } });
  env.peers[0].emit('track', { track: remote });
  const late = env.channel('late'); late.readyState = 'open';
  env.peers[0].emit('datachannel', { channel: late });
  late.message('{"type":"response.created"}');
  assert.equal(await env.transport.activate(id), 'draining');
  assert.equal(await env.transport.resumePlayback(), 'draining');
  env.transport.setMuted(false);
  assert.equal(env.track.enabled, false); assert.equal(remote.stops, 1);
  assert.equal(late.closes, 1); assert.equal(env.events.length, 0);
  assert.equal(env.counters.plays, 0);
  assert.equal(env.observations.filter((event) => event.code === 'channel_open').length, 1);
  env.transport.stop();
  assert.equal(env.transport.beginDrain(), 'cancelled');
});

test('drain settles pending playback and ignores its late denial', async () => {
  const env = environment({ playbackWait: true }); await env.connect();
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  await env.transport.activate(id);
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }) });
  const resumed = env.transport.resumePlayback();
  assert.equal(env.transport.beginDrain(), null);
  assert.equal(await resumed, 'draining');
  assert.equal(env.timers.size, 0);
  env.playback.reject({ name: 'NotAllowedError' }); await flush();
  env.audios[0].emit('playing');
  assert.equal(env.observations.some((event) => event.code === 'playback_blocked'), false);
  assert.equal(env.observations.some((event) => event.code === 'playback_playing'), false);
  assert.equal(env.peers[0].closes, 0);
  env.transport.stop();
});

test('drain before activation is rejected and stop still releases pending activation', async () => {
  const env = environment({ replaceWait: true }); await env.connect();
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  const activating = env.transport.activate(id);
  assert.equal(env.transport.beginDrain(), 'not_active');
  assert.equal(env.track.stops, 0);
  env.transport.stop();
  assert.equal(await activating, 'cancelled');
  env.replaced.resolve(); await flush();
  assert.equal(env.track.stops, 1); assert.equal(env.track.readyState, 'ended');
  assert.equal(env.counters.plays, 0);
});

test('media release failures during drain still release remaining local resources', async () => {
  const env = environment(); await env.connect();
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  await env.transport.activate(id);
  const remote = target({ kind: 'audio', stops: 0, stop() { this.stops++; } });
  env.peers[0].emit('track', { track: remote }); await flush();
  env.track.stop = () => { env.track.stops++; throw new Error('device failure'); };
  env.audios[0].pause = () => { env.counters.pauses++; throw new Error('player failure'); };
  assert.equal(env.transport.beginDrain(), 'media_failed');
  assert.equal(env.track.enabled, false); assert.equal(remote.stops, 1);
  assert.equal(env.audios[0].srcObject, null); assert.equal(env.audios[0].removed, true);
  assert.equal(env.peers[0].closes, 1); assert.equal(env.channels[0].closes, 1);
  assert.equal(env.counters.cancelled, 1); assert.equal(env.timers.size, 0);
  env.transport.stop();
});

test('drain retains a server configured channel and ignores errors from retired channels', async () => {
  const env = environment(); const original = await env.connect();
  const configured = env.channel('server'); configured.readyState = 'open';
  env.peers[0].emit('datachannel', { channel: configured });
  const id = env.observations.at(-1).detail;
  await env.transport.activate(id);
  assert.equal(env.transport.beginDrain(), null);
  assert.equal(original.closes, 1); assert.equal(configured.closes, 0);
  original.emit('error');
  assert.equal(env.peers[0].closes, 0);
  configured.message('{"type":"response.final"}');
  assert.deepEqual(env.events, [{ json: '{"type":"response.final"}', id }]);
  assert.equal(env.transport.send('{"type":"input.complete"}', id), null);
  configured.close();
  assert.equal(env.peers[0].closes, 1);
});

test('drain requested by microphone activation observation prevents its remaining playback', async () => {
  const env = environment({ onObservation(code) {
    if (code === 'microphone_active') assert.equal(env.transport.beginDrain(), null);
  } });
  await env.connect();
  env.peers[0].emit('track', { track: target({ kind: 'audio', stop() {} }) });
  const id = env.observations.find((event) => event.code === 'channel_open').detail;
  assert.equal(await env.transport.activate(id), 'draining');
  assert.equal(env.peers[0].closes, 0); assert.equal(env.counters.plays, 0);
  assert.equal(env.track.stops, 1);
  env.transport.stop();
});
