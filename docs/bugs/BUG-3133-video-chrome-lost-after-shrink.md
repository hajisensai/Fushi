## BUG-3133 · 删视频后列表缩短，收起的顶部工具区回不来
- **报告**：2026-10-09（群反馈：删了两个视频后界面卡住、丢了顶部那一块，改缩放或重启才恢复；开发者确认为已知 bug）
- **真实性**：✅ 真 bug（widget 测试复现）。根因 `fushi/lib/src/utils/components/fushi_floating_chrome.dart` 的 `FushiFloatingChromeController.handleScrollNotification`：显隐只吃 `ScrollNotification`。往下滚后工具区收起；删掉视频后列表缩短到一屏放得下，版面把滚动位置夹回 0——这种夹紧只发 `ScrollMetricsNotification`、不发 ScrollUpdate，controller 看不见，工具区停在收起态；内容又已经滚不动，用户再也唤不回顶部（页签、搜索、动作按钮全没了）。改缩放会重建整棵树，所以「改缩放 / 重启才恢复」。
- **[x] ① 已修复** — 本 PR：controller 新增 `handleScrollMetricsNotification`，最外层 `FushiFloatingChromeOverlay` 统一监听版面修正通知（过滤隐藏的保活分区）；主滚动区落回顶部（含「整页放得下」）即弹回工具区并撤遮罩。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_library_test.dart`「BUG-3133 列表缩短到一屏放得下」：滚到下面让工具区收起 → 列表缩到 2 条 → 断言位置被夹回 0 且工具区回来、遮罩撤掉（修复前红）。
- **备注**：反馈里的录屏打不开，按代码路径与 widget 复现定根因；真机删除视频后的复测待补。
