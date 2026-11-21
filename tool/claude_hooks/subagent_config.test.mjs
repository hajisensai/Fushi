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

// BUG-5086: workflow subagents of one session share a scratchpad. The old template
// (`<命令> > <日志> ...; echo "exit=$?"` + `grep -q '^exit='`) let two agents both pick
// `test.log`: each truncated the other's file and the waiter matched the other run's
// `exit=` line. Every log path and exit marker in the template must carry the run's tag.
test('long-command log template names logs and exit lines by a unique tag', () => {
  const agentsDir = fileURLToPath(new URL('../../.claude/agents/', import.meta.url));
  const LOG = '<scratchpad>/<标签>.log';
  /** @type {string[]} */
  const withTemplate = [];
  for (const file of readdirSync(agentsDir).filter((f) => f.endsWith('.md')).sort()) {
    const text = readFileSync(`${agentsDir}${file}`, 'utf8');
    assert.ok(!text.includes('"exit=$?"'), `${file}: exit line without the run tag`);
    assert.ok(!/'\^exit='/.test(text), `${file}: wait loop matches any run's exit line`);
    const spans = [...text.matchAll(/`([^`\n]+)`/g)].map((m) => m[1]);
    const runs = spans.filter((s) => /\becho\b/.test(s) && s.includes('exit='));
    const waits = spans.filter((s) => /\buntil grep\b/.test(s));
    if (runs.length === 0 && waits.length === 0) continue;
    withTemplate.push(file.replace(/\.md$/, ''));
    for (const span of [...runs, ...waits]) {
      // Any spelling of the marker (`echo exit=$?`, `'exit='$?`, `grep -q "^exit="`) must carry
      // the tag, otherwise the run never writes what the waiter greps for (or vice versa).
      const untagged = [...span.matchAll(/exit=/g)].filter((m) => !span.slice(0, m.index).endsWith('<标签> '));
      assert.equal(untagged.length, 0, `${file}: exit marker without the run tag: ${span}`);
      const echoes = [...span.matchAll(/\becho\s+"([^"]*)"/g)].map((m) => m[1]);
      if (runs.includes(span)) assert.ok(echoes.length > 0, `${file}: run template must echo the tagged exit line: ${span}`);
      for (const e of echoes) assert.equal(e, '<标签> exit=$?', `${file}: ${span}`);
      const greps = [...span.matchAll(/\bgrep\s+-q\s+'([^']*)'\s+(\S+?);/g)];
      if (waits.includes(span)) assert.ok(greps.length > 0, `${file}: wait template must grep the tagged log: ${span}`);
      for (const [, pattern, target] of greps) {
        assert.equal(pattern, '^<标签> exit=', `${file}: ${span}`);
        assert.equal(target, LOG, `${file}: ${span}`);
      }
      // Redirections and tails stand alone (`<命令>` / `<标签>` contain `>` themselves).
      const targets = [...span.matchAll(/(?:^|\s)(?:\d?>>?|tail -n \d+)\s+([^\s;"]+)/g)].map((m) => m[1]);
      assert.ok(targets.length > 0, `${file}: no log target found in ${span}`);
      for (const t of targets) assert.equal(t, LOG, `${file}: log target must be the tagged log: ${span}`);
    }
    assert.ok(runs.length > 0 && waits.length > 0, `${file}: run and wait templates must come together`);
  }
  assert.deepEqual(withTemplate, ['general', 'reviewer', 'worker']);
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

test('agent definitions carry the current root CLAUDE.md and omit the loaded copy', async () => {
  const { AGENTS, BEGIN, END, plan, render } = await import('./sync_agent_claude_md.mjs');
  const stale = plan().filter((p) => p.current !== p.wanted).map((p) => p.file);
  assert.deepEqual(stale, [], 'CLAUDE.md 改了但代理定义没同步：跑 node tool/claude_hooks/sync_agent_claude_md.mjs');
  for (const p of plan()) {
    assert.match(p.current, /^---\n[\s\S]*?\nomitClaudeMd: true\n[\s\S]*?\n---\n/, p.file);
    assert.equal(p.current.split(BEGIN).length, 2, p.file);
    assert.equal(p.current.split(END).length, 2, p.file);
  }
  assert.equal(AGENTS.length, 4);
  // Re-rendering replaces the old block instead of stacking a second one.
  const once = render('---\nname: x\nmodel: opus\n---\nbody\n', 'RULES v1\n');
  const twice = render(once, 'RULES v2\n');
  assert.equal(twice.split(BEGIN).length, 2);
  assert.match(twice, /RULES v2/);
  assert.doesNotMatch(twice, /RULES v1/);
  const front = /^---\n([\s\S]*?)\n---\n/.exec(twice)[1];
  assert.equal(front.match(/^omitClaudeMd: true$/gm).length, 1);
});
