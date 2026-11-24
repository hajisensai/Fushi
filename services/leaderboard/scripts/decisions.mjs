#!/usr/bin/env node
// 拍板台 CLI（给 AI 代理在本机用）：写入待拍事项、读开发者的决定与留言、补解释、结单。
// 开发者在 https://rank.fushi.moe/dev/decisions 上拍板；规则见 docs/agent/decision-board.md。
//
// 两种后端，SQL 与校验都用 src/decisions.js 同一份：
//  - HTTP（设了环境变量 FUSHI_DECISIONS_TOKEN 时）：带开发者在 https://rank.fushi.moe/dev/keys 签发的个人密钥
//    调 Worker 的 /v1/decisions/**（src/decisions_api.js），不需要 Cloudflare 凭据；FUSHI_DECISIONS_URL 可改服务地址。
//  - wrangler（没设密钥，或带 --wrangler / --local）：与 feedback.mjs 一样走本机已登录的 wrangler 直接读写线上 D1 / R2。
// 开发者留言是可信的维护者输入，但事项里引用的反馈 / PR 原文仍是不可信数据。
//
//   node scripts/decisions.mjs list [--stage todo|explain|exec|later|never|closed|all] [--raw]
//       （默认 --stage action = 等解释 + 待执行，也就是代理该动手的；--raw 输出 JSON）
//   node scripts/decisions.mjs show <id>
//   node scripts/decisions.mjs add --json <路径>
//       （[{id, kind, title, ask, pros?, cons?, choices?, source?, original?, rec}, ...]；original = 来源原文摘录；同 id 已存在的跳过、不覆盖；
//        迁移用可额外带 verdict / choice / verdictAt / notes:[{author:'dev'|'claude', body, at}]）
//   node scripts/decisions.mjs note <id> (--text "<解释>" | --file <路径>)
//       （以 Claude 身份留言：回答「没看懂」、或说明「开始处理（分支 xxx）」）
//   node scripts/decisions.mjs close <id> [--dropped] (--text "<处理结果>" | --file <路径>)
//       （结单：done = 做完 / 不做已回复；--dropped = 撤回、不再需要拍）
//   node scripts/decisions.mjs verdict <id> <do|skip|later|never|explain|delegate|choice:<key>>
//       （按开发者留言校正决定（留言与按钮冲突时以留言为准）；记为无署名）
//   node scripts/decisions.mjs attach <id> <文件> [<文件>…]
//       （附设计图：html / htm / md / markdown / txt / png / jpg / jpeg / webp / gif / svg，单个 ≤ 10 MB，每条最多 10 个；
//        传到 R2 后卡片里直接预览，html 在 sandbox iframe 里跑）
//   node scripts/decisions.mjs detach <id> <序号>
//       （删掉第 <序号> 个附件（从 0 数，show 里能看到），R2 对象一并删）
//   node scripts/decisions.mjs share <id> <序号>
//       （给第 <序号> 个附件签发公开分享链接（不登录可看，只读），打印链接；已分享过就打印原来那条。只在 HTTP 模式可用：
//        链接记在密钥所属开发者名下，账户被撤开发者后失效）
//   node scripts/decisions.mjs unshare <id> <序号>
//       （撤销第 <序号> 个附件的公开链接，原链接立刻 404。只在 HTTP 模式可用）
//   node scripts/decisions.mjs files <id> [--out <目录>]
//       （把这条的全部附件从 R2 下到本地（默认 ./decision-files/<id>/），含开发者在网页上拖进去的设计图 / 截图）
//   全局：--local（读写 wrangler 本地 D1，调试用；默认 --remote）
//         --wrangler（设了 FUSHI_DECISIONS_TOKEN 也强制走 wrangler）
//   HTTP 模式：先设 FUSHI_DECISIONS_TOKEN=fdk_…（在 https://rank.fushi.moe/dev/keys 签发），命令照旧；add 不收迁移字段 verdict / notes
//

import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ADD_NOTE_SQL, CLOSE_DECISION_SQL, DECISION_FILE_TYPES, DECISION_ID_RE, DECISION_LIMITS, DECISION_VERDICTS,
  INSERT_DECISION_SQL, LIST_DECISIONS_SQL, LIST_NOTES_SQL, SET_FILES_SQL, SET_VERDICT_SQL, cleanDecisionText,
  decisionFileType, decisionOriginal, decisionStage, inDecisionStage, insertDecisionArgs, normalizeDecision,
  parseChoices, parseDecisionFiles,
} from '../src/decisions.js';
import { BUCKET, d1, d1Write, inlineSql, r2WhereArgs, wrangler } from './feedback.mjs';

/** argv → { cmd, id, rest, flags }：--stage / --text / --file / --json 吃下一个参数，其余 flag 是布尔。 */
export function parseArgs(argv) {
  const valued = new Set(['--stage', '--text', '--file', '--json', '--out']);
  const flags = {};
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) pos.push(a);
    else if (valued.has(a)) {
      if (i + 1 >= argv.length) throw new Error(`${a} 需要一个值`);
      flags[a.slice(2)] = argv[++i];
    } else flags[a.slice(2)] = true;
  }
  return { cmd: pos[0] ?? 'help', id: pos[1] ?? null, rest: pos.slice(2), flags };
}

function checkId(id) {
  if (typeof id !== 'string' || !DECISION_ID_RE.test(id)) throw new Error(`事项 id 不合法：${id}`);
  return id;
}

function readText(flags, field = '--text') {
  if (typeof flags.file === 'string') return readFileSync(flags.file, 'utf8');
  if (typeof flags.text === 'string') return flags.text;
  throw new Error(`需要 ${field} "<内容>" 或 --file <路径>`);
}

const stmt = (sql, args) => `${inlineSql(sql, args)};`;

/**
 * add 的整批 SQL。条目先全部校验，任一不合法整批不写。迁移字段（verdict / notes）只在新插入时生效：
 * 用 INSERT ... SELECT ... WHERE 原行是本批刚插入的（created_at = now 且 updated_at = now 且无 verdict）来防覆盖。
 * @param {unknown[]} list
 * @param {number} now
 * @returns {{sql: string, ids: string[]}}
 */
export function addSql(list, now) {
  if (!Array.isArray(list) || !list.length) throw new Error('--json 必须是非空数组');
  const ids = new Set();
  const out = [];
  for (const raw of list) {
    const d = normalizeDecision(raw);
    if (ids.has(d.id)) throw new Error(`本批 id 重复：${d.id}`);
    ids.add(d.id);
    out.push(stmt(INSERT_DECISION_SQL, insertDecisionArgs(d, now)));
    if (raw.verdict !== undefined) {
      const v = String(raw.verdict);
      if (!(v in DECISION_VERDICTS)) throw new Error(`${d.id}: verdict 不合法：${v}`);
      const choice = v === 'choice' ? String(raw.choice ?? '') : null;
      if (v === 'choice' && !parseChoices(d.choices).some((c) => c.key === choice)) throw new Error(`${d.id}: choice 不在 choices 里`);
      const at = Number.isSafeInteger(raw.verdictAt) ? raw.verdictAt : now;
      out.push(`${inlineSql(SET_VERDICT_SQL, [d.id, v, choice, null, at, now])} AND verdict IS NULL AND created_at = ${now};`);
    }
    for (const n of raw.notes || []) {
      const author = n.author === 'claude' ? 'claude' : 'dev';
      const body = cleanDecisionText(n.body, DECISION_LIMITS.noteMax, `${d.id}: note`);
      if (!body) continue;
      const at = Number.isSafeInteger(n.at) ? n.at : now;
      out.push(`INSERT INTO decision_notes (decision_id, author, account_id, body, created_at) SELECT ${
        inlineSql('?1, ?2, NULL, ?3, ?4', [d.id, author, body, at])} WHERE EXISTS (SELECT 1 FROM decisions WHERE id = ${
        inlineSql('?1', [d.id])} AND created_at = ${now});`);
    }
  }
  return { sql: out.join('\n'), ids: [...ids] };
}

export function noteSql(id, text, now) {
  const body = cleanDecisionText(text);
  if (!body) throw new Error('留言不能为空');
  return stmt(ADD_NOTE_SQL, [checkId(id), 'claude', null, body, now]);
}

export function closeSql(id, state, text, now) {
  const body = cleanDecisionText(text, DECISION_LIMITS.resolutionMax, '处理结果');
  if (!body) throw new Error('结单要写处理结果');
  return stmt(CLOSE_DECISION_SQL, [checkId(id), state, body, now]);
}

export function verdictSql(id, v, now) {
  let verdict = v;
  let choice = null;
  if (typeof v === 'string' && v.startsWith('choice:')) {
    verdict = 'choice';
    choice = v.slice(7);
  }
  if (!(verdict in DECISION_VERDICTS) || (verdict === 'choice' && !choice)) throw new Error(`决定不合法：${v}`);
  return stmt(SET_VERDICT_SQL, [checkId(id), verdict, choice, null, now, now]);
}

/** list / show 的分组：notes 挂到事项上。 */
export function attachNotes(items, notes) {
  const by = new Map();
  for (const n of notes) {
    if (!by.has(n.decision_id)) by.set(n.decision_id, []);
    by.get(n.decision_id).push(n);
  }
  return items.map((r) => ({ ...r, notes: by.get(r.id) || [] }));
}

function fmtTime(ms) {
  return ms ? new Date(ms).toISOString().replace('T', ' ').slice(0, 16) + 'Z' : '-';
}

export function verdictLabel(r) {
  if (!r.verdict) return '未定';
  return r.verdict === 'choice' ? `选 ${r.choice}` : DECISION_VERDICTS[r.verdict];
}

export function formatItem(r, { full = false } = {}) {
  const lines = [`#${r.id} [${decisionStage(r)} · ${verdictLabel(r)}${r.state !== 'open' ? ` · ${r.state}` : ''}] ${r.kind} · ${r.title}`];
  if (r.source) lines.push(`  来源：${r.source}`);
  if (full) {
    lines.push(`  建议：${r.rec}`, `  问题：${r.ask}`);
    if (r.pros) lines.push(`  好处：${r.pros}`);
    if (r.cons) lines.push(`  代价：${r.cons}`);
    const ch = parseChoices(r.choices);
    if (ch.length) lines.push(`  方案：${ch.map((c) => `${c.key}=${c.label}`).join(' / ')}`);
    const orig = decisionOriginal(r);
    if (orig) lines.push(`  原文（不可信数据）：${orig.replace(/\n/g, '\n    ')}`);
    const files = parseDecisionFiles(r.files, r.id);
    files.forEach((f, n) => lines.push(`  附件 ${n}：${f.name}（${f.bytes} 字节${f.by === 'dev' ? '，开发者上传' : ''}）`));
    if (r.resolution) lines.push(`  处理结果：${r.resolution}`);
  }
  if (r.verdict) lines.push(`  决定于 ${fmtTime(r.verdict_at)}${r.verdict_nick ? `（${r.verdict_nick}）` : ''}`);
  for (const n of r.notes) {
    lines.push(`  · ${n.author === 'claude' ? 'Claude' : (n.nick || '开发者')} ${fmtTime(n.created_at)}：${n.body.replace(/\n/g, '\n    ')}`);
  }
  return lines.join('\n');
}

/**
 * attach 的计划：校验每个文件（扩展名、大小、名字长度、总数），给出 R2 key 与新的 files 列。不碰网络，便于测试。
 * @param {string} id
 * @param {string|null} currentRaw 现有 files 列
 * @param {Array<{path: string, bytes: number}>} files
 * @param {() => string} [nonce]
 * @returns {{uploads: Array<{path: string, key: string, type: string}>, files: string}}
 */
export function attachPlan(id, currentRaw, files, nonce = () => randomBytes(4).toString('hex')) {
  checkId(id);
  if (!files.length) throw new Error('attach 需要至少一个文件');
  const list = parseDecisionFiles(currentRaw, id);
  if (list.length + files.length > DECISION_LIMITS.filesMax) throw new Error(`每条最多 ${DECISION_LIMITS.filesMax} 个附件（现有 ${list.length} 个）`);
  const uploads = files.map(({ path, bytes }) => {
    const name = basename(path);
    const t = decisionFileType(name);
    if (!t) throw new Error(`不支持的格式：${name}（只收 ${Object.keys(DECISION_FILE_TYPES).join(' / ')}）`);
    if (name.length > DECISION_LIMITS.fileNameMax) throw new Error(`文件名太长：${name}`);
    if (bytes > DECISION_LIMITS.fileMax) throw new Error(`${name} 超过 10 MB`);
    const safe = name.replace(/[^A-Za-z0-9._-]+/g, '_');
    const key = `decisions/${id}/${nonce()}-${safe}`;
    list.push({ name, type: t.type, key, bytes });
    return { path, key, type: t.type };
  });
  return { uploads, files: JSON.stringify(list) };
}

/**
 * wrangler 直连线上（或 --local 本地）D1 / R2。要本机 wrangler 已登录 Cloudflare（维护者机器）。
 * @param {'--remote'|'--local'} where
 */
export function wranglerBackend(where) {
  const loadFiles = (id) => {
    const [rows] = d1(inlineSql('SELECT files FROM decisions WHERE id = ?1', [checkId(id)]), where);
    if (!rows.length) throw new Error(`没有这条：${id}`);
    return rows[0].files;
  };
  return {
    mode: 'wrangler',
    async loadAll() {
      const [items] = d1(LIST_DECISIONS_SQL, where);
      const [notes] = d1(LIST_NOTES_SQL, where);
      return attachNotes(items, notes);
    },
    async add(list, now) {
      const { sql, ids } = addSql(list, now);
      const [before] = d1(`SELECT id FROM decisions WHERE id IN (${ids.map((x) => inlineSql('?1', [x])).join(', ')})`, where);
      d1Write(sql, where);
      const skipped = before.map((r) => r.id);
      return { inserted: ids.filter((x) => !skipped.includes(x)), skipped };
    },
    async note(id, text, now) {
      d1Write(noteSql(id, text, now), where);
    },
    async close(id, state, text, now) {
      d1Write(closeSql(id, state, text, now), where);
    },
    async verdict(id, v, now) {
      d1Write(verdictSql(id, v, now), where);
    },
    async attach(id, paths, now) {
      const plan = attachPlan(id, loadFiles(id), paths.map((p) => ({ path: p, bytes: statSync(p).size })));
      for (const u of plan.uploads) {
        wrangler(['r2', 'object', 'put', `${BUCKET}/${u.key}`, '--file', u.path, '--content-type', u.type, ...r2WhereArgs(where)]);
      }
      d1Write(stmt(SET_FILES_SQL, [id, plan.files, now]), where);
      return plan.uploads.map((u) => basename(u.path));
    },
    async listFiles(id) {
      return parseDecisionFiles(loadFiles(id), id);
    },
    async download(id, n, f, path) {
      wrangler(['r2', 'object', 'get', `${BUCKET}/${f.key}`, '--file', path, ...r2WhereArgs(where)]);
    },
    async detach(id, n, now) {
      const list = parseDecisionFiles(loadFiles(id), id);
      if (!Number.isInteger(n) || !list[n]) throw new Error(`没有第 ${n} 个附件（共 ${list.length} 个，从 0 数）`);
      const [gone] = list.splice(n, 1);
      d1Write(stmt(SET_FILES_SQL, [id, JSON.stringify(list), now]), where);
      wrangler(['r2', 'object', 'delete', `${BUCKET}/${gone.key}`, ...r2WhereArgs(where)]);
      return gone.name;
    },
    async share() {
      throw new Error(SHARE_NEEDS_HTTP);
    },
    async unshare() {
      throw new Error(SHARE_NEEDS_HTTP);
    },
  };
}

/** 分享链接要记签发的开发者（账户被撤开发者后失效），wrangler 直连 D1 没有账户身份。 */
const SHARE_NEEDS_HTTP = 'share / unshare 只在 HTTP 模式可用（设 FUSHI_DECISIONS_TOKEN），或在网页附件旁点「分享」';

export const DEFAULT_DECISIONS_URL = 'https://rank.fushi.moe';

/**
 * 经 HTTPS 调 Worker 的 /v1/decisions/**（src/decisions_api.js），凭开发者在 /dev/keys 签发的个人密钥。
 * 不需要 Cloudflare 凭据；校验与 SQL 在服务端，与 wrangler 模式同一份。
 * @param {{token: string, base?: string, fetchImpl?: typeof fetch}} opts
 */
export function httpBackend({ token, base = DEFAULT_DECISIONS_URL, fetchImpl = globalThis.fetch }) {
  const root = base.replace(/\/+$/, '');
  async function call(method, path, { body, bytes, type } = {}) {
    const headers = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
    let payload;
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      payload = JSON.stringify(body);
    } else if (bytes) {
      headers['Content-Type'] = type;
      payload = bytes;
    }
    const res = await fetchImpl(root + path, { method, headers, body: payload });
    if (!res.ok) {
      let msg = res.statusText || '';
      try {
        const j = await res.json();
        msg = `${j.error}${j.detail ? `：${j.detail}` : ''}`;
      } catch { /* 非 JSON 错误体：用状态文本 */ }
      const hint = res.status === 401 ? '（密钥无效 / 已吊销，或账户已不是开发者；到 /dev/keys 重签）' : '';
      throw new Error(`HTTP ${res.status} ${msg}${hint}`);
    }
    return res;
  }
  const getJson = async (method, path, opts) => (await call(method, path, opts)).json();
  return {
    mode: 'http',
    async loadAll() {
      return (await getJson('GET', '/v1/decisions')).items;
    },
    async add(list) {
      if (!Array.isArray(list) || !list.length) throw new Error('--json 必须是非空数组');
      return getJson('POST', '/v1/decisions', { body: { items: list } });
    },
    async note(id, text) {
      await call('POST', `/v1/decisions/${checkId(id)}/notes`, { body: { text } });
    },
    async close(id, state, text) {
      await call('POST', `/v1/decisions/${checkId(id)}/close`, { body: { state, text } });
    },
    async verdict(id, v) {
      await call('POST', `/v1/decisions/${checkId(id)}/verdict`, { body: { v } });
    },
    async attach(id, paths) {
      const { item } = await getJson('GET', `/v1/decisions/${checkId(id)}`);
      // 先在本地按同一套规则把整批校验完，任一不合法一个都不传。
      const plan = attachPlan(id, item.files, paths.map((p) => ({ path: p, bytes: statSync(p).size })));
      for (const u of plan.uploads) {
        await call('POST', `/v1/decisions/${id}/files?name=${encodeURIComponent(basename(u.path))}`, {
          bytes: readFileSync(u.path), type: u.type,
        });
      }
      return plan.uploads.map((u) => basename(u.path));
    },
    async listFiles(id) {
      const { item } = await getJson('GET', `/v1/decisions/${checkId(id)}`);
      return parseDecisionFiles(item.files, id);
    },
    async download(id, n, f, path) {
      const res = await call('GET', `/v1/decisions/${checkId(id)}/files/${n}`);
      writeFileSync(path, new Uint8Array(await res.arrayBuffer()));
    },
    async detach(id, n) {
      if (!Number.isInteger(n) || n < 0) throw new Error(`附件序号不合法：${n}`);
      return (await getJson('DELETE', `/v1/decisions/${checkId(id)}/files/${n}`)).removed;
    },
    async share(id, n) {
      if (!Number.isInteger(n) || n < 0) throw new Error(`附件序号不合法：${n}`);
      return getJson('POST', `/v1/decisions/${checkId(id)}/files/${n}/share`);
    },
    async unshare(id, n) {
      if (!Number.isInteger(n) || n < 0) throw new Error(`附件序号不合法：${n}`);
      return getJson('DELETE', `/v1/decisions/${checkId(id)}/files/${n}/share`);
    },
  };
}

/**
 * 选后端：设了 FUSHI_DECISIONS_TOKEN 就走 HTTP（没有 Cloudflare 凭据的开发者用这个）；
 * --local / --wrangler 或没设密钥时走 wrangler。
 * @param {Record<string, string|boolean>} flags
 * @param {Record<string, string|undefined>} [env]
 */
export function pickBackend(flags, env = process.env) {
  const token = (env.FUSHI_DECISIONS_TOKEN || '').trim();
  if (flags.local || flags.wrangler || !token) return wranglerBackend(flags.local ? '--local' : '--remote');
  return httpBackend({ token, base: env.FUSHI_DECISIONS_URL || DEFAULT_DECISIONS_URL });
}

const HELP = readFileSync(fileURLToPath(import.meta.url), 'utf8')
  .split('\n').filter((l) => l.startsWith('//   ')).map((l) => l.slice(5)).join('\n');

/**
 * @param {string[]} argv
 * @param {(line: string) => void} [out]
 * @param {{backend?: ReturnType<typeof wranglerBackend>}} [deps] 测试注入
 */
export async function main(argv, out = console.log, deps = {}) {
  const { cmd, id, rest, flags } = parseArgs(argv);
  const backend = deps.backend ?? pickBackend(flags);
  const now = Date.now();
  if (cmd === 'list') {
    const stage = flags.stage || 'action';
    const all = await backend.loadAll();
    const rows = stage === 'action'
      ? all.filter((r) => inDecisionStage(r, 'explain') || inDecisionStage(r, 'exec'))
      : all.filter((r) => inDecisionStage(r, stage));
    if (flags.raw) {
      out(JSON.stringify(rows.map((r) => ({ ...r, stage: decisionStage(r) })), null, 2));
      return;
    }
    out(`${stage}：${rows.length} 条（全部 ${all.length}）`);
    for (const r of rows) out(formatItem(r, { full: true }));
    return;
  }
  if (cmd === 'show') {
    const r = (await backend.loadAll()).find((x) => x.id === checkId(id));
    if (!r) throw new Error(`没有这条：${id}`);
    out(formatItem(r, { full: true }));
    return;
  }
  if (cmd === 'add') {
    if (typeof flags.json !== 'string') throw new Error('add 需要 --json <路径>');
    const { inserted, skipped } = await backend.add(JSON.parse(readFileSync(flags.json, 'utf8')), now);
    out(`写入 ${inserted.length} 条${skipped.length ? `；已存在跳过：${skipped.join(' ')}` : ''}`);
    return;
  }
  if (cmd === 'note') {
    await backend.note(checkId(id), readText(flags), now);
    out(`#${id} 已留言`);
    return;
  }
  if (cmd === 'close') {
    await backend.close(checkId(id), flags.dropped ? 'dropped' : 'done', readText(flags), now);
    out(`#${id} 已${flags.dropped ? '撤回' : '结单'}`);
    return;
  }
  if (cmd === 'attach') {
    const names = await backend.attach(checkId(id), rest, now);
    out(`#${id} 已附 ${names.length} 个文件：${names.join(' ')}`);
    return;
  }
  if (cmd === 'files') {
    const list = await backend.listFiles(checkId(id));
    if (!list.length) {
      out(`#${id} 没有附件`);
      return;
    }
    const dir = resolve(typeof flags.out === 'string' ? flags.out : join('decision-files', id));
    mkdirSync(dir, { recursive: true });
    for (const [n, f] of list.entries()) {
      // 序号前缀：同名文件（比如多次粘贴的 image.png）不互相覆盖；名字里的路径分隔符一律去掉。
      const path = join(dir, `${n}-${basename(f.name).replace(/[\\/:*?"<>|]/g, '_')}`);
      await backend.download(id, n, f, path);
      out(path);
    }
    return;
  }
  if (cmd === 'detach') {
    const name = await backend.detach(checkId(id), Number(rest[0]), now);
    out(`#${id} 已删附件：${name}`);
    return;
  }
  if (cmd === 'share') {
    const { url, created } = await backend.share(checkId(id), Number(rest[0]), now);
    out(`#${id} 第 ${rest[0]} 个附件${created ? '已分享' : '已有分享链接'}：${url}`);
    return;
  }
  if (cmd === 'unshare') {
    const { revoked, name } = await backend.unshare(checkId(id), Number(rest[0]), now);
    out(revoked ? `#${id} 已撤销 ${name} 的分享链接` : `#${id} ${name} 没有分享链接`);
    return;
  }
  if (cmd === 'verdict') {
    await backend.verdict(checkId(id), rest[0], now);
    out(`#${id} 决定改为 ${rest[0]}`);
    return;
  }
  out(HELP);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(`错误：${e.message}`);
    process.exit(1);
  });
}
