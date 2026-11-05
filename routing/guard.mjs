import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parse as parseJS } from 'acorn';
import shellQuote from 'shell-quote';
import { gatewayCall } from './window_cli.mjs';

const here=path.dirname(fileURLToPath(import.meta.url));
const cli=path.join(here,'window_cli.mjs');
const helperFile=path.join(here,'../browser/chrome_work_window.mjs');
const helpers=()=>fs.readFileSync(helperFile,'utf8').replace(/^export /gm,'').trim();
const nativeMethods=new Set(['getAXState','getScreenshot','getAXStateAndScreenshot','click','drag','scroll',
  'selectText','setValue','pressKey','typeText','paste','performSecondaryAction','activate','raise','focus']);
const nativeMutations=new Set(['click','drag','scroll','selectText','setValue','pressKey','typeText','paste',
  'performSecondaryAction','activate','raise','focus']);
const factoryNames=new Set(['createChromeFromGateway','createChromeWorkWindow','createChromeReviewWindow','ensureChromeWorkspace']);
const deny=reason=>({allow:false,reason});
const allow=()=>({allow:true});
const message='请先用 node '+shellQuote.quote([cli])
  +' open app --application "应用名称或完整路径" 登记副屏新窗口；等待 request --request <请求编号> 返回 connectionReady=true 后，再用返回的 Bundle ID 或路径调用 cua.getApp。';
class GatewayUnavailable extends Error {}

function hammerspoonIsRunning() {
  try {
    const result=spawnSync('/usr/bin/pgrep',['-x','Hammerspoon'],{encoding:'utf8',timeout:500});
    return !result.error && result.status===0;
  } catch { return false; }
}

function invokeGateway(callGateway,request) {
  try { return callGateway(request,{timeoutMs:1500,connectTimeoutSeconds:1}); }
  catch(error) { throw new GatewayUnavailable(error?.message??'Hammerspoon 入口不可用'); }
}

function routingIsActive(callGateway,isRunning) {
  try {
    if(!isRunning())return false;
    const status=callGateway({action:'status'},{timeoutMs:1500,connectTimeoutSeconds:1});
    return status?.ok===true && status.gatewayLoaded===true && status.safetySuspended!==true
      && status.assignmentEnabled===true && status.gateway?.gatewayReady===true;
  } catch { return false; }
}

function property(node) {
  if(node?.type!=='MemberExpression')return null;
  return node.computed?node.property.type==='Literal'?node.property.value:null:node.property.name;
}
function walk(node,visit,parent=null,ancestors=[]) {
  if(!node || typeof node!=='object')return;
  if(node.type)visit(node,parent,ancestors);
  const next=node.type?[...ancestors,node]:ancestors;
  for(const [key,value] of Object.entries(node)) {
    if(['start','end','loc'].includes(key))continue;
    if(Array.isArray(value))for(const child of value)walk(child,visit,node,next);
    else if(value && typeof value==='object')walk(value,visit,node,next);
  }
}
function literal(node) {
  if(node?.type==='Literal' && !node.regex && typeof node.value!=='bigint')return node.value;
  if(node?.type==='TemplateLiteral' && node.expressions.length===0)return node.quasis[0].value.cooked;
  if(node?.type==='UnaryExpression' && node.operator==='-' && typeof literal(node.argument)==='number')return -literal(node.argument);
  if(node?.type==='ArrayExpression')return node.elements.map(literal);
  if(node?.type==='ObjectExpression') {
    const result=Object.create(null);
    for(const item of node.properties) {
      if(item.type!=='Property' || item.computed || item.method || item.kind!=='init')throw new Error('plain literal required');
      const key=item.key.name??item.key.value;
      if(['__proto__','constructor','prototype'].includes(key))throw new Error('invalid key');
      result[key]=literal(item.value);
    }
    return result;
  }
  throw new Error('literal required');
}
function staticValue(node,values) {
  if(node?.type==='Identifier' && Object.hasOwn(values,node.name))return values[node.name];
  if(node?.type==='AwaitExpression' || node?.type==='ChainExpression')return staticValue(node.argument??node.expression,values);
  if(node?.type==='ArrayExpression')return node.elements.map(item=>item?.type==='SpreadElement'
    ?staticValue(item.argument,values):staticValue(item,values));
  if(node?.type==='ObjectExpression') {
    const result=Object.create(null);
    for(const item of node.properties) {
      if(item.type!=='Property' || item.computed || item.method || item.kind!=='init')throw new Error('plain literal required');
      const key=item.key.name??item.key.value;
      if(['__proto__','constructor','prototype'].includes(key))throw new Error('invalid key');
      result[key]=staticValue(item.value,values);
    }
    return result;
  }
  return literal(node);
}
const notStatic=Symbol('notStatic');
function maybeStatic(node,values) {
  try { return staticValue(node,values); }
  catch { return notStatic; }
}
function hasPlaywright(node) {
  let found=false;walk(node,item=>{if(property(item)==='playwright')found=true;});return found;
}
function memberPath(node) {
  if(node?.type==='Identifier')return [node.name];
  if(node?.type!=='MemberExpression')return [];
  const parent=memberPath(node.object),key=property(node);
  return key===null?[]:[...parent,String(key)];
}
function patternNames(node) {
  if(node?.type==='Identifier')return [node.name];
  if(node?.type==='RestElement')return patternNames(node.argument);
  if(node?.type==='AssignmentPattern')return patternNames(node.left);
  if(node?.type==='ArrayPattern')return node.elements.flatMap(patternNames);
  if(node?.type==='ObjectPattern')return node.properties.flatMap(item=>patternNames(item.type==='RestElement'?item.argument:item.value));
  return [];
}
function nativeTargetKey(target) {
  return [target.requestID,target.pid,target.windowId,target.appPath,target.bundleID].join('\0');
}
function markNativeBindingsForConfirmation(state,acquiredTargets,toolUseId) {
  if(!acquiredTargets.size)return;
  const visit=target=>{
    if(!target)return;
    if(target.kind==='union'||target.kind==='collection') {target.items?.forEach(visit);return;}
    if(target.kind!=='app'||target.managed!==true)return;
    if(acquiredTargets.has(nativeTargetKey(target)))target.pendingToolUseId=toolUseId;
  };
  for(const target of Object.values(state.bindings??{}))visit(target);
}
function settlePendingNativeBindings(state,toolUseId,confirmed) {
  if(typeof toolUseId!=='string'||!toolUseId)return;
  const settle=target=>{
    if(!target)return null;
    if(target.kind==='app'&&target.pendingToolUseId===toolUseId) {
      if(!confirmed)return null;
      delete target.pendingToolUseId;
      return target;
    }
    if(target.kind==='union'||target.kind==='collection') {
      target.items=(target.items??[]).map(settle).filter(Boolean);
      return target.items.length?target:null;
    }
    return target;
  };
  for(const [name,target] of Object.entries(state.bindings??{})) {
    const next=settle(target);
    if(next)state.bindings[name]=next;else delete state.bindings[name];
  }
}
function toolResponseFailed(event) {
  const response=event.tool_response;
  return response==null || response.isError===true || response.status==='error'
    || response.error!==undefined&&response.error!==null;
}
function invalidateNativeBindings(state) {
  const containsApp=value=>value?.kind==='app'
    ||(value?.kind==='union'||value?.kind==='collection')&&(value.items??[]).some(containsApp);
  let changed=false;
  for(const [name,target] of Object.entries(state?.bindings??{})) {
    if(containsApp(target)) {delete state.bindings[name];changed=true;}
  }
  return changed;
}

export function checkCua(code,{callGateway=gatewayCall,state={bindings:{},helperLoaded:false},trustedHelper=helpers(),
  onNativeConnection=()=>{}}={}) {
  if(typeof code!=='string')return deny('Computer Use 代码格式不明确，未执行。');
  if(code.trim()===trustedHelper.trim()) {state.helperLoaded=true;return allow();}
  let ast;
  try {ast=parseJS(code,{ecmaVersion:'latest',sourceType:'module',allowAwaitOutsideFunction:true});}
  catch {return deny('无法检查开窗来源，未执行这段 Computer Use 代码。');}
  let failure=null;
  const authorized=new Map();
  const bindings={...state.bindings};
  const values={...state.values};
  const temporary=new Map();
  let nativeMutationCount=0;
  const rememberTemporary=name=>{
    if(!temporary.has(name))temporary.set(name,{
      binding:bindings[name],value:values[name],
      hadBinding:Object.hasOwn(bindings,name),hadValue:Object.hasOwn(values,name),
    });
  };
  function collection(items,exact=true) { return {kind:'collection',items:items.map(item=>item??{kind:'unknown'}),exact}; }
  function hasKind(target,...kinds) {
    return target?.kind==='union'?target.items.some(item=>hasKind(item,...kinds)):kinds.includes(target?.kind);
  }
  function mergeTargets(items) {
    const flattened=[];
    const add=item=>{
      if(!item)return;
      if(item.kind==='collection'||item.kind==='union')item.items.forEach(add);
      else flattened.push(item);
    };
    items.forEach(add);
    const unique=[];
    for(const item of flattened) {
      if(!unique.some(old=>old.kind===item.kind&&old.appPath===item.appPath&&old.managed===item.managed
        &&(item.kind!=='app'||old.requestID===item.requestID&&old.pid===item.pid
          &&old.windowId===item.windowId&&old.bundleID===item.bundleID)))unique.push(item);
    }
    if(!unique.length)return null;
    return unique.length===1?unique[0]:{kind:'union',items:unique};
  }
  function elementTarget(target) {
    return target?.kind==='collection'?mergeTargets(target.items):null;
  }
  function callbackResult(node,source) {
    if(node?.type!=='ArrowFunctionExpression'&&node?.type!=='FunctionExpression')return null;
    const saved=patternNames(node.params[0]).map(name=>({name,binding:bindings[name],value:values[name],
      hadBinding:Object.hasOwn(bindings,name),hadValue:Object.hasOwn(values,name)}));
    for(const {name} of saved) {
      bindings[name]=node.params[0]?.type==='Identifier'?source??{kind:'unknown'}:{kind:'unknown'};
      delete values[name];
    }
    try {
      if(node.body.type!=='BlockStatement')return infer(node.body);
      const targets=[];
      walk(node.body,(item,_parent,ancestors)=>{
        if(item.type==='ReturnStatement'&&!ancestors.some(parent=>['FunctionDeclaration','FunctionExpression','ArrowFunctionExpression'].includes(parent.type))) {
          targets.push(infer(item.argument)??{kind:'unknown'});
        }
      });
      if(node.body.body.at(-1)?.type!=='ReturnStatement')targets.push({kind:'unknown'});
      return mergeTargets(targets);
    } finally {
      for(const previous of saved) {
        if(previous.hadBinding)bindings[previous.name]=previous.binding;else delete bindings[previous.name];
        if(previous.hadValue)values[previous.name]=previous.value;else delete values[previous.name];
      }
    }
  }
  function authorize(identity) {
    const key=JSON.stringify(identity);
    if(!authorized.has(key))authorized.set(key,invokeGateway(callGateway,{action:'authorize-app',...identity}));
    const result=authorized.get(key);
    if(!result.ok)throw new Error('此应用没有本次任务的唯一窗口登记：'+result.reason+'。'+message);
    return {kind:'app',...identity,appPath:result.appPath??identity.appPath,
      bundleID:result.bundleID??identity.bundleID,requestID:result.requestID,
      pid:result.pid,windowId:result.windowId,managed:true};
  }
  function reauthorize(target) {
    if(target?.kind!=='app'||target.managed!==true)throw new Error('应用操作对象没有本次任务的窗口登记。'+message);
    const result=invokeGateway(callGateway,{action:'check-native',requestID:target.requestID,
      pid:target.pid,windowId:target.windowId});
    if(!result.ok)throw new Error('任务窗口登记已失效：'+result.reason+'。'+message);
  }
  function appIdentity(value) {
    if(typeof value!=='string'||!value)throw new Error('getApp 需要 Bundle ID 或完整 .app 路径。');
    const identity=value.toLowerCase();
    const isWorker=identity.includes('/codex-obsidian-worker/');
    const isObsidian=/(?:^|[\\/])(?:obsidian(?:\.app)?|md\.obsidian|local\.codex\.obsidianworkspace)(?:$|[\\/])/.test(identity);
    if(isObsidian&&!isWorker)throw new Error('不能连接个人 Obsidian；请先登记独立后台副本。'+message);
    if(isWorker) {
      const target=authorize({appPath:path.resolve(value)});
      onNativeConnection(target);
      return target;
    }
    if(/(?:^|[\\/])(?:(?:google )?chrome(?:\.app)?|com\.google\.chrome|finder(?:\.app)?|com\.apple\.finder)(?:$|[\\/])/.test(identity)) {
      throw new Error('Chrome 和 Finder 必须使用各自的副屏入口，不能通过原生 getApp 接管已有窗口。'+message);
    }
    const target=authorize({identity:value});
    onNativeConnection(target);
    return target;
  }
  function infer(node) {
    if(!node)return null;
    if(node.type==='AwaitExpression' || node.type==='ChainExpression')return infer(node.argument??node.expression);
    if(node.type==='Identifier')return bindings[node.name]??null;
    if(node.type==='ArrayExpression') {
      let exact=true;
      const items=node.elements.flatMap(item=>{
        if(item?.type!=='SpreadElement')return [infer(item)];
        const target=infer(item.argument);
        if(target?.kind!=='collection') {exact=false;return [null];}
        if(target.exact===false)exact=false;
        return target.items;
      });
      return collection(items,exact);
    }
    if(node.type==='MemberExpression') {
      const receiver=infer(node.object),key=property(node);
      if(receiver?.kind==='collection'&&node.computed) {
        const index=maybeStatic(node.property,values);
        return receiver.exact!==false&&Number.isInteger(index)?receiver.items[index]??null:elementTarget(receiver);
      }
      if(['windows','tabs'].includes(key))return {kind:'browser-'+key};
      if(key==='tab' && receiver?.kind==='work')return {kind:'browser'};
      if(property(node)==='playwright' || hasPlaywright(node))return {kind:'browser'};
      return null;
    }
    if(node.type==='CallExpression') {
      const method=property(node.callee);
      if(method==='getApp')return appIdentity(staticValue(node.arguments[0],values));
      if(['getTab','createBrowserTab'].includes(method) || hasPlaywright(node))return {kind:'browser'};
      if(node.callee.type==='Identifier' && node.callee.name==='createChromeFromGateway')return {kind:'work'};
      if(method==='all' && node.callee.object?.type==='Identifier' && node.callee.object.name==='Promise')return infer(node.arguments[0]);
      if(['map','flatMap'].includes(method)) {
        const source=elementTarget(infer(node.callee.object));
        return collection([callbackResult(node.arguments[0],source)],false);
      }
      if(['filter','slice'].includes(method)) {
        const source=infer(node.callee.object);
        if(source?.kind!=='collection')return null;
        const args=node.arguments.map(argument=>maybeStatic(argument,values));
        if(method==='slice'&&source.exact!==false&&args.every(value=>Number.isInteger(value)||value===undefined)) {
          return collection(source.items.slice(...args));
        }
        return collection([elementTarget(source)],false);
      }
      if(method==='at') {
        const source=infer(node.callee.object),index=maybeStatic(node.arguments[0],values);
        if(source?.kind==='collection')return source.exact!==false&&Number.isInteger(index)?source.items.at(index)??null:elementTarget(source);
      }
    }
    return null;
  }
  try {
    walk(ast,(node,parent,ancestors)=>{
      if(failure)return;
      if(node.type==='ImportExpression' || node.type==='ImportDeclaration')throw new Error('Computer Use 开窗脚本不允许动态导入；请直接加载已提供的开窗帮助函数。');
      if(node.type==='FunctionDeclaration' && factoryNames.has(node.id?.name))throw new Error('请逐字加载当前 browser/chrome_work_window.mjs，不能替换开窗帮助函数。');
      if(node.type==='AssignmentExpression' && node.left.type==='Identifier' && factoryNames.has(node.left.name))throw new Error('不能替换已登记的开窗帮助函数。');
      if(node.type==='MemberExpression' && ['getApp','createBrowserTab','launch_app'].includes(property(node))) {
        if(parent?.type!=='CallExpression' || parent.callee!==node)throw new Error('开窗方法必须直接调用，不能建立未经检查的别名。');
      }
      if(node.type==='MemberExpression'&&['create','new'].includes(property(node))
        && (memberPath(node).some(part=>['windows','tabs'].includes(part))||hasKind(infer(node.object),'browser-windows','browser-tabs'))
        && (parent?.type!=='CallExpression'||parent.callee!==node)) {
        throw new Error('不能把浏览器开窗方法保存成别名；请使用登记后的副屏帮助函数。');
      }
      if(node.type==='CallExpression' || node.type==='NewExpression') {
        const name=node.callee.type==='Identifier'?node.callee.name:property(node.callee);
        if(['eval','Function','require','getBuiltinModule'].includes(name))throw new Error('此执行方式可能绕过开窗登记。'+message);
        if(name==='launch_app'&&(node.callee.type==='Identifier'||memberPath(node.callee.object)[0]==='cua'))
          throw new Error('此执行方式可能绕过开窗登记。'+message);
        if(['launch','launchApp'].includes(name)
          &&(hasKind(infer(node.callee.object),'app')||memberPath(node.callee.object)[0]==='cua'
            ||['app','application'].includes(node.callee.object?.name))) {
          throw new Error('不能绕过副屏入口启动应用。'+message);
        }
        if(['update','remove'].includes(name) && (property(node.callee.object)==='windows'
          ||hasKind(infer(node.callee.object),'browser-windows')))throw new Error('不能直接移动或激活已有浏览器窗口。请使用登记后的副屏帮助函数。');
        if(node.callee.type==='MemberExpression' && node.callee.computed && name===null) {
          const chain=memberPath(node.callee.object),receiver=infer(node.callee.object);
          if(hasKind(receiver,'app','browser','browser-windows','browser-tabs')||chain.some(part=>['cua','windows','tabs'].includes(part))) {
            throw new Error('动态调用无法确认开窗来源，请使用明确的方法名。');
          }
        }
        if(name==='getApp') {
          appIdentity(staticValue(node.arguments[0],values));
        }
        if(name==='getTab')throw new Error('不能直接连接未登记的浏览器标签。请先通过 Chrome 副屏入口创建并登记本次任务窗口。'+message);
        if(name==='createBrowserTab') {
          const browser=staticValue(node.arguments[0],values),options=staticValue(node.arguments[2],values);
          if(browser!=='iab' || options?.visible!==false)throw new Error('外部浏览器必须通过副屏入口创建。请使用 createChromeFromGateway。');
        }
        const chain=memberPath(node.callee);
        if(['create','new'].includes(name) && !(chain[0]==='Object'&&name==='create')
          && (chain.includes('windows')||chain.includes('tabs')||hasKind(infer(node.callee.object),'browser-windows','browser-tabs'))) {
          throw new Error('不能直接新建浏览器窗口或标签。请使用 createChromeFromGateway。');
        }
        if(factoryNames.has(name)) {
          if(name!=='createChromeFromGateway')throw new Error('此帮助函数没有本次开窗登记，请使用 createChromeFromGateway。');
          if(!state.helperLoaded)throw new Error('请先逐字加载 browser/chrome_work_window.mjs（移除 export）。');
          const request=staticValue(node.arguments[1],values),extensionInstanceId=staticValue(node.arguments[2],values);
          if(request?.kind!=='browser' || typeof request.requestID!=='string' || typeof extensionInstanceId!=='string')throw new Error('需要本次请求的完整 JSON 和浏览器连接编号。');
          const checked=invokeGateway(callGateway,{action:'authorize-browser',requestID:request.requestID,placement:request.placement,extensionInstanceId});
          if(!checked.ok)throw new Error('副屏开窗登记无效：'+checked.reason);
        }
        if(nativeMethods.has(name)) {
          const target=infer(node.callee.object);
          const origins=target?.kind==='union'?target.items:[target];
          if(!target||target.kind==='collection'||!origins.length
            ||!origins.every(item=>item?.kind==='browser'||item?.kind==='app'&&item.managed===true)) {
            throw new Error('该操作对象的来源不明确。请重新获取已登记的任务副本，或使用浏览器 Playwright 对象。');
          }
          const apps=origins.filter(item=>item.kind==='app');
          if(apps.some(item=>item.pendingToolUseId))
            throw new Error('此应用连接尚未通过 PostToolUse 确认；请重新调用 cua.getApp 后再继续。'+message);
          if(nativeMutations.has(name)) {
            nativeMutationCount+=apps.length;
            if(nativeMutationCount>1)throw new Error('每次 Computer Use 调用最多执行一个原生界面操作；请拆成多个调用。');
          }
          for(const item of apps)reauthorize(item);
        }
      }
      if(node.type==='ForOfStatement') {
        const target=elementTarget(infer(node.right));
        const left=node.left.type==='VariableDeclaration'?node.left.declarations[0]?.id:node.left;
        for(const name of patternNames(left)) {
          rememberTemporary(name);
          if(target)bindings[name]=target;else delete bindings[name];
        }
      }
      if(node.type==='CallExpression'&&['map','flatMap','forEach','filter'].includes(property(node.callee))) {
        const target=elementTarget(infer(node.callee.object)),callback=node.arguments[0];
        for(const name of patternNames(callback?.params?.[0])) {
          rememberTemporary(name);
          if(target)bindings[name]=target;else delete bindings[name];
        }
      }
      if(node.type==='VariableDeclarator') {
        const scoped=ancestors.some(item=>item.type==='ArrowFunctionExpression'||item.type==='FunctionExpression'
          ||item.type==='FunctionDeclaration'||item.type==='ForOfStatement'||item.type==='ForInStatement'||item.type==='BlockStatement');
        const names=patternNames(node.id);
        if(scoped)for(const name of names)rememberTemporary(name);
        if(node.id.type==='Identifier') {
          const target=infer(node.init),value=node.init?maybeStatic(node.init,values):notStatic;
          if(target)bindings[node.id.name]=target;else if(node.init)delete bindings[node.id.name];
          if(value!==notStatic)values[node.id.name]=value;else if(node.init)delete values[node.id.name];
        } else if(node.id.type==='ArrayPattern') {
          const source=infer(node.init);
          for(let i=0;i<node.id.elements.length;i++) {
            const name=patternNames(node.id.elements[i])[0],target=source?.kind==='collection'&&source.exact!==false?source.items[i]:elementTarget(source);
            if(!name)continue;
            if(target)bindings[name]=target;else delete bindings[name];
          }
        } else if(node.id.type==='ObjectPattern') {
          const source=infer(node.init);
          for(const item of node.id.properties) {
            const names=patternNames(item.type==='RestElement'?item.argument:item.value);
            const key=item.type==='Property'?(item.computed?maybeStatic(item.key,values):item.key.name??item.key.value):null;
            if(hasKind(source,'browser-windows','browser-tabs')&&item.type==='Property'
              && (key===notStatic||['create','new'].includes(key)||hasKind(source,'browser-windows')&&['update','remove'].includes(key))) {
              throw new Error('不能把浏览器开窗或窗口控制方法保存成别名；请使用登记后的副屏帮助函数。');
            }
            const target=item.type==='Property'?infer({type:'MemberExpression',object:node.init,
              property:item.key,computed:item.computed}):source;
            for(const name of names) {
              if(target)bindings[name]=target;else delete bindings[name];
              delete values[name];
            }
          }
        }
      }
      if(node.type==='AssignmentExpression' && node.left.type==='Identifier') {
        const target=infer(node.right),value=maybeStatic(node.right,values);
        if(target)bindings[node.left.name]=target;else delete bindings[node.left.name];
        if(value!==notStatic)values[node.left.name]=value;else delete values[node.left.name];
      }
    });
  } catch(error) {
    if(error instanceof GatewayUnavailable)return allow();
    failure=error.message;
  }
  if(failure)return deny(failure);
  for(const [name,previous] of temporary) {
    if(previous.hadBinding)bindings[name]=previous.binding;else delete bindings[name];
    if(previous.hadValue)values[name]=previous.value;else delete values[name];
  }
  state.bindings=bindings;
  state.values=values;
  return allow();
}

const guiCommands=new Set(['open','osascript','hs']);
const shellCommands=new Set(['sh','bash','zsh','dash']);
function hasSubstitution(source) {
  let quote=null;
  for(let i=0;i<source.length;i++) {
    const c=source[i];
    if(quote==="'"){if(c==="'")quote=null;continue;}
    if(c==='\\'){i++;continue;}
    if(c==='`' || (c==='$' && source[i+1]==='('))return true;
    if(c==='"'){quote=quote==='"'?null:'"';continue;}
    if(c==="'" && !quote)quote="'";
  }
  return false;
}
function maskHereDocs(command) {
  const lines=command.match(/[^\n]*(?:\n|$)/g)?.filter(Boolean)??[];
  const output=[],bodies=[],pending=[];
  let quote=null;
  for(const line of lines) {
    if(pending.length) {
      const current=pending[0],candidate=current.stripTabs?line.replace(/^\t+/,''):line;
      if(candidate.replace(/\r?\n$/,'')===current.delimiter)pending.shift();
      else current.body+=line;
      output.push(line.includes('\n')?'\n':'');
      continue;
    }
    let masked='';
    for(let i=0;i<line.length;i++) {
      const char=line[i];
      if(quote==="'") {masked+=char;if(char==="'")quote=null;continue;}
      if(char==='\\') {masked+=char+(line[i+1]??'');i++;continue;}
      if(quote==='"') {masked+=char;if(char==='"')quote=null;continue;}
      if(char==='"'||char==="'") {quote=char;masked+=char;continue;}
      if(char==='#'&&(i===0||/\s/.test(line[i-1]))) {masked+=line.slice(i);break;}
      if(char==='<'&&line[i+1]==='<'&&line[i+2]!=='<'&&line[i-1]!=='<') {
        let cursor=i+2,stripTabs=false;
        if(line[cursor]==='-') {stripTabs=true;cursor++;}
        while(/\s/.test(line[cursor]??'')&&line[cursor]!=='\n')cursor++;
        let delimiter='',delimiterQuote=null,quoted=false,started=false;
        while(cursor<line.length) {
          const c=line[cursor];
          if(delimiterQuote) {
            if(c===delimiterQuote)delimiterQuote=null;
            else if(c==='\\'&&delimiterQuote==='"'&&['\\','"','$','`'].includes(line[cursor+1]))delimiter+=line[++cursor];
            else delimiter+=c;
          } else if(c==='"'||c==="'") {
            delimiterQuote=c;quoted=true;
          } else if(c==='\\'&&cursor+1<line.length) {
            quoted=true;delimiter+=line[++cursor];
          } else if(/[\s;|&<>]/.test(c))break;
          else delimiter+=c;
          started=true;cursor++;
        }
        if(delimiterQuote)return {source:command,bodies,complete:false};
        if(started) {
          masked+=' '.repeat(cursor-i);
          const document={delimiter,stripTabs,expand:!quoted,body:''};
          pending.push(document);
          bodies.push(document);
          i=cursor-1;
          continue;
        }
      }
      masked+=char;
    }
    output.push(masked);
  }
  return {source:output.join(''),bodies,complete:pending.length===0};
}
function hasHereDocSubstitution(source) {
  // Quotes in an unquoted heredoc body are ordinary text; they do not stop
  // the shell from expanding command substitutions.
  for(let i=0;i<source.length;i++) {
    if(source[i]==='\\'&&['\\','$','`','\n'].includes(source[i+1])) {i++;continue;}
    if(source[i]==='`'||source[i]==='$'&&source[i+1]==='(')return true;
  }
  return false;
}
function scriptMayOpenWindow(source) {
  return /webbrowser\s*\.\s*open|NSWorkspace|launchApplication|activateIgnoringOtherApps|(?:exec|spawn|system|run|Popen)[\s\S]{0,90}['"](?:\/usr\/bin\/)?(?:open|osascript|hs)['"]/.test(source);
}
export function checkShell(command,{cwd=process.cwd(),isDirectory=p=>fs.statSync(p).isDirectory()}={}) {
  if(typeof command!=='string')return deny('无法检查开窗命令。');
  const heredocs=maskHereDocs(command);
  if(!heredocs.complete)return deny('Here-document 没有结束标记，无法确认开窗命令。');
  if(heredocs.bodies.some(document=>document.expand&&hasHereDocSubstitution(document.body)
    && /\b(open|osascript|hs)\b/.test(document.body)))return deny('开窗不能隐藏在命令替换中。'+message);
  command=heredocs.source;
  let tokens;
  try {tokens=shellQuote.parse(command);}
  catch {return /\b(open|osascript|hs)\b/.test(command)?deny('复杂开窗命令无法确认来源。'+message):allow();}
  if(hasSubstitution(command) && /\b(open|osascript|hs)\b/.test(command))return deny('开窗不能隐藏在命令替换中。'+message);
  const sections=[[]];
  for(const token of tokens) {
    if(typeof token==='object' && token.op)sections.push([]);
    else if(typeof token==='string')sections.at(-1).push(token);
  }
  let rewrite=null;
  for(const raw of sections) {
    const args=[...raw];
    let wrapped=false;
    if(path.basename(args[0]??'')==='command'&&['-v','-V'].includes(args[1]))continue;
    while(args.length) {
      if(/^[A-Za-z_][A-Za-z0-9_]*=/.test(args[0])){args.shift();wrapped=true;continue;}
      const wrapper=path.basename(args[0]);
      if(!['env','command','builtin','nohup','sudo','nice','time','exec','then','do','if'].includes(wrapper))break;
      args.shift();wrapped=true;
      while(args[0]?.startsWith('-')) {
        const option=args.shift();if(option==='--')break;
        const withValue={env:['-u','--unset','-C','--chdir'],sudo:['-u','-g','-h','-p','-C','-D','-T'],nice:['-n'],time:['-f','-o']}[wrapper]??[];
        if(withValue.includes(option))args.shift();
        else if(option==='-S' && wrapper==='env')return deny('请直接调用副屏入口，不要嵌套启动图形应用。'+message);
      }
    }
    const commandPath=args.shift()??'';
    const executable=path.basename(commandPath);
    if(shellCommands.has(executable) && args.includes('-c')) {
      const inner=checkShell(args[args.indexOf('-c')+1],{cwd,isDirectory});
      if(!inner.allow || inner.command)return deny('请直接调用副屏入口，不要嵌套启动图形应用。'+message);
    }
    if(shellCommands.has(executable)&&heredocs.bodies.length) {
      for(const document of heredocs.bodies) {
        const inner=checkShell(document.body,{cwd,isDirectory});
        if(!inner.allow||inner.command)return deny('请直接调用副屏入口，不要在 shell 输入中启动图形应用。'+message);
      }
    }
    if(['node','nodejs','python','python3','ruby','perl','swift'].includes(executable)) {
      const source=args.join(' ');
      const readsStdin=args.length===0||args.includes('-')||args.includes('-s');
      if(scriptMayOpenWindow(source)||readsStdin&&heredocs.bodies.some(document=>scriptMayOpenWindow(document.body))) {
        return deny('脚本中的直接开窗会绕过屏幕分配。'+message);
      }
    }
    if(/\.app\/Contents\/MacOS\//.test(commandPath))return deny('不能直接执行图形应用。'+message);
    if(!guiCommands.has(executable))continue;
    if(executable==='hs' && args.length>0 && args.every(arg=>['-h','--help'].includes(arg)))continue;
    if(executable==='open' && !wrapped && sections.length===1) {
      let selector=null,selectorFlag='--application',invalid=false;
      for(let i=0;i<args.length;i++) {
        const arg=args[i];
        if(arg==='-a'||arg==='--application'||arg==='-b'||arg==='--bundle-id') {
          if(selector!==null||!args[i+1]){invalid=true;break;}
          selector=args[++i];
          selectorFlag=arg==='-b'||arg==='--bundle-id'?'--bundle-id':'--application';
          continue;
        }
        if(['-n','--new','-g','--background','-j','--hide','-F','--fresh'].includes(arg))continue;
        if(arg==='--args'){invalid=true;break;}
        if(arg.startsWith('-')){invalid=true;break;}
        if(selector!==null){invalid=true;break;}
        if(/\.app(?:\/|$)/i.test(arg))selector=path.resolve(cwd,arg);
        else if(args.length===1) {
          const directory=path.resolve(cwd,arg);
          try {
            if(isDirectory(directory)) {
              rewrite=shellQuote.quote([process.execPath,cli,'open','finder','--directory',directory]);
              continue;
            }
          } catch {}
          invalid=true;
        } else invalid=true;
      }
      if(rewrite)continue;
      if(selector&&!invalid) {
        rewrite=shellQuote.quote([process.execPath,cli,'open','app',selectorFlag,selector]);
        continue;
      }
    }
    return deny('此命令会绕过 Codex/个人开窗分流。'+message);
  }
  return rewrite?{allow:true,command:rewrite}:allow();
}

export function evaluate(event,options={}) {
  const tool=event.tool_name??'',input=event.tool_input??{};
  const callGateway=options.callGateway??gatewayCall;
  const isRunning=options.isHammerspoonRunning??hammerspoonIsRunning;
  if(tool==='Bash' || /(?:^|__|\.)(?:exec_command|shell_command)$/.test(tool)) {
    const decision=checkShell(input.command??input.cmd,{cwd:event.cwd,...options});
    if(decision.allow && !decision.command)return decision;
    return routingIsActive(callGateway,isRunning)?decision:allow();
  }
  if(/cua_repl/i.test(tool) && /js_reset$/.test(tool)) {
    if(options.state){options.state.bindings={};options.state.values={};options.state.helperLoaded=false;}
    return allow();
  }
  if(/cua_repl/i.test(tool) && /js$/.test(tool)) {
    const active=options.routingActive??routingIsActive(callGateway,isRunning);
    if(!active) {
      invalidateNativeBindings(options.state);
      return allow();
    }
    const acquiredTargets=new Set();
    const decision=checkCua(input.code,{...options,callGateway,onNativeConnection:target=>acquiredTargets.add(nativeTargetKey(target))});
    if(decision.allow&&typeof event.tool_use_id==='string'&&options.state) {
      markNativeBindingsForConfirmation(options.state,acquiredTargets,event.tool_use_id);
    }
    return decision.allow || routingIsActive(callGateway,isRunning)?decision:allow();
  }
  return allow();
}

export function verifyCuaAfter(event,options={}) {
  const tool=event.tool_name??'';
  if(!/cua_repl/i.test(tool)||!/js$/.test(tool))return allow();
  const callGateway=options.callGateway??gatewayCall;
  const state=options.state??{bindings:{}};
  const confirmed=!toolResponseFailed(event);
  const settle=()=>settlePendingNativeBindings(state,event.tool_use_id,confirmed);
  let targets=[];
  const add=target=>{
    if(!target)return;
    if(target.kind==='union'||target.kind==='collection')target.items?.forEach(add);
    else if(target.kind==='app'&&target.managed)targets.push(target);
  };
  for(const target of Object.values(state.bindings??{}))add(target);
  const unique=[];
  for(const target of targets) {
    if(!unique.some(item=>item.requestID===target.requestID&&item.pid===target.pid&&item.windowId===target.windowId
      &&item.appPath===target.appPath))unique.push(target);
  }
  for(const target of unique) {
    let result;
    try {
      result=invokeGateway(callGateway,{action:'check-native',requestID:target.requestID,
        pid:target.pid,windowId:target.windowId});
    } catch(error) {
      if(error instanceof GatewayUnavailable) {settlePendingNativeBindings(state,event.tool_use_id,false);return allow();}
      throw error;
    }
    if(!result.ok) {
      for(const [name,binding] of Object.entries(state.bindings??{})) {
        if(binding?.kind==='app'&&binding.requestID===target.requestID&&binding.pid===target.pid
          &&binding.windowId===target.windowId)delete state.bindings[name];
      }
      settlePendingNativeBindings(state,event.tool_use_id,false);
      return deny('Computer Use 操作后，任务窗口已离开已核验状态：'+result.reason+'。请停止后续输入并重新登记。');
    }
  }
  settle();
  return allow();
}

export function formatHookOutput(eventName,decision) {
  if(eventName==='PostToolUse')return decision.allow?{}:{decision:'block',reason:decision.reason};
  if(decision.allow&&!decision.command)return {};
  const output={hookSpecificOutput:{hookEventName:'PreToolUse',permissionDecision:decision.allow?'allow':'deny'}};
  if(decision.allow&&decision.command) {
    output.hookSpecificOutput.updatedInput={command:decision.command};
    output.hookSpecificOutput.additionalContext='此目录打开请求已改为副屏新任务窗口；返回 JSON 中的编号只属于本次请求。';
  } else if(!decision.allow)output.hookSpecificOutput.permissionDecisionReason=decision.reason;
  return output;
}

function statePath(event) {
  const id=[event.session_id,event.agent_id??'root'].join('-');
  if(!/^[A-Za-z0-9_-]{1,250}$/.test(id))throw new Error('会话编号无效，开窗检查已停止。');
  const root=process.env.CODEX_WINDOW_GUARD_STATE_ROOT??path.join(os.homedir(),'.codex/window-routing/state');
  return path.join(root,id+'.json');
}
function main() {
  let decision,eventName='PreToolUse';
  try {
    const event=JSON.parse(fs.readFileSync(0,'utf8'));
    eventName=event.hook_event_name==='PostToolUse'?'PostToolUse':'PreToolUse';
    const cuaJS=/cua_repl/i.test(event.tool_name??'') && /js$/.test(event.tool_name??'');
    // The Hook is only a companion to Hammerspoon. When its controller is
    // closed, paused, suspended, or unavailable, leave Codex's normal behavior
    // untouched while invalidating old native App bindings before resumption.
    const active=cuaJS?routingIsActive(gatewayCall,hammerspoonIsRunning):undefined;
    if(cuaJS && !active) {
      const file=statePath(event);
      const state=file && fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{bindings:{},values:{},helperLoaded:false};
      const before=JSON.stringify(state);
      decision=evaluate(event,{state,routingActive:false});
      if(file && JSON.stringify(state)!==before) {
        try {
          fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
          const temp=file+'.'+process.pid+'.tmp';fs.writeFileSync(temp,JSON.stringify(state),{mode:0o600});fs.renameSync(temp,file);
        } catch {
          try {fs.rmSync(file,{force:true});} catch {}
        }
      }
    } else {
      const relevant=/cua_repl/i.test(event.tool_name??'');
      const file=relevant?statePath(event):null;
      const state=file && fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{bindings:{},values:{},helperLoaded:false};
      decision=eventName==='PostToolUse'
        ?verifyCuaAfter(event,{state,routingActive:active})
        :evaluate(event,{state,routingActive:active});
      if(file && (decision.allow||eventName==='PostToolUse')) {
        fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
        const temp=file+'.'+process.pid+'.tmp';fs.writeFileSync(temp,JSON.stringify(state),{mode:0o600});fs.renameSync(temp,file);
      }
    }
  } catch(error) {
    decision=routingIsActive(gatewayCall,hammerspoonIsRunning)
      ?deny('开窗检查没有完成，已停止本次调用：'+error.message)
      :allow();
  }
  // Ordinary permitted calls retain Codex's normal approval behavior.
  const output=formatHookOutput(eventName,decision);
  process.stdout.write(JSON.stringify(output)+'\n');
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main();
