#!/usr/bin/env node
// Copies the root CLAUDE.md into each subagent definition (.claude/agents/*.md)
// and marks the definition `omitClaudeMd: true`.
//
// Why: a subagent normally gets the CLAUDE.md files as part of its *first user
// message*, right before its own task text. The prompt cache only reuses a prefix
// up to a breakpoint, and the first breakpoint after the system prompt sits after
// the task text — so every subagent wrote those ~10k tokens to the cache again
// (2026-11-21 audit: 467 agents in one session, ~19.5k tokens of fresh cache write
// each, 9.1M in total, while only ~20k of tools + system prompt were shared).
// The agent definition body *is* the subagent's system prompt, which sits before
// that breakpoint and is identical for every agent of one type, so the same rules
// placed there are written once and then read from the shared cache.
// `omitClaudeMd: true` (Claude Code agent frontmatter: "Run this agent without the
// user, project and local CLAUDE.md instruction files when it runs as a subagent";
// no effect on the main session) keeps them from being loaded twice.
//
//   node tool/claude_hooks/sync_agent_claude_md.mjs          rewrite the agent files
//   node tool/claude_hooks/sync_agent_claude_md.mjs --check  exit 1 when out of sync
//
// The guard in subagent_config.test.mjs runs in CI (ci-config-gate.yml), which also
// triggers on CLAUDE.md changes: edit CLAUDE.md, then run this script.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const AGENTS = ['general', 'reviewer', 'scout', 'worker'];
export const BEGIN =
  '<!-- BEGIN 仓库根 CLAUDE.md：由 tool/claude_hooks/sync_agent_claude_md.mjs 生成，勿手改；改 CLAUDE.md 后重跑该脚本 -->';
export const END = '<!-- END 仓库根 CLAUDE.md -->';
const PREAMBLE =
  '以下是仓库根 CLAUDE.md 的原文（本定义设了 `omitClaudeMd: true`，CLAUDE.md 不会再单独加载，' +
  '这里就是你要遵守的那份）。文中链接相对仓库根。进到带自己 CLAUDE.md / AGENTS.md 的子目录时 Read 那一份；' +
  '本机私有说明（如 Flutter SDK 路径）在仓库根 `CLAUDE.local.md`（不入库，可能不存在），需要时再 Read。';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));

/**
 * The agent definition with `omitClaudeMd: true` in its frontmatter and the
 * generated CLAUDE.md block at the end of its body (replacing an older block).
 *
 * @param {string} agentText current file content
 * @param {string} claudeMd root CLAUDE.md content
 * @returns {string}
 */
export function render(agentText, claudeMd) {
  const fm = /^---\n([\s\S]*?)\n---\n/.exec(agentText);
  if (!fm) throw new Error('agent definition has no frontmatter');
  let front = fm[1]
    .split('\n')
    .filter((line) => !/^omitClaudeMd\s*:/.test(line));
  const modelAt = front.findIndex((line) => /^model\s*:/.test(line));
  front.splice(modelAt === -1 ? front.length : modelAt + 1, 0, 'omitClaudeMd: true');
  let body = agentText.slice(fm[0].length);
  const begin = body.indexOf(BEGIN);
  if (begin !== -1) {
    const end = body.indexOf(END, begin);
    if (end === -1) throw new Error('generated block has no END marker');
    body = body.slice(0, begin) + body.slice(end + END.length);
  }
  body = body.replace(/\s+$/, '');
  const block = [BEGIN, PREAMBLE, '', claudeMd.replace(/\s+$/, ''), END].join('\n');
  return `---\n${front.join('\n')}\n---\n${body}\n\n${block}\n`;
}

/** @returns {{file: string, current: string, wanted: string}[]} */
export function plan() {
  const claudeMd = readFileSync(`${ROOT}CLAUDE.md`, 'utf8');
  return AGENTS.map((name) => {
    const file = `${ROOT}.claude/agents/${name}.md`;
    const current = readFileSync(file, 'utf8');
    return { file, current, wanted: render(current, claudeMd) };
  });
}

if (process.argv[1]?.endsWith('sync_agent_claude_md.mjs')) {
  const check = process.argv.includes('--check');
  const stale = plan().filter((p) => p.current !== p.wanted);
  if (check) {
    for (const p of stale) console.error(`out of sync: ${p.file}`);
    if (stale.length > 0) {
      console.error('run: node tool/claude_hooks/sync_agent_claude_md.mjs');
      process.exit(1);
    }
  } else {
    for (const p of stale) writeFileSync(p.file, p.wanted, 'utf8');
    console.log(`updated ${stale.length} of ${AGENTS.length} agent definitions`);
  }
}
