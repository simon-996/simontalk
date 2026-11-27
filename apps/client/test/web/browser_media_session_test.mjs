import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const file = new URL('../../web/browser_media_session.js', import.meta.url);
const uuid = 'a'.repeat(8)+'-aaaa-aaaa-aaaa-'+ 'a'.repeat(12);
const path = '/v1/practice-sessions/'+uuid+'/connections/'+uuid+'/media/'+uuid+'/1';
const tick = () => new Promise(resolve => setImmediate(resolve));

function setup({startCapture = async () => true} = {}) {
  const window = new EventTarget(), document = new EventTarget();
  const calls = [];
  const contexts = [];
  let grant, rejectPermission, finishOutput, failOutput, capturePcm, current = true, socket;
  const stream = {getTracks: () => [{stop() {calls.push('track.stop');}}]};
  class Socket extends EventTarget {
    constructor(url) { super(); socket = this; calls.push(url); }
    send(frame) { calls.push(frame); }
    close() { calls.push('socket.close'); }
  }
  class Context extends EventTarget {
    state = 'running';
    constructor() { super(); contexts.push(this); }
    changeState(state) {
      this.state = state;
      this.dispatchEvent(new Event('statechange'));
    }
    close() { calls.push('context.close'); this.changeState('closed'); return Promise.resolve(); }
  }
  window.simontalkStreamingPcmInput = { create(_ctx, _stream, onPcm) {
    capturePcm = onPcm;
    return {start: startCapture, stop() {}, setMuted() {return true;}};
  }};
  window.simontalkPcmSender = {create(_s, _c, releaseMedia) {return {
    setMuted(muted) {calls.push(['mute', muted]); return true;},
    send() {calls.push('pcm'); return true;},
    sendSettled(id) {calls.push(['settled', id]); return true;},
    sendSlowPace() {calls.push('sender.pace_slow'); return true;},
    sendInterrupt() {calls.push('sender.interrupt'); return true;},
    drain() {calls.push('sender.drain'); releaseMedia(); return true;},
    stop() {calls.push('sender.stop');},
  };}};
  window.simontalkStreamingPcmOutput = {createResponseRouter() {return {
    start(r,i) {calls.push(['bind',r,i]);return true;},
    appendQwenDelta() {calls.push('append');return 'appended';},
    complete(r, cb, error) {calls.push(['complete',r]); finishOutput = cb; failOutput = error; return true;},
    stop(r) {calls.push(['retire',r]); finishOutput = failOutput = null; return true;},
    dispose() {calls.push('silence'); finishOutput = failOutput = null;},
  };}};
  const location = new URL('https://example.test/');
  const navigator = {mediaDevices:{getUserMedia() {
    calls.push('permission');
    return new Promise((resolve, reject) => {
      grant = () => resolve(stream);
      rejectPermission = reject;
    });
  }}};
  vm.runInNewContext(readFileSync(file,'utf8'), {window,document,location,navigator,URL,WebSocket:Socket,
    AudioContext:Context,setTimeout,clearTimeout});
  const session = window.simontalkBrowserMedia.open(path, () => 'proof', () => current,
    (type, payload) => calls.push(payload ? [type, payload] : type), reason => calls.push(reason));
  function emit(kind, fields = {}) {
    socket.onmessage?.({data:JSON.stringify({kind,...fields})});
  }
  return {session, calls, contexts, window, document, emit, open:()=>socket.onopen?.(),
    grant:()=>grant(), rejectPermission:error=>rejectPermission(error),
    deliverPcm:()=>capturePcm(new Uint8Array(3200)),
    settleOutput:()=>finishOutput?.(),
    failOutput:()=>failOutput?.(),
    invalidate:()=>{current=false;}, disconnect:()=>socket.onclose?.()};
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

test('output clock suspension without an active reply closes the media session', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  assert.ok(client.calls.includes('active'));
  const output = client.contexts[1];
  output.changeState('suspended');
  assert.equal(client.calls.at(-1), 'playback_failed');
  assert.equal(client.calls.filter(call => call === 'track.stop').length, 1);
  assert.equal(client.calls.filter(call => call === 'socket.close').length, 1);
  output.changeState('running');
  assert.equal(client.session.setMuted(false), false);
  assert.equal(client.calls.filter(call => call === 'active').length, 1);
});

test('queued PCM cannot be sent after output suspension but before statechange', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  client.contexts[1].state = 'suspended';
  client.deliverPcm();
  assert.ok(!client.calls.includes('pcm'));
  assert.equal(client.calls.at(-1), 'playback_failed');
});

test('capture completion cannot activate a session with suspended output', async () => {
  let captureReady;
  const client = setup({startCapture: () => new Promise(resolve => {captureReady = resolve;})});
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  client.contexts[1].state = 'suspended';
  captureReady(true);
  await tick();
  assert.ok(!client.calls.includes('active'));
  assert.equal(client.calls.at(-1), 'playback_failed');
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

test('pre-active mute applies on activation and active mute forwards to sender', async () => {
  const client = setup();
  assert.equal(client.session.setMuted(true), true);
  client.open();
  client.emit('ready');
  assert.ok(client.calls.includes('ready'));
  client.grant();
  await tick();
  assert.deepEqual(
    client.calls.filter(v => Array.isArray(v) && v[0] === 'mute'),
    [['mute', true]],
  );
  assert.equal(client.session.setMuted(false), true);
  assert.deepEqual(
    client.calls.filter(v => Array.isArray(v) && v[0] === 'mute'),
    [['mute', true], ['mute', false]],
  );
});

test('beginDrain silences output and stops tracks while forwarding tail events and dropping audio', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  client.emit('provider_event', {event: {type:'response.created', response:{id:'r'}}});
  client.emit('provider_event', {
    event: {type:'response.output_item.added', response_id:'r', output_index:0,
      item:{type:'message', role:'assistant', id:'i'}},
  });
  assert.equal(client.session.beginDrain(), true);
  assert.equal(client.session.beginDrain(), true);
  assert.equal(client.session.setMuted(false), false);
  assert.ok(client.calls.includes('silence'));
  assert.ok(client.calls.includes('sender.drain'));
  assert.equal(client.calls.filter(v => v === 'track.stop').length, 1);
  assert.ok(!client.calls.includes('socket.close'));
  client.emit('provider_event', {event: {type:'response.audio.delta', response_id:'r'}});
  client.emit('provider_event', {
    event: {type:'response.audio_transcript.done', response_id:'r', item_id:'i',
      output_index:0, content_index:0, transcript:'Hello'},
  });
  assert.equal(client.calls.filter(v => v === 'append').length, 0);
  assert.ok(client.calls.some(v => Array.isArray(v) && v[0] === 'provider_event' &&
    v[1].includes('response.audio_transcript.done')));
  client.session.stop();
  assert.ok(client.calls.includes('sender.stop'));
  assert.ok(client.calls.includes('socket.close'));
});

test('permission rejection and missing device map to specific close reasons', async () => {
  for (const [name, expected] of [
    ['NotAllowedError', 'microphone_denied'],
    ['NotFoundError', 'no_device'],
  ]) {
    const client = setup();
    client.open();
    client.emit('ready');
    client.rejectPermission({name});
    await tick();
    assert.ok(client.calls.includes(expected));
  }
});

test('multi-turn response waits for output settle before sending settled and accepting next reply', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  const event = (type, fields) => client.emit('provider_event', {event: {type, ...fields}});
  event('response.created', {response:{id:'r1'}});
  event('response.output_item.added', {response_id:'r1', output_index:0,
    item:{type:'message', role:'assistant', id:'i1'}});
  event('response.audio.delta', {response_id:'r1'});
  event('response.done', {response:{id:'r1', status:'completed'}});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'complete,r1'));
  assert.ok(!client.calls.some(v => Array.isArray(v) && v[0] === 'settled'));
  client.settleOutput();
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'settled,r1'));

  event('response.created', {response:{id:'r2'}});
  event('response.output_item.added', {response_id:'r2', output_index:0,
    item:{type:'message', role:'assistant', id:'i2'}});
  event('response.audio.delta', {response_id:'r2'});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'bind,r2,i2'));
  assert.equal(client.calls.filter(v => v === 'append').length, 2);
});

test('crossing quarantine right after local settle notifies Dart without protocol failure', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  const event = (type, fields) => client.emit('provider_event', {event: {type, ...fields}});
  event('response.created', {response:{id:'r1'}});
  event('response.output_item.added', {response_id:'r1', output_index:0,
    item:{type:'message', role:'assistant', id:'i1'}});
  event('response.done', {response:{id:'r1', status:'completed'}});
  client.settleOutput();
  client.emit('quarantine', {response_id:'r1'});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'quarantine,r1'));
  assert.ok(!client.calls.includes('protocol_failed'));
});

test('an asynchronous output clock failure releases both media paths without settling', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  const event = (type, fields) => client.emit('provider_event', {event: {type, ...fields}});
  event('response.created', {response:{id:'r1'}});
  event('response.output_item.added', {response_id:'r1', output_index:0,
    item:{type:'message', role:'assistant', id:'i1'}});
  event('response.audio.delta', {response_id:'r1'});
  event('response.done', {response:{id:'r1', status:'completed'}});
  client.failOutput();
  assert.ok(client.calls.includes('playback_failed'));
  assert.ok(client.calls.includes('track.stop'));
  assert.ok(client.calls.includes('silence'));
  assert.ok(!client.calls.some(v => Array.isArray(v) && v[0] === 'settled'));
});

test('in-flight output_item.added after quarantine skips player start and drops trailing audio', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  const event = (type, fields) => client.emit('provider_event', {event: {type, ...fields}});
  event('response.created', {response:{id:'r1'}});
  client.emit('quarantine', {response_id:'r1'});
  event('response.output_item.added', {response_id:'r1', output_index:0,
    item:{type:'message', role:'assistant', id:'i1'}});
  event('response.audio.delta', {response_id:'r1'});
  event('response.done', {response:{id:'r1', status:'cancelled'}});
  assert.ok(!client.calls.some(v => Array.isArray(v) && v[0] === 'bind'));
  assert.ok(!client.calls.includes('append'));
  assert.ok(!client.calls.includes('protocol_failed'));
});

test('requestSlowPace gates pace_updated once and rejects unsolicited or duplicate server echo', async () => {
  const client = setup();
  assert.equal(client.session.requestSlowPace(), false);
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  assert.equal(client.session.requestSlowPace(), true);
  assert.equal(client.session.requestSlowPace(), false);
  assert.equal(client.calls.filter(v => v === 'sender.pace_slow').length, 1);
  client.emit('pace_updated', {pace: 'slow'});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'pace_updated,slow'));
  client.emit('pace_updated', {pace: 'slow'});
  assert.ok(client.calls.includes('protocol_failed'));

  const unsolicited = setup();
  unsolicited.open();
  unsolicited.emit('ready');
  unsolicited.grant();
  await tick();
  unsolicited.emit('pace_updated', {pace: 'slow'});
  assert.ok(unsolicited.calls.includes('protocol_failed'));
});

test('playback transitions waiting -> playing -> idle and explicit interrupt silences immediately unless muted', async () => {
  const client = setup();
  client.open();
  client.emit('ready');
  client.grant();
  await tick();
  const event = (type, fields) => client.emit('provider_event', {event: {type, ...fields}});
  assert.equal(client.session.interruptPlayback(), false);
  event('response.created', {response:{id:'r1'}});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'playback,waiting'));
  event('response.output_item.added', {response_id:'r1', output_index:0,
    item:{type:'message', role:'assistant', id:'i1'}});
  event('response.audio.delta', {response_id:'r1'});
  event('response.audio.delta', {response_id:'r1'});
  assert.equal(client.calls.filter(v => Array.isArray(v) && v.join() === 'playback,playing').length, 1);

  // While muted, interruptPlayback refuses without stopping audio or sending interrupt.
  assert.equal(client.session.setMuted(true), true);
  assert.equal(client.session.interruptPlayback(), false);
  assert.ok(!client.calls.includes('sender.interrupt'));
  assert.equal(client.session.setMuted(false), true);

  // Unmuted explicit takeover retires local output immediately and still accepts server quarantine once.
  assert.equal(client.session.interruptPlayback(), true);
  assert.equal(client.session.interruptPlayback(), false);
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'retire,r1'));
  assert.ok(client.calls.includes('sender.interrupt'));
  event('response.audio.delta', {response_id:'r1'});
  assert.equal(client.calls.filter(v => v === 'append').length, 2);
  client.emit('quarantine', {response_id:'r1'});
  assert.ok(client.calls.some(v => Array.isArray(v) && v.join() === 'quarantine,r1'));
  assert.equal(client.calls.filter(v => Array.isArray(v) && v.join() === 'retire,r1').length, 1);
  assert.equal(client.session.holdPlayback(), true);
  assert.ok(!client.calls.includes('protocol_failed'));
});
