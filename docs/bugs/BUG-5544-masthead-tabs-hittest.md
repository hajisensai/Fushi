## BUG-5544 · 页头大字收缩后嵌套标签行 / 工具行点不动

- **报告**：2026-11-27（用户：应用内反馈 ki-PPMWRKt，Windows 1206x720，MD3 重设计外壳，视频媒体库）
- **真实性**：✅ 真 bug。列表滚下去再轻滑唤回顶栏后，页头下的标签筛选栏看得见却点不动，只有滚回最顶端才恢复。
  根因 `fushi/lib/src/utils/components/fushi_floating_chrome.dart`（修前 1115-1155，`_FushiFloatingChromeOverlayState.build`
  里嵌套层的 `Positioned(top: outer)`）：页头收短 `collapse` 的那段上移 `Transform.translate` 包在
  `ExcludeSemantics` / `IgnorePointer` / `fushiChromeFade`（MD3 是 `Opacity`）里面。这几层是普通 `RenderProxyBox`，按自己
  仍在 `outer` 原位的 size 判命中；`RenderTransform` 只平移绘制与子树坐标，不扩大父级命中盒。桌面宽窗 collapse ≈ 62 px，
  超过嵌套行高度（标签栏 48 + nestedGap 8），上移后整行落在命中盒外；窄窗 collapse ≈ 24 px，上半截成死区。
  影响所有在页头大字外壳下嵌套 `FushiFloatingChromeOverlay` 的页面：视频库、书架 / 漫画库、游戏库、浏览页二级页签、视频 / 漫画发现页控制行。
- **[x] ① 已修复** — 位移拆两段：页头收短的 `collapse` 提到 `Positioned` 的直接子节点（`fushi_floating_chrome.dart:1139`），
  命中盒随行一起上移；弹簧滑出与 Apple 外壳里「随内容滚到导航栏背后」那段留在内层（`:1151`），命中盒留在槽位里，
  只有槽位内露出的部分可点、藏在导航栏背后的那截不会被点穿。两段都是 paint-only，滚动不重排。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_masthead_nested_hit_test.dart`：
  MD3 宽窗滚到页头完全收缩后 tap 标签（含上半截）必须触发；Apple 宽窗嵌套行滚到导航栏背后一部分，露出的部分可点、
  藏起的部分不得点穿。修前 MD3 用例红；把 Apple 滚走那段也提到外层的「朴素修法」会让 Apple 用例红。
- **备注**：分诊提的次要点「`FushiMastheadPanel`（`fushi_page_masthead.dart:1604` 的 `ColoredBox`）没包 IgnorePointer」
  评估后不改：它是近乎不透明的页头底板，让点击穿过去会点到被底板盖住、看不见的内容；修复后嵌套行在 Stack 里
  排在底板之后、先于底板接命中，不再被它吞掉。
