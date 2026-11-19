-- 拍板台「原文」（2026-11-17，src/decisions.js）：事项卡片默认展开显示来源原文，可收起。
--   original  写入方给的原文（PR 正文 / issue / 评论 / 第三方意见的原话摘录），不可信数据，页面只转义展示。
--   反馈类事项不必填：页面按 id / source 联表 feedback 直接取用户的标题与正文。
-- 可空新列，旧 Worker 不读它。
ALTER TABLE decisions ADD COLUMN original TEXT;
