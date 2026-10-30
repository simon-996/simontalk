import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function setup() {
  const nodes = [];
  const listeners = new Set();
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
    { window, Uint8Array, DataView, Float32Array, Number, Math });
  return { context, nodes, create: () => window.simontalkStreamingPcmOutput.create(context, 8000) };
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
