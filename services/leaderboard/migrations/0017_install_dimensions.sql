-- 安装统计的地区 / 界面语言 / 设备维度（2026-10-21，src/installs.js `recordPing`）。
--
--   country     Cloudflare 按连接 IP 判出的 ISO 3166-1 alpha-2 国家 / 地区码（request.cf.country；
--               T1 = Tor，XX = 未知）。只存这两位码：IP、城市、经纬度、ASN 一律不落库。
--   locale      客户端可选：App 当前界面语言（BCP 47 标签，如 zh-CN / ja / pt-BR）。
--   arch        客户端可选：设备 CPU 架构（x64 / arm64 / x86 / arm …，按宿主而非进程）。
--   os_version  客户端可选：系统**大**版本（Android API 级别 / Windows 10|11 / macOS 主版本 /
--               Linux 发行版 id-版本），不报具体 build 号。
--   source      客户端可选：安装来源类别（play / fdroid / obtainium / self_update / manual / adb /
--               installer / portable / direct / source），只报类别，不报安装器包名。
-- 旧客户端不发可选字段，记 NULL。
--
-- 纯增量、可空、无索引（D1 每个受影响的索引另计一行写入；只有开发者统计页按它们分组）。
-- 旧 Worker 仍在线时先执行也安全：旧代码的 INSERT / upsert 不提这些列。
ALTER TABLE installs ADD COLUMN country TEXT;
ALTER TABLE installs ADD COLUMN locale TEXT;
ALTER TABLE installs ADD COLUMN arch TEXT;
ALTER TABLE installs ADD COLUMN os_version TEXT;
ALTER TABLE installs ADD COLUMN source TEXT;
ALTER TABLE install_days ADD COLUMN country TEXT;
ALTER TABLE install_days ADD COLUMN locale TEXT;
ALTER TABLE install_days ADD COLUMN arch TEXT;
ALTER TABLE install_days ADD COLUMN os_version TEXT;
ALTER TABLE install_days ADD COLUMN source TEXT;
