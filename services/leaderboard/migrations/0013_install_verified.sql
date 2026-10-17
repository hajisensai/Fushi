-- 安装证明（2026-10-17，src/installs.js `verifyInstallProof`）。
--
-- 新客户端的 installId 由系统机器标识派生（HMAC-SHA256 → P-256 钥匙 → 公钥指纹，原始机器标识不上传），
-- 心跳与反馈出示 X-Fushi-Install-Key / -Time / -Sig / -Pow 四个头：installId == fp(公钥)、验签（覆盖
-- 方法 + 路径 + 请求体哈希 + 时刻，±5 分钟，签名串进 used_sigs 防重放）、工作量证明都过了才记 verified = 1。
-- 不带证明头的旧客户端（2.10.0-debug 起的随机 UUID v4）照收，记 verified = 0；统计页默认只数已验证。
--
-- 纯增量、带默认值：旧 Worker 仍在线时先执行也安全（旧代码的 INSERT 不提这几列，落默认 0；
-- 旧代码的 upsert 不碰 verified）。服务端仍不存 IP、不存原始机器标识。
ALTER TABLE installs ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE install_days ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE feedback ADD COLUMN install_verified INTEGER NOT NULL DEFAULT 0;
