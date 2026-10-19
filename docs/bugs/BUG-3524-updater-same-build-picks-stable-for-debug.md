## BUG-3524 · updater-same-build-picks-stable-for-debug
- **报告**：2026-10-18（用户：调试版最新没有 SRS 的入口；截图 设置 → 外观 → 功能模块 列表里没有「复习」）
- **真实性**：✅ 真 bug。用户 Windows 处于调试通道，10-18 09:44 app 内更新装的是正式版 `fushi-3.0.0-windows-setup.exe`（`%APPDATA%\Fushi\Fushi\updates\fushi-3.0.0-windows-setup.exe.meta.json`，运行中 `fushi.exe` ProductVersion `3.0.0+19763`，`app.so` 无 `-debug` 版本串），正式版按 PR #2237 屏蔽复习。根因 `fushi/lib/src/utils/misc/update_checker_release.dart` 的 `selectUpdateReleaseForCurrentPlatform` 排序：正式版 3.0.0 与 3.0.0-debug.19763 出自同一提交、`releaseSequence` 同为 19763，`_compareReleaseRecency` 判并列，稳定排序保原序，合集里排在前面的 stable 胜出。#2237 之前两轨功能相同，这个偏向无感；之后 debug 通道用户会被换进正式版、丢掉预发布能力。
- **[x] ① 已修复** — 排序平局时按 `_trackRank` 优先用户自己的轨道（debug 通道选 debug 包，beta 选 beta）。不改 `isUpdateVersionNewer`：已被换进同序号正式版的用户不会被同序号 debug 包「回推」（守 BUG-480「不混渠道」），等下一个更高序号的 debug 构建按「谁后用谁」自动回到 debug。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/version_comparison_test.dart`「same build shipped on stable and debug: debug user gets the debug one」（两种拉取顺序；正式版通道仍只拿正式版）；去掉修复时该用例选中 `3.0.0`。
- **备注**：
