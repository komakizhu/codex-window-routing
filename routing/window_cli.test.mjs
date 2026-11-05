import assert from 'node:assert/strict';
import { test } from 'node:test';
import path from 'node:path';
import { luaString, gatewayCall, parseArgs } from './window_cli.mjs';

test('Lua data delimiters cannot be closed by a path or JSON payload',()=>{
  const value='a]]b]=]c\n"quote"';const quoted=luaString(value);
  assert.equal(quoted,'[==['+value+']==]');
});
test('the bridge sends a fixed API script and data through argv, without shell execution',()=>{
  let invocation;const result=gatewayCall({action:'open',application:'finder',directory:'/task/$(bad)'},{
    apiPath:'/source/with space/window_api.lua',run:(...args)=>{invocation=args;return {status:0,stdout:'{"ok":true,"windowId":12}\n',stderr:''};}});
  assert.equal(result.windowId,12);assert.equal(path.basename(invocation[0]),'hs');
  assert.equal(invocation[2].shell,undefined);assert.match(invocation[1].at(-1),/hs\.json\.decode/);
});
test('connection failure and invalid replies never retry through open or osascript',()=>{
  let count=0;
  assert.throws(()=>gatewayCall({action:'status'},{run:()=>{count++;return {status:1,stderr:'unavailable'};}}),/连接失败/);
  assert.equal(count,1);
  assert.throws(()=>gatewayCall({action:'status'},{run:()=>({status:0,stdout:'not JSON'})}),/结构化/);
});
test('CLI keeps exact browser identity and positive native IDs',()=>{
  assert.deepEqual(parseArgs(['open','app','--application','Telegram']),
    {action:'open',application:'app',applicationSelector:'Telegram'});
  assert.deepEqual(parseArgs(['open','app','--bundle-id','com.apple.Safari']),
    {action:'open',application:'app',applicationSelector:'com.apple.Safari'});
  assert.throws(()=>parseArgs(['open','app']),/需要/);
  assert.deepEqual(parseArgs(['open','chrome','--baseline','[10,11]','--extension','connection']),
    {action:'open',application:'chrome',browserBaselineIDs:[10,11],extensionInstanceId:'connection'});
  assert.deepEqual(parseArgs(['close-native','--request','ticket','--pid','12','--window','13']),
    {action:'close-native',requestID:'ticket',pid:12,windowId:13});
  assert.throws(()=>parseArgs(['close-native','--pid','0']),/正整数/);
  assert.throws(()=>parseArgs(['open','finder','--foreground']),/参数/);
});
test('acceptance scope cannot silently fall back to the installed gateway',()=>{
  let code;
  gatewayCall({action:'status'},{scope:'acceptance',run:(_file,args)=>{
    code=args.at(-1);return {status:0,stdout:'{"ok":true}\n'};
  }});
  assert.match(code,/assert\(hs\._codexWindowRoutingAcceptance/);
  assert.doesNotMatch(code,/loadfile/);
  assert.throws(()=>gatewayCall({action:'status'},{scope:'other'}),/测试入口/);
});
