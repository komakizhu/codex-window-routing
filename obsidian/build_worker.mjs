// Build a private, separately identified worker from the installed application.
// Original executables, archives, frameworks, user settings, and vaults are read-only.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const output = path.resolve(process.argv[2] || '');
const asarEntry = process.argv[3];
if (!process.argv[2]) throw new Error('Usage: node build_worker.mjs OUTPUT_ROOT [ASAR_MODULE_ENTRY]');
const here = path.dirname(fileURLToPath(import.meta.url));
const projectVersion = fs.readFileSync(path.join(here, '../VERSION'), 'utf8').trim();
if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(projectVersion)) throw new Error('Invalid project VERSION');
const asar = asarEntry ? await import(pathToFileURL(path.resolve(asarEntry))) : await import('@electron/asar');
const source = '/Applications/Obsidian.app';
if (output.startsWith(source + path.sep) || output === source) throw new Error('Output cannot be the installed app');
const sourceContents = path.join(source, 'Contents');
const sourceResources = path.join(sourceContents, 'Resources');
const originalInfo = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(sourceContents, 'Info.plist')]));
const info = structuredClone(originalInfo);
const bundleID = 'local.codex.ObsidianWorkspace';
const build = path.join(output, 'build-' + Date.now());
fs.mkdirSync(build, { recursive: true });
const app = path.join(build, 'Codex Obsidian Workspace.app');
const contents = path.join(app, 'Contents');
const resources = path.join(contents, 'Resources');
fs.mkdirSync(path.join(contents, 'MacOS'), { recursive: true });
fs.mkdirSync(resources);
const executable = path.join(contents, 'MacOS', originalInfo.CFBundleExecutable);
const sourceExecutable = path.join(sourceContents, 'MacOS', originalInfo.CFBundleExecutable);
fs.copyFileSync(sourceExecutable, executable);
fs.chmodSync(executable, fs.statSync(sourceExecutable).mode & 0o777);
if (fs.statSync(executable).ino === fs.statSync(sourceExecutable).ino) throw new Error('Worker binary must not share a writable inode');
// APFS copy-on-write cloning keeps a valid self-contained bundle, with distinct
// writable inodes. The installed app is never re-signed or edited.
execFileSync('/bin/cp', ['-cR', path.join(sourceContents, 'Frameworks'), path.join(contents, 'Frameworks')]);
for (const name of fs.readdirSync(sourceResources)) {
  if (name === 'app.asar' || name === 'app.asar.unpacked') continue;
  const from = path.join(sourceResources, name), to = path.join(resources, name);
  execFileSync('/bin/cp', ['-cR', from, to]);
}
const stage = path.join(build, 'loader-source');
asar.extractAll(path.join(sourceResources, 'app.asar'), stage);
const packageFile = path.join(stage, 'package.json');
const metadata = JSON.parse(fs.readFileSync(packageFile, 'utf8'));
const originalMain = metadata.main || 'index.js';
metadata.main = 'codex-main.cjs';
fs.writeFileSync(packageFile, JSON.stringify(metadata, null, 2));
fs.copyFileSync(path.join(here, 'background.cjs'), path.join(stage, 'codex-background.cjs'));
fs.writeFileSync(path.join(stage, 'codex-main.cjs'), `
'use strict';
try {
  const flag = process.argv.find(v => v.startsWith('--codex-workspace-config='));
  if (!flag) throw new Error('A Codex workspace configuration is required');
  const fs = require('node:fs');
  const config = JSON.parse(fs.readFileSync(flag.slice('--codex-workspace-config='.length), 'utf8'));
  const background = require('./codex-background.cjs').install({electron:require('electron'),fs,
    net:require('node:net'),path:require('node:path'),os:require('node:os'),process,config});
  const Module = require('node:module');
  const load = Module._load;
  Module._load = function(request, parent, isMain) {
    if (request === 'electron' || request === 'electron/main') return background.electron;
    return load.call(this, request, parent, isMain);
  };
} catch (error) {
  process.stderr.write('Codex worker startup stopped: ' + error.message + '\\n');
  process.exit(64);
}
require(${JSON.stringify('./' + originalMain)});
`);
const archive = path.join(resources, 'app.asar');
await asar.createPackageWithOptions(stage, archive, { unpack: '**/*.node' });
// Check that the vendor's original modules are byte-identical in the worker.
let verifiedFiles = 0;
for (const entry of asar.listPackage(path.join(sourceResources, 'app.asar'))) {
  const name = entry.replace(/^\//, '');
  const stat = asar.statFile(path.join(sourceResources, 'app.asar'), name);
  if (stat.files || stat.link || name === 'package.json') continue;
  if (!asar.extractFile(path.join(sourceResources, 'app.asar'), name).equals(asar.extractFile(archive, name))) {
    throw new Error('Vendor module unexpectedly changed: ' + name);
  }
  verifiedFiles++;
}
info.CFBundleIdentifier = bundleID;
info.CFBundleShortVersionString = projectVersion;
info.CodexObsidianSourceVersion = originalInfo.CFBundleShortVersionString;
// Electron derives helper executable names from its original application name.
// Keep those names; the distinct bundle ID separates worker and personal apps.
info.LSUIElement = true;
for (const key of ['CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'UTImportedTypeDeclarations']) delete info[key];
if (info.ElectronAsarIntegrity?.['Resources/app.asar']) {
  info.ElectronAsarIntegrity['Resources/app.asar'].hash = createHash('sha256').update(asar.getRawHeader(archive).headerString).digest('hex');
}
const plist = path.join(contents, 'Info.plist');
fs.writeFileSync(plist, JSON.stringify(info));
execFileSync('/usr/bin/plutil', ['-convert', 'xml1', plist]);
const entitlements = path.join(build, 'original-entitlements.plist');
fs.writeFileSync(entitlements, execFileSync('/usr/bin/codesign', ['-d', '--entitlements', ':-', source], { stdio: ['ignore', 'pipe', 'pipe'] }));
// No --deep: signing follows no shared frameworks and never re-signs the original app.
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--entitlements', entitlements, app], { stdio: ['ignore', 'pipe', 'pipe'] });
execFileSync('/usr/bin/codesign', ['--verify', '--strict', app], { stdio: ['ignore', 'pipe', 'pipe'] });
execFileSync('/usr/bin/codesign', ['--verify', '--strict', source], { stdio: ['ignore', 'pipe', 'pipe'] });
const descriptor = { version: projectVersion, bundleID, appPath: app, executable, backgroundProtocolVersion: 1,
  sourceVersion: originalInfo.CFBundleShortVersionString, sourceInstallerVersion: originalInfo.CFBundleVersion,
  verifiedVendorModules: verifiedFiles, frameworkSharing: 'APFS copy-on-write clone', originalAppUnchanged: true };
fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(build, 'worker.json'), JSON.stringify(descriptor, null, 2));
fs.writeFileSync(path.join(output, 'worker.json.tmp'), JSON.stringify(descriptor, null, 2));
fs.renameSync(path.join(output, 'worker.json.tmp'), path.join(output, 'worker.json'));
console.log(JSON.stringify(descriptor));
