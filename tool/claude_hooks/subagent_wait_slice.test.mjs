import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { SUBAGENT_FOREGROUND_TIMEOUT_MS, slicedToolInput } from './subagent_wait_slice.mjs';

const sub = (toolInput, toolName = 'Bash') => ({
  agent_id: 'a1',
  agent_type: 'general',
  tool_name: toolName,
  tool_input: toolInput,
});

test('the cap stays under the 5-minute subagent cache TTL', () => {
  assert.ok(SUBAGENT_FOREGROUND_TIMEOUT_MS < 5 * 60 * 1000);
  assert.ok(SUBAGENT_FOREGROUND_TIMEOUT_MS >= 4 * 60 * 1000);
});

test('a long foreground wait inside a subagent is capped, other fields kept', () => {
  for (const tool of ['Bash', 'PowerShell']) {
    assert.deepEqual(
      slicedToolInput(sub({ command: 'x', description: 'd', timeout: 600000 }, tool)),
      { command: 'x', description: 'd', timeout: SUBAGENT_FOREGROUND_TIMEOUT_MS },
    );
  }
});

test('main conversation, background, short and default timeouts are left alone', () => {
  for (const payload of [
    { tool_name: 'Bash', tool_input: { command: 'x', timeout: 600000 } }, // main: no agent_id
    { agent_type: 'general', tool_name: 'Bash', tool_input: { command: 'x', timeout: 600000 } },
    { agent_id: '', tool_name: 'Bash', tool_input: { command: 'x', timeout: 600000 } },
    sub({ command: 'x', timeout: 600000, run_in_background: true }),
    sub({ command: 'x', timeout: SUBAGENT_FOREGROUND_TIMEOUT_MS }),
    sub({ command: 'x', timeout: 120000 }),
    sub({ command: 'x' }),
    sub({ command: 'x', timeout: '600000' }),
    sub({ file_path: 'a', timeout: 600000 }, 'Read'),
    sub(null),
    null,
    'not an object',
  ]) {
    assert.equal(slicedToolInput(payload), null, JSON.stringify(payload));
  }
});

test('the hook answers updatedInput JSON on stdin input, nothing otherwise', () => {
  const script = fileURLToPath(new URL('./subagent_wait_slice.mjs', import.meta.url));
  const run = (stdin) => spawnSync(process.execPath, [script], { input: stdin, encoding: 'utf8' });

  const capped = run(JSON.stringify(sub({ command: 'until x; do sleep 20; done', timeout: 600000 })));
  assert.equal(capped.status, 0);
  assert.deepEqual(JSON.parse(capped.stdout).hookSpecificOutput, {
    hookEventName: 'PreToolUse',
    updatedInput: { command: 'until x; do sleep 20; done', timeout: SUBAGENT_FOREGROUND_TIMEOUT_MS },
  });

  for (const stdin of [
    JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'x', timeout: 600000 } }),
    'not json',
    '',
  ]) {
    const quiet = run(stdin);
    assert.equal(quiet.status, 0);
    assert.equal(quiet.stdout, '');
  }
});

test('agent definitions teach the same slice, not a 10-minute blocking wait', () => {
  for (const name of ['general', 'worker', 'reviewer']) {
    const text = readFileSync(new URL(`../../.claude/agents/${name}.md`, import.meta.url), 'utf8');
    assert.ok(text.includes(`\`timeout\` 给 ${SUBAGENT_FOREGROUND_TIMEOUT_MS}`), name);
    assert.ok(!text.includes('600000'), `${name}: 600000 outlives the 5-minute cache TTL`);
    assert.match(text, /timeout 240 bash -c/, name);
  }
});
