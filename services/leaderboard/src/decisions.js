// 拍板台（迁移 0020）：AI 代理写入待拍事项，开发者在处理台 /dev/decisions 拍板，代理按结果执行后结单。
//
//   GET  /dev/decisions?stage=todo|explain|exec|later|never|closed|all   列表（默认 todo = 待拍）
//   POST /dev/d/:id   {v, text, back}   拍板并 / 或留言：v ∈ VERDICTS | choice:<key> | clear | note
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

/**
 * 网页表单：拍板（v）并 / 或留言（text）。v = 'note' 只留言；'clear' 撤销决定。
 * 「没看懂」不带留言也收（代理会按标题和原文补背景），但页面提示写清哪里没看懂。
 */
export async function submitDecision(env, dev, id, { v, text }, now) {
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
    stmts.push(env.DB.prepare(SET_VERDICT_SQL).bind(id, verdict, choice, verdict ? dev.id : null, verdict ? now : null, now));
  } else if (!body) {
    return;
  }
  if (body) stmts.push(env.DB.prepare(ADD_NOTE_SQL).bind(id, 'dev', dev.id, body, now));
  await env.DB.batch(stmts);
}

// ---- 页面（devconsole 套 layout；无脚本，全部是表单） ----

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

function verdictText(row) {
  if (!row.verdict) return '';
  if (row.verdict === 'choice') {
    const c = parseChoices(row.choices).find((x) => x.key === row.choice);
    return `选「${c ? c.label : row.choice}」`;
  }
  return `「${DECISION_VERDICTS[row.verdict]}」`;
}

function card(row, back) {
  const stage = decisionStage(row);
  const reexplained = row.verdict === 'explain' && stage === 'todo';
  const choices = parseChoices(row.choices);
  const btn = (v, label, cls) => {
    const on = v === 'do' ? row.verdict === 'do'
      : v.startsWith('choice:') ? row.verdict === 'choice' && row.choice === v.slice(7)
        : row.verdict === v;
    return `<button name="v" value="${esc(v)}" class="vb ${cls}${on ? ' on' : ''}">${esc(label)}</button>`;
  };
  const verdictButtons = [
    ...(choices.length ? choices.map((c) => btn(`choice:${c.key}`, c.label, 'v-do')) : [btn('do', '做', 'v-do')]),
    btn('skip', '不做', 'v-skip'), btn('later', '以后', 'v-later'), btn('never', '永远不做', 'v-never'),
    btn('explain', '没看懂', 'v-explain'), btn('delegate', '你定', 'v-delegate'),
  ].join('');
  const notes = row.notes.map((n) => `<div class="msg${n.author === 'claude' ? ' claude' : ' dev'}"><b>${
    esc(n.author === 'claude' ? 'Claude' : (n.nick || '开发者'))}</b> <span class="muted">${esc(fmtTime(n.created_at))}</span>
<div class="body">${esc(n.body)}</div></div>`).join('');
  const closed = stage === 'closed';
  const form = closed ? '' : `<form method="post" action="/dev/d/${esc(row.id)}" class="dform">
<input type="hidden" name="back" value="${esc(back)}">
<textarea name="text" maxlength="${DECISION_LIMITS.noteMax}" aria-label="留言" placeholder="${
  row.verdict === 'explain' ? '哪里没看懂？写下来 Claude 针对着解释' : '可选：补充说明，随决定一起提交'}"></textarea>
<div class="vrow">${verdictButtons}<button name="v" value="note" class="vb v-note">只留言</button>${
  row.verdict ? '<button name="v" value="clear" class="link">撤销决定</button>' : ''}</div>
</form>`;
  return `<article class="card dcard st-${esc(row.verdict || 'none')}${closed ? ' closed' : ''}" id="d-${esc(row.id)}">
<div class="dhead"><span class="badge">${esc(DECISION_KINDS[row.kind] || row.kind)}</span>
<span class="badge rec-${esc(row.rec)}">${esc(DECISION_RECS[row.rec] || row.rec)}</span>
<span class="badge stage-${esc(stage)}">${esc(reexplained ? '已补充解释，请重拍' : STAGE_LABEL[stage])}</span>
<span class="muted">${sourceHtml(row.source)}</span> <span class="muted">#${esc(row.id)}</span></div>
<h3>${esc(row.title)}</h3>
<div class="body">${esc(row.ask)}</div>
${row.pros || row.cons ? `<div class="pc">${row.pros ? `<div><b class="up">好处</b> ${esc(row.pros)}</div>` : ''}${
    row.cons ? `<div><b class="err">代价</b> ${esc(row.cons)}</div>` : ''}</div>` : ''}
${row.resolution ? `<div class="card ai"><b>处理结果（${esc(row.state === 'dropped' ? '撤回' : '已结')}）</b><div class="body">${esc(row.resolution)}</div></div>` : ''}
${row.verdict ? `<p class="muted">${esc(row.verdict_nick || '开发者')} 定为${esc(verdictText(row))} · ${esc(fmtTime(row.verdict_at))}</p>` : ''}
${notes}
${form}
</article>`;
}

export const DECISIONS_STYLE = `
.legend{display:flex;flex-wrap:wrap;gap:2px 14px;font-size:13px}
.dcard{border-left:4px solid var(--line)}
.dcard.st-do,.dcard.st-choice{border-left-color:var(--ok)}
.dcard.st-skip{border-left-color:var(--muted)}
.dcard.st-never{border-left-color:#c0392b}
.dcard.st-later{border-left-color:#c98a00}
.dcard.st-explain{border-left-color:var(--c2)}
.dcard.st-delegate{border-left-color:#7a57c2}
.dcard.closed{opacity:.75}
.dcard h3{margin:6px 0;font-size:16px}
.dhead{display:flex;flex-wrap:wrap;gap:6px;align-items:baseline;font-size:13px}
.dhead a{color:var(--c2)}
.badge.stage-todo{border-color:var(--accent);color:var(--accent)}
.badge.stage-explain{border-color:var(--c2);color:var(--c2)}
.badge.stage-exec{border-color:var(--ok);color:var(--ok)}
.pc{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:4px 12px;margin-top:8px;font-size:14px}
.msg.claude{border-color:var(--c2)}
.dform textarea{min-height:56px;margin-top:10px}
.vrow{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:8px}
.vrow button{margin:0}
.vb{padding:6px 12px;font-size:14px;background:transparent;color:var(--fg);border:1px solid var(--line)}
.vb.on{color:#fff}
.vb.v-do.on{background:var(--ok);border-color:var(--ok)}
.vb.v-skip.on{background:var(--muted);border-color:var(--muted)}
.vb.v-never{border-style:dashed}
.vb.v-never.on{background:#c0392b;border-color:#c0392b;border-style:solid}
.vb.v-later.on{background:#c98a00;border-color:#c98a00}
.vb.v-explain.on{background:var(--c2);border-color:var(--c2)}
.vb.v-delegate.on{background:#7a57c2;border-color:#7a57c2}
.vb.v-note{margin-left:auto}
`;

/** /dev/decisions 的正文。 */
export function renderDecisions(rows, stage) {
  const counts = Object.fromEntries(DECISION_STAGES.map(([k]) => [k, rows.filter((r) => inDecisionStage(r, k)).length]));
  const tabs = DECISION_STAGES.map(([k, label]) => `<a href="/dev/decisions?stage=${k}"${k === stage ? ' class="on"' : ''}>${
    esc(label)} ${counts[k]}</a>`).join('');
  const list = rows.filter((r) => inDecisionStage(r, stage));
  const empty = stage === 'todo' ? '没有待拍的了。' : '这一栏是空的。';
  return `<h1>拍板台</h1>
<p class="muted">Claude 把要你拍板的 PR 取舍、反馈建议、issue、审查发现写在这里。每条点一个决定，想补充就先在框里写再点；点「没看懂」后 Claude 会在下面回一条解释，这条回到待拍。</p>
<div class="legend muted"><span><b>做</b> 照建议做</span><span><b>不做</b> 这次不做、关单</span><span><b>以后</b> 先挂着</span><span><b>永远不做</b> 拉黑，以后不再提</span><span><b>没看懂</b> 让 Claude 再解释</span><span><b>你定</b> 按 Claude 的判断做</span></div>
<nav class="tabs">${tabs}</nav>
${list.length ? list.map((r) => card(r, stage)).join('\n') : `<p class="muted">${esc(empty)}</p>`}`;
}

export function decisionStageParam(v) {
  return DECISION_STAGES.some(([k]) => k === v) ? v : 'todo';
}
