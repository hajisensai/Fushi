-- AI 额度消耗（2026-10-29，src/ai_usage.js；公开页 GET /usage）：维护者机器上的 Claude Code 把本地对话日志
-- 按「UTC 日 × 模型」汇总后自动上传（tool/claude_usage_upload.mjs），这里只存汇总计数，
-- 不存项目名、提示词或任何会话内容。
--
--   source      上传端自己起的机器标签（小写字母 / 数字 / - / _，≤ 32 字符），多台机器各自一行，页面按日合并。
--   requests    当天该模型的 API 请求数；input / output / cache_read / cache_write 是各类 token 累计。
--
-- 上传端每次发整天的完整汇总，所以主键冲突时整行覆盖（不累加），重传幂等。
-- 写入量：每次上传 ≤ 400 行，扣全局 write_rows 日预算；不加二级索引（主键前缀 day 已够读最近 N 天）。
CREATE TABLE ai_usage_daily (
  day TEXT NOT NULL,
  source TEXT NOT NULL,
  model TEXT NOT NULL,
  requests INTEGER NOT NULL,
  input INTEGER NOT NULL,
  output INTEGER NOT NULL,
  cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (day, source, model)
);
