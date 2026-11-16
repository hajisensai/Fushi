-- 服务端下发的公告（2026-11-17，src/notices.js；POST /v1/notices，管理端 /admin/api/notices/**，处理台 /dev/notices）。
-- App 定期带上自己的构建信息（版本 / 平台 / 通道 / 界面语言 / 应用 id / 签名证书摘要）来问有没有要显示的公告，
-- 服务端按下面的规则匹配，命中的公告（横幅 / 对话框 / 全屏）连同文案一起下发。规则与文案只在这里，不在客户端代码里。
--
--   notice_rules    一条公告规则。kind 决定怎么匹配（value 的含义随 kind 变）：
--                     'h'           value 等于 h 或 k 里任一摘要
--                     'id'          value 等于应用 id
--                     'h_unlisted'  h / k 至少一个非空，且其中没有任何摘要登记在 notice_known_h
--                     'hk_disjoint' h 与 k 都非空且没有共同摘要
--                     'all'         全部请求
--                   platform 为 NULL = 任何平台。文案按界面语言取 zh / en 两套（en 空时回落 zh）。
--   notice_known_h  已登记的签名证书摘要（给 'h_unlisted' 用）。
--   notice_seen     按 UTC 日 × 构建信息的请求计数（upsert），让维护者看到外面有哪些构建在跑。
--                   h = h（没有则 k）的第一个摘要，没有则 ''。只存这些粗粒度字段，不存 IP、安装 id 或设备标识；
--                   country 是 Cloudflare 判出的两位码（同 install_days）。主键列一律非空（NULL 会让 upsert 失效）。
--
-- 纯新表，旧 Worker 不读它们。
CREATE TABLE notice_rules (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('h', 'id', 'h_unlisted', 'hk_disjoint', 'all')),
  value TEXT,
  platform TEXT,
  level TEXT NOT NULL CHECK (level IN ('banner', 'dialog', 'block')),
  title_zh TEXT,
  body_zh TEXT,
  title_en TEXT,
  body_en TEXT,
  url TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);

CREATE TABLE notice_known_h (
  h TEXT PRIMARY KEY,
  label TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE notice_seen (
  day TEXT NOT NULL,
  id TEXT NOT NULL DEFAULT '',
  h TEXT NOT NULL DEFAULT '',
  hk_disjoint INTEGER NOT NULL DEFAULT 0,
  v TEXT NOT NULL DEFAULT '',
  p TEXT NOT NULL DEFAULT '',
  country TEXT NOT NULL DEFAULT '',
  n INTEGER NOT NULL,
  PRIMARY KEY (day, id, h, hk_disjoint, v, p, country)
);
