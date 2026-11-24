import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const window = {};
vm.runInNewContext(readFileSync(new URL('../../web/streaming_pcm_wire.js', import.meta.url), 'utf8'),
  {window, ArrayBuffer, Uint8Array, DataView, Number, BigInt, TypeError});
const encode = window.simontalkPcmWire.encode;

test('frame uses fixed version and big endian epoch/sequence with an independent PCM copy', () => {
  const pcm = new Uint8Array(3200); pcm[0]=0x12; pcm[1]=0x34; pcm[3199]=0x56;
  const wire = encode(0x01020304, 0x010203040506, pcm);
  const bytes = new Uint8Array(wire);
  assert.equal(bytes.length, 3213);
  assert.equal(Buffer.from(bytes.slice(0,13)).toString('hex'), '01010203040000010203040506');
  assert.equal(bytes[13],0x12); assert.equal(bytes[14],0x34); assert.equal(bytes[3212],0x56);
  pcm.fill(0); assert.equal(bytes[13],0x12);
});

test('rejects unsafe fields and wrong PCM without serializing input', () => {
  const pcm = new Uint8Array(3200);
  for (const [epoch,sequence,frame] of [[-1,1,pcm],[2**32,1,pcm],[1,0,pcm],[1,Number.MAX_SAFE_INTEGER+1,pcm],[true,1,pcm],[1,1,new Uint8Array(3199)],[1,1,{}]]) {
    assert.throws(()=>encode(epoch,sequence,frame),TypeError);
  }
});
