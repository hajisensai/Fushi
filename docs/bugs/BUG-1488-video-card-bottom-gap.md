## BUG-1488 · 视频卡底部常驻空白（续 BUG-926 16:9 封面修复）
- **报告**：2026-07-21（用户：底部多显示了一块）。截图为视频 tab 合集横排行 S01E06/07 等成员卡：16:9 封面顶对齐正常，但标题下方常驻约 50px 空白块。
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/home_video_page.dart`。
  - BUG-926 把封面锁死 16:9（`AspectRatio(16/9)`）后，封面下方文字块高度由常量 `_kVideoCardTextBlock`（`home_video_page.dart:2431`，原值 83）固定预留，卡总高 `_videoCardExtent = cardWidth × 9/16 + _kVideoCardTextBlock`。
  - 83 是「2 行标题 + 观看进度行 + 内边距」的**最坏预留**，且本是逆算值（`cardWidth=240` 时凑回旧固定 218，非文字实测）。
  - 但绝大多数视频/剧集卡是**单行标题、无观看进度**（`_buildCardWatchMeta` 返回空、不渲染进度行）：文字实占约 28px，`Expanded` 文字块顶对齐后底部剩约 55px 空白 → 显眼空块（用户看到的「多一块」）。本地卡 `_buildCard` 与远端卡 `_buildRemoteVideoCard` 对称同症。
- **[x] ① 根因修复** — 收敛为紧凑固定高：`_kVideoCardTextBlock` 83→52（单行标题 + 单行进度 + 内边距）；本地 `_buildCard` / 远端 `_buildRemoteVideoCard` 标题 `maxLines: 2→1`；本地卡进度行包一层 `Flexible` 让位，避免大字号倍率下文字块溢出。无进度卡仅剩约一行的常规内边距、不再是空块，有进度卡两行紧贴。封面仍锁 16:9、`BoxFit.contain` 不裁切均不变（保留 BUG-926 / TODO-616C 决策）。提交哈希：4fe2ea05b
- **[x] ② 已加自动化测试** — 扩展 `hibiki/test/pages/video_card_cover_aspect_guard_test.dart`：源码扫描守卫断言两张卡标题均 `maxLines: 1`（禁回退 2 行预留）、`_kVideoCardTextBlock ≤ 60`（禁回退到 83 的最坏预留）。原 16:9 AspectRatio 断言 + `video_cover_fit_guard_test.dart`（contain 不裁切）保持通过。提交哈希：4fe2ea05b
- **备注**：真机验证（Windows 离屏 / Android 模拟器）复测「单行标题无进度的视频卡底部无空块」「有进度卡两行不溢出」「大字号倍率下文字块不溢出」。BUG-926 号在 develop 已归属另一 bug（popup 触屏复制），本续修另起 943 号，代码/守卫注释以 943 记，封面 16:9 血缘仍标注 BUG-926。
