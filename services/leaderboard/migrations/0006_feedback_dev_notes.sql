-- 开发者私有批注（2026-10-10）：只经开发者出口（devView / devList / 网页处理台）返回，
-- 反馈人接口（reporterView / batchStatus）一律不带，也不进 feedback_messages 时间线。
--   ai_summary：AI 代理读反馈后写的总结（scripts/feedback.mjs 回写；输入是未核实的用户内容）。
--   dev_note：开发者看完总结后手写的批改意见，可反复改写。
-- 两者都不刷新 updated_at / dev_reply_at：处理台排序与反馈人「有新回复」红点不受影响。
ALTER TABLE feedback ADD COLUMN ai_summary TEXT;
ALTER TABLE feedback ADD COLUMN ai_summary_at INTEGER;
ALTER TABLE feedback ADD COLUMN dev_note TEXT;
ALTER TABLE feedback ADD COLUMN dev_note_at INTEGER;
