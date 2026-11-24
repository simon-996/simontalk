(() => {
  'use strict';

  // Pure encoder. It does not open sockets, authorize users, or own media.
  function encode(epoch, sequence, pcm) {
    if (!Number.isSafeInteger(epoch) || epoch < 0 || epoch > 0xffffffff ||
        !Number.isSafeInteger(sequence) || sequence < 1 ||
        !(pcm instanceof Uint8Array) || !(pcm.buffer instanceof ArrayBuffer) ||
        pcm.byteLength !== 3200) {
      throw new TypeError('Invalid PCM frame');
    }
    const buffer = new ArrayBuffer(3213);
    const view = new DataView(buffer);
    view.setUint8(0, 1);
    view.setUint32(1, epoch, false);
    view.setBigUint64(5, BigInt(sequence), false);
    new Uint8Array(buffer, 13).set(pcm);
    return buffer;
  }

  window.simontalkPcmWire = { encode };
})();
