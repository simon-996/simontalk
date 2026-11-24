import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function setup() {
  let Processor;
  class Base {
    constructor() {
      this.port = { messages: [], onmessage: null,
        postMessage(message) { this.messages.push(message); },
        close() { this.closed = true; },
      };
    }
  }
  vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_input_worklet.js', import.meta.url), 'utf8'), {
    AudioWorkletProcessor: Base, registerProcessor(name, value) {
      assert.equal(name, 'simontalk-pcm-input'); Processor = value;
    }, Uint8Array, ArrayBuffer, DataView, Map, Number, Math,
  });
  return new Processor();
}

function mode(processor, epoch, muted) {
  processor.port.onmessage({data: {kind: 'mode', epoch, muted}});
}
function feed(processor, samples) {
  const out = [new Float32Array(samples.length).fill(0.5)];
  const result = processor.process([[samples]], [out]);
  assert.equal(out[0].every(x => x === 0), true);
  return result;
}

test('capture defaults to muted and emits one bounded little-endian mono frame', () => {
  const p = setup();
  feed(p, new Float32Array(1600).fill(0.5));
  assert.equal(p.port.messages.length, 0);
  mode(p, 1, false);
  const values = new Float32Array(1600); values[0] = -1; values[1] = 1;
  assert.equal(feed(p, values), true);
  const [message] = p.port.messages;
  assert.equal(message.kind, 'audio'); assert.equal(message.epoch, 1);
  assert.equal(message.sequence, 1); assert.equal(message.pcm.byteLength, 3200);
  const decoded = new DataView(message.pcm);
  assert.equal(decoded.getInt16(0, true), -32768);
  assert.equal(decoded.getInt16(2, true), 32767);
});

test('mute and unmute discard a partial frame from the old generation', () => {
  const p = setup(); mode(p, 1, false);
  feed(p, new Float32Array(800).fill(-1));
  mode(p, 2, true); mode(p, 3, false);
  feed(p, new Float32Array(1600).fill(1));
  assert.equal(p.port.messages.length, 1);
  const msg = p.port.messages[0];
  assert.equal(msg.epoch, 3);
  assert.equal(new DataView(msg.pcm).getInt16(0, true), 32767);
});

test('without acknowledgement capture stops after three frames instead of buffering indefinitely', () => {
  const p = setup(); mode(p, 1, false);
  assert.equal(feed(p, new Float32Array(4800).fill(0.1)), true);
  assert.equal(p.port.messages.filter(m => m.kind === 'audio').length, 3);
  assert.equal(feed(p, new Float32Array(1600).fill(0.1)), false);
  assert.equal(p.port.messages.at(-1).kind, 'error');
  assert.equal(feed(p, new Float32Array(1600)), false);
});

test('matching acknowledgements free capacity and invalid acknowledgements stop processing', () => {
  const p = setup(); mode(p, 1, false); feed(p, new Float32Array(1600));
  p.port.onmessage({data: {kind:'ack', epoch:1, sequence:1}});
  feed(p, new Float32Array(1600));
  assert.equal(p.port.messages.filter(m => m.kind === 'audio').length, 2);
  p.port.onmessage({data: {kind:'ack', epoch:1, sequence:1}});
  assert.equal(p.port.messages.at(-1).kind, 'error');
  assert.equal(feed(p, new Float32Array(1600)), false);
});
