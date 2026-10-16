import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const sourceUrl = new URL('../../web/microphone_probe.js', import.meta.url);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

function eventTarget(extra = {}) {
  const events = new Map();
  return {
    ...extra, events,
    addEventListener(name, handler) { events.set(name, [...(events.get(name) ?? []), handler]); },
    removeEventListener(name, handler) {
      events.set(name, (events.get(name) ?? []).filter((value) => value !== handler));
    },
    dispatch(name) { for (const callback of [...(events.get(name) ?? [])]) callback(); },
    dispatchEvent(event) { this.dispatch(event.type); },
  };
}

function environment({ secure = true, resumeError, resumeWait = false } = {}) {
  const permission = deferred();
  const resume = deferred();
  const counters = { requests: 0, contexts: 0, closed: 0, disconnected: 0 };
  const tracks = [0, 1].map(() => eventTarget({ readyState: 'live', stops: 0,
    stop() { this.stops++; this.readyState = 'ended'; },
  }));
  const stream = { getTracks: () => tracks, getAudioTracks: () => tracks };
  const connections = [];
  const contexts = [];
  const timers = new Map();
  const analyser = { fftSize: 0, getByteTimeDomainData(data) { data.fill(160); } };
  class AudioContext {
    constructor() {
      Object.assign(this, eventTarget());
      counters.contexts++; contexts.push(this); this.state = 'running'; this.destination = {};
    }
    resume() { return resumeWait ? resume.promise : resumeError ? Promise.reject(resumeError) : Promise.resolve(); }
    close() { counters.closed++; this.state = 'closed'; return Promise.resolve(); }
    createAnalyser() { return analyser; }
    createMediaStreamSource(value) {
      assert.equal(value, stream);
      return { connect(target) { connections.push(target); }, disconnect() { counters.disconnected++; } };
    }
  }
  const document = eventTarget({ hidden: false });
  const window = eventTarget({
    isSecureContext: secure, AudioContext,
    navigator: { mediaDevices: { getUserMedia(constraints) {
      counters.requests++;
      assert.equal(constraints.video, false);
      assert.equal(constraints.audio, true);
      return permission.promise;
    } } },
  });
  vm.runInNewContext(readFileSync(sourceUrl, 'utf8'), {
    window, document, Uint8Array, Event,
    setInterval(callback) { const id = timers.size + 1; timers.set(id, callback); return id; },
    clearInterval(id) { timers.delete(id); },
  });
  return { window, document, permission, resume, counters, tracks, stream, connections, contexts, analyser, timers,
    create: () => window.simontalkMicrophone.create(),
  };
}

test('creating a probe never requests permission or creates audio resources', () => {
  const env = environment();
  env.create();
  assert.equal(env.counters.requests, 0);
  assert.equal(env.counters.contexts, 0);
});

test('real sample analysis stays local and stop releases all resources once', async () => {
  const env = environment();
  const levels = [];
  const probe = env.create();
  const started = probe.start((level) => levels.push(level), () => {});
  env.permission.resolve(env.stream);
  assert.equal(await started, null);
  assert.equal(env.connections.length, 1);
  assert.equal(env.connections[0], env.analyser);
  [...env.timers.values()][0]();
  assert.equal(levels.length, 1);
  assert.ok(levels[0] > 0 && levels[0] <= 1);
  probe.stop(); probe.stop();
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
  assert.equal(env.counters.closed, 1);
  assert.equal(env.timers.size, 0);
  assert.equal([...env.document.events.values()].flat().length, 0);
  assert.equal([...env.window.events.values()].flat().length, 0);
});

test('cancelled pending permission releases a late stream without sampling', async () => {
  const env = environment();
  const probe = env.create();
  const started = probe.start(() => assert.fail('stale sample'), () => assert.fail('stale interruption'));
  probe.stop();
  env.permission.resolve(env.stream);
  await started;
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
  assert.equal(env.counters.closed, 1);
  assert.equal(env.timers.size, 0);
});

for (const name of ['visibilitychange', 'pagehide', 'ended']) {
  test(`${name} releases capture and reports an interruption`, async () => {
    const env = environment();
    const reasons = [];
    const probe = env.create();
    const started = probe.start(() => {}, (reason) => reasons.push(reason));
    env.permission.resolve(env.stream); await started;
    if (name === 'visibilitychange') env.document.hidden = true;
    (name === 'ended' ? env.tracks[0] : name === 'pagehide' ? env.window : env.document).dispatch(name);
    assert.equal(reasons.length, 1);
    assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
    assert.equal(env.counters.closed, 1);
    assert.equal(env.timers.size, 0);
  });
}

test('hiding the page during permission wait also releases late capture', async () => {
  const env = environment();
  const reasons = [];
  const probe = env.create();
  const started = probe.start(() => assert.fail('stale sample'), (reason) => reasons.push(reason));
  env.document.hidden = true; env.document.dispatch('visibilitychange');
  env.permission.resolve(env.stream); await started;
  assert.equal(reasons.length, 1);
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
});

test('permission denial produces a stable error and closes the context', async () => {
  const env = environment();
  const started = env.create().start(() => {}, () => {});
  env.permission.reject({ name: 'NotAllowedError', message: 'private details' });
  assert.equal(await started, 'permission_denied');
  assert.equal(env.counters.closed, 1);
});

test('audio initialization failure still releases permission granted later', async () => {
  const env = environment({ resumeError: new Error('audio failure') });
  const started = env.create().start(() => {}, () => {});
  assert.equal(await started, 'unavailable');
  env.permission.resolve(env.stream);
  await new Promise(setImmediate);
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
  assert.equal(env.counters.closed, 1);
});

test('insecure origins do not request access', async () => {
  const env = environment({ secure: false });
  assert.equal(env.window.simontalkMicrophone.supported, false);
  assert.equal(await env.create().start(() => {}, () => {}), 'unsupported');
  assert.equal(env.counters.requests, 0);
});

test('interrupted audio context cannot report frozen samples as live input', async () => {
  const env = environment();
  const reasons = [];
  const probe = env.create();
  const started = probe.start(() => assert.fail('frozen sample'), (reason) => reasons.push(reason));
  env.permission.resolve(env.stream); await started;
  env.contexts[0].state = 'suspended';
  env.contexts[0].dispatch('statechange');
  assert.equal(reasons[0], 'device_lost');
  assert.equal(env.timers.size, 0);
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
});

test('cancel releases a late stream even when audio resume is still pending', async () => {
  const env = environment({resumeWait:true});
  const probe = env.create();
  const started = probe.start(() => assert.fail('stale sample'), () => assert.fail('stale event'));
  probe.stop(); env.permission.resolve(env.stream);
  await new Promise(setImmediate);
  assert.deepEqual(env.tracks.map((track) => track.stops), [1, 1]);
  assert.equal(env.counters.closed, 1);
  env.resume.resolve(); await started;
});

for (const [name, code] of [['NotFoundError','no_device'], ['NotReadableError','device_busy'], ['AbortError','device_busy']]) {
  test(`${name} provides an actionable stable error`, async () => {
    const env = environment();
    const started = env.create().start(() => {}, () => {});
    env.permission.reject({name});
    assert.equal(await started, code);
    assert.equal(env.counters.closed, 1);
  });
}
