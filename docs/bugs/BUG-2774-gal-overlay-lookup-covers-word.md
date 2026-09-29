## BUG-2774 · 台词浮窗贴屏幕底时查词卡压住被点的词
- **报告**：2026-09-29（用户：「GAL的文本浮窗放下面查词会遮」，附截图：浮窗在屏幕下方，查词卡把被点的「何気なく」连同所在行右半整段盖住）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/lookup/global_lookup_controller.dart` `_lookupExternal`：逻辑锚点只把窗口种在词下方 `(left, bottom + 4)`，根卡**不带锚点**，走 `global_lookup_render.dart` 的 anchorless 分支 → `computeRootShellOffset` 只做「夹进工作区」；下方放不下时整卡被上推，正好压在词上）
- **[x] ① 已修复** — 逻辑锚点按 dpr 换成物理矩形后与 attached 物理锚点同一套：窗口种在词左上角、根卡设锚交给 `computeFrameRect` 择上/下侧（分支 `pr/gal-overlay-popup-occlusion`）
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_popup_placement_test.dart`「logical text-overlay anchor near the screen bottom flips the root card above the word」（旧代码下卡片落在 y=350..1400、词在 1225..1274，断言红）
- **备注**：同一逻辑锚点入口还有剪贴板面板点词，一并受益。

### 根因

`lookupText(anchorScreenRect:)`（台词浮窗 `gal_hook_text_overlay_controller.dart` 点词传被点字的屏幕逻辑矩形）
在 `_lookupExternal` 里只影响 `showAt` 的种子点：`showY = (anchor.bottom + 4) * dpr`，
随后只有 `physicalPlacement`（attached 表面）分支会写 `_frameAnchors[root]`。逻辑锚点的根卡因此
没有锚，渲染时走 anchorless 分支，位置 = `computeRootShellOffset` 把「词下方」夹回工作区：
浮窗在屏幕上方时下方空间够，看不出问题；浮窗贴屏幕底时下方放不下，卡片被整块上推到
`screenH - cardH`，覆盖被查的词与整行正文。

### 修复

`_lookupExternal` 先把逻辑锚点乘 dpr 得到 `anchorPhysical`，两种锚点统一：
`showAt` 种在词左上角，`_frameAnchors[root]` = 词相对窗口原点的 CSS 矩形。根卡随即与嵌套卡
一样经 `computeFrameRect`：下方放得下放下方，放不下翻到上方并把高度收进该侧空间。

### 待验证（真机）

- 台词浮窗拖到屏幕底部 → 点词 → 卡片出现在词上方，不遮挡正文。
- 浮窗在屏幕上方时仍出现在词下方（原行为）。
