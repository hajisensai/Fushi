// PreToolUse hook (Agent / Task): pin the subagent model by subagent_type, and redirect
// general-purpose to the trimmed project agent `general` (.claude/agents/general.md).
//
// Only subagent_type decides the model; the prompt text and any `model` passed in the call are
// ignored, so conversation framing cannot change the routing. Types not listed pass through
// untouched (fork, Explore, claude-code-guide...).
//
// Why the redirect: built-in general-purpose carries every tool schema, the skills list and the
// MCP / session prompt sections (~54k baseline tokens re-read on every turn). `general` is the
// same Opus role with only the tools subagents actually use (2026-11-05 audit: first-turn
// baseline 51.9k -> 34.3k in this repo). Same logic as ~/.claude/hooks/subagent_model_router.py
// on the maintainer's machine; keep both in sync.

import { pathToFileURL } from 'node:url';

/** @type {ReadonlySet<string>} */
export const SONNET_TYPES = new Set(['scout', 'worker']);
/** @type {ReadonlySet<string>} */
export const OPUS_TYPES = new Set(['reviewer', 'general', 'general-purpose', 'claude', 'Plan']);
/** @type {Readonly<Record<string, string>>} */
export const REDIRECT_TYPES = { 'general-purpose': 'general' };

/**
 * @param {string | undefined | null} subagentType
 * @returns {'sonnet' | 'opus' | null}
 */
export function pinnedModel(subagentType) {
  const kind = subagentType || 'general-purpose';
  if (SONNET_TYPES.has(kind)) return 'sonnet';
  if (OPUS_TYPES.has(kind)) return 'opus';
  return null;
}

/**
 * Returns the rewritten tool input, or null when the call needs no change.
 * @param {Record<string, unknown>} original
 * @returns {Record<string, unknown> | null}
 */
export function routeAgentInput(original) {
  const input = { ...original };
  const kind = /** @type {string} */ (input.subagent_type || 'general-purpose');
  const redirected = REDIRECT_TYPES[kind];
  // Forks / named teammates keep their own semantics; only plain dispatches are redirected.
  if (redirected && !input.name && !input.team_name) input.subagent_type = redirected;
  const model = pinnedModel(/** @type {string | undefined} */ (input.subagent_type));
  if (model === null) return null;
  if (input.model === model && input.subagent_type === original.subagent_type) return null;
  input.model = model;
  return input;
}

/** @param {string} raw @returns {string} stdout payload ('' = no change) */
export function handle(raw) {
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return '';
  }
  if (event?.tool_name !== 'Agent' && event?.tool_name !== 'Task') return '';
  const updated = routeAgentInput(event.tool_input ?? {});
  if (updated === null) return '';
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: `subagent model pinned to ${updated.model} by subagent_type`,
      updatedInput: updated,
    },
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => (raw += chunk));
  process.stdin.on('end', () => process.stdout.write(handle(raw)));
}
