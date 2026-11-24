import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function emitter() {
  const events = new Map();
  return {addEventListener(name, fn) {events.set(name, fn);},
    removeEventListener(name, fn) {if (events.get(name) === fn) events.delete(name);},
    emit(name) {events.get(name)?.();}, events};
}
function setup() {
  const window = emitter(); const document = {...emitter(), hidden:false};
  const socket = {...emitter(), readyState:1, bufferedAmount:0, sent:[], closed:0,
    send(value) {this.sent.push(value);}, close() {this.closed++; this.readyState=3;}};
  const capture = {modes:[], stops:0, setMuted(m) {this.modes.push(m);return true;},stop(){this.stops++;}};
  let releases=0; const errors=[];
  const context={window,document,ArrayBuffer,Uint8Array,DataView,Number,BigInt,TypeError,JSON};
  vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_wire.js', import.meta.url),'utf8'),context);
  vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_sender.js', import.meta.url),'utf8'),context);
  const sender=window.simontalkPcmSender.create(socket,capture,()=>{releases++;},e=>errors.push(e));
  return {window,document,socket,capture,sender,errors,releases:()=>releases};
}

test('mode and audio order follow local capture, with stop releasing once', () => {
  const x=setup(), pcm=new Uint8Array(3200);
  assert.equal(x.sender.send(pcm),false); assert.equal(x.socket.sent.length,0);
  assert.equal(x.sender.setMuted(false),true);
  assert.deepEqual(JSON.parse(x.socket.sent[0]),{kind:'mode',epoch:1,muted:false});
  assert.deepEqual(x.capture.modes,[true,false]);
  assert.equal(x.sender.send(pcm),true);
  const bytes=new DataView(x.socket.sent[1]); assert.equal(bytes.getUint32(1),1); assert.equal(bytes.getBigUint64(5),1n);
  assert.equal(x.sender.setMuted(true),true);
  assert.deepEqual(x.capture.modes,[true,false,true]);
  assert.deepEqual(JSON.parse(x.socket.sent[2]),{kind:'mode',epoch:2,muted:true});
  assert.equal(x.sender.send(pcm),false); x.sender.stop(); x.sender.stop();
  assert.deepEqual(JSON.parse(x.socket.sent[3]),{kind:'stop'});
  assert.equal(x.capture.stops,1); assert.equal(x.releases(),1); assert.equal(x.socket.closed,1);
  assert.equal(x.sender.send(pcm),false); assert.deepEqual(x.errors,[]);
});

test('backpressure or invalid audio fails closed and releases media exactly once', () => {
  for (const cause of ['buffer','audio']) {
    const x=setup(); x.sender.setMuted(false);
    if (cause==='buffer') x.socket.bufferedAmount=32768;
    assert.equal(x.sender.send(cause==='audio'?new Uint8Array(2):new Uint8Array(3200)),false);
    assert.equal(x.releases(),1); assert.equal(x.capture.stops,1); assert.equal(x.socket.closed,1);
    assert.deepEqual(x.errors,['transport_failed']); assert.equal(x.sender.setMuted(false),false);
  }
});

test('background, page exit and unexpected socket closure stop media', () => {
  for (const event of ['visibilitychange','pagehide','error','close']) {
    const x=setup(); x.sender.setMuted(false);
    if (event==='visibilitychange') {x.document.hidden=true;x.document.emit(event);}
    else if(event==='pagehide') x.window.emit(event); else x.socket.emit(event);
    assert.equal(x.releases(),1); assert.equal(x.capture.stops,1);
    assert.equal(x.sender.send(new Uint8Array(3200)),false); assert.equal(x.errors.length,1);
  }
});

test('reentrant stop while enabling cannot unmute or revive capture', () => {
  const x=setup(); const base=x.socket.send;
  x.socket.send=function(v){base.call(this,v); x.sender.stop();};
  assert.equal(x.sender.setMuted(false),false);
  assert.ok(!x.capture.modes.includes(false)); assert.equal(x.releases(),1);
  assert.equal(x.sender.send(new Uint8Array(3200)),false);
});
