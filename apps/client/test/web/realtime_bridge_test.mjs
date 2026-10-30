import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

test('compiled Dart bridge passes async signalling, event and cancellation callbacks', { timeout: 10000 }, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'simontalk-realtime-bridge-'));
  try {
    const output = join(directory, 'bridge.js');
    try {
      execFileSync('dart', ['compile', 'js', '-o', output, 'test/web/realtime_bridge_entry.dart'], {
        cwd: fileURLToPath(new URL('../../', import.meta.url)), encoding: 'utf8', timeout: 30000,
        stdio: 'pipe',
      });
    } catch (error) { assert.fail(`${error.stdout ?? ''}${error.stderr ?? ''}`); }
    const instances = [];
    const browserBoundary = {
      supported: true,
      create() {
        let closed = false;
        let observe, receive, cancel;
        const instance = {
          muted: false, sent: [], activated: false, drains: 0,
          async start(exchange, onObservation, onEvent, onCancel) {
            observe = onObservation; receive = onEvent; cancel = onCancel;
            try {
              assert.equal(await exchange('v=0\r\no=offer\r\n'), 'v=0\r\no=answer\r\n');
              observe('transport_connected', '');
              onEvent('{"type":"session.created"}', 'server-channel');
              return null;
            } catch (_) {
              this.stop(); return 'connection_failed';
            }
          },
          async activate(id) { assert.equal(id, 'server-channel'); this.activated = true; return null; },
          send(json, id) { assert.equal(id, 'server-channel'); this.sent.push(json); return null; },
          setMuted(value) { this.muted = value; },
          async resumePlayback() { return 'playback_blocked'; },
          beginDrain() {
            this.drains++;
            if (instances.indexOf(this) === 2) return 'media_failed';
            receive('{"type":"input.final"}', 'server-channel');
            return null;
          },
          stop() { if (closed) return; closed = true; cancel?.(); observe?.('local_closed', 'cancelled'); },
        };
        instances.push(instance); return instance;
      },
    };
    const logs = [];
    let done, failed;
    const completion = new Promise((resolve, reject) => { done = resolve; failed = reject; });
    const context = { window: { simontalkRealtime: browserBoundary },
      console: { log(value) { logs.push(String(value)); if (value === 'realtime-bridge-passed') done(); } },
      setTimeout(callback, delay) {
        return setTimeout(() => { try { callback(); } catch (error) { failed(error); } }, delay);
      }, clearTimeout,
    };
    context.self = context;
    vm.runInNewContext(readFileSync(output, 'utf8'), context);
    await completion;
    assert.equal(instances.length, 3);
    assert.equal(instances[0].activated, true);
    assert.equal(instances[0].muted, true);
    assert.equal(instances[0].drains, 2);
    assert.equal(instances[2].drains, 1);
    assert.deepEqual(instances[0].sent, ['{"type":"session.update"}', '{"type":"response.cancel"}']);
    assert.ok(!logs.join('\n').includes('private upstream details'));
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
