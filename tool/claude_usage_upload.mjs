#!/usr/bin/env node
// 把本机 Claude Code 的额度消耗按「UTC 日 × 模型」汇总，上传到 rank.fushi.moe/usage 展示。
// 只发计数（请求数 / input / output / 缓存读 / 缓存写），不发项目名、提示词或会话内容。
//
//   node tool/claude_usage_upload.mjs [--days 3] [--dry-run] [--projects <dir>]
//
// 配置（环境变量优先，其次 ~/.fushi/usage-upload.json）：
//   FUSHI_USAGE_TOKEN / token   服务端 secret USAGE_UPLOAD_TOKEN 的同值
//   FUSHI_USAGE_URL   / url     默认 https://rank.fushi.moe
//   FUSHI_USAGE_SOURCE / source 机器标签（小写字母数字 - _），默认主机名
//
// 统计口径：同一次 API 响应（message.id + requestId）在日志里会因流式落盘与 fork / 子代理复制父会话
// 出现多次，按它去重并取输出 token 最大的一条。每次上传整天的完整汇总，服务端整行覆盖，重复跑幂等。
// 只扫 mtime 在最近 --days 天内的日志：一天的数据只会在当天或之后修改过的文件里。
// 调度见 tool/install_claude_usage_upload.ps1。

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { join } from 'node:path';

const DAY_MS = 86400 * 1000;
const MAX_ROWS = 400;
// 与服务端 services/leaderboard/src/ai_usage.js 的 MODEL_RE 同一规则：不合规的模型名在本地丢弃，
// 否则服务端整批 400，之后每次定时上传都会因同一行失败。
export const MODEL_RE = /^[A-Za-z0-9._:@/-]{1,128}$/;

/**
 * @param {string[]} argv
 * @returns {{days: number, dryRun: boolean, projects: string}}
 */
export function parseArgs(argv) {
  const out = { days: 3, dryRun: false, projects: join(homedir(), '.claude', 'projects') };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--days') out.days = Math.max(1, Math.min(60, Number(argv[++i]) || 3));
    else if (argv[i] === '--dry-run') out.dryRun = true;
    else if (argv[i] === '--projects') out.projects = argv[++i];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return out;
}

/** @param {string} dir @param {number} sinceMs @returns {string[]} */
function* jsonlFiles(dir, sinceMs) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) yield* jsonlFiles(p, sinceMs);
    else if (e.name.endsWith('.jsonl') && statSync(p).mtimeMs >= sinceMs) yield p;
  }
}

/**
 * 汇总 projects 目录下最近 days 天的用量。
 * @param {string} projects
 * @param {number} days
 * @param {number} now
 * @returns {{day: string, model: string, requests: number, input: number, output: number, cacheRead: number, cacheWrite: number}[]}
 */
export function aggregate(projects, days, now = Date.now()) {
  // 对齐到 UTC 日零点：首日必须完整，否则不完整的首日会覆盖服务端上次传好的整天数据。
  const firstDay = new Date(now - days * DAY_MS).toISOString().slice(0, 10);
  const sinceMs = Date.parse(`${firstDay}T00:00:00Z`);
  /** @type {Map<string, {day: string, model: string, input: number, output: number, cacheRead: number, cacheWrite: number}>} */
  const calls = new Map();
  for (const file of jsonlFiles(projects, sinceMs)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (!line.includes('"usage"')) continue;
      let d;
      try {
        d = JSON.parse(line);
      } catch {
        continue;
      }
      const m = d.message;
      const u = m && m.usage;
      if (d.type !== 'assistant' || !u || typeof m.model !== 'string' || !MODEL_RE.test(m.model)) continue;
      const day = String(d.timestamp || '').slice(0, 10);
      if (day < firstDay) continue;
      const key = `${m.id}|${d.requestId}`;
      const rec = {
        day,
        model: m.model,
        input: u.input_tokens || 0,
        output: u.output_tokens || 0,
        cacheRead: u.cache_read_input_tokens || 0,
        cacheWrite: u.cache_creation_input_tokens || 0,
      };
      const prev = calls.get(key);
      if (!prev || rec.output >= prev.output) calls.set(key, rec);
    }
  }
  /** @type {Map<string, any>} */
  const rows = new Map();
  for (const c of calls.values()) {
    const k = `${c.day}|${c.model}`;
    let r = rows.get(k);
    if (!r) rows.set(k, (r = { day: c.day, model: c.model, requests: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }));
    r.requests++;
    r.input += c.input;
    r.output += c.output;
    r.cacheRead += c.cacheRead;
    r.cacheWrite += c.cacheWrite;
  }
  return [...rows.values()].sort((a, b) => a.day.localeCompare(b.day) || a.model.localeCompare(b.model));
}

/** @returns {{token?: string, url: string, source: string}} */
function loadConfig() {
  let file = {};
  const p = join(homedir(), '.fushi', 'usage-upload.json');
  if (existsSync(p)) file = JSON.parse(readFileSync(p, 'utf8'));
  const source = (process.env.FUSHI_USAGE_SOURCE || file.source || hostname()).toLowerCase().replace(/[^a-z0-9_-]/g, '-').slice(0, 32);
  return {
    token: process.env.FUSHI_USAGE_TOKEN || file.token,
    url: (process.env.FUSHI_USAGE_URL || file.url || 'https://rank.fushi.moe').replace(/\/$/, ''),
    source,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rows = aggregate(args.projects, args.days);
  const cfg = loadConfig();
  console.log(`rows=${rows.length} source=${cfg.source} days=${args.days}`);
  if (args.dryRun) {
    for (const r of rows) console.log(JSON.stringify(r));
    return;
  }
  if (!cfg.token) throw new Error('missing token: set FUSHI_USAGE_TOKEN or ~/.fushi/usage-upload.json');
  if (!rows.length) return;
  for (let i = 0; i < rows.length; i += MAX_ROWS) {
    const res = await fetch(`${cfg.url}/v1/ci/usage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.token}` },
      body: JSON.stringify({ source: cfg.source, rows: rows.slice(i, i + MAX_ROWS) }),
      signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) throw new Error(`upload failed: HTTP ${res.status} ${await res.text()}`);
    console.log(`uploaded ${Math.min(MAX_ROWS, rows.length - i)} rows`);
  }
}

if (import.meta.url === new URL(process.argv[1], 'file://').href || process.argv[1]?.endsWith('claude_usage_upload.mjs')) {
  main().catch((e) => {
    console.error(String(e.message || e));
    process.exit(1);
  });
}
