-- 邮箱别名归一（2026-10-17，src/email.js `canonicalEmail` / `resolveEmailAccount`）。
--
-- email_hash 改按规范化邮箱算（Gmail 去点 / +tag、googlemail→gmail，若干域去 +tag）。服务端不存明文，
-- 历史账户的哈希无法批量重算，只能在登录时惰性升级：新旧哈希一起查，命中旧哈希就原地改成新哈希。
-- 新哈希已被另一个账户占着（同一个收件箱在旧规则下注册过两个账户）时不合并、保留旧哈希，
-- 把这对账户记在这里，管理员经 GET /admin/api/email-conflicts 查看。只存账户 id，不存邮箱或哈希。
--
-- 纯增量：只新建表。旧 Worker 在线时先执行也安全（旧代码不碰这张表）。
-- 编号跳过 0014：留给 PR #2293；两者互不依赖，wrangler 按名字记已应用的迁移，先后合入都能补上。
CREATE TABLE IF NOT EXISTS email_hash_conflicts (
  account_id    TEXT NOT NULL,              -- 仍挂旧哈希、没能升级的账户
  holder_id     TEXT NOT NULL,              -- 已占用规范化哈希的另一个账户
  first_seen_at INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL,
  seen_count    INTEGER NOT NULL DEFAULT 1, -- 冲突账户之后又登录了几次
  PRIMARY KEY (account_id, holder_id)
);
CREATE INDEX IF NOT EXISTS idx_email_hash_conflicts_holder ON email_hash_conflicts (holder_id);
