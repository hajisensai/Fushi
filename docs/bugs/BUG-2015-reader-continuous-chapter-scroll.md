## BUG-2015 · 连续阅读跨章由惯性误触且整页黑屏跳转
- **报告**：2026-09-01（用户录屏 `1788254094703.mp4`：触摸板连续滚动时章尾未看稳
  就切章，跨章整页黑屏/转圈，数位板小键盘滚轮疑似无响应）
- **真实性**：✅ 真 bug。录屏约 9–10s、30s、49s 三次跨章都经过整份 WebView document
  替换；`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:1397` 的旧
  arm-then-fire 只按相邻 wheel tick 确认，同一段触摸板惯性在真实边界卡两拍就会替用户
  跨章，而只发一拍的离散旋钮永远停在 arm；`reader_content_styles.dart:1137` 此前没有章末
  主轴留白；`reader_fushi_page.dart:2918` 在 `_readerContentReady=false` 时只盖纯背景，直接
  暴露单文档换章的黑屏。
- **[x] ① 已修复** — `76b8f51fc5`：连续模式章末增加 36% 视口的 block-axis 留白；触摸板必须
  静默后从边界重新起手势才跨章，离散滚轮/数位板旋钮一拍可跨；跨章前捕获并预解码旧
  WebView 视口，目标章 ready 后 140ms 淡出，截图不可用或 450ms 超预算时安全降级为原导航。
- **[x] ①b 审查补修** — 复审发现两处：① 拿到快照却没真正进导航的路径（分页在飞 / 无目标章 /
  `_handlePageTurnLimit` 内部 spread 边界与 nav 页守卫）不丢弃快照，那帧旧视口会挂到**下一次**
  `_readerContentReady` 归 false（换字号重排、歌词模式切换）被当成「上一章画面」整屏淡出——
  新增 `_discardIdleChapterTransitionSnapshot()`（`navigation.part.dart`）并在两条闲置路径调用；
  ② 两条既有守卫被本 PR 打红（`reader_image_metrics_invalidate_guard_static_test.dart` 的
  `onBoundarySwipe` 字面量被折行 + 新增第三实参打掉、`reader_fushi_lyrics_transition_static_test.dart`
  的 `if (!_readerContentReady)` 锚点被条件扩写打掉），已按语义等价物修复而非删断言，
  并把后者扩窗跟进 `_buildChapterTransitionOverlay()`，避免它对新的淡出层永久失明。
- **[x] ② 已加自动化测试** —
  `fushi/test/reader/continuous_wheel_boundary_confirm_test.dart` 覆盖触摸板惯性/新手势/离散
  旋钮真值表；`reader_content_styles_test.dart` 覆盖横竖排章末留白；
  `fushi/test/pages/reader_continuous_chapter_transition_guard_test.dart` 锁定截图先于导航、
  ready 淡出与缓存释放；并回归 BUG-369/1342/1745/1829 既有守卫。
- **备注**：定向 160/160 通过，`flutter analyze --no-pub` 0 issue。首轮测试在任何用例
  执行前因 `pdfium_dart` 直连 GitHub 超时失败，启用仓库本地代理后原范围重跑全绿。
  未在真实 Windows WebView2 上复播原 EPUB/触摸板/数位板旋钮路径，截图耗时与最终手感仍
  待设备肉眼验收；这里不把 headless/源码守卫当作真机通过。
