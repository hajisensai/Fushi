import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import {
  SUBAGENT_FOREGROUND_TIMEOUT_MS,
  install,
  slicedToolInput,
  withHeavyWaitLimit,
} from './subagent_wait_slice.mjs';

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

test('a subagent heavy.dart run gets the wait limit, background ones too', () => {
  const cmd = 'cd fushi && dart tool/heavy.dart -- flutter test a_test.dart --no-pub > x.log 2>&1';
  const want = 'cd fushi && dart tool/heavy.dart --wait-max-min=10 -- flutter test a_test.dart --no-pub > x.log 2>&1';
  assert.deepEqual(slicedToolInput(sub({ command: cmd, timeout: 270000 })), { command: want, timeout: 270000 });
  assert.deepEqual(slicedToolInput(sub({ command: cmd, run_in_background: true })), {
    command: want,
    run_in_background: true,
  });
  assert.deepEqual(slicedToolInput(sub({ command: cmd, timeout: 600000 }, 'PowerShell')), {
    command: want,
    timeout: SUBAGENT_FOREGROUND_TIMEOUT_MS,
  });
  // Main conversation: no limit.
  assert.equal(slicedToolInput({ tool_name: 'Bash', tool_input: { command: cmd } }), null);
});

test('withHeavyWaitLimit leaves set limits, reports and other commands alone', () => {
  for (const c of [
    'dart tool/heavy.dart --wait-max-min=3 -- flutter analyze',
    'dart tool/heavy.dart --status',
    'dart tool/heavy.dart --stats=3',
    'dart tool/heavy.dart --replay',
    'flutter test a_test.dart',
    'cat tool/heavy.dart.bak x',
  ]) {
    assert.equal(withHeavyWaitLimit(c), null, c);
  }
  assert.equal(
    withHeavyWaitLimit('dart ../tool/heavy.dart --check-only -- .\\gradlew.bat x'),
    'dart ../tool/heavy.dart --wait-max-min=10 --check-only -- .\\gradlew.bat x',
  );
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

test('--install copies the hook, registers it once and keeps the old settings', () => {
  const home = mkdtempSync(path.join(os.tmpdir(), 'wait-slice-'));
  try {
    const claudeDir = path.join(home, '.claude');
    mkdirSync(claudeDir);
    const settingsPath = path.join(claudeDir, 'settings.json');
    const before = '﻿{"env":{"A":"中文"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}';
    writeFileSync(settingsPath, before);

    install(home);
    const target = path.join(claudeDir, 'hooks', 'subagent_wait_slice.mjs');
    assert.ok(existsSync(target));
    assert.equal(readFileSync(`${settingsPath}.bak-subagent-wait-slice`, 'utf8'), before);
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    assert.equal(settings.env.A, '中文');
    assert.equal(settings.hooks.PreToolUse.length, 2);
    const entry = settings.hooks.PreToolUse[1];
    assert.equal(entry.matcher, 'Bash|PowerShell');
    assert.equal(entry.hooks[0].command, `node "${target.replace(/\\/g, '/')}"`);

    // The installed copy answers like the original, and a second run adds nothing.
    const out = spawnSync(process.execPath, [target], {
      input: JSON.stringify(sub({ command: 'x', timeout: 600000 })),
      encoding: 'utf8',
    });
    assert.equal(JSON.parse(out.stdout).hookSpecificOutput.updatedInput.timeout, SUBAGENT_FOREGROUND_TIMEOUT_MS);
    assert.ok(install(home).includes('already registered in settings.json'));
    assert.equal(JSON.parse(readFileSync(settingsPath, 'utf8')).hooks.PreToolUse.length, 2);

    // No settings file yet: one is created.
    const fresh = mkdtempSync(path.join(os.tmpdir(), 'wait-slice-'));
    try {
      install(fresh);
      const created = JSON.parse(readFileSync(path.join(fresh, '.claude', 'settings.json'), 'utf8'));
      assert.equal(created.hooks.PreToolUse.length, 1);
    } finally {
      rmSync(fresh, { recursive: true, force: true });
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
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
