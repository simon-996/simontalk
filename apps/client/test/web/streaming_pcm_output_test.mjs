import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function setup() {
  const nodes = [];
  const listeners = new Set();
  const timers = new Map();
  let now = 0, nextTimer = 0;
  const performance = {now: () => now};
  function advance(milliseconds) {
    const end = now + milliseconds;
    while (timers.size) {
      const [key, timer] = [...timers].sort((a, b) => a[1].due - b[1].due)[0];
      if (timer.due > end) break;
      now = timer.due;
      timers.delete(key);
      timer.run();
    }
    now = end;
  }
  const context = {
    state: 'running', currentTime: 10, outputTime: 10, performanceTime: 100,
    destination: {},
    addEventListener(name, listener) { if (name === 'statechange') listeners.add(listener); },
    removeEventListener(name, listener) { if (name === 'statechange') listeners.delete(listener); },
    changeState(value) { this.state = value; for (const listener of [...listeners]) listener(); },
    getOutputTimestamp() { return { contextTime: this.outputTime, performanceTime: this.performanceTime }; },
    createBuffer(channels, length, rate) {
      assert.equal(channels, 1);
      const data = new Float32Array(length);
      return { duration: length / rate, getChannelData() { return data; } };
    },
    createBufferSource() {
      const node = { stops: 0, disconnects: 0,
        connect() {}, start(time) { this.startTime = time; },
        stop() { this.stops++; }, disconnect() { this.disconnects++; },
      };
      nodes.push(node); return node;
    },
  };
  const window = {};
  vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_output.js', import.meta.url), 'utf8'),
    { window, Uint8Array, DataView, Float32Array, Number, Math, atob, btoa,
      performance,
      setTimeout(run, delay) { const key = ++nextTimer; timers.set(key, {due: now + delay, run}); return key; },
      clearTimeout(key) { timers.delete(key); } });
  return { context, nodes, create: () => window.simontalkStreamingPcmOutput.create(context, 8000),
    createRouter: () => window.simontalkStreamingPcmOutput.createResponseRouter(context, 8000),
    advance, timers, performance };
}

const pcm = (samples) => new Uint8Array(samples * 2);

test('consecutive chunks are scheduled in order and the output clock counts only scheduled audio', () => {
  const env = setup(); const player = env.create();
  assert.equal(player.append(pcm(4000)), true);
  assert.equal(player.append(pcm(4000)), true);
  assert.equal(env.nodes[0].startTime, 10.05);
  assert.equal(env.nodes[1].startTime, 10.55);
  env.context.currentTime = 10.75; env.context.outputTime = 10.6;
  assert.ok(Math.abs(player.estimateSeconds() - 0.55) < 0.00001);
  assert.equal(player.stop(), player.estimateSeconds());
  assert.equal(env.nodes[0].stops, 1); assert.equal(env.nodes[1].stops, 1);
  assert.equal(player.append(pcm(10)), false);
  env.context.outputTime = 10.7;
  assert.ok(Math.abs(player.estimateSeconds() - 0.55) < 0.00001);
});

test('a scheduling gap is not counted as audio', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(4000));
  env.context.currentTime = 11; player.append(pcm(4000));
  env.context.currentTime = 11.5; env.context.outputTime = 11.25;
  assert.ok(Math.abs(player.estimateSeconds() - 0.7) < 0.00001);
});

test('clock anomalies remain unknown and stop freezes unknown', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(4000));
  env.context.currentTime = 10.4; env.context.outputTime = 10.2;
  assert.ok(Math.abs(player.estimateSeconds() - 0.15) < 0.00001);
  env.context.outputTime = 10.1;
  assert.equal(player.estimateSeconds(), null);
  assert.equal(player.stop(), null);
  env.context.outputTime = 10.3;
  assert.equal(player.estimateSeconds(), null);
});

test('invalid input and too much buffered audio stop the player', () => {
  for (const invalid of [new Uint8Array(0), new Uint8Array(1), pcm(8001)]) {
    const env = setup(); const player = env.create();
    assert.equal(player.append(invalid), false);
    assert.equal(player.append(pcm(1)), false);
  }
  const env = setup(); const player = env.create();
  for (let i = 0; i < 10; i++) assert.equal(player.append(pcm(8000)), true);
  assert.equal(player.append(pcm(1)), false);
  assert.equal(env.nodes.length, 11);
  assert.equal(env.nodes.slice(0, 10).every((node) => node.stops === 1), true);
  assert.equal(env.nodes[10].startTime, undefined);
  assert.equal(env.nodes[10].disconnects, 1);
});

test('suspended contexts and impossible timestamps are never reported as output', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(100));
  env.context.state = 'suspended';
  assert.equal(player.estimateSeconds(), null);
  env.context.state = 'running'; env.context.outputTime = 11;
  assert.equal(player.estimateSeconds(), null);
  assert.equal(player.stop(), null);
});

test('PCM values are decoded as signed little-endian samples', () => {
  const env = setup(); const player = env.create();
  assert.equal(player.append(new Uint8Array([0, 128, 255, 127, 0, 0])), true);
  const samples = env.nodes[0].buffer.getChannelData(0);
  assert.deepEqual(Array.from(samples), [-1, 32767 / 32768, 0]);
});

test('release failure makes the frozen output estimate unknown but releases other sources', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(100)); player.append(pcm(100));
  env.nodes[0].disconnect = () => { throw new Error('device error'); };
  assert.equal(player.stop(), null);
  assert.equal(env.nodes[1].stops, 1);
  assert.equal(env.nodes[1].disconnects, 1);
  assert.equal(player.estimateSeconds(), null);
});

test('a node scheduling exception stops and disconnects all allocated nodes', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(100));
  const original = env.context.createBufferSource;
  env.context.createBufferSource = () => {
    const node = original(); node.start = () => { throw new Error('start failed'); }; return node;
  };
  assert.equal(player.append(pcm(100)), false);
  assert.equal(env.nodes.every((node) => node.stops === 1 && node.disconnects === 1), true);
  assert.equal(player.estimateSeconds(), null);
});

test('context suspension stops pending audio and prevents late resume', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(100));
  env.context.changeState('suspended');
  assert.equal(env.nodes[0].stops, 1);
  assert.equal(env.nodes[0].disconnects, 1);
  env.context.changeState('running');
  assert.equal(player.append(pcm(100)), false);
  assert.equal(player.estimateSeconds(), null);
});

test('quarantine stops audio when a reliable output timestamp is unavailable', () => {
  const env = setup();
  const router = env.createRouter();
  env.context.getOutputTimestamp = undefined;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append({
    responseId: 'response-a', itemId: 'item-a', eventId: 'event-a',
    outputIndex: 0, contentIndex: 0, bytes: pcm(100),
  }), 'appended');
  assert.equal(router.stop('response-a'), true);
  assert.equal(env.nodes[0].stops, 1);
  assert.equal(env.nodes[0].disconnects, 1);
});

test('a backwards output timestamp performance clock invalidates the estimate', () => {
  const env = setup(); const player = env.create();
  player.append(pcm(100));
  assert.equal(player.estimateSeconds(), 0);
  env.context.performanceTime = 99;
  assert.equal(player.estimateSeconds(), null);
  assert.equal(player.stop(), null);
});

test('audio preparation delay never schedules the source in the past', () => {
  const env = setup(); const player = env.create();
  const original = env.context.createBuffer;
  env.context.createBuffer = (...args) => {
    const buffer = original(...args);
    env.context.currentTime += 0.25;
    return buffer;
  };
  assert.equal(player.append(pcm(4000)), true);
  assert.ok(env.nodes[0].startTime >= env.context.currentTime);
  env.context.outputTime = 10.2;
  assert.equal(player.estimateSeconds(), 0);
});

test('an unexpectedly late start invalidates the estimate and closes the player', () => {
  const env = setup(); const player = env.create();
  const original = env.context.createBufferSource;
  env.context.createBufferSource = () => {
    const node = original();
    node.start = (time) => { node.startTime = time; env.context.currentTime = time + 0.1; };
    return node;
  };
  assert.equal(player.append(pcm(1000)), false);
  assert.equal(env.nodes[0].stops, 1);
  assert.equal(env.nodes[0].disconnects, 1);
  assert.equal(player.estimateSeconds(), null);
  assert.equal(player.append(pcm(1)), false);
});

test('stop during audio preparation does not schedule or retain the new source', () => {
  const env = setup(); const player = env.create();
  const original = env.context.createBufferSource;
  env.context.createBufferSource = () => {
    const node = original();
    node.connect = () => { player.stop(); };
    return node;
  };
  assert.equal(player.append(pcm(100)), false);
  assert.equal(env.nodes[0].startTime, undefined);
  assert.equal(env.nodes[0].disconnects, 1);
  assert.equal(player.append(pcm(1)), false);
});


const audioEvent = (responseId, itemId, eventId, bytes = pcm(100)) => ({
  responseId, itemId, eventId, outputIndex: 0, contentIndex: 0, bytes,
});

test('retired response audio cannot enter a later response player', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'event-a')), 'appended');
  assert.equal(router.stop('response-a'), true);
  assert.equal(env.nodes[0].stops, 1);
  assert.equal(router.start('response-b', 'item-b'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'late')), 'stale');
  assert.equal(router.append(audioEvent('response-b', 'item-b', 'event-b')), 'appended');
  assert.equal(env.nodes.length, 2);
  assert.equal(router.stop('response-b'), true);
  assert.equal(router.start('response-a', 'item-a'), false);
});

test('unknown identities and duplicate events close playback without scheduling twice', () => {
  for (const bad of [
    audioEvent('unknown', 'item-a', 'event-x'),
    audioEvent('response-a', 'item-other', 'event-x'),
    {...audioEvent('response-a', 'item-a', 'event-x'), outputIndex: 1},
    audioEvent('response-a', 'item-a', 'event-a'),
  ]) {
    const env = setup(); const router = env.createRouter();
    assert.equal(router.start('response-a', 'item-a'), true);
    assert.equal(router.append(audioEvent('response-a', 'item-a', 'event-a')), 'appended');
    assert.equal(router.append(bad), 'rejected');
    assert.equal(env.nodes.length, 1);
    assert.equal(env.nodes[0].stops, 1);
    assert.equal(router.start('response-b', 'item-b'), false);
  }
});

test('local release uncertainty prevents creating another response player', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'event-a')), 'appended');
  env.nodes[0].disconnect = () => { throw Error('release failure'); };
  assert.equal(router.stop('response-a'), false);
  assert.equal(router.start('response-b', 'item-b'), false);
});

test('reentrant shutdown during audio preparation prevents that chunk from starting', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  const original = env.context.createBufferSource;
  env.context.createBufferSource = () => {
    const node = original();
    node.connect = () => { router.dispose(); };
    return node;
  };
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'event-a')), 'rejected');
  assert.equal(env.nodes[0].startTime, undefined);
  assert.equal(env.nodes[0].disconnects, 1);
  assert.equal(router.start('response-b', 'item-b'), false);
});

test('a response item cannot be reused by a later response', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.stop('response-a'), true);
  assert.equal(router.start('response-b', 'item-a'), false);
  assert.equal(router.start('response-c', 'item-c'), false);
});

test('invalid audio and unknown stop close the whole router', () => {
  for (const action of [
    router => router.append(audioEvent('response-a', 'item-a', 'event-a', new Uint8Array(1))),
    router => router.stop('other'),
  ]) {
    const env = setup(); const router = env.createRouter();
    assert.equal(router.start('response-a', 'item-a'), true);
    action(router);
    assert.equal(router.start('response-b', 'item-b'), false);
  }
});

test('response lifetime is bounded and prior identities cannot be forgotten', () => {
  const env = setup(); const router = env.createRouter();
  for (let i = 0; i < 64; i++) {
    assert.equal(router.start(`response-${i}`, `item-${i}`), true);
    assert.equal(router.stop(`response-${i}`), true);
  }
  assert.equal(router.start('response-64', 'item-64'), false);
});


const qwenAudioEvent = (responseId, itemId, eventId, delta = 'AAAAAA==') => ({
  type: 'response.audio.delta', response_id: responseId, item_id: itemId,
  event_id: eventId, output_index: 0, content_index: 0, delta,
});

test('Qwen audio event is decoded only for its explicitly bound response and item', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.appendQwenDelta(qwenAudioEvent('response-a', 'item-a', 'event-a', 'AID/fwAA')), 'appended');
  assert.deepEqual(Array.from(env.nodes[0].buffer.getChannelData(0)), [-1, 32767 / 32768, 0]);
  assert.equal(router.stop('response-a'), true);
  assert.equal(router.start('response-b', 'item-b'), true);
  assert.equal(router.appendQwenDelta(qwenAudioEvent('response-a', 'item-a', 'late')), 'stale');
  assert.equal(router.appendQwenDelta(qwenAudioEvent('response-b', 'item-b', 'event-b')), 'appended');
  assert.equal(env.nodes.length, 2);
});

test('Qwen malformed, noncanonical and odd-length Base64 close the active player', () => {
  for (const delta of ['', 'AA=', 'AB==', 'AA==', 'AA A=', 'AAAA'.repeat(16001)]) {
    const env = setup(); const router = env.createRouter();
    assert.equal(router.start('response-a', 'item-a'), true);
    assert.equal(router.appendQwenDelta(qwenAudioEvent('response-a', 'item-a', 'event-a', delta)), 'rejected');
    assert.equal(env.nodes.length, 0);
    assert.equal(router.start('response-b', 'item-b'), false);
  }
});

test('Qwen wrong item, duplicate event and non-audio type fail closed', () => {
  for (const invalid of [
    qwenAudioEvent('response-a', 'wrong-item', 'event-b'),
    qwenAudioEvent('response-a', 'item-a', 'event-a'),
    {...qwenAudioEvent('response-a', 'item-a', 'event-b'), type: 'response.done'},
  ]) {
    const env = setup(); const router = env.createRouter();
    assert.equal(router.start('response-a', 'item-a'), true);
    assert.equal(router.appendQwenDelta(qwenAudioEvent('response-a', 'item-a', 'event-a')), 'appended');
    assert.equal(router.appendQwenDelta(invalid), 'rejected');
    assert.equal(env.nodes.length, 1);
    assert.equal(env.nodes[0].stops, 1);
  }
});

test('reentrant disposal during Qwen event decoding cannot schedule audio', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  const event = qwenAudioEvent('response-a', 'item-a', 'event-a');
  Object.defineProperty(event, 'delta', {get() { router.dispose(); return 'AAAAAA=='; }});
  assert.equal(router.appendQwenDelta(event), 'rejected');
  assert.equal(env.nodes.length, 0);
  assert.equal(router.start('response-b', 'item-b'), false);
});

test('late Qwen audio is dropped without decoding or reviving the old player', () => {
  const env = setup(); const router = env.createRouter();
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.stop('response-a'), true);
  assert.equal(router.start('response-b', 'item-b'), true);
  const late = qwenAudioEvent('response-a', 'item-a', 'late');
  Object.defineProperty(late, 'delta', {get() { throw Error('must not decode old audio'); }});
  assert.equal(router.appendQwenDelta(late), 'stale');
  assert.equal(router.appendQwenDelta(qwenAudioEvent('response-b', 'item-b', 'event-b')), 'appended');
});

test('complete waits for graph end and the output clock to reach the last sample', () => {
  const env = setup(); const router = env.createRouter();
  let settled = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e2')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }), true);
  assert.equal(settled, 0);
  assert.equal(env.nodes[0].stops, 0);
  assert.equal(env.nodes[1].stops, 0);
  env.nodes[0].onended();
  assert.equal(settled, 0);
  const end = env.nodes[1].startTime + env.nodes[1].buffer.duration;
  env.context.currentTime = end + 0.04;
  env.context.outputTime = end - 0.025;
  env.nodes[1].onended();
  assert.equal(settled, 0);
  env.advance(80);
  assert.equal(settled, 0);
  env.context.outputTime = end;
  env.advance(40);
  assert.equal(settled, 1);
  assert.equal(env.timers.size, 0);
  assert.equal(router.start('response-b', 'item-b'), true);
});

test('graph progress during output sampling does not invalidate a current timestamp', () => {
  const env = setup(); const router = env.createRouter();
  let settled = 0;
  let unavailable = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }, () => { unavailable++; }), true);
  const end = env.nodes[0].startTime + env.nodes[0].buffer.duration;
  env.context.currentTime = end + 0.01;
  env.context.getOutputTimestamp = () => {
    env.context.currentTime = end + 0.03;
    return { contextTime: end + 0.02, performanceTime: 100 };
  };
  env.nodes[0].onended();
  assert.equal(settled, 1);
  assert.equal(unavailable, 0);
});

test('a timestamp query that crosses the deadline cannot settle playback', () => {
  const env = setup(); const router = env.createRouter();
  let settled = 0;
  let unavailable = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }, () => { unavailable++; }), true);
  const end = env.nodes[0].startTime + env.nodes[0].buffer.duration;
  env.nodes[0].onended();
  env.context.currentTime = end + 0.04;
  env.context.getOutputTimestamp = () => {
    env.performance.now = () => 1001;
    return { contextTime: end, performanceTime: 100 };
  };
  env.advance(25);
  assert.equal(unavailable, 1);
  assert.equal(settled, 0);
  assert.equal(env.timers.size, 0);
});

test('missing output clock retains the graph-end settlement path', () => {
  const env = setup();
  env.context.getOutputTimestamp = undefined;
  const router = env.createRouter();
  let settled = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }), true);
  env.nodes[0].onended();
  assert.equal(settled, 1);
  assert.equal(env.timers.size, 0);
});

test('a supported clock that stalls or goes backwards never settles the reply', () => {
  for (const regress of [false, true]) {
    const env = setup(); const router = env.createRouter();
    let settled = 0, unavailable = 0;
    assert.equal(router.start('response-a', 'item-a'), true);
    assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
    assert.equal(router.complete('response-a', () => { settled++; }, () => { unavailable++; }), true);
    env.context.currentTime = 10.2;
    env.context.outputTime = 10.04;
    env.nodes[0].onended();
    assert.equal(unavailable, 0);
    if (regress) env.context.outputTime = 10.03;
    env.advance(regress ? 35 : 1200);
    assert.equal(settled, 0);
    assert.equal(unavailable, 1);
    assert.equal(env.timers.size, 0);
    assert.equal(router.start('response-b', 'item-b'), false);
  }
});

test('quarantine during device settlement cancels the pending clock observation', () => {
  const env = setup(); const router = env.createRouter();
  let settled = 0, unavailable = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }, () => { unavailable++; }), true);
  env.context.currentTime = 10.2;
  env.context.outputTime = 10.04;
  env.nodes[0].onended();
  assert.equal(env.timers.size, 1);
  assert.equal(router.stop('response-a'), true);
  assert.equal(env.timers.size, 0);
  env.context.outputTime = 10.2;
  env.advance(1200);
  assert.equal(settled, 0);
  assert.equal(unavailable, 0);
});

test('stop while completing immediately stops remaining nodes and suppresses settled callback', () => {
  const env = setup(); const router = env.createRouter();
  let settled = 0;
  assert.equal(router.start('response-a', 'item-a'), true);
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e1')), 'appended');
  assert.equal(router.append(audioEvent('response-a', 'item-a', 'e2')), 'appended');
  assert.equal(router.complete('response-a', () => { settled++; }), true);
  env.nodes[0].onended();
  assert.equal(router.stop('response-a'), true);
  assert.equal(env.nodes[0].stops, 0);
  assert.equal(env.nodes[1].stops, 1);
  env.nodes[1].onended?.();
  assert.equal(settled, 0);
});
