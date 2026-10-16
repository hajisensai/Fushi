-- 安装统计（2026-10-17，src/installs.js）。
--
-- 客户端（Android / Windows / macOS / Linux；iOS 不发，用 App Store Connect 自带分析）每天最多一次
-- POST /v1/ping {installId, version, platform, channel}。installId 是客户端首次启动生成的随机 UUID v4，
-- 只存本机、不进备份 / 同步，用户可在设置里关掉统计。服务端**不存 IP**（只拿来过限流 binding）。
--
--   installs       每个安装一行：首次 / 最近一次心跳时刻与最近一次上报的版本 / 平台 / 通道
--   install_days   (UTC 日, installId) 去重表：日活 = 当天行数，周活 / 月活 = 窗口内 DISTINCT installId；
--                  同时记下当天的版本，反馈详情据此画「版本轨迹」
--   feedback.install_id  提交反馈时勾选了「附带设备信息」才有（客户端自报，可伪造）
--
-- 两张表都按 INSTALL_LIMITS.retentionDays 由定时任务清理。
-- 索引刻意少建：D1 每个受影响的索引另计一行写入。installs 不给 first_seen 建索引（只有开发者统计页
-- 按它数新增，扫 installs 全表可以接受），换来每次心跳少写一行。
CREATE TABLE IF NOT EXISTS installs (
  install_id TEXT PRIMARY KEY,
  first_seen INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  platform   TEXT NOT NULL,
  channel    TEXT NOT NULL,
  version    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_installs_last_seen ON installs (last_seen);

CREATE TABLE IF NOT EXISTS install_days (
  day        TEXT NOT NULL,
  install_id TEXT NOT NULL,
  platform   TEXT NOT NULL,
  channel    TEXT NOT NULL,
  version    TEXT NOT NULL,
  PRIMARY KEY (day, install_id)
);
CREATE INDEX IF NOT EXISTS idx_install_days_install ON install_days (install_id, day);

ALTER TABLE feedback ADD COLUMN install_id TEXT;
CREATE INDEX IF NOT EXISTS idx_feedback_install ON feedback (install_id) WHERE install_id IS NOT NULL;
