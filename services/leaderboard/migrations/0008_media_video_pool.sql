-- 反馈视频单独一个 R2 配额池（src/budget.js MEDIA_POOLS）。
--
-- ⚠️ 先迁移再部署：新代码的视频补传 / 视频清理读写 media_usage.video_bytes，没迁移就部署时
-- PUT .../attachments/v0 与定时清理会 500。迁移只加列，先迁移、旧代码照跑不受影响。
--
--   video_bytes  反馈视频（槽位 v0）已占的 R2 字节，上限 VIDEO_QUOTA_BYTES（默认 1 GiB，最多总配额一半）。
--                bytes 列仍是头像 / 封面 / 反馈截图与日志，上限 = MEDIA_QUOTA_BYTES − 视频池。
--                视频单个 50 MB、匿名可传，与头像封面共池时几个 IP 一天就能把总配额打满，
--                之后全站头像 / 封面 / 截图上传 507 到视频 30 天过期为止；分池后视频满了只拒视频。
ALTER TABLE media_usage ADD COLUMN video_bytes INTEGER NOT NULL DEFAULT 0;
