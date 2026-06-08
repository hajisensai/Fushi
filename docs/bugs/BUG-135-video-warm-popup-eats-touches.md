## BUG-135 · 手机热WebView吞掉视频控制条触摸（顶栏/底栏点了没反应）
- **报告**：2026-06-08（用户：手机视频顶栏横屏全展开也点不了、底栏也点不了、点了完全没反应、播放正常）
- **真实性**：✅ 真 bug（手机特有，原生平台视图截获触摸），根因 `dictionary_page_mixin.dart:222 buildNestedPopupLayer` + `base_source_page.dart:398 _buildPopupLayer` 的隐藏热槽渲染 + `dictionary_popup_controller.dart:95 seedWarmSlot(selectionRect: Rect.zero)`。

### 根因（真实代码路径取证）
用户真机：横屏图标全展开（无溢出）也点不动、底栏同样点不动、点了「完全没反应」，但播放正常——指向**有东西盖在视频上吞掉所有触摸**。
BUG-094 为查词弹窗预热，开页 seed 一个常驻「热槽」`DictionaryPopupEntry(visible:false, isWarmSlot:true, selectionRect: Rect.zero)`，渲染在根 Overlay。`buildNestedPopupLayer` 用 `Visibility(visible:false, maintainState/Size/Animation:true)` 把它「隐身」——实为 `Opacity(0)+IgnorePointer`，并停在 `calcPopupPosition(Rect.zero)` 算出的**屏幕左上一大片**。但热槽内是 Android `InAppWebView`＝**原生平台视图**；`IgnorePointer` 只挡 Flutter 命中测试，**挡不住原生 view 直接截获触摸** → 盖住区域内的视频控制条（顶栏图标、底栏播放条）点击全被这层隐形 WebView 吃掉，故「点了没反应」；播放本身不需点击故正常。桌面 webview 实现无此行为，故仅手机复现。
（此前 BUG-134 误判为「顶栏图标过多溢出」，是另一回事——溢出只影响竖屏布局，不是点不动的根因；BUG-134 改自适应布局保留，本 bug 才是点不动的真因。）

### 修复（隐藏热槽移到屏幕外，保留预热）
隐藏的热槽（`!entry.visible`）在 `buildNestedPopupLayer` / `base_source_page._buildPopupLayer` 里**停到屏幕右外侧** `left = screen.width + 8`（保持真实 `width/height` 让原生 WebView 仍冷加载预热）；宿主 Stack（视频 `_buildPopupOverlay`、阅读器 base_source_page）改 `clipBehavior: Clip.none`，让屏外的热槽照常栅格化保持温热、不被裁掉。可见（真查词）时仍用真实 `pos`，行为完全不变。这样隐形热槽不再盖任何控件 → 顶栏/底栏触摸放行；BUG-094 预热保留。

- **[x] ① 已修复** — `dictionary_page_mixin.dart buildNestedPopupLayer` + `base_source_page.dart _buildPopupLayer`：`!visible` 热槽 `left=screen.width+8` 停屏外；视频 `_buildPopupOverlay` 与阅读器弹窗 Stack 加 `clipBehavior: Clip.none`。
- **[x] ② 已加自动化测试** — `test/pages/video_warm_popup_offscreen_guard_test.dart`（两处渲染对隐藏热槽用 `screen.width + 8` 停屏外 + 两宿主 Stack 用 `Clip.none`）。
- **备注**：平台视图触摸/预热无 headless 测试。**真机复验**：手机视频顶栏（横/竖屏）与底栏所有按钮可正常点击；首次查词弹窗仍温热（无明显白屏）。若个别机型屏外热槽不预热，回退为首次冷加载（功能正常，仅首查一次轻微白屏）。
