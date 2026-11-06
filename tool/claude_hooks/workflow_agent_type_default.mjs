// PreToolUse hook (Workflow): default every workflow agent() call to the trimmed `general` agent
// type (.claude/agents/general.md) and pin the model by agent type.
//
// A workflow agent() without opts.agentType runs as the built-in workflow-subagent, which carries
// 26 tool schemas (Artifact, SendUserFile, plugin / skill suggesters, session tools, visualize...)
// plus the skills list: ~55k baseline tokens re-read on every turn (2026-11-05 audit: workflow
// subagents were 19% of all spend; measured 55.6k -> 33.2k with `general`). An explicit
// opts.agentType in the script still wins.
//
// The model map mirrors subagent_model_router.mjs. As of Claude Code 2.1.310 the workflow runtime
// ignores opts.model (measured: requested sonnet, served Opus), so today only agentType takes
// effect; the model pin starts working once the runtime honours it.
//
// Rewrite: every code-position call `agent(` becomes `__wfAgent(` (strings, template text,
// comments and `x.agent(` are left alone), and a one-line helper is inserted right after the
// `export const meta = {...}` literal. Idempotent via MARKER. Byte-identical output to
// ~/.claude/hooks/workflow_agent_type_default.py on the maintainer's machine; keep both in sync.

import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const DEFAULT_TYPE = 'general';
export const MARKER = '/*wf-agent-default*/';
/** Kept as a literal so the output matches the Python twin (json.dumps spacing). */
const TYPE_MODEL_JSON = '{"scout": "sonnet", "worker": "sonnet", "general": "opus", "reviewer": "opus"}';
export const HELPER =
  `${MARKER} const __wfAgent = (p, o) => { const q = Object.assign({agentType: '${DEFAULT_TYPE}'}, o || {}); ` +
  `const m = ${TYPE_MODEL_JSON}[q.agentType]; if (m) q.model = m; return agent(p, q); };\n`;

/**
 * Index just past the closing brace of the `export const meta = {` literal, or null.
 * @param {string} script
 * @returns {number | null}
 */
export function metaEnd(script) {
  const m = /export\s+const\s+meta\s*=\s*\{/.exec(script);
  if (!m) return null;
  let depth = 0;
  let quote = null;
  for (let i = m.index + m[0].length - 1; i < script.length; i++) {
    const ch = script[i];
    if (quote) {
      if (ch === '\\') i++;
      else if (ch === quote) quote = null;
    } else if (ch === "'" || ch === '"' || ch === '`') {
      quote = ch;
    } else if (ch === '{') {
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0) {
        let j = i + 1;
        while (j < script.length && ' \t;'.includes(script[j])) j++;
        return j;
      }
    }
  }
  return null;
}

/**
 * Replace `agent(` with `__wfAgent(` only in code positions.
 * @param {string} body
 * @returns {string}
 */
export function rewriteCalls(body) {
  const out = [];
  const n = body.length;
  /** @type {Array<{kind: 'code', depth: number} | {kind: 'tpl'}>} */
  const stack = [{ kind: 'code', depth: 0 }];
  let i = 0;
  while (i < n) {
    const ctx = stack[stack.length - 1];
    const ch = body[i];
    if (ctx.kind === 'tpl') {
      if (ch === '\\') { out.push(body.slice(i, i + 2)); i += 2; continue; }
      if (ch === '`') { stack.pop(); out.push(ch); i++; continue; }
      if (body.startsWith('${', i)) { stack.push({ kind: 'code', depth: 0 }); out.push('${'); i += 2; continue; }
      out.push(ch); i++; continue;
    }
    if (body.startsWith('//', i)) {
      let j = body.indexOf('\n', i); if (j < 0) j = n;
      out.push(body.slice(i, j)); i = j; continue;
    }
    if (body.startsWith('/*', i)) {
      let j = body.indexOf('*/', i + 2); j = j < 0 ? n : j + 2;
      out.push(body.slice(i, j)); i = j; continue;
    }
    if (ch === "'" || ch === '"') {
      let j = i + 1;
      while (j < n && body[j] !== ch && body[j] !== '\n') j += body[j] === '\\' ? 2 : 1;
      out.push(body.slice(i, j + 1)); i = j + 1; continue;
    }
    if (ch === '`') { stack.push({ kind: 'tpl' }); out.push(ch); i++; continue; }
    if (ch === '{') {
      ctx.depth++;
    } else if (ch === '}') {
      if (ctx.depth === 0 && stack.length > 1) { stack.pop(); out.push(ch); i++; continue; }
      ctx.depth--;
    }
    if (body.startsWith('agent(', i) && (i === 0 || !/[\w.$]/.test(body[i - 1]))) {
      out.push('__wfAgent('); i += 'agent('.length; continue;
    }
    out.push(ch); i++;
  }
  return out.join('');
}

/** @param {string} script @returns {string} */
export function rewrite(script) {
  if (script.includes(MARKER)) return script;
  const end = metaEnd(script);
  if (end === null) return script;
  const head = script.slice(0, end);
  const body = script.slice(end);
  const newBody = rewriteCalls(body);
  if (newBody === body) return script;
  return `${head}\n${HELPER}${newBody.replace(/^\n+/, '')}`;
}

/** @param {string} raw @returns {string} stdout payload ('' = no change) */
export function handle(raw) {
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return '';
  }
  if (event?.tool_name !== 'Workflow') return '';
  const input = { ...(event.tool_input ?? {}) };
  if (typeof input.scriptPath === 'string' && input.scriptPath) {
    // Iteration path: rewrite the persisted script file in place (idempotent).
    let old;
    try {
      old = readFileSync(input.scriptPath, 'utf8');
    } catch {
      return '';
    }
    const updated = rewrite(old);
    if (updated !== old) writeFileSync(input.scriptPath, updated, 'utf8');
    return '';
  }
  if (typeof input.script !== 'string') return '';
  const updated = rewrite(input.script);
  if (updated === input.script) return '';
  input.script = updated;
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput: input } });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => (raw += chunk));
  process.stdin.on('end', () => process.stdout.write(handle(raw)));
}
