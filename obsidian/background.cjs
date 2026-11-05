'use strict';

// Loaded only by the private Codex worker before Obsidian creates any window.
// The installed personal application and its JavaScript are never changed.
function install({ electron, fs, net, path, os, process, config, timers = globalThis }) {
  const { app, BrowserWindow } = electron;
  const b = config?.bounds;
  const displayBounds = config?.displayBounds;
  if (!config || path.resolve(process.execPath) !== path.resolve(config.workerExecutable)
      || !path.isAbsolute(config.profile) || BrowserWindow.getAllWindows().length !== 0
      || !b || !['left', 'top', 'width', 'height'].every(k => Number.isInteger(b[k]))
      || b.width < 200 || b.height < 150 || typeof BrowserWindow.prototype.showInactive !== 'function'
      || !Number.isInteger(config.displayID) || !displayBounds
      || !['x', 'y', 'width', 'height'].every(k => Number.isInteger(displayBounds[k]))
      || b.left < displayBounds.x || b.top < displayBounds.y
      || b.left + b.width > displayBounds.x + displayBounds.width
      || b.top + b.height > displayBounds.y + displayBounds.height
      || typeof config.requestID !== 'string' || !config.requestID
      || typeof config.controlFile !== 'string'
      || path.resolve(config.controlFile) !== path.join(path.dirname(path.resolve(config.profile)), 'control.json')) {
    throw new Error('A fresh, explicitly configured Codex worker is required');
  }
  // Electron chooses the macOS Keychain service from app.getName(). Use a
  // separate identity before its storage/network services initialize. Keep
  // CFBundleName unchanged so the cloned native helper paths still resolve.
  // Each task copy lives under its own token directory. Keep the established
  // Electron app name while giving every task a separate Keychain service.
  const taskName = path.basename(path.resolve(path.dirname(process.execPath), '../../..'));
  app.setName('Codex Obsidian Workspace ' + taskName);
  app.setPath('userData', config.profile);
  const emit = event => process.stdout.write('CODEX_OBSIDIAN_BG ' + JSON.stringify({
    event, pid: process.pid, requestID: config.requestID, screenUUID: config.screenUUID,
  }) + '\n');
  const bounds = { x: b.left, y: b.top, width: b.width, height: b.height };
  const showInactive = BrowserWindow.prototype.showInactive;
  const originalFocus = BrowserWindow.prototype.focus;
  const originalAppFocus = app.focus;
  let suspendedReason = null;
  function suspend(reason) {
    if (!suspendedReason) { suspendedReason = reason; emit('suspended:' + reason); }
    for (const win of BrowserWindow.getAllWindows()) {
      if (!win.isDestroyed()) win.hide();
    }
    return false;
  }
  function canShow() {
    if (suspendedReason) return false;
    if (!app.isReady()) return false;
    let control;
    try { control = JSON.parse(fs.readFileSync(config.controlFile, 'utf8')); }
    catch { return suspend('control_unavailable'); }
    if (control.protocolVersion !== 1 || control.requestID !== config.requestID || control.enabled !== true) {
      return suspend('task_paused');
    }
    const display = electron.screen.getAllDisplays().find(d => d.id === config.displayID);
    if (!display) return suspend('target_display_disconnected');
    if (!['x', 'y', 'width', 'height'].every(k => display.bounds[k] === displayBounds[k])) {
      return suspend('target_display_layout_changed');
    }
    return true;
  }
  function canFocus(win) {
    if (!canShow() || !win || win.isDestroyed()) return false;
    let control;
    try { control = JSON.parse(fs.readFileSync(config.controlFile, 'utf8')); }
    catch { return suspend('control_unavailable'); }
    if (control.protocolVersion !== 1 || control.requestID !== config.requestID
        || control.enabled !== true || control.foregroundAllowed !== true) return false;
    const current = win.getBounds();
    const display = electron.screen.getDisplayMatching(current);
    return display?.id === config.displayID
      && ['x', 'y', 'width', 'height'].every(key => current[key] === bounds[key]);
  }
  const place = win => win.setBounds(bounds, false);
  function backgroundShow() {
    if (!canShow()) return;
    place(this); emit('showInactive'); return showInactive.call(this);
  }
  BrowserWindow.prototype.show = backgroundShow;
  BrowserWindow.prototype.showInactive = backgroundShow;
  // A native BrowserWindow defaults to show:true. Force hidden construction so
  // browser-window-created never has to repair a window already shown elsewhere.
  const BackgroundWindow = new Proxy(BrowserWindow, {
    construct(Target, args) {
      const options = args[0] || {};
      const win = Reflect.construct(Target, [{ ...options, ...bounds, show: false }]);
      if (options.show !== false) timers.queueMicrotask(() => { if (!win.isDestroyed()) backgroundShow.call(win); });
      return win;
    },
  });
  // Electron's exported BrowserWindow property is non-configurable. Give only
  // this private loader a facade; never redefine the native module's export.
  const facade = Object.create(null);
  for (const key of Reflect.ownKeys(electron)) {
    Object.defineProperty(facade, key, { enumerable: true,
      get: () => key === 'BrowserWindow' ? BackgroundWindow : electron[key] });
  }
  BrowserWindow.prototype.focus = function () {
    if (!canFocus(this)) {
      emit('backgroundFocusSuppressed');
      return;
    }
    if (this.isFocused()) return originalFocus.call(this);
    emit('verifiedWindowFocused');
    return originalFocus.call(this);
  };
  app.focus = () => {
    if (!canShow()) { emit('backgroundAppFocusSuppressed'); return; }
    const windows = BrowserWindow.getAllWindows().filter(win => !win.isDestroyed());
    if (windows.length !== 1 || !canFocus(windows[0])) {
      emit('backgroundAppFocusSuppressed');
      return;
    }
    emit('verifiedAppFocused');
    return originalAppFocus.call(app);
  };
  app.on('browser-window-created', (_event, win) => {
    if (canShow()) place(win); else win.hide();
    emit('windowCreated');
  });
  function watchDisplays() {
    for (const event of ['display-added', 'display-removed', 'display-metrics-changed']) {
      electron.screen.on(event, () => { canShow(); });
    }
    canShow();
  }
  if (app.isReady()) watchDisplays(); else app.once('ready', watchDisplays);
  // The gateway writes only this task's control file. A pause remains latched;
  // reconnecting a display or re-enabling routing never silently resumes a task.
  const monitor = timers.setInterval(() => { canShow(); }, 100);
  monitor.unref();
  app.on('will-quit', () => timers.clearInterval(monitor));

  // A private --user-data-dir alone does not separate Obsidian's CLI socket.
  // Redirect this one known path; HOME and unrelated filesystem calls stay as-is.
  const sharedSocket = path.join(os.homedir(), '.obsidian-cli.sock');
  const ownSocket = path.join(config.profile, 'cli.sock');
  if (Buffer.byteLength(ownSocket) > 103) throw new Error('Private CLI socket path is too long');
  const mapPath = value => value === sharedSocket ? ownSocket : value;
  const unlink = fs.unlinkSync;
  fs.unlinkSync = function (value) { return unlink.call(this, mapPath(value)); };
  const listen = net.Server.prototype.listen;
  net.Server.prototype.listen = function (...args) {
    args[0] = mapPath(args[0]); return listen.apply(this, args);
  };
  const connect = net.createConnection;
  net.createConnection = function (...args) {
    args[0] = typeof args[0] === 'object' && args[0] !== null
      ? { ...args[0], path: mapPath(args[0].path) } : mapPath(args[0]);
    return connect.apply(this, args);
  };
  // The worker must never replace the user's normal Obsidian URL handler.
  app.setAsDefaultProtocolClient = () => false;
  app.removeAsDefaultProtocolClient = () => false;
  app.isDefaultProtocolClient = protocol => protocol === 'obsidian';
  emit('installed');
  return { installed: true, socket: ownSocket, bounds, electron: facade, suspendedReason: () => suspendedReason };
}
module.exports = { install };
