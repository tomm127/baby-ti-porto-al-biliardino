import test from 'node:test';
import assert from 'node:assert/strict';
import { startPolling, type PollingEnvironment } from '../src/lib/polling.ts';

function fakeEnv(initialHidden = false) {
  let hidden = initialHidden;
  let next = 0;
  const timers = new Map<number, { cb: () => void; delay: number }>();
  const listeners = new Set<() => void>();
  const env: PollingEnvironment = {
    schedule(cb, delay) { timers.set(++next, { cb, delay }); return next; },
    cancel(id) { timers.delete(id); },
    hidden: () => hidden,
    onVisibilityChange(cb) { listeners.add(cb); return () => { listeners.delete(cb); }; },
    random: () => 0.5,
  };
  return { env, timers, listeners,
    visibility(value: boolean) { hidden = value; listeners.forEach(cb => cb()); },
    fire() { const entry = timers.entries().next().value; assert.ok(entry); timers.delete(entry[0]); entry[1].cb(); },
  };
}
const settle = async () => { await Promise.resolve(); await Promise.resolve(); };

test('automatic refreshes never overlap, including visibility changes', async () => {
  const f = fakeEnv(); let calls = 0; let resolve!: () => void;
  const stop = startPolling(() => { calls++; return new Promise<void>(r => { resolve = r; }); }, 3000, true, f.env);
  assert.equal([...f.timers.values()][0].delay, 3150);
  f.fire(); assert.equal(calls, 1); assert.equal(f.timers.size, 0);
  f.visibility(true); f.visibility(false); assert.equal(calls, 1);
  resolve(); await settle(); assert.equal(f.timers.size, 1);
  assert.equal([...f.timers.values()][0].delay, 3000); stop();
});

test('noncritical hidden page stops polling and refreshes immediately on return', async () => {
  const f = fakeEnv(); let calls = 0;
  const stop = startPolling(async () => { calls++; }, 15000, true, f.env);
  f.visibility(true); assert.equal(f.timers.size, 0); assert.equal(calls, 0);
  f.visibility(false); assert.equal(calls, 1); await settle(); assert.equal(f.timers.size, 1); stop();
});

test('hidden at mount waits for visibility', async () => {
  const f = fakeEnv(true); let calls = 0;
  const stop = startPolling(async () => { calls++; }, 15000, true, f.env);
  assert.equal(f.timers.size, 0); f.visibility(false); await settle(); assert.equal(calls, 1); stop();
});

test('critical match polling remains scheduled in background', async () => {
  const f = fakeEnv(); let calls = 0;
  const stop = startPolling(async () => { calls++; }, 3000, false, f.env);
  f.visibility(true); assert.equal(f.timers.size, 1); f.fire(); await settle(); assert.equal(calls, 1); assert.equal(f.timers.size, 1); stop();
});

test('failed refresh does not permanently stop polling', async () => {
  const f = fakeEnv(); let calls = 0;
  const stop = startPolling(async () => { calls++; throw Error('offline'); }, 3000, true, f.env);
  f.fire(); await settle(); assert.equal(calls, 1); assert.equal(f.timers.size, 1); stop();
});

test('cleanup prevents late async completion from restarting polling', async () => {
  const f = fakeEnv(); let resolve!: () => void;
  const stop = startPolling(() => new Promise<void>(r => { resolve = r; }), 3000, true, f.env);
  f.fire(); stop(); resolve(); await settle(); assert.equal(f.timers.size, 0); assert.equal(f.listeners.size, 0);
});
