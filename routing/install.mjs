// Explicit installation only. The default command is a read-only plan.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import shellQuote from 'shell-quote';

const source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const home=os.homedir();
const installRoot=path.join(home,'.codex/window-routing');
const current=path.join(installRoot,'current');
const hammerspoon=path.join(home,'.hammerspoon');
const hooksFile=path.join(home,'.codex/hooks.json');
const node=process.execPath;
const read=file=>fs.existsSync(file)?fs.readFileSync(file,'utf8'):null;
const run=(file,args,options={})=>execFileSync(file,args,{encoding:'utf8',cwd:source,...options});
function isKnownHookInstall(destination,content) {
  const backups=path.join(installRoot,'backups');
  if(!fs.existsSync(backups))return false;
  return fs.readdirSync(backups).some(name=>{
    const manifestText=read(path.join(backups,name,'manifest.json'));
    if(!manifestText)return false;
    try {
      const manifest=JSON.parse(manifestText);
      return manifest.installRoot===installRoot && manifest.hookOnly===true
        && manifest.files?.some(file=>file.destination===destination && file.installed===content);
    } catch {return false;}
  });
}
function isKnownInstalledFile(destination,content) {
  const backups=path.join(installRoot,'backups');
  if(!fs.existsSync(backups))return false;
  return fs.readdirSync(backups).some(name=>{
    const manifestText=read(path.join(backups,name,'manifest.json'));
    if(!manifestText)return false;
    try {
      const manifest=JSON.parse(manifestText);
      return manifest.installRoot===installRoot
        && manifest.files?.some(file=>file.destination===destination && file.installed===content);
    } catch {return false;}
  });
}

export function mergeHooks(existingConfig,root,nodePath) {
  const output=structuredClone(existingConfig??{});
  if(typeof output!=='object' || Array.isArray(output) || output===null)throw new Error('hooks.json 必须是对象');
  output.hooks??={};
  if(typeof output.hooks!=='object' || Array.isArray(output.hooks))throw new Error('hooks 配置格式不受支持');
  const command=shellQuote.quote([nodePath,path.join(root,'routing/guard.mjs')]);
  const events=['PreToolUse','PostToolUse'];
  for(const event of events) {
    const groups=output.hooks[event]??[];
    if(!Array.isArray(groups))throw new Error(event+' 配置格式不受支持');
    const statusMessage=event==='PreToolUse'?'检查 Codex 副屏开窗':'复核 Codex 副屏窗口';
    const timeout=event==='PreToolUse'?10:30;
    const owned=group=>group.hooks?.length===1 && group.hooks[0].command===command
      && group.hooks[0].statusMessage===statusMessage;
    const existing=groups.find(owned);
    if(existing) {
      if(existing.hooks[0].enabled===false)existing.hooks[0].enabled=true;
      existing.hooks[0].timeout=timeout;
      continue;
    }
    output.hooks[event]=[...groups,{
      matcher:'^(Bash|.*(?:exec_command|shell_command)|.*cua_repl.*)$',
      hooks:[{type:'command',command,timeout,statusMessage}],
    }];
  }
  return output;
}
function liveState() {
  const code='local g=hs._codexWindowGateway;local n=0;for _,p in pairs(g and g.pending or {})do if p.task and p.task:isRunning()then n=n+1 end end;print(hs.json.encode({safetySuspended=hs.settings.get("codexComputerUseSafetySuspended")==true,activeRegisteredWorkers=n}))';
  return JSON.parse(run('hs',['-t','5','-c',code],{timeout:7000}).trim());
}
function preflight({hookOnly=false}={}) {
  const branch=run('git',['branch','--show-current']).trim();
  if(!branch || branch==='main')throw new Error('请从独立工作分支安装');
  const base=run('git',['merge-base','HEAD','main']).trim();
  const files=['init.lua','computer_use_sidecar.lua','window_gateway.lua'];
  if(!hookOnly) {
    for(const name of files) {
      const destination=path.join(hammerspoon,name),installed=read(destination);
      const proposed=read(path.join(source,'hammerspoon',name));
      const original=run('git',['show',base+':hammerspoon/'+name]);
      if(installed!==null && installed!==original && installed!==proposed
          && !isKnownInstalledFile(destination,installed)) {
        throw new Error('已安装文件有其他修改，未覆盖：'+destination);
      }
    }
  }
  const config=JSON.parse(run('python3',['-c',
    'import pathlib,tomllib,json;c=tomllib.loads((pathlib.Path.home()/".codex/config.toml").read_text());print(json.dumps({"hooksDisabled":c.get("features",{}).get("hooks") is False,"managedOnly":c.get("allow_managed_hooks_only") is True}))']));
  if(config.hooksDisabled || config.managedOnly)throw new Error('Codex 配置已禁止本地 hook；未擅自更改此设置');
  const hooks=mergeHooks(JSON.parse(read(hooksFile)??'{}'),current,node);
  const live=liveState();
  if(fs.existsSync(current) && (read(path.join(current,'routing/package.json'))===null
      || JSON.parse(read(path.join(current,'routing/package.json'))).name!=='codex-window-routing')) {
    throw new Error('安装目录已有其他内容，未覆盖');
  }
  if(hookOnly) {
    if(!fs.existsSync(current))throw new Error('尚无 Hammerspoon 分流安装目录，不能单独更新配套 Hook');
    for(const name of ['guard.mjs','window_cli.mjs']) {
      const destination=path.join(current,'routing',name);
      const installed=read(destination);
      const proposed=read(path.join(source,'routing',name));
      const original=run('git',['show',base+':routing/'+name]);
      if(installed===null || (installed!==original && installed!==proposed && !isKnownHookInstall(destination,installed))) {
        throw new Error('已安装的配套脚本状态无法识别，未覆盖：'+destination);
      }
    }
  } else if(live.activeRegisteredWorkers>0) {
    throw new Error('有仍在使用已安装入口的任务副本，未替换其运行模块');
  }
  return {branch,files,hooks,live,hookOnly};
}
function loadInstalled() {
  run('hs',['-t','5','-c','hs.timer.doAfter(0.2, hs.reload)'],{timeout:7000});
  const deadline=Date.now()+10000;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1000);
  while(Date.now()<deadline) {
    try {
      const state=liveState();
      if(state) return;
    } catch {}
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,250);
  }
  throw new Error('Hammerspoon 重载后未能恢复连接');
}
function restore(manifestFile) {
  const manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8'));
  if(manifest.installRoot!==installRoot || !path.resolve(manifestFile).startsWith(installRoot+'/backups/'))throw new Error('不是本项目的安装备份');
  // Older manifests include the now-retired global AGENTS.md guidance block.
  const allowed=new Set([path.join(home,'.codex/AGENTS.md'),hooksFile,
    ...['init.lua','computer_use_sidecar.lua','window_gateway.lua','codex-obsidian-worker/worker.json'].map(name=>path.join(hammerspoon,name)),
    ...['guard.mjs','window_cli.mjs'].map(name=>path.join(current,'routing',name))]);
  for(const file of manifest.files) {
    if(!allowed.has(file.destination))throw new Error('备份目标不受支持');
    const installed=read(file.destination);
    if(installed!==null && installed!==file.installed && installed!==file.original)throw new Error('安装后文件又有修改，未覆盖：'+file.destination);
  }
  if(!manifest.hookOnly && liveState().activeRegisteredWorkers>0)throw new Error('仍有登记中的副本运行，暂不回退');
  for(const file of manifest.files) {
    if(file.original===null)fs.rmSync(file.destination,{force:true});
    else fs.writeFileSync(file.destination,file.original);
  }
  if(!manifest.hookOnly) {
    if(fs.existsSync(current))fs.renameSync(current,path.join(path.dirname(manifestFile),'reverted-current-'+Date.now()));
    if(manifest.previousCurrent)fs.renameSync(manifest.previousCurrent,current);
    loadInstalled();
  }
  return {ok:true,restored:true,backup:manifestFile};
}
function installHookOnly(plan) {
  const stamp=Date.now().toString(),backup=path.join(installRoot,'backups',stamp);
  fs.mkdirSync(backup,{recursive:true});
  const destinations=[hooksFile,...['guard.mjs','window_cli.mjs'].map(name=>path.join(current,'routing',name))];
  const manifest={installRoot,hookOnly:true,files:destinations.map(destination=>({destination,original:read(destination)})),previousCurrent:null};
  const manifestFile=path.join(backup,'manifest.json');
  fs.writeFileSync(manifestFile,JSON.stringify(manifest,null,2),{mode:0o600});
  try {
    for(const name of ['guard.mjs','window_cli.mjs']) {
      fs.copyFileSync(path.join(source,'routing',name),path.join(current,'routing',name));
    }
    fs.writeFileSync(hooksFile,JSON.stringify(plan.hooks,null,2)+'\n');
    for(const file of manifest.files)file.installed=read(file.destination);
    fs.writeFileSync(manifestFile,JSON.stringify(manifest,null,2),{mode:0o600});
    return {ok:true,installed:true,hookOnly:true,hooksFile,files:destinations.slice(1),backup:manifestFile};
  } catch(error) {
    for(const file of manifest.files) {
      if(file.original===null)fs.rmSync(file.destination,{force:true});
      else fs.writeFileSync(file.destination,file.original);
    }
    throw error;
  }
}
export function install({apply=false,hookOnly=false}={}) {
  const plan=preflight({hookOnly});
  if(hookOnly) {
    if(!apply)return {ok:true,dryRun:true,hookOnly:true,branch:plan.branch,hooksFile,
      files:['guard.mjs','window_cli.mjs'].map(name=>path.join(current,'routing',name)),hookTrustRequired:true,live:plan.live};
    return installHookOnly(plan);
  }
  if(!apply)return {ok:true,dryRun:true,branch:plan.branch,destination:current,
    hammerspoonFiles:plan.files.map(name=>path.join(hammerspoon,name)),hooksFile,
    workerBuildRequired:true,hookTrustRequired:true,live:plan.live};
  const stamp=Date.now().toString(),backup=path.join(installRoot,'backups',stamp);
  fs.mkdirSync(backup,{recursive:true});
  const manifest={installRoot,files:[],previousCurrent:null};
  const destinations=[hooksFile,...[...plan.files,'codex-obsidian-worker/worker.json'].map(name=>path.join(hammerspoon,name))];
  for(const destination of destinations)manifest.files.push({destination,original:read(destination)});
  const manifestFile=path.join(backup,'manifest.json');
  fs.writeFileSync(manifestFile,JSON.stringify(manifest,null,2),{mode:0o600});
  const stage=path.join(installRoot,'staging-'+stamp);
  fs.mkdirSync(stage);
  let deployed=false;
  try {
    for(const relative of ['VERSION','routing/window_cli.mjs','routing/window_api.lua','routing/guard.mjs',
      'routing/native_app_launcher.swift','routing/package.json',
      'routing/package-lock.json','routing/node_modules','browser/chrome_work_window.mjs','obsidian/build_worker.mjs','obsidian/background.cjs']) {
      fs.mkdirSync(path.dirname(path.join(stage,relative)),{recursive:true});
      fs.cpSync(path.join(source,relative),path.join(stage,relative),{recursive:true,verbatimSymlinks:true});
    }
    const nativeLauncher=path.join(stage,'bin','native-app-launcher');
    fs.mkdirSync(path.dirname(nativeLauncher),{recursive:true});
    run('/usr/bin/swiftc',['-O','-parse-as-library',path.join(stage,'routing/native_app_launcher.swift'),
      '-o',nativeLauncher],{timeout:120000});
    const worker=JSON.parse(run(node,['obsidian/build_worker.mjs',path.join(hammerspoon,'codex-obsidian-worker'),
      path.join(source,'routing/node_modules/@electron/asar/lib/asar.js')],{timeout:120000}).trim());
    if(fs.existsSync(current)) {
      manifest.previousCurrent=path.join(backup,'previous-current');fs.renameSync(current,manifest.previousCurrent);
    }
    fs.renameSync(stage,current);
    deployed=true;
    for(const name of plan.files)fs.copyFileSync(path.join(source,'hammerspoon',name),path.join(hammerspoon,name));
    fs.writeFileSync(hooksFile,JSON.stringify(plan.hooks,null,2)+'\n');
    for(const file of manifest.files)file.installed=read(file.destination);
    fs.writeFileSync(manifestFile,JSON.stringify(manifest,null,2),{mode:0o600});
    loadInstalled();
    const status=JSON.parse(run(node,[path.join(current,'routing/window_cli.mjs'),'status']).trim());
    return {ok:true,installed:true,workerApp:worker.appPath,status,hookTrustRequired:true,backup:manifestFile};
  } catch(error) {
    for(const file of manifest.files) {
      if(file.original===null)fs.rmSync(file.destination,{force:true});
      else fs.writeFileSync(file.destination,file.original);
    }
    if(deployed && fs.existsSync(current))fs.renameSync(current,path.join(backup,'failed-current'));
    if(manifest.previousCurrent) {
      fs.renameSync(manifest.previousCurrent,current);
    }
    try {loadInstalled();}catch {}
    throw error;
  }
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const args=process.argv.slice(2);
    if(args.length && !['--apply','--apply-hook'].includes(args.join(' ')) && !(args.length===2 && args[0]==='--rollback'))throw new Error('用法：node routing/install.mjs [--apply | --apply-hook | --rollback 备份manifest路径]');
    console.log(JSON.stringify(args[0]==='--rollback'?restore(args[1]):install({apply:args[0]==='--apply'||args[0]==='--apply-hook',hookOnly:args[0]==='--apply-hook'})));
  } catch(error) {console.error(error.message);process.exitCode=2;}
}
