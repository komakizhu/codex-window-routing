import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import { checkCua, checkShell, evaluate, verifyCuaAfter, formatHookOutput } from './guard.mjs';
import shellQuote from 'shell-quote';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const worker='/safe/codex-obsidian-worker/build-1/Task.app';
const state=()=>({bindings:{},helperLoaded:false});
const helper=fs.readFileSync(new URL('../browser/chrome_work_window.mjs',import.meta.url),'utf8').replace(/^export /gm,'').trim();
function fixture() {
  const calls=[],s=state();let running=true;
  const callGateway=r=>{
    calls.push(r);
    if(r.action==='status')return {ok:true,gatewayLoaded:true,safetySuspended:false,assignmentEnabled:running,gateway:{gatewayReady:running}};
    if(r.action==='authorize-app') {
      if(r.appPath?.startsWith('/safe/codex-obsidian-worker/'))return {ok:running,
        requestID:'worker-ticket',pid:60,windowId:61,reason:'not_owned'};
      if(['com.test.Task','/Applications/Task.app'].includes(r.identity)&&running)return {ok:true,appPath:'/Applications/Task.app',
        bundleID:'com.test.Task',requestID:'native-ticket',pid:70,windowId:71,connectionReady:true};
      return {ok:false,reason:'not_owned'};
    }
    if(r.action==='check-native')return {ok:running
      && (r.requestID==='native-ticket'&&r.pid===70&&r.windowId===71
        ||r.requestID==='worker-ticket'&&r.pid===60&&r.windowId===61),
      reason:'not_owned'};
    if(r.action==='authorize-browser')return {ok:r.requestID==='ticket' && r.extensionInstanceId==='connection'
      && r.placement?.targetScreenUUID==='side' && r.placement?.bounds?.left===1240,reason:'invalid_ticket'};
    throw new Error('unexpected bridge call');
  };
  return {calls,s,options:{state:s,callGateway,isHammerspoonRunning:()=>true},stop:()=>{running=false;}};
}
test('personal application names and dynamic launch aliases are rejected before any app runs',()=>{
  const f=fixture();
  for(const code of ['await cua.getApp("Obsidian")','await cua.getApp("md.obsidian")',
    'const launch=cua.getApp;await launch("Chrome")','await cua.getApp(target)']) {
    assert.equal(checkCua(code,f.options).allow,false);
  }
  assert.equal(f.calls.length,0);
});
test('ordinary apps require a registered task window while personal Chrome, Finder, and Obsidian remain protected',()=>{
  const f=fixture();
  assert.equal(checkCua('await cua.getApp("Anki")',f.options).allow,false);
  assert.equal(checkCua('let app=await cua.getApp("com.test.Task");await app.getAXState()',f.options).allow,true);
  assert.equal(checkCua('let app=await cua.getApp("com.test.Task");await app.activate()',f.options).allow,true);
  for(const app of ['Chrome','Google Chrome','com.google.Chrome','/Applications/Google Chrome.app',
    'Finder','com.apple.finder','/System/Library/CoreServices/Finder.app']) {
    assert.equal(checkCua('await cua.getApp('+JSON.stringify(app)+')',f.options).allow,false,app);
  }
  assert.deepEqual(f.calls.map(item=>item.action),[
    'authorize-app','authorize-app','check-native','authorize-app','check-native',
  ]);
});
test('native Computer Use binding accepts the registered Bundle ID or exact app path, not a display name',()=>{
  const f=fixture();
  assert.equal(checkCua('await cua.getApp("Task")',f.options).allow,false);
  assert.equal(checkCua('await cua.getApp("com.test.Task")',f.options).allow,true);
  assert.equal(checkCua('await cua.getApp("/Applications/Task.app")',f.options).allow,true);
});
test('Telegram Safari Simulator and Terminal all require a gateway task registration',()=>{
  const f=fixture();
  for(const app of ['Telegram','ru.keepcoder.Telegram','Safari','com.apple.Safari',
    'Simulator','com.apple.iphonesimulator','Terminal','com.apple.Terminal']) {
    assert.equal(checkCua('await cua.getApp('+JSON.stringify(app)+')',f.options).allow,false,app);
  }
  assert.deepEqual(f.calls.map(item=>item.action),Array(8).fill('authorize-app'));
});
test('one native Computer Use call may perform at most one interface-changing action',()=>{
  const f=fixture();
  const one='const app=await cua.getApp("com.test.Task");await app.getAXState();await app.click(1);await app.getAXState()';
  const two='const app=await cua.getApp("com.test.Task");await app.click(1);await app.typeText("next")';
  assert.equal(checkCua(one,f.options).allow,true);
  assert.equal(checkCua(two,f.options).allow,false);
});
test('application launch methods stay blocked without banning unrelated objects',()=>{
  const f=fixture();
  assert.equal(checkCua('const app=await cua.getApp("com.test.Task");await app.launch()',f.options).allow,false);
  assert.equal(checkCua('await cua.computer.launch_app("Telegram")',f.options).allow,false);
  assert.equal(checkCua('await buildPipeline.launch()',f.options).allow,true);
  assert.equal(checkCua('await taskManager.launch_app()',f.options).allow,true);
});
test('a precise registered worker can be bound and is rechecked on every later operation',()=>{
  const f=fixture();assert.equal(checkCua('let task=await cua.getApp('+JSON.stringify(worker)+')',f.options).allow,true);
  assert.equal(checkCua('await task.getAXState()',f.options).allow,true);
  f.stop();assert.equal(checkCua('await task.click(5)',f.options).allow,false);
  assert.equal(f.calls.length,3);
});
test('arrays, Promise.all, and loops preserve the exact browser and worker origins',()=>{
  const f=fixture();
  checkCua(helper,f.options);
  const pages='let work=await createChromeFromGateway(browser,{kind:"browser",requestID:"ticket",placement:{targetScreenUUID:"side",intent:"automation",bounds:{left:1240}}},"connection");const pages=[work.tab];for(const page of pages)await page.getAXState()';
  assert.equal(checkCua(pages,f.options).allow,true);
  const workers='const workers=[await cua.getApp('+JSON.stringify(worker)+'),await cua.getApp("/safe/codex-obsidian-worker/build-2/Task.app")];for(const task of workers)await task.getAXState()';
  assert.equal(checkCua(workers,f.options).allow,true);
  assert.equal(f.calls.filter(item=>item.action==='authorize-app').length,2);
  assert.equal(checkCua('await workers[0].getAXState();await workers.at(-1).getScreenshot()',f.options).allow,true);
  assert.equal(checkCua('const copies=[...workers];await copies[1].getAXState()',f.options).allow,true);
  assert.equal(checkCua('const selected=workers.filter(task=>true).map(task=>task);await selected[1].getAXState()',f.options).allow,true);
  assert.equal(checkCua('const tabs=[work.tab];await tabs[0].getAXState()',f.options).allow,true);
});
test('a collection cannot hide unknown app origins or dynamic native calls',()=>{
  const f=fixture();
  assert.equal(checkCua('const apps=[await cua.getApp("Anki"),oldApp];for(const app of apps)await app.getAXState()',f.options).allow,false);
  assert.equal(checkCua('const apps=[await cua.getApp("Anki")];await apps[0][method]()',f.options).allow,false);
  for(const transform of ['slice(1)','filter((app,index)=>index===1)','map(()=>oldApp)','flatMap(()=>[oldApp])']) {
    assert.equal(checkCua('const apps=[await cua.getApp("Anki"),oldApp];const selected=apps.'+transform+';await selected[0].getAXState()',f.options).allow,false,transform);
  }
});
test('bindings from before the guard or a REPL reset cannot silently select personal windows',()=>{
  const f=fixture();assert.equal(checkCua('await oldApp.getAXState()',f.options).allow,false);
  checkCua('let task=await cua.getApp('+JSON.stringify(worker)+')',f.options);
  evaluate({tool_name:'mcp__cua_repl__js_reset',tool_input:{}},f.options);
  assert.equal(checkCua('await task.click(5)',f.options).allow,false);
});
test('native bindings are discarded during inactive routing while normal Computer Use remains allowed',()=>{
  const f=fixture();
  checkCua('let app=await cua.getApp("com.test.Task")',f.options);
  const event={tool_name:'mcp__cua_repl__js',tool_input:{code:'app=await cua.getApp("PersonalApp")'}};
  assert.equal(evaluate(event,{...f.options,routingActive:false}).allow,true);
  assert.equal(Object.keys(f.s.bindings).length,0);
  assert.equal(evaluate({tool_name:'mcp__cua_repl__js',tool_input:{code:'await app.click(3)'}},
    {...f.options,routingActive:true}).allow,false);
});
test('normal browser DOM actions and explicitly hidden IAB tabs remain usable',()=>{
  const f=fixture();
  assert.equal(checkCua('let page=await cua.createBrowserTab("iab","https://example.com",{visible:false});await page.playwright.getByRole("button",{name:"Continue"}).click()',f.options).allow,true);
  assert.equal(checkCua('let button=page.playwright.getByRole("button");await button.click()',f.options).allow,true);
  assert.equal(checkCua('await page.playwright.getByRole("button").focus()',f.options).allow,true);
  assert.equal(checkCua('let hidden=await cua.createBrowserTab("iab","https://example.com",{visible:false})',f.options).allow,true);
  const localState=state();
  assert.equal(checkCua('const browser="iab";const options={visible:false};await cua.createBrowserTab(browser,"https://example.com",options)',
    {...f.options,state:localState}).allow,true);
  assert.equal(f.calls.length,0);
});
test('raw external browser windows, tabs, and dynamic method calls cannot bypass the gateway',()=>{
  const f=fixture();
  for(const code of ['await cua.createBrowserTab("chrome","https://example.com")',
    'await management.windows.create({focused:false})','await browser.tabs.new()',
    'const create=management.windows.create;await create({focused:false})',
    'const newTab=browser.tabs.new;await newTab()',
    'const api=browser.tabs;await api.new()',
    'const api=management.windows;await api.create({focused:false})',
    'const {tabs:api}=browser;await api.new()',
    'const {create}=management.windows;await create({focused:false})',
    'const {new:n}=browser.tabs;await n()',
    'const {...api}=browser.tabs;await api.new()',
    'const api=browser.tabs;const newTab=api.new;await newTab()',
    'const api=management.windows;await api.update(12,{focused:true})',
    'await import("node:child_process")'])assert.equal(checkCua(code,f.options).allow,false,code);
  assert.equal(checkCua('await auditDataFactory.create()',f.options).allow,true);
  assert.equal(checkCua('await record[method]()',f.options).allow,true);
});
test('direct focus and changes to existing browser windows are refused',()=>{
  const f=fixture();
  for(const code of ['await app.activate()','await app.raise()',
    'await management.windows.update(12,{focused:true})'])assert.equal(checkCua(code,f.options).allow,false);
});
test('browser tabs cannot be connected directly outside the gateway-created task window',()=>{
  const f=fixture();
  assert.equal(checkCua('await cua.getTab("123")',f.options).allow,false);
  assert.equal(checkCua('await cua.createBrowserTab("iab","https://example.com",{visible:false})',f.options).allow,true);
});
test('the unmodified helper and a current literal ticket are required before Chrome creation',()=>{
  const f=fixture();const code='let work=await createChromeFromGateway(browser,{kind:"browser",requestID:"ticket",placement:{targetScreenUUID:"side",intent:"automation",bounds:{left:1240}}},"connection")';
  assert.equal(checkCua(code,f.options).allow,false);
  assert.equal(checkCua(helper,f.options).allow,true);
  assert.equal(checkCua(code,f.options).allow,true);
  assert.equal(checkCua(code.replace('left:1240','left:0'),f.options).allow,false);
  assert.equal(checkCua(code.replace('"connection"','"different"'),f.options).allow,false);
});
test('legacy helper shortcuts and replacing the gateway helper are rejected',()=>{
  const f=fixture();checkCua(helper,f.options);
  for(const code of ['await createChromeWorkWindow(browser,placement)',
    'await createChromeReviewWindow(browser,placement)','function createChromeFromGateway(){}',
    'createChromeFromGateway=other'])assert.equal(checkCua(code,f.options).allow,false);
});
test('gateway unavailability lets Codex retain its normal behavior',()=>{
  const f=fixture();f.options.callGateway=()=>{throw new Error('connection timeout');};
  const result=checkCua('let app=await cua.getApp('+JSON.stringify(worker)+')',f.options);
  assert.equal(result.allow,true);
});
test('a directory open is rewritten with shell quoting and the original target directory',()=>{
  const directory='/task/a b/$(echo bad)';
  const result=checkShell('open '+shellQuote.quote([directory]),{cwd:'/task',isDirectory:p=>p===directory});
  assert.equal(result.allow,true);const args=shellQuote.parse(result.command);
  assert.deepEqual(args.slice(-4),['open','finder','--directory',directory]);
});
test('supported app starts are rewritten while AppleScript and compound launches are stopped',()=>{
  const telegram=shellQuote.parse(checkShell('open -a Telegram').command);
  assert.deepEqual(telegram.slice(-4),['open','app','--application','Telegram']);
  const safari=shellQuote.parse(checkShell('open -b com.apple.Safari').command);
  assert.deepEqual(safari.slice(-4),['open','app','--bundle-id','com.apple.Safari']);
  const terminal=shellQuote.parse(checkShell('open -a Terminal').command);
  assert.deepEqual(terminal.slice(-4),['open','app','--application','Terminal']);
  for(const command of ['open -R /task/file','osascript -e "tell app \\"Finder\\" to activate"',
    'hs -c "hs.application.launchOrFocus(\"Obsidian\")"','open /task && echo done',
    'bash -c "open -a Finder"','"/Applications/My App.app/Contents/MacOS/My App"',
    'echo "$(open -a Finder)"','env -u LANG open /task','sudo -u mac open /task',
    'env -i /usr/bin/open /task'])assert.equal(checkShell(command,{isDirectory:()=>true}).allow,false,command);
});
test('inline interpreter launches are stopped while ordinary reads and builds are preserved',()=>{
  for(const command of ["python3 -c 'import webbrowser;webbrowser.open(\"https://example.com\")'",
    "node -e 'require(\"child_process\").execFileSync(\"open\",[])'"])assert.equal(checkShell(command).allow,false,command);
  for(const command of ['cat /Applications/Task.app/Contents/MacOS/Task','echo "open -a Finder"',
    'node obsidian/build_worker.mjs /task/output','python3 hammerspoon/test/run_safety_checks.py'])assert.equal(checkShell(command).allow,true,command);
});
test('heredoc source is not parsed as shell commands, while real launches inside it remain blocked',()=>{
  const stat="python3 - <<'PY'\nfrom pathlib import Path\nprint(Path('/Applications/Example.app/Contents/MacOS/Example').stat().st_size)\nPY";
  const json="python3 - <<'PY'\nimport json\nfor case in data['cases']:\n print(case['id'])\nPY";
  assert.equal(checkShell(stat).allow,true);
  assert.equal(checkShell(json).allow,true);
  assert.equal(checkShell("bash -s <<'SH'\nopen -a Finder\nSH").allow,false);
  assert.equal(checkShell("python3 - <<'PY'\nimport webbrowser\nwebbrowser.open('https://example.com')\nPY").allow,false);
  assert.equal(checkShell('command -v hs').allow,true);
  assert.equal(checkShell("cat <<< 'ordinary text'").allow,true);
});
test('heredoc expansion is checked without treating quoted documents as executable commands',()=>{
  for(const body of ['$(open -a Finder)','`open -a Finder`',"'$(open -a Finder)'"]) {
    assert.equal(checkShell('cat <<EOF\n'+body+'\nEOF').allow,false,body);
    assert.equal(checkShell("cat <<'EOF'\n"+body+'\nEOF').allow,true,body);
  }
  assert.equal(checkShell('cat <<EOF\n\\$(open -a Finder)\nEOF').allow,true);
  assert.equal(checkShell('cat <<EOF\n\\\\$(open -a Finder)\nEOF').allow,false);
  assert.equal(checkShell("cat <<'E'OF\n$(open -a Finder)\nEOF").allow,true);
  assert.equal(checkShell("cat <<FIRST <<'SECOND'\n$(open -a Finder)\nFIRST\nplain text\nSECOND").allow,false);
  assert.equal(checkShell("cat <<'FIRST' <<SECOND\nliteral text\nFIRST\n$(open -a Finder)\nSECOND").allow,false);
});
test('a failed directory lookup never changes the request into a main-screen file reveal',()=>{
  const result=checkShell('open /missing',{isDirectory:()=>{throw new Error('missing');}});
  assert.equal(result.allow,false);assert.equal(result.command,undefined);
});
test('normal calls avoid Hammerspoon and closed, paused, or unavailable routing fails open',()=>{
  const f=fixture();assert.equal(evaluate({tool_name:'mcp__github__read_file',tool_input:{}},f.options).allow,true);
  assert.equal(evaluate({tool_name:'Bash',tool_input:{command:'git status --short'}},f.options).allow,true);assert.equal(f.calls.length,0);
  const risky={tool_name:'Bash',tool_input:{command:'open -a Obsidian'}};
  const closed=fixture();closed.options.isHammerspoonRunning=()=>false;
  assert.equal(evaluate(risky,closed.options).allow,true);assert.equal(closed.calls.length,0);
  const paused=fixture();paused.stop();assert.equal(evaluate(risky,paused.options).allow,true);
  const unavailable=fixture();unavailable.options.callGateway=()=>{throw new Error('connection timeout');};
  assert.equal(evaluate(risky,unavailable.options).allow,true);
});
test('closed, paused, or unavailable routing leaves Computer Use calls to Codex',()=>{
  const event={tool_name:'mcp__cua_repl__js',tool_input:{code:'await cua.getApp("Obsidian")'}};
  const closed=fixture();closed.options.isHammerspoonRunning=()=>false;
  assert.equal(evaluate(event,closed.options).allow,true);assert.equal(closed.calls.length,0);
  const paused=fixture();paused.stop();
  assert.equal(evaluate(event,paused.options).allow,true);
  const unavailable=fixture();unavailable.options.callGateway=()=>{throw new Error('connection timeout');};
  assert.equal(evaluate(event,unavailable.options).allow,true);
});
test('post-tool verification repeats exact native ownership and drops stale bindings',()=>{
  const f=fixture();
  const options={...f.options,state:{bindings:{task:{kind:'app',managed:true,appPath:'/Applications/Task.app',
    requestID:'native-ticket',pid:70,windowId:71}}}};
  assert.equal(verifyCuaAfter({tool_name:'mcp__cua_repl__js'},options).allow,true);
  f.stop();
  const result=verifyCuaAfter({tool_name:'mcp__cua_repl__js'},options);
  assert.equal(result.allow,false);
  assert.equal(Object.hasOwn(options.state.bindings,'task'),false);
});
test('post-tool success confirms a pending binding and failure revokes it',()=>{
  for(const failed of [false,true]) {
    const f=fixture(),event={tool_name:'mcp__cua_repl__js',tool_use_id:failed?'failed-call':'ok-call',
      tool_input:{code:'const task=await cua.getApp("com.test.Task")'}};
    assert.equal(evaluate(event,f.options).allow,true);
    assert.equal(f.s.bindings.task.pendingToolUseId,event.tool_use_id);
    const result=verifyCuaAfter({...event,tool_response:failed?{isError:true,content:[]}:{isError:false,content:[]}},f.options);
    assert.equal(result.allow,true);
    if(failed)assert.equal(Object.hasOwn(f.s.bindings,'task'),false);
    else assert.equal(Object.hasOwn(f.s.bindings.task,'pendingToolUseId'),false);
  }
});
test('an unconfirmed binding cannot be reused until getApp succeeds again',()=>{
  const f=fixture();f.s.bindings.task={kind:'app',managed:true,appPath:'/Applications/Task.app',
    bundleID:'com.test.Task',requestID:'native-ticket',pid:70,windowId:71,pendingToolUseId:'missed-post'};
  assert.equal(checkCua('await task.click(1)',f.options).allow,false);
  const event={tool_name:'mcp__cua_repl__js',tool_use_id:'rebind',
    tool_input:{code:'const task=await cua.getApp("com.test.Task");await task.click(1)'}};
  assert.equal(evaluate(event,f.options).allow,true);
  assert.equal(f.s.bindings.task.pendingToolUseId,'rebind');
});
test('PostToolUse blocks use the documented top-level decision shape',()=>{
  assert.deepEqual(formatHookOutput('PostToolUse',{allow:false,reason:'window_left_target'}),
    {decision:'block',reason:'window_left_target'});
});
test('permitted calls do not grant approval; a direct launch returns an explicit denial',()=>{
  for(const [command,denied] of [['git status --short',false],['open --help',true]]) {
    const r=spawnSync(process.execPath,[fileURLToPath(new URL('guard.mjs',import.meta.url))],{encoding:'utf8',
      input:JSON.stringify({tool_name:'Bash',tool_input:{command}})});
    assert.equal(r.status,0);
    const response=JSON.parse(r.stdout);
    assert.equal(response.hookSpecificOutput?.permissionDecision,denied?'deny':undefined);
  }
});
