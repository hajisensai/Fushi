-- 项目数据（2026-10-21，src/project_stats.js；开发者处理台 /dev/project）：GitHub 仓库与官网 fushi.moe 的
-- 每日快照。定时任务每隔几小时取一次外部 API，当天的行覆盖写（一天一行），历史行留着画趋势——
-- GitHub 只给当前 star 数、Cloudflare 免费版的分析也有保留期，不自己存就没有长期曲线。
--
--   repo_daily   每仓库每 UTC 日：star / fork / 关注 / 开放 issue+PR / App Release 累计下载。
--   site_daily   官网 zone 每 UTC 日：请求数、页面浏览、独立访客、流量字节、国家分布 JSON
--                （{"JP": 123, …}，按请求数）。
--   project_meta 最近一次的明细与状态：releases:<repo>（近期 Release 各平台下载）、
--                traffic:<repo>（GitHub 近 14 天访问 / clone，需 token）、status:github / status:site
--                （最近一次成功时刻与错误）。值是 JSON。
--
-- 写入量：每次刷新几行，远低于日预算；不加二级索引。
CREATE TABLE repo_daily (
  day TEXT NOT NULL,
  repo TEXT NOT NULL,
  stars INTEGER NOT NULL,
  forks INTEGER NOT NULL,
  watchers INTEGER NOT NULL,
  open_issues INTEGER NOT NULL,
  downloads INTEGER,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (day, repo)
);

CREATE TABLE site_daily (
  day TEXT PRIMARY KEY,
  requests INTEGER NOT NULL,
  page_views INTEGER NOT NULL,
  visitors INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  countries TEXT,
  fetched_at INTEGER NOT NULL
);

CREATE TABLE project_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  at INTEGER NOT NULL
);
