## BUG-3438 · 「超级大西瓜」页头像清晰度太低
- **报告**：2026-10-16（用户反馈 `AZbVODlkgx`，Windows 2560x1440@1.5：「超级大西瓜这里图像的清晰度太低了」；截图上传失败，日志无相关报错）
- **真实性**：✅ 真 bug（按代码路径定性）。「超级大西瓜」页（`fushi/lib/src/pages/implementations/leaderboard/leaderboard_watermelon_page.dart`）里唯一的图片是排行榜头像，球直径最大 `2 × kWatermelonMaxRadius = 192` 逻辑像素，「适应屏幕」还会把整堆再放大（2560x1440@1.5 下约 1.5x），并允许双指放大到 6x。而头像在上传前被 `encodeLeaderboardAvatarBytes`（`fushi/lib/src/leaderboard/leaderboard_service.dart`，`kLeaderboardAvatarSize = 128`）裁成 128px，大球上要放大 3 倍以上显示，必然发糊。`LeaderboardAvatar` 本身按原图解码、没有降采样，问题出在源图尺寸。
- **[x] ① 已修复** — `kLeaderboardAvatarSize` 128 → 384；编码按服务端 `AVATAR_MAX_BYTES`（64KB）逐级降质量（85/75/60），极端噪点图再缩边长（256/128），保证不被服务端 413。服务端不需要改动（只验魔数与字节数）。提交见本分支 `fix(leaderboard): upload avatars at 384px so watermelon balls stay sharp`。
- **[x] ② 已加自动化测试** — `fushi/test/leaderboard/leaderboard_service_test.dart`：`encodeLeaderboardAvatarBytes` 输出边长 = `kLeaderboardAvatarSize` 且 ≥384、字节 ≤ 上限；高噪点 600x600 图也压到上限以内。
- **备注**：存量头像仍是 128px，要等各用户重新设置头像才会变清晰（服务端只存了 128px 的版本，客户端无从恢复）。未在 Windows 真机目测（截图没传上来，"清晰度低"指头像是按页面内容推定的）。
