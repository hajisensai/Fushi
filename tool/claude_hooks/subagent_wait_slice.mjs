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
// timeout (default 120 s) are left alone. Enable in .claude/settings.json:
//
//   "hooks": { "PreToolUse": [ { "matcher": "Bash|PowerShell", "hooks": [
//     { "type": "command", "command": "node tool/claude_hooks/subagent_wait_slice.mjs" } ] } ] }

/** 4.5 minutes: margin under the 5-minute TTL for the request round trip. */
export const SUBAGENT_FOREGROUND_TIMEOUT_MS = 270000;

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
  if (input.run_in_background === true) return null;
  if (typeof input.timeout !== 'number' || !(input.timeout > SUBAGENT_FOREGROUND_TIMEOUT_MS)) {
    return null;
  }
  // updatedInput replaces the whole tool input, so every other field rides along.
  return { ...input, timeout: SUBAGENT_FOREGROUND_TIMEOUT_MS };
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

if (process.argv[1]?.endsWith('subagent_wait_slice.mjs')) {
  await main();
}
