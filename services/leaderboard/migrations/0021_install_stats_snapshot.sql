-- 安装统计快照（2026-11-11，src/installs.js refreshInstallStatsSnapshot；处理台 /dev/stats、/dev/stats.json、/dev/project）。
--
-- 为什么：installStats() 现场算一次 ≈ 20 条全表聚合（install_days 保留 400 天、installs 每安装一行），
-- 2026-11-10 实测一次读约 30 万行，开十几次处理台就把 D1 免费额度的 500 万行 / 天读光，全站读接口跟着报错。
-- 现在由定时任务按间隔（INSTALL_LIMITS.snapshotEveryMs）算一次存成一行 JSON，页面只读这一行；
-- 处理台的「立即刷新」另有冷却（snapshotRefreshCooldownMs）。
--
-- 单行表：id 恒为 1。
CREATE TABLE IF NOT EXISTS install_stats_snapshot (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  computed_at INTEGER NOT NULL,
  data TEXT NOT NULL
);
