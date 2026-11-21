## BUG-4967 · Windows 阅读器顶部标题行空白处单击不唤出/收起悬浮控制栏
- **报告**：2026-11-14（应用内反馈 jWXKgQxjR2，Windows 11 鼠标；拍板台 jWXKgQxjR2 维护者 2026-11-17：「继续用悬浮，点击空白地方无法收起或者打开要修复」）
- **真实性**：✅ 真 bug（部分）。在 Windows 真实窗口（`run_windows_itest.ps1` 离屏跑 develop@71d1a8d360，有声书竖排、暂停 / 播放两种状态）用真实鼠标指针事件探针取证：
  - 正文 WebView 内真空白处单击：`pointerdown → pointerup → onTapEmpty`，悬浮栏开 / 关均正常（唤出、收起各 3 次全对）。
  - 窗口顶部 0–32px（自绘标题行 `FushiDesktopTitleBar.height = 32`，透明叠在阅读器之上，纸色铺到顶边，视觉上就是正文上方的空白）：命中链是 `_CaptionTapForwarder > DragToMoveArea > ColoredBox`，单击**整条被拖动区吃掉**，JS 侧零事件、悬浮栏不变（截图 s1 里用户最自然去点的「顶栏旁空白」正是这一条）。
  - 根因：`fushi/lib/src/pages/base_source_page.dart` `_onCaptionTap` 只在查词弹窗可见时转发标题行单击（BUG-4475），弹窗不在时直接丢弃，页面收不到「点顶部空白」。
  - 竖排满页时正文内的真空白只剩列间约 9px 的窄缝（字矩形 ±6px 容差之外），点到字上是查词，这是既有设计，不在本条范围。
- **[x] ① 已修复** — 标题行单击的分派收成纯函数 `resolveCaptionTapAction`（被盖住不动 / 有弹窗走 dismiss barrier / 无弹窗交页面 `onCaptionBlankTap`）；阅读器覆写 `onCaptionBlankTap` 走与 `onTapEmpty` 同一入口 `_handleReaderBlankTap`（悬浮态 = 纯开关，挤压态维持旧语义；不参与点击翻页区域模板；歌词覆盖层在场时不经这里）。拖动整窗、双击最大化仍归窗口。
- **[x] ② 已加自动化测试** — `fushi/test/desktop/caption_tap_dismisses_lookup_test.dart`（分派纯函数四种组合 + base 页 / 阅读器接线守卫；原有「单击转发、拖动 / 双击不算单击」行为测试照旧）。
- **备注**：Windows 真实窗口复测（同一离屏探针、同一有声书竖排夹具、真实鼠标指针事件）：修复前标题行 y=20 单击两次悬浮栏均不变（JS 零事件）；修复后第一次收起（[true,true]→[false,false]）、第二次唤出（→[true,true]），正文真空白与屏底状态行的开关行为不变。探针是一次性诊断用例，未入库。
