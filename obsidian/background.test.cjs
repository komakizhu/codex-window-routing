const assert = require('node:assert/strict');
const { test } = require('node:test');
const { EventEmitter } = require('node:events');
const path = require('node:path');
let install;
try { ({ install } = require('./background.cjs')); } catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
}

function fixture() {
  const state = { front: 'personal-app', windows: [], calls: [], paths: {}, microtasks: [], monitors: [], ready: true,
    control: { protocolVersion: 1, requestID: 'request-1', enabled: true, foregroundAllowed: false },
    displays: [{ id: 22, bounds: { x: 400, y: 1100, width: 1200, height: 900 } }] };
  class Window extends EventEmitter {
    constructor(options = {}) {
      super(); this.options = options; this.bounds = { x: 0, y: 0, width: 800, height: 600 }; state.windows.push(this);
      app.emit('browser-window-created', {}, this);
      if (options.show !== false) this.show();
    }
    static getAllWindows() { return state.windows; }
    show() { state.front = this; this.visible = true; state.calls.push('show'); }
    showInactive() { this.visible = true; state.calls.push('showInactive'); }
    focus() { state.front = this; state.calls.push('focus'); }
    isFocused() { return state.front === this; }
    isDestroyed() { return false; }
    hide() { this.visible = false; state.calls.push('hide'); }
    setBounds(value) { this.bounds = value; }
    getBounds() { return this.bounds; }
  }
  const app = new EventEmitter();
  app.isReady = () => state.ready;
  app.setPath = (key, value) => { state.paths[key] = value; };
  app.setName = value => { state.applicationName = value; };
  app.focus = () => { state.front = 'worker'; state.calls.push('app.focus'); };
  app.setAsDefaultProtocolClient = () => { state.calls.push('protocol.changed'); return true; };
  app.removeAsDefaultProtocolClient = () => { state.calls.push('protocol.removed'); return true; };
  app.isDefaultProtocolClient = () => false;
  const fakeFs = { unlinkSync: value => { state.calls.push(['unlink', value]); }, readFileSync: () => {
    if (state.controlMissing) throw new Error('missing'); return JSON.stringify(state.control);
  } };
  class Server { listen(...args) { state.calls.push(['listen', ...args]); return this; } }
  const net = { Server, createConnection: (...args) => { state.calls.push(['connect', ...args]); } };
  const process = { pid: 123, execPath: '/worker/tasks/task-1/Codex Obsidian Workspace.app/Contents/MacOS/Obsidian',
    stdout: { write: value => { state.lastLog = value; } } };
  const config = { profile: '/workspace/profile', workerExecutable: process.execPath,
    bounds: { left: 446, top: 1145, width: 1100, height: 800 }, screenUUID: 'side-screen',
    displayID: 22, displayBounds: { ...state.displays[0].bounds }, requestID: 'request-1', controlFile: '/workspace/control.json' };
  const screen = new EventEmitter(); screen.getAllDisplays = () => state.displays;
  screen.getDisplayMatching = bounds => state.displays.find(display => {
    const frame=display.bounds;
    return bounds.x>=frame.x&&bounds.y>=frame.y&&bounds.x+bounds.width<=frame.x+frame.width
      &&bounds.y+bounds.height<=frame.y+frame.height;
  })??null;
  const timers = { queueMicrotask: fn => state.microtasks.push(fn), clearInterval: fn => { state.monitors = state.monitors.filter(m => m !== fn); },
    setInterval: fn => { fn.unref = () => {}; state.monitors.push(fn); return fn; } };
  const deps = { electron: { app, BrowserWindow: Window, screen }, fs: fakeFs, net, path, timers,
    os: { homedir: () => '/personal/home' }, process, config };
  return { state, app, get Window() { return (state.facade || deps.electron).BrowserWindow; }, deps, config, fs: fakeFs, net, screen,
    flush: () => { const tasks = state.microtasks.splice(0); tasks.forEach(fn => fn()); } };
}
function apply(f) {
  assert.equal(typeof install, 'function'); const result = install(f.deps); f.state.facade = result.electron; return result;
}

test('the private worker selects its own storage identity before Obsidian loads', () => {
  const f = fixture(); apply(f);
  assert.equal(f.state.applicationName, 'Codex Obsidian Workspace task-1');
  assert.equal(f.state.paths.userData, '/workspace/profile');
});
test('rebuilt workers use separate storage identities without changing the personal service', () => {
  const a = fixture(), b = fixture();
  b.deps.process.execPath = b.config.workerExecutable = '/worker/tasks/task-2/Codex Obsidian Workspace.app/Contents/MacOS/Obsidian';
  apply(a); apply(b);
  assert.notEqual(a.state.applicationName, b.state.applicationName);
  assert.notEqual(b.state.applicationName, 'Obsidian');
});

test('show displays a correctly placed window while the personal app keeps focus', () => {
  const f = fixture(); apply(f); const w = new f.Window(); f.app.emit('browser-window-created', {}, w); w.show();
  assert.equal(w.visible, true); assert.equal(f.state.front, 'personal-app');
  assert.deepEqual(w.bounds, { x: 446, y: 1145, width: 1100, height: 800 });
  assert.deepEqual(f.state.calls, ['showInactive']);
});
test('focus is allowed only for an exactly placed task window', () => {
  const f = fixture(); apply(f); const w = new f.Window();
  w.focus(); f.app.focus();
  assert.equal(f.state.front, 'personal-app');
  f.flush();
  w.focus();
  assert.equal(f.state.front,'personal-app');
  f.state.control.foregroundAllowed=true; // The gateway sets this only after exact side-screen registration.
  w.focus();
  assert.equal(f.state.front,w);
  assert.equal(f.state.calls.includes('focus'),true);
  assert.equal(f.state.calls.includes('app.focus'),false);
  f.state.front='personal-app';
  f.app.focus();
  assert.equal(f.state.front,'worker');
  f.state.control.foregroundAllowed=false;
  f.state.front='personal-app';
  f.state.displays[0].bounds.y=0;
  w.focus();
  assert.equal(f.state.front,'personal-app');
});
test('later exact task windows can focus individually while app-wide focus is refused', () => {
  const f = fixture(); apply(f);
  f.state.control.foregroundAllowed=true;
  for (let i = 0; i < 3; i++) {
    const w = new f.Window(); f.app.emit('browser-window-created', {}, w); w.show(); w.focus();
    assert.equal(w.bounds.y, 1145); assert.equal(f.state.front,w);
  }
  f.app.focus();
  assert.equal(f.state.front,f.state.windows.at(-1));
  assert.equal(f.state.calls.includes('app.focus'),false);
});
test('default and explicit show:true construction stays hidden until the guarded display step', () => {
  const f = fixture(); apply(f);
  for (const options of [undefined, { show: true }]) {
    const w = new f.Window(options);
    assert.equal(w.options.show, false); assert.notEqual(w.visible, true);
    f.flush(); assert.equal(w.visible, true); assert.equal(f.state.front, 'personal-app');
  }
});
test('the native read-only Electron export is preserved while the private loader uses its facade', () => {
  const f = fixture(), native = f.deps.electron.BrowserWindow;
  Object.defineProperty(f.deps.electron, 'BrowserWindow', { value: native, configurable: false, writable: false });
  apply(f); assert.equal(f.deps.electron.BrowserWindow, native); assert.notEqual(f.Window, native);
  const w = new f.Window(); assert.equal(w instanceof native, true); f.flush(); assert.equal(w.visible, true);
});
test('missing or replaced displays cannot show a window and reconnect never resumes the task', () => {
  for (const change of ['missing', 'replaced', 'layout']) {
    const f = fixture(); const worker = apply(f); const w = new f.Window(); f.flush();
    if (change === 'missing') f.state.displays = [];
    if (change === 'replaced') f.state.displays[0].id = 23;
    if (change === 'layout') f.state.displays[0].bounds.y = 0;
    f.screen.emit('display-removed'); assert.equal(w.visible, false);
    f.state.displays = [{ id: 22, bounds: { ...f.config.displayBounds } }];
    w.showInactive(); assert.equal(w.visible, false);
    const later = new f.Window({ show: true }); f.flush(); assert.notEqual(later.visible, true);
    assert.ok(worker.suspendedReason()); assert.equal(f.state.front, 'personal-app');
  }
});
test('pause, missing control, and a different request all hide only the private windows', () => {
  for (const change of ['paused', 'missing', 'wrong-request']) {
    const f = fixture(); apply(f); const w = new f.Window(); f.flush();
    if (change === 'paused') f.state.control.enabled = false;
    if (change === 'missing') f.state.controlMissing = true;
    if (change === 'wrong-request') f.state.control.requestID = 'another-request';
    f.state.monitors[0](); assert.equal(w.visible, false); w.show(); assert.equal(w.visible, false);
    assert.equal(f.state.front, 'personal-app');
  }
});
test('the monitor waits for Electron readiness and is removed when its own app exits', () => {
  const f = fixture(); f.state.ready = false;
  const screen = f.screen;
  Object.defineProperty(f.deps.electron, 'screen', { get() {
    assert.equal(f.state.ready, true, 'Electron screen must not be accessed before ready'); return screen;
  } });
  const worker = apply(f); f.state.monitors[0]();
  assert.equal(worker.suspendedReason(), null);
  f.state.ready = true; f.app.emit('ready'); const w = new f.Window(); f.flush(); assert.equal(w.visible, true);
  f.app.emit('will-quit'); assert.equal(f.state.monitors.length, 0);
});
test('only the shared Obsidian CLI socket is redirected to this private profile', () => {
  const f = fixture(); apply(f); const shared = '/personal/home/.obsidian-cli.sock';
  new f.net.Server().listen(shared); f.fs.unlinkSync(shared); f.net.createConnection(shared);
  f.fs.unlinkSync('/unrelated/file'); new f.net.Server().listen('/unrelated/socket');
  assert.deepEqual(f.state.calls, [
    ['listen', '/workspace/profile/cli.sock'], ['unlink', '/workspace/profile/cli.sock'],
    ['connect', '/workspace/profile/cli.sock'], ['unlink', '/unrelated/file'], ['listen', '/unrelated/socket'],
  ]);
});
test('the worker cannot register itself as the normal obsidian URL handler', () => {
  const f = fixture(); apply(f);
  assert.equal(f.app.setAsDefaultProtocolClient('obsidian'), false);
  assert.equal(f.app.removeAsDefaultProtocolClient('obsidian'), false);
  assert.equal(f.app.isDefaultProtocolClient('obsidian'), true);
  assert.deepEqual(f.state.calls, []);
});
test('a wrong executable or an already existing window is rejected before hooks change', () => {
  for (const kind of ['wrong-process', 'old-window', 'outside-display', 'foreign-control']) {
    const f = fixture(); const show = f.Window.prototype.show;
    if (kind === 'wrong-process') f.config.workerExecutable = '/Applications/Obsidian.app/Contents/MacOS/Obsidian';
    else if (kind === 'old-window') new f.Window();
    else if (kind === 'outside-display') f.config.bounds.left = 0;
    else f.config.controlFile = '/personal/control.json';
    assert.equal(typeof install, 'function');
    assert.throws(() => install(f.deps)); assert.equal(f.Window.prototype.show, show);
  }
});
