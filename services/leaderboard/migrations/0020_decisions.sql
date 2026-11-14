-- 拍板台（2026-11-10，src/decisions.js；开发者处理台 /dev/decisions，CLI scripts/decisions.mjs）：
-- AI 代理把需要维护者拍板的事项（外部 PR 取舍、反馈建议、issue、审查发现）写进来，开发者在网页上
-- 点「做 / 不做 / 以后 / 永远不做 / 没看懂 / 你定」并留言；代理按结果执行后结单。
--
--   decisions       一条待拍事项。id 由写入方给（pr3162a / 反馈 id / issue123 / review-xxx），重复写入不覆盖。
--                   verdict 一条只存最新一个决定（谁、何时）；state = open | done | dropped。
--   decision_notes  双方留言：author = 'dev'（开发者在网页上写，带 account_id）| 'claude'（代理经 CLI 写）。
--                   「没看懂」之后有比 verdict_at 新的 claude 留言 → 该条回到待拍。
--
-- 纯新表，旧 Worker 不读它们；写入量极小（人工点按），不走日预算。
CREATE TABLE decisions (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  ask TEXT NOT NULL,
  pros TEXT,
  cons TEXT,
  choices TEXT,
  source TEXT,
  rec TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open',
  resolution TEXT,
  verdict TEXT,
  choice TEXT,
  verdict_by TEXT,
  verdict_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX decisions_created ON decisions (created_at);

CREATE TABLE decision_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  decision_id TEXT NOT NULL,
  author TEXT NOT NULL,
  account_id TEXT,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX decision_notes_decision ON decision_notes (decision_id, created_at);
