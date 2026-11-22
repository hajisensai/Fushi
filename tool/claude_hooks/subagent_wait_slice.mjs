#!/usr/bin/env node
// Claude Code PreToolUse hook (Bash / PowerShell): inside a subagent, cap a
// foreground command's `timeout` below the 5-minute prompt-cache TTL.
//
// Subagent requests are cached for 5 minutes (the main conversation gets one
// hour). A foreground command that blocks longer makes the next request
// rewrite the subagent's whole context. 2026-11-20 audit of this machine's
// transcripts: 1752 such misses in 10 days, 197M tokens rewritten, 98% right
// after one blocking shell call, median gap 10.1 min = the 600000 ms ceiling.
//
// At its timeout a foreground command is moved to the background, not killed,
// so the cap only hands control back while the cache is still warm; the agent
// then waits for it in further slices (.claude/agents/*.md「省轮次」). Calls
// from the main conversation, background calls and calls without an explicit
// timeout (default 120 s) are left alone.
//
// It also gives a subagent's `tool/heavy.dart` run a wait limit
// (`--wait-max-min=10`, unless it set one): a queue that already says the
// run will not get a slot within that leaves at once with exit 75 and a
// `gives up now` line (test_flow/heavy_wait_estimate.dart) -- the subagent
// reports it not run and its delegator runs it with the batch -- instead of
// the subagent waiting out a queue it cannot outlast (owner, 2026-11-22).
//
// This file is self-contained (Node built-ins only) and installs itself for
// the current user, on any machine and for every project:
//
//   node subagent_wait_slice.mjs --install
//
// which copies it to ~/.claude/hooks/ and adds a `Bash|PowerShell` PreToolUse
// entry to ~/.claude/settings.json (idempotent, old file kept as a backup).

import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HOOK_FILE = 'subagent_wait_slice.mjs';

/** 4.5 minutes: margin under the 5-minute TTL for the request round trip. */
export const SUBAGENT_FOREGROUND_TIMEOUT_MS = 270000;

/** A subagent's heavy.dart wait limit, in minutes. */
export const SUBAGENT_HEAVY_WAIT_MAX_MIN = 10;

/**
 * [command] with every `heavy.dart` run given the subagent wait limit, or
 * null when it has none to give (no such run, a limit already set, or a
 * `--status` / `--stats` / `--replay` report).
 * @param {string} command
 * @returns {string | null}
 */
export function withHeavyWaitLimit(command) {
  if (command.includes('--wait-max-min')) return null;
  const run = /(\bheavy\.dart)(?=\s)(?!\s+--(?:status|stats|replay)\b)/g;
  if (!run.test(command)) return null;
  return command.replace(run, `$1 --wait-max-min=${SUBAGENT_HEAVY_WAIT_MAX_MIN}`);
}

/**
 * The tool input to run instead, or null when the call is left as it is.
 * @param {unknown} payload PreToolUse hook input.
 * @returns {Record<string, unknown> | null}
 */
export function slicedToolInput(payload) {
  if (payload === null || typeof payload !== 'object') return null;
  // `agent_id` is only present when the hook fires inside a subagent;
  // `agent_type` alone also appears in a `claude --agent` main session.
  if (typeof payload.agent_id !== 'string' || payload.agent_id.length === 0) return null;
  if (payload.tool_name !== 'Bash' && payload.tool_name !== 'PowerShell') return null;
  const input = payload.tool_input;
  if (input === null || typeof input !== 'object') return null;
  // updatedInput replaces the whole tool input, so every other field rides along.
  const out = { ...input };
  let changed = false;
  if (typeof input.command === 'string') {
    const limited = withHeavyWaitLimit(input.command);
    if (limited !== null) {
      out.command = limited;
      changed = true;
    }
  }
  if (
    input.run_in_background !== true &&
    typeof input.timeout === 'number' &&
    input.timeout > SUBAGENT_FOREGROUND_TIMEOUT_MS
  ) {
    out.timeout = SUBAGENT_FOREGROUND_TIMEOUT_MS;
    changed = true;
  }
  return changed ? out : null;
}

async function main() {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return; // Not ours to judge.
  }
  const updatedInput = slicedToolInput(payload);
  if (updatedInput === null) return;
  process.stdout.write(
    JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput } }),
  );
}

/**
 * Copy this file to `<home>/.claude/hooks/` and register it as a user-level
 * PreToolUse hook in `<home>/.claude/settings.json`. Idempotent; the previous
 * settings file is kept as a `.bak-subagent-wait-slice` copy.
 * @param {string} homeDir The user's home directory.
 * @returns {string[]} What was done, one line each.
 */
export function install(homeDir) {
  const self = fileURLToPath(import.meta.url);
  const claudeDir = path.join(homeDir, '.claude');
  const target = path.join(claudeDir, 'hooks', HOOK_FILE);
  const settingsPath = path.join(claudeDir, 'settings.json');
  const done = [];

  mkdirSync(path.dirname(target), { recursive: true });
  if (path.resolve(self) !== path.resolve(target)) {
    copyFileSync(self, target);
    done.push(`copied hook -> ${target}`);
  }

  const raw = existsSync(settingsPath) ? readFileSync(settingsPath, 'utf8') : '{}';
  const settings = JSON.parse(raw.replace(/^﻿/, ''));
  settings.hooks ??= {};
  settings.hooks.PreToolUse ??= [];
  const registered = settings.hooks.PreToolUse.some((entry) =>
    (entry?.hooks ?? []).some((hook) => String(hook?.command ?? '').includes(HOOK_FILE)),
  );
  if (registered) {
    done.push('already registered in settings.json');
    return done;
  }
  const command = `node "${target.replace(/\\/g, '/')}"`;
  settings.hooks.PreToolUse.push({
    matcher: 'Bash|PowerShell',
    hooks: [{ type: 'command', command, timeout: 10 }],
  });
  if (existsSync(settingsPath)) {
    const backup = `${settingsPath}.bak-subagent-wait-slice`;
    writeFileSync(backup, raw);
    done.push(`backup: ${backup}`);
  }
  writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
  done.push(`registered: ${command}`);
  done.push('new sessions pick it up; running sessions keep their old hook list');
  return done;
}

if (process.argv[1]?.endsWith(HOOK_FILE)) {
  if (process.argv.includes('--install')) {
    console.log(install(os.homedir()).join('\n'));
  } else {
    await main();
  }
}
