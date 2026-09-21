## BUG-2614 · VN 模式切换章节后加载永不就绪
- **报告**：2026-09-21（用户：最新调试版；《无职转生》切换任意章节复现）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_visual_novel_scripts.dart:920-945` 在 VN 将章节正文移入脱离文档的 `sourceRoot` 后等待所有图片；`loading="lazy"` 图片不再满足交叉观察条件，也不会触发 `load`/`error`，导致 `readyPromise` 不结算，Dart 侧只能等内容就绪兜底超时。
- **[x] ① 已修复** — 在等待前把脱离文档中的 lazy 图片改为 `loading="eager"`，让其走正常加载/失败收敛路径（本提交）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_shell_smoke_test.dart` 锁定 eager 转换发生在等待注册前，并保留 complete/error 收敛分支。
- **备注**：章节切换使用同一 VN shell 初始化链，因此 Android、iOS、Windows、macOS 共用该根因；需在真实设备上复测无职转生章节切换，确认正文遮罩在就绪后消失。
