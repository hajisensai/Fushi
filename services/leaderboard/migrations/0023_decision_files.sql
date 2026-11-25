-- 拍板台附件（2026-11-17，src/decisions.js；CLI scripts/decisions.mjs attach / detach）：
-- 代理给事项附设计图（html / md / txt / 图片），开发者在卡片里直接预览。
--   files  JSON 数组 [{name, type, key, bytes}]，对象存 R2 MEDIA 桶的 decisions/<id>/… 下；
--          经 GET /dev/d/:id/f/:n 取，回包带 CSP sandbox（不透明源，拿不到处理台会话）。
-- 带默认值的新列，旧 Worker 不读它。
ALTER TABLE decisions ADD COLUMN files TEXT NOT NULL DEFAULT '[]';
