import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
const bootstrap = readFileSync(new URL('../../web/flutter_bootstrap.js', import.meta.url), 'utf8')
  .replace('{{flutter_js}}', '').replace('{{flutter_build_config}}', '');

function launch({ load = () => Promise.resolve() } = {}) {
  const elements = new Map(['startup', 'startup-status', 'startup-retry'].map((id) => [id, {
    hidden: id === 'startup-retry', removed: false, textContent: '', attributes: {}, events: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener(name, listener) { this.events[name] = listener; },
    remove() { this.removed = true; },
  }]));
  const events = new Map();
  const timers = new Map();
  let reloads = 0;
  let options;
  const window = {
    location: { reload() { reloads++; } },
    addEventListener(type, callback) {
      events.set(type, [...(events.get(type) ?? []), callback]);
    },
    dispatchEvent(event) {
      for (const callback of events.get(event.type) ?? []) callback(event);
    },
  };
  const context = vm.createContext({
    window, Event, URL, console,
    document: { baseURI: 'http://localhost/', getElementById: (id) => elements.get(id) },
    setTimeout(callback) { const id = timers.size + 1; timers.set(id, callback); return id; },
    clearTimeout(id) { timers.delete(id); },
    _flutter: { loader: { load(value) { options = value; return load(); } } },
  });
  for (const script of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) {
    if (script[1].trim()) vm.runInContext(script[1], context);
  }
  return {
    elements, window, timers,
    get options() { return options; },
    get reloads() { return reloads; },
    boot() { vm.runInContext(bootstrap, context); },
    frame() { window.dispatchEvent(new Event('flutter-first-frame')); },
  };
}

const settle = () => new Promise(setImmediate);

test('real first frame removes startup and cancels slow-load notice', () => {
  const page = launch();
  page.frame();
  assert.equal(page.elements.get('startup').removed, true);
  assert.equal(page.timers.size, 0);
});

test('slow load offers explicit reload while the app can continue loading', () => {
  const page = launch();
  assert.equal(page.timers.size, 1);
  [...page.timers.values()][0]();
  assert.equal(page.elements.get('startup').removed, false);
  assert.equal(page.elements.get('startup-retry').hidden, false);
  assert.match(page.elements.get('startup-status').textContent, /仍在加载/);
  page.elements.get('startup-retry').events.click();
  assert.equal(page.reloads, 1);
  page.frame();
  assert.equal(page.elements.get('startup').removed, true);
});

test('bootstrap download failure presents a readable error and reload', () => {
  const page = launch();
  page.window.dispatchEvent({ type: 'error', target: { id: 'flutter-loader' } });
  assert.match(page.elements.get('startup-status').textContent, /加载失败/);
  assert.equal(page.elements.get('startup-status').attributes.role, 'alert');
  assert.equal(page.elements.get('startup-status').attributes['aria-live'], 'assertive');
  assert.equal(page.elements.get('startup-retry').hidden, false);
  assert.equal(page.timers.size, 0);
});

test('main entrypoint download failure does not claim to still be loading', () => {
  const page = launch();
  page.window.dispatchEvent({
    type: 'error', target: { tagName: 'SCRIPT', src: 'http://localhost/main.dart.js?v=1' },
  });
  assert.match(page.elements.get('startup-status').textContent, /加载失败/);
  assert.equal(page.elements.get('startup-retry').hidden, false);
});

test('main entrypoint execution failure is reported only before the first frame', () => {
  const page = launch();
  const error = { type: 'error', filename: 'http://localhost/main.dart.js' };
  page.window.dispatchEvent(error);
  assert.match(page.elements.get('startup-status').textContent, /加载失败/);
  page.frame();
  page.window.dispatchEvent(error);
  assert.equal(page.elements.get('startup').removed, true);
});

test('loader rejection is handled without exposing raw error details', async () => {
  const page = launch({ load: () => Promise.reject(new Error('private details')) });
  page.boot();
  await settle();
  assert.match(page.elements.get('startup-status').textContent, /加载失败/);
  assert.doesNotMatch(page.elements.get('startup-status').textContent, /private details/);
});

for (const phase of ['initializeEngine', 'runApp']) {
  test(`${phase} rejection presents retry instead of a blank page`, async () => {
    const page = launch();
    page.boot();
    assert.equal(typeof page.options.onEntrypointLoaded, 'function');
    await page.options.onEntrypointLoaded({
      async initializeEngine() {
        if (phase === 'initializeEngine') throw new Error('test initialization failure');
        return { async runApp() { throw new Error('test run failure'); } };
      },
    });
    assert.match(page.elements.get('startup-status').textContent, /加载失败/);
    assert.equal(page.elements.get('startup-retry').hidden, false);
  });
}

test('custom initialization retains local resources and waits for the first frame', async () => {
  const page = launch();
  page.boot();
  assert.equal(typeof page.options.onEntrypointLoaded, 'function');
  let ran = false;
  await page.options.onEntrypointLoaded({
    async initializeEngine(config) {
      assert.equal(config, page.options.config);
      assert.equal(config.canvasKitBaseUrl, 'canvaskit/');
      assert.equal(config.fontFallbackBaseUrl, 'assets/font_fallback/');
      return { async runApp() { ran = true; } };
    },
  });
  assert.equal(ran, true);
  assert.equal(page.elements.get('startup').removed, false);
  page.frame();
  assert.equal(page.elements.get('startup').removed, true);
});

test('unrelated resource failures and late errors do not replace the app', () => {
  const page = launch();
  page.window.dispatchEvent({ type: 'error', target: { id: 'unrelated' } });
  assert.equal(page.elements.get('startup-retry').hidden, true);
  page.frame();
  page.window.dispatchEvent(new Event('simontalk-startup-error'));
  assert.equal(page.elements.get('startup').removed, true);
  assert.equal(page.elements.get('startup-retry').hidden, true);
});
