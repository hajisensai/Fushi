## BUG-5590 · srs-donation-status-device-local-mirror
- **报告**：2026-11-27（用户：捐赠页上传成功后写「已于 11月27日 捐出 0 次复习」；电脑上捐过，手机复习首页照样弹「了解并捐赠」）
- **真实性**：✅ 真 bug，两个症状是同一类问题：捐赠状态有两份来源，彼此对不上。
  - 「0 次」：服务端 `PUT /v1/srs-donations/:id` 成功只回 `{donated, updatedAt}`（`services/leaderboard/src/srs_donations.js` putDonation 末尾），GET 才带 `reviews/cards`；捐赠页把 PUT 的返回直接当状态（`srs_donation_page.dart` `_donate` 里 `_status = status`），显示时 `status.reviews ?? 0`（`_statusRow`）把缺字段补成 0。服务端 D1 记的是真实数字（批次清单里 dcef44a6 = 57428 次 / 3223 张）。
  - 「手机还弹」：横幅判据只看本机偏好 `srs_donation_last_at` / `srs_donation_last_reviews`（`srs_donation_eligibility.dart` `srsDonationPromptOf` 里 `prefs.lastAt == null` → donate），而捐赠身份按 profileUid 派生、跨设备共享，本机镜像在另一台设备上必然缺失。
- **[x] ① 已修复** — 捐赠状态只认服务端。服务端 PUT 与 GET 共用 `donationStatus(row)` 生成响应体，形状相同；客户端 `SrsDonationStatus` 改成 `none` / `donated(SrsDonationRecord)`，捐过却缺 `reviews/cards/updatedAt` 时按坏响应抛错，不再补 0。新增 `srsDonationStatusProvider`（GET，跟随复习库 / profile），横幅判据先过本机门（平台、不再提示、以后再说、1000 次 / 14 天），门开了才问服务端，状态未知就不出横幅。捐赠页的状态行、上传和撤回都读写这个 provider。删掉本机镜像 `lastAt/lastReviews`：两个偏好键标为已废弃、冻结保留。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/srs_donations.test.js`：PUT 响应带计数，且与 GET 完全相等。`fushi/test/srs/donation/srs_donation_client_test.dart`：`donated=true` 缺字段时报错。`srs_donation_eligibility_test.dart`「横幅判据接服务端状态」：本机偏好为空、服务端已捐时不出横幅；服务端未捐时出；状态未知时不出；本机门关时不发 GET。
- **备注**：排除词集合与「包含单词」开关仍是 Profile 偏好，随设置同步走，不在服务端。没开设置同步的另一台设备上点「更新捐赠」，会按那台设备的选项导出。这属于用户在那台设备上的选择，不算错误状态。
