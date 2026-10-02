-- 同机多 Profile 去重（BUG-2870）：一台设备上多个 Profile 各开一个排行榜账户时，
-- 「哪个 Profile 都没有学习记录」的作品每个账户都上传（各自书架照常显示、账户计分照常算），
-- 但只有其中一个账户的那行计入作品维度的读者数——works.readers、work_periods、作品页读者
-- 列表与头像墙。counted = 0 的行只是不参与这些作品维度的计数。
-- 旧行与不带该字段的上报一律 counted = 1（行为不变）。
ALTER TABLE shelf ADD COLUMN counted INTEGER NOT NULL DEFAULT 1;
