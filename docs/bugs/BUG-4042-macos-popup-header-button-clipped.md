## BUG-4042 · macOS 查词弹窗右上角调节按钮被右边缘裁掉一半
- **报告**：2026-11-04（反馈 #SwFjAzjBqq，QQ 群机器人代提交，macOS 调试版（版本未提供）：阅读器竖排小说里查词弹窗右上角收藏 / 添加 / 调节三颗按钮中，最右的调节（「高级制卡」`.ctx-adjust-button`）只露出左半。截图第二轮单独导出）。
- **真实性**：✅ 真 bug。
  - **第一轮**：只在页内布局层面排除——页面 CSS 不会把按钮排出视口。
  - **第二轮截图** `SwFjAzjBqq_s0.png`：弹窗是三列词典排版，**最右一列词典卡与按钮一起**在同一条竖线处被截断，右侧留着一条空白竖带。说明整块内容比可见区宽，不只是按钮组的问题。
  - **根因**：宿主 `fushi/lib/src/pages/implementations/dictionary_popup_webview.dart` 的 `_applyPopupViewportSize`（`:818`，修前脚本里 `width / z - leftInset - rightInset`）把 `#entries-container` 钉成 Flutter 平台视图的**整宽**。这是 BUG-1812 的 iOS `innerWidth == 0` 修复。它没有减掉文档竖向滚动条的占位 gutter（macOS「始终显示滚动条」/ 接鼠标时用的 legacy 滚动条约 15px）。gutter 出现后，内容比可见区宽出 `gutter − body 右内边距`，最右一列和按钮被视口裁掉，空白竖带就是滚动条槽。
  - **实测**：Playwright WebKit webkit-2248，真 popup.html/css/js，强制 15px classic 滚动条。修前 `scrollWidth 390 > clientWidth 385`，最后一颗按钮右缘 390，越出可见区；修后 `scrollWidth == clientWidth`（zoom 1 时 385，zoom 1.25 时 382）。overlay 滚动条下修前修后结果相同。「内容变长后滚动条才出现」的路径也已验证：ResizeObserver 触发后自动重算。
- **[x] ① 已修复**（见本条提交）— `dictionary_popup_webview.dart`：
  - `kPopupScrollbarGutterJsExpr`（`:802`）：`innerWidth − documentElement.clientWidth`，取不到值时（BUG-1812 态）按 0；
  - 注入脚本抽成 `popupViewportScript`（`:843`），算式改为 `(width - gutter) / z - leftInset - rightInset`；
  - 在 `documentElement` 上装一次 `ResizeObserver`：gutter 变化时（换词 / 展开词典后滚动条才出现）重跑 `__fushiApplyPopupViewport`。重复注入不叠加观察者。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_viewport_scrollbar_gutter_test.dart`：用 node 在假 DOM 上真执行注入脚本，覆盖 5 种情况：
  - 15px gutter → 365px；
  - overlay（gutter 0）→ 380px，不回归；
  - zoom 1.25 下先减 gutter 再折算；
  - `innerWidth == 0` 仍用 Flutter 宽度；
  - 观察者只装一次，gutter 不变不重排、变了重算。

  `dictionary_popup_webview_test.dart` 的算式断言同步改为 `(width - gutter) / z`。
- **备注**：未在 macOS 真机复测（本机只有 Windows），引擎层证据来自 WebKit 探针。
