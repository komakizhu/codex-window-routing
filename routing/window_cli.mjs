import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here=path.dirname(fileURLToPath(import.meta.url));
const hsExecutable=['/opt/homebrew/bin/hs','/usr/local/bin/hs'].find(file=>fs.existsSync(file))??'hs';
export function luaString(value) {
  let equals='';
  while (value.includes(']'+equals+']')) equals+='=';
  return '['+equals+'['+value+']'+equals+']';
}
export function gatewayCall(request,{run=spawnSync,apiPath=path.join(here,'window_api.lua'),scope=process.env.CODEX_WINDOW_GATEWAY_SCOPE,
  timeoutMs=7000,connectTimeoutSeconds=5}={}) {
  if(scope && scope!=='acceptance') throw new Error('不受支持的测试入口');
  const payload='hs.json.decode('+luaString(JSON.stringify(request))+')';
  const call=scope==='acceptance'
    ? 'assert(hs._codexWindowRoutingAcceptance,"acceptance scope is not loaded").call('+payload+')'
    : 'assert(loadfile('+luaString(apiPath)+'))('+payload+')';
  const code='local r='+call+';print(hs.json.encode(r))';
  const result=run(hsExecutable,['-t',String(connectTimeoutSeconds),'-c',code],{encoding:'utf8',timeout:timeoutMs,maxBuffer:1024*1024});
  if (result.error || result.status!==0) throw new Error('Hammerspoon 入口连接失败：'+(result.error?.message || result.stderr?.trim() || 'unknown_error'));
  const lines=result.stdout.trim().split('\n').filter(line=>line.trim().startsWith('{'));
  if (!lines.length) throw new Error('Hammerspoon 没有返回结构化结果');
  return JSON.parse(lines.at(-1));
}
export function parseArgs(args) {
  const [action,...rest]=args;
  const input={action};
  let i=0;
  if(action==='open') input.application=rest[i++];
  const fields={'--directory':'directory','--request':'requestID','--pid':'pid','--window':'windowId',
    '--application':'applicationSelector','--bundle-id':'applicationSelector',
    '--extension':'extensionInstanceId','--baseline':'browserBaselineIDs','--protected':'protectedDirectories','--proof-file':'proofFile'};
  while(i<rest.length) {
    const key=fields[rest[i++]];
    if(!key || i>=rest.length) throw new Error('参数不完整或不受支持');
    const value=rest[i++];
    if(['pid','windowId'].includes(key)) {
      if(!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value)<=0) throw new Error('进程和窗口编号必须是正整数');
      input[key]=Number(value);
    } else input[key]=['browserBaselineIDs','protectedDirectories'].includes(key)?JSON.parse(value):value;
  }
  if(input.proofFile){input.proof=JSON.parse(fs.readFileSync(input.proofFile,'utf8'));delete input.proofFile;}
  if(!['status','open','request','finish-browser','check-native','close-native','stop-worker'].includes(action)) {
    throw new Error('用法：node routing/window_cli.mjs status | open app --application 应用名称或路径 | open finder --directory /绝对路径 | open obsidian | open chrome --baseline "[]" --extension 连接编号 | request --request 请求编号');
  }
  if(input.application==='app'&&!input.applicationSelector)throw new Error('open app 需要 --application 或 --bundle-id');
  return input;
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const result=gatewayCall(parseArgs(process.argv.slice(2)));
    process.stdout.write(JSON.stringify(result)+'\n');
    if(result.ok!==true) process.exitCode=2;
  } catch(error) {process.stderr.write(error.message+'\n');process.exitCode=2;}
}
