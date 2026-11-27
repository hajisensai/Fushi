-- SRS 复习历史捐赠：每月快照批次换成长期 feed（2026-11-27，src/srs_donations.js；设计
-- docs/specs/2026-11-26-srs-review-donation.md「下载 feed」）。
--
-- 起因：anki-rwkv 作者想每 30 分钟自动拉新数据；快照批次的清单在 30 天内一成不变、撤回最长要等一个月才报告。
-- 改成一个长期有效、可吊销的 feed：清单实时反映当前全部捐赠与全部撤回，消费方按 updatedAt / ETag 只下变了的文件。
--
--   srs_donation_feeds        一个 feed 凭据一行。token 明文只在签发时给一次，库里只存 sha256(token) 的小写 hex；
--                             revoked_at 非空 = 已吊销（链接立即 404）。label 只给所有者看（发给了谁）。
--   srs_donation_withdrawals  撤回记录改为长期保留、每次清单都给全；去掉 reported_batch（不再有「报告给哪一批」）。
--                             重新捐赠时无条件删掉该 donorId 的撤回记录（新文件在清单里取代它）。
--   srs_donation_batches      删除（旧批次链接随部署失效，改发 feed 链接）。
--
-- ⚠️ 先迁移再部署：新 Worker 读 srs_donation_feeds、写撤回时不带 reported_batch；旧 Worker 在迁移后、部署前
-- 撤回会因缺列 500（窗口只有一次部署，写入量极小）。
CREATE TABLE srs_donation_feeds (
  id INTEGER PRIMARY KEY,
  label TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

-- 旧语义下「已报告的撤回在重新捐赠后保留」：新语义里有捐赠行就不该再有撤回记录。
DELETE FROM srs_donation_withdrawals WHERE donor_id IN (SELECT donor_id FROM srs_donations);
ALTER TABLE srs_donation_withdrawals DROP COLUMN reported_batch;

DROP TABLE srs_donation_batches;
