-- 安装统计的地区与界面语言（2026-10-21，src/installs.js `recordPing`）。
--
--   country  Cloudflare 按连接 IP 判出的 ISO 3166-1 alpha-2 国家 / 地区码（request.cf.country；
--            T1 = Tor，XX = 未知）。只存这两位码：IP、城市、经纬度、ASN 一律不落库。
--   locale   客户端心跳可选字段：App 当前界面语言（BCP 47 标签，如 zh-CN / ja / pt-BR）。
--            旧客户端不发，记 NULL。
--
-- 纯增量、可空、无索引（D1 每个受影响的索引另计一行写入；只有开发者统计页按它们分组）。
-- 旧 Worker 仍在线时先执行也安全：旧代码的 INSERT / upsert 不提这两列。
ALTER TABLE installs ADD COLUMN country TEXT;
ALTER TABLE installs ADD COLUMN locale TEXT;
ALTER TABLE install_days ADD COLUMN country TEXT;
ALTER TABLE install_days ADD COLUMN locale TEXT;
