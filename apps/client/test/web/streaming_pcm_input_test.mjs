import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function emitter() {
  const listeners = new Map();
  return { addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name); },
    emit(name) { listeners.get(name)?.(); }, listeners };
}
function setup({modulePromise = Promise.resolve()} = {}) {
  const track = {...emitter(), kind: 'audio', readyState: 'live', stops: 0, stop() { this.stops++; }};
  const stream = {getTracks: () => [track], getAudioTracks: () => [track]};
  const source = {connects: 0, disconnects: 0, connect() { this.connects++; }, disconnect() { this.disconnects++; }};
  const gain = {gain: {value: 1}, connect() {}, disconnect() { this.disconnected = true; }};
  const context = {...emitter(), state: 'running', sampleRate:16000, destination: {},
    audioWorklet: {addModule: () => modulePromise},
    createMediaStreamSource: () => source, createGain: () => gain};
  const doc = {...emitter(), hidden:false, baseURI:'http://localhost/'};
  const window = {...emitter(), document: doc, location:{origin:'http://localhost'}};
  const nodes = [];
  class FakeNode {
    constructor() { Object.assign(this, emitter()); this.port = {messages:[], onmessage:null, postMessage(m) {this.messages.push(m);}, close() {this.closed=true;}}; nodes.push(this); }
    connect() { this.connected = true; } disconnect() { this.disconnected = true; }
  }
  vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_input.js', import.meta.url), 'utf8'),
    {window, document:doc, AudioWorkletNode:FakeNode, URL, ArrayBuffer, Uint8Array, Number, Promise, setTimeout, clearTimeout});
  const chunks=[], errors=[];
  const player=window.simontalkStreamingPcmInput.create(context,stream,chunk=>chunks.push(chunk),error=>errors.push(error));
  return {context, track, stream, source, gain, doc, window, nodes, chunks, errors, player};
}
const frame = (epoch, sequence) => ({kind:'audio', epoch, sequence, pcm:new ArrayBuffer(3200)});

test('authorized stream starts muted and drops old generation across mute/unmute', async () => {
  const x=setup(); assert.equal(await x.player.start(),true);
  const port=x.nodes[0].port;
  assert.deepEqual({...port.messages[0]}, {kind:'mode',epoch:0,muted:true});
  assert.equal(x.gain.gain.value,0);
  assert.equal(x.player.setMuted(false),true);
  port.onmessage({data:frame(1,1)}); assert.equal(x.chunks.length,1);
  assert.equal(x.player.setMuted(true),true);
  port.onmessage({data:frame(1,2)}); assert.equal(x.chunks.length,1);
  assert.equal(x.player.setMuted(false),true);
  port.onmessage({data:frame(1,3)}); assert.equal(x.chunks.length,1);
  port.onmessage({data:frame(3,4)}); assert.equal(x.chunks.length,2);
  x.player.stop(); port.onmessage?.({data:frame(3,5)});
  assert.equal(x.chunks.length,2); assert.equal(x.track.stops,0);
});

test('stop before async module load resolves never connects a source', async () => {
  let resolve; const promise=new Promise(r=>{resolve=r;}); const x=setup({modulePromise:promise});
  const started=x.player.start(); x.player.stop(); resolve();
  assert.equal(await started,false); assert.equal(x.nodes.length,0);
  assert.equal(x.source.connects,0); assert.equal(x.track.stops,0);
});

test('invalid worklet messages and interruptions close delivery exactly once', async () => {
  const x=setup(); await x.player.start(); x.player.setMuted(false);
  const port=x.nodes[0].port;
  port.onmessage({data:{kind:'audio',epoch:1,sequence:1,pcm:new ArrayBuffer(2)}});
  assert.deepEqual(x.errors,['capture_failed']); assert.equal(x.chunks.length,0);
  x.track.emit('ended'); port.onmessage?.({data:frame(1,2)});
  assert.deepEqual(x.errors,['capture_failed']); assert.equal(x.chunks.length,0);
  assert.equal(x.source.disconnects,1); assert.equal(x.track.stops,0);
});

test('background and failed async consumers cannot continue capture', async () => {
  const x=setup(); await x.player.start(); x.player.setMuted(false);
  x.doc.hidden=true; x.doc.emit('visibilitychange');
  assert.deepEqual(x.errors,['background']); assert.equal(x.source.disconnects,1);
  assert.equal(x.player.setMuted(false),false);
});

test('synchronous stop during graph setup never reconnects nodes', async () => {
  const x=setup();
  x.source.connect = function () { this.connects++; x.player.stop(); };
  assert.equal(await x.player.start(),false);
  assert.equal(x.nodes[0].connected,undefined);
  assert.equal(x.source.disconnects,1);
  assert.equal(x.nodes[0].disconnected,true);
  assert.equal(x.gain.disconnected,true);
});

test('stop during source creation disconnects the returned source', async () => {
  const x=setup();
  x.context.createMediaStreamSource = () => { x.player.stop(); return x.source; };
  assert.equal(await x.player.start(),false);
  assert.equal(x.source.disconnects,1);
  assert.equal(x.nodes.length,0);
});
