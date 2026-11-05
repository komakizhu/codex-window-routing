import assert from 'node:assert/strict';
import { test } from 'node:test';
import shellQuote from 'shell-quote';
import { mergeHooks } from './install.mjs';

test('adding the routing hook preserves unrelated hooks and is idempotent',()=>{
  const original={description:'keep',hooks:{PreToolUse:[{matcher:'Bash',hooks:[{type:'command',command:'other-check'}]}],Stop:[{hooks:[{command:'cleanup'}]}]}};
  const first=mergeHooks(original,'/task/current','/opt/node');
  assert.deepEqual(first.hooks.PreToolUse[0],original.hooks.PreToolUse[0]);
  assert.ok(first.hooks.PostToolUse.length===1);
  assert.deepEqual(first.hooks.Stop,original.hooks.Stop);
  assert.deepEqual(mergeHooks(first,'/task/current','/opt/node'),first);
  first.hooks.PreToolUse[1].hooks[0].enabled=false;
  assert.equal(mergeHooks(first,'/task/current','/opt/node').hooks.PreToolUse[1].hooks[0].enabled,true);
  assert.equal(original.hooks.PreToolUse.length,1);
});
test('hook paths keep spaces and shell metacharacters as literal arguments',()=>{
  const root='/task/a b/$(literal)';
  const result=mergeHooks(null,root,'/opt/node');
  const entry=result.hooks.PreToolUse[0];
  assert.deepEqual(shellQuote.parse(entry.hooks[0].command),['/opt/node',root+'/routing/guard.mjs']);
  assert.ok(new RegExp(entry.matcher).test('Bash'));
  assert.ok(new RegExp(entry.matcher).test('mcp__cua_repl__js'));
  assert.ok(new RegExp(entry.matcher).test('mcp__cua_repl.js_reset'));
  const post=result.hooks.PostToolUse[0];
  assert.deepEqual(shellQuote.parse(post.hooks[0].command),['/opt/node',root+'/routing/guard.mjs']);
  assert.equal(post.hooks[0].timeout,30);
  assert.ok(new RegExp(post.matcher).test('mcp__cua_repl__js'));
});
test('invalid existing hook structures are rejected without replacing them',()=>{
  for(const value of [[],{hooks:[]},{hooks:{PreToolUse:{}}}])assert.throws(()=>mergeHooks(value,'/task','/node'));
});
