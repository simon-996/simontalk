import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const file = new URL('../../web/browser_media_session.js', import.meta.url);
const uuid = 'a'.repeat(8)+'-aaaa-aaaa-aaaa-'+ 'a'.repeat(12);
const path = '/v1/practice-sessions/'+uuid+'/connections/'+uuid+'/media/'+uuid+'/1';
const tick = () => new Promise(resolve => setImmediate(resolve));

function setup() {
  const window = new EventTarget(), document = new EventTarget();
  const calls = [];
  let grant, current = true, socket;
  const stream = {getTracks: () => [{stop() {calls.push('track.stop');}}]};
  class Socket extends EventTarget {
    constructor(url) { super(); socket = this; calls.push(url); }
    send(frame) { calls.push(frame); }
    close() { calls.push('socket.close'); }
  }
  class Context {
    state = 'running';
    close() { calls.push('context.close'); return Promise.resolve(); }
  }
  window.simontalkStreamingPcmInput = { create() {
    return {async start() {return true;}, stop() {}, setMuted() {return true;}};
  }};
  window.simontalkPcmSender = {create() {return {
    setMuted(muted) {calls.push(['mute', muted]); return true;}, stop() {},
  };}};
  window.simontalkStreamingPcmOutput = {createResponseRouter() {return {
    start(r,i) {calls.push(['bind',r,i]);return true;},
    appendQwenDelta() {calls.push('append');return 'appended';},
    stop(r) {calls.push(['retire',r]);return true;}, dispose() {calls.push('silence');},
  };}};
  const location = new URL('https://example.test/');
  const navigator = {mediaDevices:{getUserMedia() {
    calls.push('permission'); return new Promise(resolve => {grant = () => resolve(stream);});
  }}};
  vm.runInNewContext(readFileSync(file,'utf8'), {window,document,location,navigator,URL,WebSocket:Socket,
    AudioContext:Context,setTimeout,clearTimeout});
  const session = window.simontalkBrowserMedia.open(path, () => 'proof', () => current,
    type => calls.push(type), reason => calls.push(reason));
  function emit(kind, fields = {}) {
    socket.onmessage?.({data:JSON.stringify({kind,...fields})});
  }
  return {session, calls, window, document, emit, open:()=>socket.onopen?.(),
    grant:()=>grant(), invalidate:()=>{current=false;}, disconnect:()=>socket.onclose?.()};
}

test('proof first, ready gates capture, quarantine retires only the bound reply',async()=>{
  const x=setup(); x.open(); assert.deepEqual(x.calls,['wss://example.test'+path,'proof']);
  x.emit('ready'); assert.ok(x.calls.includes('permission')); x.grant(); await tick();
  function event(type, fields) {x.emit('provider_event',{event:{type,...fields}});}
  event('response.created',{response:{id:'r'}});
  event('response.output_item.added',{response_id:'r',output_index:0,item:{type:'message',role:'assistant',id:'i'}});
  event('response.audio.delta',{response_id:'r'}); x.emit('quarantine',{response_id:'r'});
  event('response.audio.delta',{response_id:'r'});
  assert.ok(x.calls.some(v=>Array.isArray(v)&&v.join()==='bind,r,i'));
  assert.ok(x.calls.some(v=>Array.isArray(v)&&v.join()==='retire,r'));
  assert.equal(x.calls.filter(v=>v==='append').length,1);
  x.disconnect(); assert.ok(x.calls.includes('track.stop'));
});
for(const ending of ['background','disconnect','account']) {
  test('late permission after '+ending+' is released',async()=>{
    const x=setup(); x.open(); x.emit('ready');
    if(ending==='background') {x.document.hidden=true; x.document.dispatchEvent(new Event('visibilitychange'));}
    if(ending==='disconnect') x.disconnect();
    if(ending==='account') {x.invalidate(); x.session.stop();}
    x.grant(); await tick();
    assert.equal(x.calls.filter(v=>v==='track.stop').length,1);
    assert.ok(!x.calls.some(v=>Array.isArray(v)&&v[0]==='mute'));
  });
}
test('account changed before open consumes no proof',()=>{
  const x=setup(); x.invalidate(); x.open();
  assert.ok(!x.calls.includes('proof')); assert.ok(x.calls.includes('socket.close'));
});

test('unexpected frame before ready closes without microphone permission', () => {
  const client = setup();
  client.open();
  client.emit('provider_event', {event: {type:'response.created'}});
  client.emit('ready');
  assert.ok(client.calls.includes('protocol_failed'));
  assert.ok(!client.calls.includes('permission'));
});

test('quarantine for a different reply stops capture and output', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  client.emit('provider_event', {event: {type:'response.created', response:{id:'r'}}});
  client.emit('quarantine', {response_id:'another'});
  assert.ok(client.calls.includes('protocol_failed'));
  assert.ok(client.calls.includes('silence'));
  assert.ok(client.calls.includes('track.stop'));
});
