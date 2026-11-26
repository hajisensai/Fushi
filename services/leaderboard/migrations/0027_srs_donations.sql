-- SRS 复习历史捐赠（2026-11-26，src/srs_donations.js；设计 docs/specs/2026-11-26-srs-review-donation.md）：
-- 用户自愿把复习历史（脱敏 .apkg）捐给 anki-rwkv 训练调度模型；文件存 R2 `srs-donations/<donorId>.apkg`，
-- 所有者每月生成一个私有批次链接（scripts/srs_donation_batch.mjs）交给作者。
--
--   srs_donations             一个捐赠者一行（同一 donorId 重传覆盖）。key_hash = sha256(donorKey 的 UTF-8 字节)
--                             的小写 hex；donorKey 明文不落库。bytes = R2 对象大小（占「大附件」配额池）。
--   srs_donation_withdrawals  撤回记录。reported_batch 为空 = 还没在批次里报给作者；批次生成时填上批次 token。
--                             重新捐赠时删掉尚未报告的那条；已报告的保留（作者那边已删，新文件照常进下一批）。
--   srs_donation_batches      一个私有批次：token（链接即凭据）、30 天有效期、生成时刻的捐赠者快照与撤回清单。
--   srs_donation_milestones   一次性里程碑（如 donors_30：不同捐赠者数第一次到 30 时通知所有者）。
--
-- 纯新表，旧 Worker 不读它；写入量极小（每捐赠者每小时 ≤ 2 次上传）。
CREATE TABLE srs_donations (
  donor_id TEXT PRIMARY KEY,
  key_hash TEXT NOT NULL,
  bytes INTEGER,
  reviews INTEGER,
  cards INTEGER,
  app_version TEXT,
  created_at INTEGER,
  updated_at INTEGER
);

CREATE TABLE srs_donation_withdrawals (
  donor_id TEXT PRIMARY KEY,
  withdrawn_at INTEGER NOT NULL,
  reported_batch TEXT NULL
);

CREATE TABLE srs_donation_batches (
  token TEXT PRIMARY KEY,
  created_at INTEGER,
  expires_at INTEGER,
  donors_json TEXT,
  withdrawn_json TEXT
);

CREATE TABLE srs_donation_milestones (
  name TEXT PRIMARY KEY,
  reached_at INTEGER
);
