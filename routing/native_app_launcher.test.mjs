import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const source=fileURLToPath(new URL('./native_app_launcher.swift',import.meta.url));

test('the native launcher resolves a direct app path and an iOS Wrapper app path without launching either',
  {skip:process.platform!=='darwin'},()=>{
    const root=fs.mkdtempSync(path.join(os.tmpdir(),'codex-native-app-launcher-'));
    try {
      const executable=path.join(root,'native-app-launcher');
      const compiled=spawnSync('swiftc',['-O','-parse-as-library',source,'-o',executable],
        {encoding:'utf8',timeout:120000});
      assert.equal(compiled.status,0,compiled.stderr||compiled.stdout);

      const outer=path.join(root,'Wrapped App.app');
      const inner=path.join(outer,'Wrapper','Wrapped iOS App.app');
      fs.mkdirSync(path.join(outer,'Contents','MacOS'),{recursive:true});
      fs.mkdirSync(inner,{recursive:true});
      fs.writeFileSync(path.join(outer,'Contents','Info.plist'),plist('com.test.wrapper','Wrapped App'));
      fs.writeFileSync(path.join(inner,'Info.plist'),plist('com.test.ios-wrapper','Wrapped iOS App'));

      const resolve=selector=>{
        const result=spawnSync(executable,['resolve',selector],{encoding:'utf8',timeout:10000});
        assert.equal(result.status,0,result.stderr||result.stdout);
        return JSON.parse(result.stdout.trim());
      };
      const safariByBundle=resolve('com.apple.Safari');
      const safariByName=resolve('Safari');
      const safariByPath=resolve(safariByBundle.appPath);
      assert.equal(safariByName.bundleID,'com.apple.Safari');
      assert.equal(safariByName.appPath,safariByBundle.appPath);
      assert.equal(safariByPath.bundleID,'com.apple.Safari');
      assert.equal(resolve(inner).bundleID,'com.test.ios-wrapper');
      assert.equal(resolve(path.join(outer,'Wrapper')).bundleID,'com.test.ios-wrapper');
      assert.equal(resolve(outer).bundleID,'com.test.wrapper');
    } finally {
      fs.rmSync(root,{recursive:true,force:true});
    }
  });

test('application names resolve uniquely and duplicate names fail instead of guessing',
  {skip:process.platform!=='darwin'},()=>{
    const root=fs.mkdtempSync(path.join(os.tmpdir(),'codex-native-app-names-'));
    try {
      const apps=path.join(root,'Applications');fs.mkdirSync(apps);
      writeMacApp(path.join(apps,'Unique.app'),'com.test.unique','Unique');
      writeMacApp(path.join(apps,'Duplicate A.app'),'com.test.duplicate-a','Duplicate');
      writeMacApp(path.join(apps,'Duplicate B.app'),'com.test.duplicate-b','Duplicate');
      writeMacApp(path.join(apps,'Wrapped App.app'),'com.test.wrapper','Wrapped App');
      writeIOSApp(path.join(apps,'Wrapped App.app','Wrapper','Wrapped iOS App.app'),
        'com.test.ios-wrapper','Wrapped iOS App');

      const executable=path.join(root,'resolver-tests');
      const compiled=spawnSync('swiftc',['-O','-parse-as-library','-DNATIVE_APP_LAUNCHER_LIBRARY',source,
        fileURLToPath(new URL('./native_app_launcher_test_main.swift',import.meta.url)),'-o',executable],
      {encoding:'utf8',timeout:120000});
      assert.equal(compiled.status,0,compiled.stderr||compiled.stdout);
      const result=spawnSync(executable,[apps],{encoding:'utf8',timeout:10000});
      assert.equal(result.status,0,result.stderr||result.stdout);
      assert.equal(result.stdout.trim(),'resolver-tests-ok');
    } finally {
      fs.rmSync(root,{recursive:true,force:true});
    }
  });

test('requested apps resolve by their registered Bundle IDs without launching windows',
  {skip:process.platform!=='darwin'},()=>{
    const root=fs.mkdtempSync(path.join(os.tmpdir(),'codex-native-app-identities-'));
    try {
      const executable=path.join(root,'native-app-launcher');
      const compiled=spawnSync('swiftc',['-O','-parse-as-library',source,'-o',executable],
        {encoding:'utf8',timeout:120000});
      assert.equal(compiled.status,0,compiled.stderr||compiled.stdout);
      for(const bundleID of ['com.apple.iphonesimulator','ru.keepcoder.Telegram','com.apple.Safari',
        'com.google.Chrome','md.obsidian','net.ankiweb.anki','com.apple.Photos']) {
        const result=spawnSync(executable,['resolve',bundleID],{encoding:'utf8',timeout:10000});
        assert.equal(result.status,0,result.stderr||result.stdout);
        const identity=JSON.parse(result.stdout.trim());
        assert.equal(identity.bundleID,bundleID);
        assert.equal(fs.existsSync(identity.appPath),true);
      }
    } finally {
      fs.rmSync(root,{recursive:true,force:true});
    }
  });

function plist(bundleID,name) {
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string><key>CFBundleName</key><string>${name}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`;
}

function writeMacApp(directory,bundleID,name) {
  const info=path.join(directory,'Contents','Info.plist');
  fs.mkdirSync(path.dirname(info),{recursive:true});fs.writeFileSync(info,plist(bundleID,name));
}

function writeIOSApp(directory,bundleID,name) {
  fs.mkdirSync(directory,{recursive:true});fs.writeFileSync(path.join(directory,'Info.plist'),plist(bundleID,name));
}
