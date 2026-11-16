// 拍板台（迁移 0020）：AI 代理写入待拍事项，开发者在处理台 /dev/decisions 拍板，代理按结果执行后结单。
//
//   GET  /dev/decisions?stage=todo|explain|exec|later|never|closed|all   列表（默认 todo = 待拍）
//   GET  /dev/decisions.json?sig=…   客户端同步：签名没变回 {same:true}，变了回全部卡片 HTML
//   GET  /dev/decisions.js           客户端脚本（decisions_client.js）
//   POST /dev/d/:id   {v, text, back}   拍板并 / 或留言：v ∈ VERDICTS | choice:<key> | clear | note
//                                     Accept: application/json → 回这一条的新卡片（不跳转）；否则 303 回原栏
//
// 写入事项、补解释、结单走本机 CLI scripts/decisions.mjs（wrangler 直连 D1，与 feedback.mjs 同一套凭据），
// 网页只给开发者拍板和留言。SQL 与校验都在这里，CLI 与 Worker 共用一份。
//
// 六个决定（docs/agent/decision-board.md 写了代理拿到各个决定后怎么做）：
//   do 做（有 choices 时换成 choice:<key>） / skip 不做 / later 以后 / never 永远不做（进功能黑名单）
//   explain 没看懂（代理留 claude 留言解释，之后回到待拍） / delegate 你定（代理按自己的判断做）

import { HttpError } from './util.js';
import { esc } from './pages.js';

export const DECISION_KINDS = { pr: 'PR', feedback: '反馈', issue: 'Issue', review: '审查', design: '设计', other: '其他' };
export const DECISION_RECS = { do: '建议做', skip: '建议不做', never: '建议永远不做', later: '建议以后', weigh: '看取舍' };
export const DECISION_VERDICTS = {
  do: '做', choice: '选', skip: '不做', later: '以后', never: '永远不做', explain: '没看懂', delegate: '你定',
};
export const DECISION_STATES = ['open', 'done', 'dropped'];
export const DECISION_STAGES = [
  ['todo', '待拍'], ['explain', '等解释'], ['exec', '待执行'], ['later', '以后'], ['never', '永远不做'], ['closed', '已结'], ['all', '全部'],
];
export const DECISION_LIMITS = {
  idMax: 40, titleMax: 200, askMax: 6000, prosConsMax: 2000, sourceMax: 500, noteMax: 4000, resolutionMax: 4000,
  choicesMax: 6, choiceLabelMax: 60, listMax: 500,
};
export const DECISION_ID_RE = /^[A-Za-z0-9_-]{1,40}$/;
const CHOICE_KEY_RE = /^[a-z0-9]{1,8}$/;

/** 去掉控制字符（保留换行 / 制表），去首尾空白。 */
function clean(v, max, field, { required = false } = {}) {
  if (v === undefined || v === null || v === '') {
    if (required) throw new Error(`${field} 不能为空`);
    return null;
  }
  if (typeof v !== 'string') throw new Error(`${field} 必须是字符串`);
  // eslint-disable-next-line no-control-regex
  const s = v.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim();
  if (!s) {
    if (required) throw new Error(`${field} 不能为空`);
    return null;
  }
  if (s.length > max) throw new Error(`${field} 超过 ${max} 字`);
  return s;
}

/**
 * 写入方（CLI）给的一条事项 → 规范化后的行。不合法直接抛错（整批不写）。
 * @param {Record<string, unknown>} input
 * @returns {{id: string, kind: string, title: string, ask: string, pros: string|null, cons: string|null,
 *   choices: string|null, source: string|null, rec: string}}
 */
export function normalizeDecision(input) {
  if (!input || typeof input !== 'object') throw new Error('事项必须是对象');
  const id = typeof input.id === 'string' ? input.id.trim() : '';
  if (!DECISION_ID_RE.test(id)) throw new Error(`id 不合法：${input.id}（只允许字母数字 _ -，最长 40）`);
  const kind = input.kind ?? 'other';
  if (!(kind in DECISION_KINDS)) throw new Error(`${id}: kind 不合法：${kind}`);
  const rec = input.rec ?? 'weigh';
  if (!(rec in DECISION_RECS)) throw new Error(`${id}: rec 不合法：${rec}`);
  let choices = null;
  if (input.choices !== undefined && input.choices !== null) {
    if (!Array.isArray(input.choices) || input.choices.length < 2 || input.choices.length > DECISION_LIMITS.choicesMax) {
      throw new Error(`${id}: choices 要 2–${DECISION_LIMITS.choicesMax} 项`);
    }
    const seen = new Set();
    const list = input.choices.map((c) => {
      const key = c && typeof c.key === 'string' ? c.key.trim() : '';
      if (!CHOICE_KEY_RE.test(key) || seen.has(key)) throw new Error(`${id}: choice key 不合法或重复：${c && c.key}`);
      seen.add(key);
      return { key, label: clean(c.label ?? key, DECISION_LIMITS.choiceLabelMax, `${id}: choice label`, { required: true }) };
    });
    choices = JSON.stringify(list);
  }
  return {
    id,
    kind,
    title: clean(input.title, DECISION_LIMITS.titleMax, `${id}: title`, { required: true }),
    ask: clean(input.ask, DECISION_LIMITS.askMax, `${id}: ask`, { required: true }),
    pros: clean(input.pros, DECISION_LIMITS.prosConsMax, `${id}: pros`),
    cons: clean(input.cons, DECISION_LIMITS.prosConsMax, `${id}: cons`),
    choices,
    source: clean(input.source, DECISION_LIMITS.sourceMax, `${id}: source`),
    rec,
  };
}

/** 留言 / 结单说明的清洗：空白 → null。 */
export function cleanDecisionText(text, max = DECISION_LIMITS.noteMax, field = '留言') {
  return clean(text ?? '', max, field);
}

// ---- 共用 SQL（?N 占位；CLI 用 inlineSql 内联成字面量执行同一份语句） ----

/** 新事项；同 id 已存在则什么都不改（重复写入不覆盖开发者已拍的结果）。 */
export const INSERT_DECISION_SQL = `INSERT INTO decisions
  (id, kind, title, ask, pros, cons, choices, source, rec, state, created_at, updated_at)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'open', ?10, ?10)
  ON CONFLICT(id) DO NOTHING`;

export function insertDecisionArgs(d, now) {
  return [d.id, d.kind, d.title, d.ask, d.pros, d.cons, d.choices, d.source, d.rec, now];
}

export const SET_VERDICT_SQL = `UPDATE decisions SET verdict = ?2, choice = ?3, verdict_by = ?4, verdict_at = ?5, updated_at = ?6
  WHERE id = ?1 AND state = 'open'`;

/**
 * 网页拍板用的乐观锁版：只有当前决定仍是提交方看到的那个（?7，表单 v 的形式：'' / 'do' / 'choice:a' …）才写。
 * 两个开发者同时拍同一条时，后到的那次 changes = 0 → 409 verdict_conflict，不会悄悄覆盖先拍的人。
 */
export const SET_VERDICT_IF_SQL = `${SET_VERDICT_SQL}
  AND COALESCE(CASE WHEN verdict = 'choice' THEN 'choice:' || choice ELSE verdict END, '') = ?7`;

export const ADD_NOTE_SQL = `INSERT INTO decision_notes (decision_id, author, account_id, body, created_at)
  VALUES (?1, ?2, ?3, ?4, ?5)`;

export const CLOSE_DECISION_SQL = `UPDATE decisions SET state = ?2, resolution = ?3, updated_at = ?4 WHERE id = ?1`;

/** 列表：最近的 listMax 条，带拍板人昵称与最近一条 claude 留言的时刻。 */
export const LIST_DECISIONS_SQL = `SELECT d.*, a.nickname AS verdict_nick,
    (SELECT MAX(n.created_at) FROM decision_notes n WHERE n.decision_id = d.id AND n.author = 'claude') AS claude_at
  FROM decisions d LEFT JOIN accounts a ON a.id = d.verdict_by
  ORDER BY d.created_at DESC, d.id LIMIT ${DECISION_LIMITS.listMax}`;

export const LIST_NOTES_SQL = `SELECT n.*, a.nickname AS nick FROM decision_notes n LEFT JOIN accounts a ON a.id = n.account_id
  WHERE n.decision_id IN (SELECT id FROM decisions ORDER BY created_at DESC, id LIMIT ${DECISION_LIMITS.listMax})
  ORDER BY n.created_at, n.id`;

/**
 * 一条事项在流程里的位置。
 * @param {{state: string, verdict: string|null, verdict_at: number|null, claude_at: number|null}} row
 * @returns {'todo'|'explain'|'exec'|'later'|'closed'}
 */
export function decisionStage(row) {
  if (row.state !== 'open') return 'closed';
  if (!row.verdict) return 'todo';
  if (row.verdict === 'explain') return (row.claude_at || 0) > (row.verdict_at || 0) ? 'todo' : 'explain';
  if (row.verdict === 'later') return 'later';
  return 'exec';
}

/** 某个筛选页是否包含这条（never 页 = 所有拍成永远不做的，含已结，是长期黑名单）。 */
export function inDecisionStage(row, stage) {
  if (stage === 'all') return true;
  if (stage === 'never') return row.verdict === 'never';
  return decisionStage(row) === stage;
}

export function parseChoices(text) {
  try {
    const v = JSON.parse(text || 'null');
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

// ---- Worker 端 ----

export async function listDecisions(env) {
  const [items, notes] = await Promise.all([
    env.DB.prepare(LIST_DECISIONS_SQL).all(),
    env.DB.prepare(LIST_NOTES_SQL).all(),
  ]);
  const byId = new Map();
  for (const n of notes.results || []) {
    if (!byId.has(n.decision_id)) byId.set(n.decision_id, []);
    byId.get(n.decision_id).push(n);
  }
  return (items.results || []).map((r) => ({ ...r, notes: byId.get(r.id) || [] }));
}

/** 行的当前决定，写成表单 v 的形式（'' 表示未拍）。乐观锁拿它和提交方的 base 比。 */
export function verdictValue(row) {
  if (!row.verdict) return '';
  return row.verdict === 'choice' ? `choice:${row.choice}` : row.verdict;
}

/**
 * 网页表单：拍板（v）并 / 或留言（text）。v = 'note' 只留言；'clear' 撤销决定。
 * 「没看懂」不带留言也收（代理会按标题和原文补背景），但页面提示写清哪里没看懂。
 *
 * 并发：base = 提交方页面上看到的决定（verdictValue 形式）。给了 base 就走乐观锁——别人在这期间改过决定
 * （且改成的不是同一个决定）→ 409 verdict_conflict，决定和留言都不写，页面换成最新的卡让人重看。
 * 只留言不改决定时不需要锁（留言只增不改）。不带 base（旧页面）退回原来的直接覆盖。
 */
export async function submitDecision(env, dev, id, { v, text, base = null }, now) {
  if (!DECISION_ID_RE.test(id)) throw new HttpError(404, 'not_found');
  const row = await env.DB.prepare('SELECT * FROM decisions WHERE id = ?1').bind(id).first();
  if (!row) throw new HttpError(404, 'not_found');
  if (row.state !== 'open') throw new HttpError(409, 'decision_closed');
  let body;
  try {
    body = cleanDecisionText(text);
  } catch {
    throw new HttpError(400, 'note_too_long');
  }
  const stmts = [];
  let locked = false;
  if (v && v !== 'note') {
    let verdict = v;
    let choice = null;
    if (v.startsWith('choice:')) {
      verdict = 'choice';
      choice = v.slice(7);
      if (!parseChoices(row.choices).some((c) => c.key === choice)) throw new HttpError(400, 'bad_choice');
    } else if (v === 'clear') {
      verdict = null;
    } else if (!(v in DECISION_VERDICTS) || v === 'choice') {
      throw new HttpError(400, 'bad_verdict');
    } else if (v === 'do' && parseChoices(row.choices).length) {
      throw new HttpError(400, 'bad_choice');
    }
    const target = verdict === 'choice' ? `choice:${choice}` : (verdict || '');
    if (base !== null && base !== verdictValue(row)) {
      // 页面看到的已经过时：别人改成的正好是同一个决定就当成功（不重复写），否则冲突。
      if (target !== verdictValue(row)) throw new HttpError(409, 'verdict_conflict');
    } else if (base !== null) {
      locked = true;
      stmts.push(env.DB.prepare(SET_VERDICT_IF_SQL)
        .bind(id, verdict, choice, verdict ? dev.id : null, verdict ? now : null, now, base));
    } else {
      stmts.push(env.DB.prepare(SET_VERDICT_SQL).bind(id, verdict, choice, verdict ? dev.id : null, verdict ? now : null, now));
    }
  } else if (!body) {
    return;
  }
  if (locked) {
    // 读到行之后、写之前别人又改了：条件 UPDATE 不命中。先单独写决定，命中了才写留言，免得留言跟着一个没生效的决定。
    const r = await stmts.shift().run();
    if (!r.meta || r.meta.changes !== 1) throw new HttpError(409, 'verdict_conflict');
  }
  if (body) stmts.push(env.DB.prepare(ADD_NOTE_SQL).bind(id, 'dev', dev.id, body, now));
  if (stmts.length) await env.DB.batch(stmts);
}

// ---- 页面（devconsole 套 layout） ----
//
// 渐进增强：服务端一次渲染全部事项（最多 listMax 条），按栏用 hidden 过滤；没有脚本时表单照常 303 回原栏。
// 有脚本时（decisions_client.js）：切栏在本地做、拍板 / 留言走 fetch 只换那一张卡、带撤销提示和键盘快捷键，
// 并定时用签名比对同步 Claude 新写的事项与留言——全程不刷新页面。

function fmtTime(ms) {
  return ms ? new Date(ms).toISOString().replace('T', ' ').slice(0, 16) + ' UTC' : '';
}

function sourceHtml(src) {
  if (!src) return '';
  return src.split(/\s*·\s*/).map((p) => {
    if (!/^https:\/\//.test(p)) return `<span>${esc(p)}</span>`;
    const m = /github\.com\/[^/]+\/[^/]+\/(pull|issues)\/(\d+)/.exec(p);
    const label = m ? `${m[1] === 'pull' ? 'PR' : 'Issue'} #${m[2]}` : p;
    return `<a href="${esc(p)}" rel="noopener noreferrer" target="_blank">${esc(label)}</a>`;
  }).join(' · ');
}

const STAGE_LABEL = { todo: '待拍', explain: '等 Claude 解释', exec: '等 Claude 执行', later: '挂着', closed: '已结' };

/** 决定按钮：值、文案、样式、快捷键。「做」/ 方案的快捷键是数字 1…6。 */
const VERDICT_BUTTONS = [
  ['skip', '不做', 'v-skip', 'x'], ['later', '以后', 'v-later', 'l'], ['never', '永远不做', 'v-never', 'n'],
  ['explain', '没看懂', 'v-explain', 'e'], ['delegate', '你定', 'v-delegate', 'y'],
];

function verdictText(row) {
  if (!row.verdict) return '';
  if (row.verdict === 'choice') {
    const c = parseChoices(row.choices).find((x) => x.key === row.choice);
    return `选「${c ? c.label : row.choice}」`;
  }
  return `「${DECISION_VERDICTS[row.verdict]}」`;
}

/**
 * 卡片的内容版本：updated_at 随决定 / 结单变化，留言只增不删，条数变了就是有新留言。
 * @param {{updated_at: number, notes: unknown[]}} row
 * @returns {string}
 */
export function decisionVersion(row) {
  return `${row.updated_at || 0}.${row.notes.length}`;
}

function card(row, back, { hidden = false } = {}) {
  const stage = decisionStage(row);
  const reexplained = row.verdict === 'explain' && stage === 'todo';
  const choices = parseChoices(row.choices);
  const current = verdictValue(row);
  const btn = (v, label, cls, key) => `<button name="v" value="${esc(v)}" class="vb ${cls}${current === v ? ' on' : ''}" data-key="${
    esc(key)}" title="${esc(label)}（快捷键 ${esc(key.toUpperCase())}）">${esc(label)}<kbd>${esc(key.toUpperCase())}</kbd></button>`;
  const verdictButtons = [
    ...(choices.length
      ? choices.map((c, i) => btn(`choice:${c.key}`, c.label, 'v-do', String(i + 1)))
      : [btn('do', '做', 'v-do', '1')]),
    ...VERDICT_BUTTONS.map(([v, label, cls, key]) => btn(v, label, cls, key)),
  ].join('');
  const notes = row.notes.map((n) => `<div class="msg${n.author === 'claude' ? ' claude' : ' dev'}"><b>${
    esc(n.author === 'claude' ? 'Claude' : (n.nick || '开发者'))}</b> <span class="muted">${esc(fmtTime(n.created_at))}</span>
<div class="body">${esc(n.body)}</div></div>`).join('');
  const closed = stage === 'closed';
  const form = closed ? '' : `<form method="post" action="/dev/d/${esc(row.id)}" class="dform">
<input type="hidden" name="back" value="${esc(back)}">
<input type="hidden" name="base" value="${esc(current)}">
<textarea name="text" rows="2" maxlength="${DECISION_LIMITS.noteMax}" aria-label="留言" placeholder="${
  row.verdict === 'explain' ? '哪里没看懂？写下来 Claude 针对着解释' : '可选：补充说明，随下面的决定一起提交（Ctrl+Enter 只发留言）'}"></textarea>
<div class="vrow">${verdictButtons}<span class="vsp"></span>${
  row.verdict ? '<button name="v" value="clear" class="vb v-clear" data-key="u" title="撤销决定（快捷键 U）">撤销决定</button>' : ''
}<button name="v" value="note" class="vb v-note" title="只发留言，不改决定（Ctrl+Enter）">只留言</button></div>
</form>`;
  return `<article class="card dcard st-${esc(row.verdict || 'none')}${closed ? ' closed' : ''}" id="d-${esc(row.id)}" data-id="${
    esc(row.id)}" data-stage="${esc(stage)}" data-never="${row.verdict === 'never' ? 1 : 0}" data-verdict="${esc(current)}" data-v="${
    esc(decisionVersion(row))}" tabindex="-1"${hidden ? ' hidden' : ''}>
<div class="dhead"><span class="badge">${esc(DECISION_KINDS[row.kind] || row.kind)}</span>
<span class="badge rec-${esc(row.rec)}">${esc(DECISION_RECS[row.rec] || row.rec)}</span>
<span class="badge stage-${esc(stage)}${reexplained ? ' re' : ''}">${esc(reexplained ? '已补充解释，请重拍' : STAGE_LABEL[stage])}</span>
<span class="muted">${sourceHtml(row.source)}</span> <span class="muted">#${esc(row.id)}</span></div>
<h3>${esc(row.title)}</h3>
<div class="body">${esc(row.ask)}</div>
${row.pros || row.cons ? `<div class="pc">${row.pros ? `<div><b class="up">好处</b> ${esc(row.pros)}</div>` : ''}${
    row.cons ? `<div><b class="err">代价</b> ${esc(row.cons)}</div>` : ''}</div>` : ''}
${row.resolution ? `<div class="card ai"><b>处理结果（${esc(row.state === 'dropped' ? '撤回' : '已结')}）</b><div class="body">${esc(row.resolution)}</div></div>` : ''}
${row.verdict ? `<p class="muted dverdict">${esc(row.verdict_nick || '开发者')} 定为${esc(verdictText(row))} · ${esc(fmtTime(row.verdict_at))}</p>` : ''}
${notes}
${form}
</article>`;
}

/**
 * 给客户端的一条：卡片 HTML（不带 hidden，由客户端按当前栏过滤）+ 过滤所需的字段。
 * @returns {{id: string, v: string, stage: string, never: boolean, html: string}}
 */
export function decisionItem(row) {
  return { id: row.id, v: decisionVersion(row), stage: decisionStage(row), never: row.verdict === 'never', html: card(row, 'todo') };
}

/** 单条（含拍板人昵称、claude_at 与留言），拍板后回给客户端换卡用。 */
export async function getDecision(env, id) {
  const [r, notes] = await Promise.all([
    env.DB.prepare(`SELECT d.*, a.nickname AS verdict_nick,
        (SELECT MAX(n.created_at) FROM decision_notes n WHERE n.decision_id = d.id AND n.author = 'claude') AS claude_at
      FROM decisions d LEFT JOIN accounts a ON a.id = d.verdict_by WHERE d.id = ?1`).bind(id).first(),
    env.DB.prepare(`SELECT n.*, a.nickname AS nick FROM decision_notes n LEFT JOIN accounts a ON a.id = n.account_id
      WHERE n.decision_id = ?1 ORDER BY n.created_at, n.id`).bind(id).all(),
  ]);
  if (!r) throw new HttpError(404, 'not_found');
  return { ...r, notes: notes.results || [] };
}

/**
 * 整个拍板台的变化签名：事项条数 + 最晚 updated_at + 最大留言 id。任何写入（新事项、拍板、留言、结单）都会改变它。
 * 客户端轮询时带上次的签名，没变就不回列表。
 * @returns {Promise<string>}
 */
export async function decisionsSig(env) {
  const r = await env.DB.prepare(`SELECT (SELECT COUNT(*) FROM decisions) AS n,
      (SELECT COALESCE(MAX(updated_at), 0) FROM decisions) AS u,
      (SELECT COALESCE(MAX(id), 0) FROM decision_notes) AS m`).first();
  return `${r.n}.${r.u}.${r.m}`;
}

/** GET /dev/decisions.json?sig=… 的响应体。 */
export async function decisionsPayload(env, sig) {
  const now = await decisionsSig(env);
  if (sig && sig === now) return { sig: now, same: true };
  return { sig: now, items: (await listDecisions(env)).map(decisionItem) };
}

export const DECISIONS_STYLE = `
.dtop{display:flex;align-items:baseline;justify-content:space-between;gap:12px}
.dtop #dsync{font-size:12px}
.legend{font-size:13px;margin:4px 0}
.legend summary{cursor:pointer}
.legend div{display:flex;flex-wrap:wrap;gap:2px 14px;margin-top:4px}
kbd{display:inline-block;min-width:1.4em;padding:0 4px;margin-left:6px;border:1px solid currentColor;border-radius:4px;
  font:11px/1.4 ui-monospace,Consolas,monospace;text-align:center;opacity:.55}
.legend kbd{margin:0 4px 0 0}
@media (hover:none){.vb kbd{display:none}}
#dtabs{position:sticky;top:0;z-index:5;background:var(--bg);padding:8px 0;margin:8px 0 0}
.dcard{border-left:4px solid var(--line);scroll-margin-top:64px;transition:opacity .18s,transform .18s,box-shadow .15s}
.dcard:focus{outline:none}
.dcard.cur{box-shadow:0 0 0 2px var(--accent)}
.dcard.st-do,.dcard.st-choice{border-left-color:var(--ok)}
.dcard.st-skip{border-left-color:var(--muted)}
.dcard.st-never{border-left-color:#c0392b}
.dcard.st-later{border-left-color:#c98a00}
.dcard.st-explain{border-left-color:var(--c2)}
.dcard.st-delegate{border-left-color:#7a57c2}
.dcard.closed{opacity:.75}
.dcard.busy{opacity:.6;pointer-events:none}
.dcard.leaving{opacity:0;transform:translateX(24px)}
.dcard.fresh{animation:dflash 1.2s ease-out}
@keyframes dflash{from{box-shadow:0 0 0 3px var(--c2)}to{box-shadow:0 0 0 0 transparent}}
@media (prefers-reduced-motion:reduce){.dcard{transition:none}.dcard.fresh{animation:none}}
.dcard h3{margin:6px 0;font-size:16px}
.dhead{display:flex;flex-wrap:wrap;gap:6px;align-items:baseline;font-size:13px}
.dhead a{color:var(--c2)}
.badge.stage-todo{border-color:var(--accent);color:var(--accent)}
.badge.stage-todo.re{background:var(--accent);color:#fff}
.badge.stage-explain{border-color:var(--c2);color:var(--c2)}
.badge.stage-exec{border-color:var(--ok);color:var(--ok)}
.pc{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:4px 12px;margin-top:8px;font-size:14px}
.msg.claude{border-color:var(--c2)}
.dform textarea{min-height:0;margin-top:10px;resize:vertical}
.vrow{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:8px}
.vrow button{margin:0}
.vsp{flex:1}
.vb{padding:6px 12px;font-size:14px;background:transparent;color:var(--fg);border:1px solid var(--line)}
.vb:hover{border-color:var(--fg)}
.vb.on{color:#fff}
.vb.v-do.on{background:var(--ok);border-color:var(--ok)}
.vb.v-skip.on{background:var(--muted);border-color:var(--muted)}
.vb.v-never{border-style:dashed}
.vb.v-never.on{background:#c0392b;border-color:#c0392b;border-style:solid}
.vb.v-later.on{background:#c98a00;border-color:#c98a00}
.vb.v-explain.on{background:var(--c2);border-color:var(--c2)}
.vb.v-delegate.on{background:#7a57c2;border-color:#7a57c2}
.vb.v-clear,.vb.v-note{color:var(--muted)}
#dtoast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:10;display:flex;flex-direction:column;gap:8px;
  align-items:center;width:max-content;max-width:calc(100vw - 32px)}
.toast{display:flex;gap:14px;align-items:center;padding:10px 16px;border-radius:10px;background:var(--fg);color:var(--bg);
  box-shadow:0 4px 18px rgba(0,0,0,.25);font-size:14px}
.toast.err{background:#c0392b;color:#fff}
.toast button{margin:0;padding:2px 10px;background:transparent;color:inherit;border:1px solid currentColor;font-size:13px}
`;

/**
 * /dev/decisions 的正文。
 * @param {Array<object>} rows listDecisions 的结果
 * @param {string} stage 当前栏
 * @param {{sig?: string, script?: string}} [opts] sig = decisionsSig；script = 客户端脚本 URL（带版本）
 */
export function renderDecisions(rows, stage, { sig = '', script = '', conflict = false } = {}) {
  const counts = Object.fromEntries(DECISION_STAGES.map(([k]) => [k, rows.filter((r) => inDecisionStage(r, k)).length]));
  const tabs = DECISION_STAGES.map(([k, label]) => `<a href="/dev/decisions?stage=${k}" data-stage="${k}"${
    k === stage ? ' class="on"' : ''}>${esc(label)} <span class="n">${counts[k]}</span></a>`).join('');
  const shown = rows.filter((r) => inDecisionStage(r, stage)).length;
  const empty = stage === 'todo' ? '没有待拍的了。' : '这一栏是空的。';
  return `<div class="dtop"><h1>拍板台</h1><span id="dsync" class="muted"></span></div>
<p class="muted">Claude 把要你拍板的 PR 取舍、反馈建议、issue、审查发现写在这里。点一个决定即可，想补充就先在框里写再点；点「没看懂」后 Claude 会回一条解释，这条回到待拍。点完不刷新页面，可以撤销。</p>
<details class="legend muted"><summary>决定含义与快捷键</summary>
<div><span><b>做 / 方案</b> 照建议做</span><span><b>不做</b> 这次不做、关单</span><span><b>以后</b> 先挂着</span><span><b>永远不做</b> 拉黑，以后不再提</span><span><b>没看懂</b> 让 Claude 再解释</span><span><b>你定</b> 按 Claude 的判断做</span></div>
<div><span><kbd>J</kbd><kbd>K</kbd>下一条 / 上一条</span><span><kbd>1</kbd>…<kbd>6</kbd>做 / 选方案</span><span><kbd>X</kbd>不做</span><span><kbd>L</kbd>以后</span><span><kbd>N</kbd>永远不做</span><span><kbd>E</kbd>没看懂</span><span><kbd>Y</kbd>你定</span><span><kbd>C</kbd>写留言</span><span><kbd>U</kbd>撤销决定</span><span><kbd>Ctrl</kbd>+<kbd>Enter</kbd>只发留言</span><span><kbd>Esc</kbd>离开输入框</span></div>
</details>
${conflict ? '<p class="note">刚才那条在你提交前已被别人改了决定，你的决定没有提交。下面是最新状态，看过后再拍。</p>' : ''}
<nav class="tabs" id="dtabs">${tabs}</nav>
<div id="dlist" data-sig="${esc(sig)}" data-stage="${esc(stage)}">
${rows.map((r) => card(r, stage, { hidden: !inDecisionStage(r, stage) })).join('\n')}
</div>
<p id="dempty" class="muted"${shown ? ' hidden' : ''}>${esc(empty)}</p>
<div id="dtoast" role="status" aria-live="polite"></div>
${script ? `<script src="${esc(script)}" defer></script>` : ''}`;
}

export function decisionStageParam(v) {
  return DECISION_STAGES.some(([k]) => k === v) ? v : 'todo';
}
