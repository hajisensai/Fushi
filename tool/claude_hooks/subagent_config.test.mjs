import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { readdirSync, readFileSync } from 'node:fs';

import { handle as routeHandle, pinnedModel, routeAgentInput } from './subagent_model_router.mjs';
import { HELPER, MARKER, handle as wfHandle, rewrite } from './workflow_agent_type_default.mjs';

const SCRIPT = `export const meta = {
  name: 'x', description: 'has } brace and agent( in string',
  phases: [{ title: 'A' }],
}
phase('A')
const r = await agent('say agent( hi', {schema: S})
const rs = await parallel(xs.map(x => () => agent(\`p \${x}\`, {label: x})))
const t = await agent("q", {agentType: 'reviewer'})
// comment mentioning agent( stays
const u = await agent(\`tpl agent( text \${ok ? agent('inner') : 'x'} end\`)
const v = obj.agent('not me')
return [r, rs, t]
`;

test('router pins model by type and redirects general-purpose to general', () => {
  assert.deepEqual(routeAgentInput({ prompt: 'x' }), { prompt: 'x', subagent_type: 'general', model: 'opus' });
  assert.deepEqual(routeAgentInput({ subagent_type: 'general-purpose', prompt: 'x' }), {
    subagent_type: 'general', prompt: 'x', model: 'opus',
  });
  assert.deepEqual(routeAgentInput({ subagent_type: 'worker', model: 'opus' }), { subagent_type: 'worker', model: 'sonnet' });
  assert.deepEqual(routeAgentInput({ subagent_type: 'scout' }), { subagent_type: 'scout', model: 'sonnet' });
  assert.equal(routeAgentInput({ subagent_type: 'reviewer', model: 'opus' }), null);
  assert.equal(routeAgentInput({ subagent_type: 'fork' }), null);
  assert.equal(routeAgentInput({ subagent_type: 'Explore' }), null);
  // named teammates keep general-purpose
  assert.deepEqual(routeAgentInput({ subagent_type: 'general-purpose', name: 'a' }), {
    subagent_type: 'general-purpose', name: 'a', model: 'opus',
  });
  assert.equal(routeHandle('{"tool_name":"Bash","tool_input":{}}'), '');
  assert.equal(routeHandle('not json'), '');
});

test('workflow rewrite touches calls, not strings, comments or members', () => {
  const out = rewrite(SCRIPT);
  assert.equal(out.split(MARKER).length, 2);
  assert.ok(out.includes("await __wfAgent('say agent( hi'"));
  assert.ok(out.includes('() => __wfAgent(`p ${x}`'));
  assert.ok(out.includes("obj.agent('not me')"));
  assert.ok(out.includes('// comment mentioning agent( stays'));
  assert.ok(out.includes("__wfAgent(`tpl agent( text ${ok ? __wfAgent('inner') : 'x'} end`)"));
  assert.ok(out.includes("description: 'has } brace and agent( in string'"));
  assert.ok(out.indexOf(HELPER) < out.indexOf("phase('A')"));
  assert.equal(rewrite(out), out);
  assert.equal(rewrite('const a = 1'), 'const a = 1');
  const noAgent = "export const meta = {name: 'n', description: 'd'}\nlog('x')\n";
  assert.equal(rewrite(noAgent), noAgent);
});

test('rewritten script defaults agentType and pins model by type at runtime', async () => {
  const calls = [];
  const agent = async (_p, o) => { calls.push(o); return 'r'; };
  const parallel = async (ts) => Promise.all(ts.map((t) => t()));
  const body = rewrite(SCRIPT.replace("{agentType: 'reviewer'}", "{agentType: 'scout', model: 'opus'}"))
    .replace(/export\s+const\s+meta/, 'const meta');
  const fn = new Function('agent', 'parallel', 'phase', 'xs', 'obj', 'S', 'ok', `return (async () => {${body}})()`);
  await fn(agent, parallel, () => {}, ['a', 'b'], { agent: () => 'm' }, {}, true);
  assert.deepEqual(calls, [
    { agentType: 'general', schema: {}, model: 'opus' },
    { agentType: 'general', label: 'a', model: 'opus' },
    { agentType: 'general', label: 'b', model: 'opus' },
    { agentType: 'scout', model: 'sonnet' },
    { agentType: 'general', model: 'opus' },
    { agentType: 'general', model: 'opus' },
  ]);
});

// The type -> model map lives in three places (agent frontmatter, the router sets, the workflow
// helper literal) and the report contract in four agent bodies; nothing but this test ties them.
test('agent definitions, router and workflow helper agree', () => {
  const agentsDir = fileURLToPath(new URL('../../.claude/agents/', import.meta.url));
  /** @type {Record<string, string>} */
  const declared = {};
  for (const file of readdirSync(agentsDir).filter((f) => f.endsWith('.md')).sort()) {
    const text = readFileSync(`${agentsDir}${file}`, 'utf8');
    const front = /^---\n([\s\S]*?)\n---\n/.exec(text.replace(/\r\n/g, '\n'));
    assert.ok(front, `${file}: missing frontmatter`);
    const field = (/** @type {string} */ key) => new RegExp(`^${key}:\\s*(\\S+)\\s*$`, 'm').exec(front[1])?.[1];
    const name = field('name');
    assert.equal(`${name}.md`, file, `${file}: frontmatter name must match the file name`);
    declared[/** @type {string} */ (name)] = /** @type {string} */ (field('model'));
    // The dispatcher triages on the first line of every report (docs/agent/fast-workflow.md).
    assert.ok(text.includes('第一行写状态'), `${file}: report contract (status on the first line) is missing`);
  }
  assert.deepEqual(Object.keys(declared), ['general', 'reviewer', 'scout', 'worker']);
  for (const [name, model] of Object.entries(declared)) {
    assert.equal(pinnedModel(name), model, `${name}: router pins a different model than its frontmatter`);
  }
  const helperMap = JSON.parse(/** @type {RegExpExecArray} */ (/const m = (\{[^}]*\})\[q\.agentType\]/.exec(HELPER))[1]);
  assert.deepEqual(helperMap, declared);
});

test('hooks answer on stdin as real processes', () => {
  const dir = fileURLToPath(new URL('.', import.meta.url));
  const wf = spawnSync(process.execPath, [`${dir}workflow_agent_type_default.mjs`], {
    input: JSON.stringify({ tool_name: 'Workflow', tool_input: { script: "export const meta = {name: 'n', description: 'd'}\nawait agent('x')" } }),
    encoding: 'utf8',
  });
  assert.equal(wf.status, 0);
  assert.ok(JSON.parse(wf.stdout).hookSpecificOutput.updatedInput.script.includes("__wfAgent('x')"));
  const rt = spawnSync(process.execPath, [`${dir}subagent_model_router.mjs`], {
    input: JSON.stringify({ tool_name: 'Agent', tool_input: { subagent_type: 'worker' } }),
    encoding: 'utf8',
  });
  assert.equal(rt.status, 0);
  assert.equal(JSON.parse(rt.stdout).hookSpecificOutput.updatedInput.model, 'sonnet');
  assert.equal(wfHandle('{"tool_name":"Bash"}'), '');
});
