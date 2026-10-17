## BUG-2992 · 歌词更多设置入口被上次标签页记忆覆盖
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实入口选择策略缺陷，新增 Aa 文字面板与已有标签页记忆组合触发。
- **根因**：固定快照 `1a5424c847a` 的 `fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:526` 的“更多歌词设置”只打开普通设置面板；`fushi/lib/src/reader/reader_settings_ia.dart:312` 原先优先有效 remembered 标签。曾切到查词或主题页后，此入口落到记忆页而非歌词设置。
- **[x] ① 已实现修复** — 仅 Aa 更多入口请求 `lyrics`，请求经面板装配传入初始页策略；有效定向目标优先，不改变普通入口记忆，无效目标回退有效记忆页。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/reader/reader_settings_requested_tab_test.dart`，真实初始页策略函数覆盖记忆 lookup + 请求 lyrics、普通入口、不可见及未知目标回退；不是源码字符串断言。
- **验证结果**：见 [审查报告 HBK-AUDIT-014 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：该自动化测试不实例化整套 WebView 阅读器；实际 Aa 路由、歌词播放器与设备验收仍待补，不宣称实机通过。
