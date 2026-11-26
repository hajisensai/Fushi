-- SRS 复习历史捐赠单独一个 R2 配额池（src/budget.js MEDIA_POOLS 'donation'；src/srs_donations.js）。
--
-- ⚠️ 先迁移再部署：新代码的捐赠上传 / 撤回与 GET /v1/admin/srs-donations 读写 media_usage.donation_bytes，
-- 没迁移就部署时这几个接口会 500（其余接口不受影响）。迁移只加列，先迁移、旧代码照跑不受影响。
--
--   donation_bytes  捐赠包（R2 srs-donations/<donorId>.apkg）已占的 R2 字节，上限 DONATION_QUOTA_BYTES
--                   （默认 2 GiB，最多总配额的四分之一；从总配额里切出，不另加）。
--                   0027 起捐赠包借用反馈视频池（video_bytes）；捐赠包永不过期、视频 30 天过期，共池时
--                   捐赠会慢慢把视频池占死，视频洪峰也会让捐赠 507。分池后两边互不挤占。
--
-- 已在视频池里的捐赠字节从 video_bytes 挪到 donation_bytes（按 srs_donations.bytes 合计；video_bytes 不减到负数）。
ALTER TABLE media_usage ADD COLUMN donation_bytes INTEGER NOT NULL DEFAULT 0;
UPDATE media_usage SET
  donation_bytes = (SELECT COALESCE(SUM(bytes), 0) FROM srs_donations),
  video_bytes = MAX(0, video_bytes - (SELECT COALESCE(SUM(bytes), 0) FROM srs_donations))
WHERE id = 1;
