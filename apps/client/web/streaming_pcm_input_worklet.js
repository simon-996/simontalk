/* global AudioWorkletProcessor, registerProcessor */
'use strict';

// Receives samples already converted to the owning AudioContext's 16 kHz rate.
// It never acquires a microphone, sends network data, or emits audible output.
class SimonTalkPcmInput extends AudioWorkletProcessor {
  constructor() {
    super();
    this.closed = false;
    this.modeSeen = false;
    this.muted = true;
    this.epoch = 0;
    this.sequence = 0;
    this.pending = new Map();
    this.resetFrame();
    this.port.onmessage = ({data}) => this.control(data);
  }

  resetFrame() {
    this.buffer = new ArrayBuffer(3200);
    this.view = new DataView(this.buffer);
    this.used = 0;
  }

  fail() {
    if (this.closed) return;
    this.closed = true;
    this.pending.clear();
    this.resetFrame();
    this.port.postMessage({kind: 'error'});
  }

  control(data) {
    if (this.closed) return;
    if (!data || typeof data !== 'object') { this.fail(); return; }
    if (data.kind === 'stop') {
      this.closed = true;
      this.pending.clear();
      this.resetFrame();
      return;
    }
    if (data.kind === 'mode') {
      if (!Number.isSafeInteger(data.epoch) || data.epoch < 0 ||
          typeof data.muted !== 'boolean' ||
          (this.modeSeen && data.epoch <= this.epoch) ||
          (!this.modeSeen && data.epoch < this.epoch)) {
        this.fail(); return;
      }
      this.modeSeen = true;
      this.epoch = data.epoch;
      this.muted = data.muted;
      this.resetFrame();
      return;
    }
    if (data.kind === 'ack') {
      if (!Number.isSafeInteger(data.sequence) || !Number.isSafeInteger(data.epoch) ||
          this.pending.get(data.sequence) !== data.epoch) {
        this.fail(); return;
      }
      this.pending.delete(data.sequence);
      return;
    }
    this.fail();
  }

  process(inputs, outputs) {
    for (const output of outputs) for (const channel of output) channel.fill(0);
    if (this.closed) return false;
    if (!this.modeSeen || this.muted) return true;
    const channels = inputs[0];
    if (!channels || channels.length === 0) return true;
    const length = channels[0].length;
    if (channels.some(channel => channel.length !== length)) { this.fail(); return false; }
    for (let i = 0; i < length; i++) {
      let mixed = 0;
      for (const channel of channels) {
        if (!Number.isFinite(channel[i])) { this.fail(); return false; }
        mixed += channel[i] / channels.length;
      }
      mixed = Math.max(-1, Math.min(1, mixed));
      const value = Math.round(mixed < 0 ? mixed * 32768 : mixed * 32767);
      this.view.setInt16(this.used * 2, value, true);
      this.used++;
      if (this.used === 1600) {
        if (this.pending.size >= 3 || this.sequence >= Number.MAX_SAFE_INTEGER) {
          this.fail(); return false;
        }
        const pcm = this.buffer;
        const sequence = ++this.sequence;
        this.pending.set(sequence, this.epoch);
        this.resetFrame();
        this.port.postMessage({kind: 'audio', epoch: this.epoch, sequence, pcm}, [pcm]);
      }
    }
    return true;
  }
}

registerProcessor('simontalk-pcm-input', SimonTalkPcmInput);
