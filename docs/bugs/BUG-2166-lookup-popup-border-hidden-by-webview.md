## BUG-2166 · 查词浮层四边描边被 WebView 盖住（只剩顶栏和圆角弧可见）
- **报告**：2026-09-06（用户：「查词框没包边」，附 Windows 阅读器划词截图 3840×2064）
- **真实性**：✅ 真 bug，用户截图像素级复现（见下方「现象」的采样表）。根因 `fushi/lib/src/utils/components/fushi_material_components.dart:3246`（`FushiPopupSurface.build` 把 child 直接塞进 `Material`，而浮层传的是 `borderOnForeground: false`）。
- **[x] ① 已修复** — `fushi/lib/src/utils/components/fushi_material_components.dart`：`FushiPopupSurface` 新增 `_borderInsetChild`，`borderOnForeground: false && showBorder` 时把 child 沿四边内缩一个笔宽（1）并按内圈半径 `cardRadius - 1` 再裁一次，描边环因此落在 child 之外；`BorderSide` 显式 `width: _borderWidth`，让笔宽与内缩量同源。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/bug_2166_popup_surface_border_inset_test.dart`（4 例 widget 行为：`borderOnForeground:false` 时 child 尺寸 = surface − 2 且存在内圈半径 `ClipRRect`；默认 `true` 不内缩；`showBorder:false` 不内缩；`BorderSide.width == 1` 且 `strokeAlignInside`）。同时 `fushi/test/tools/bug_1692_platform_view_overlay_guard_test.dart` 全绿，证明修法没把描边挪回 foreground。
- **备注**：与 BUG-1692 是同一处的**一体两面**——1692 为了 macOS 命中测试把描边挪到 child **之前**绘制，本 bug 是那次改动的可见代价（当时结论「透明背景的 WebView 仍能透出下面的描边，观感无变化」在 macOS 上成立，在 Windows in-app 浮层上不成立：`transparentDocumentBackground: false`，popup 文档背景不透明）。

### 现象（用户截图像素采样，Windows / 阅读器绿色主题 / DPR 2）

页面背景 `rgb(199,237,204)`。沿弹层左边界横向逐像素采样：

| 采样行 | 位置 | 结果 |
|---|---|---|
| 顶栏内（`y≈1082`，surface 左边 `x≈1573`） | Flutter 画的顶栏 | ✅ 描边可见（灰线，见 `corner_tl` 放大图） |
| WebView 区直边段（`y=1400/1500/1900`，`x=1573..1592`） | 平台视图铺满处 | ❌ **一路都是纯背景色 `(199,237,204)`，没有任何描边像素** |
| 左下圆角弧（`y≈1990`） | `Clip.antiAlias` 把 WebView 的直角裁掉的那几段 | ✅ 露出一小段圆弧描边 |

`x=1593..1596` 处那条 `(171,204,175)` + `(222,245,225)` 是 **popup.html 内部卡片自己的 CSS 边框**，不是 surface 描边——它离 surface 边界还有 10 逻辑 px。用户看到的正是「顶栏有边、往下就没了」。

### 根因

`FushiPopupSurface` 的描边由 `Material.shape` 的 `RoundedRectangleBorder.side` 画。`Material.borderOnForeground` 决定它画在 child **之前**还是**之后**：

- 默认 `true`：走 `CustomPaint.foregroundPainter`，画在 child 之后 ⇒ 一定看得见，但 bounds 覆盖整个 surface ⇒ macOS 把整块浮层写进 `_hitTestIgnoreRegion`（BUG-1692，「查词框点哪都没反应」）。
- 浮层传的 `false`：描边画在 child 之前 ⇒ macOS 命中恢复，但**任何铺满 surface 的不透明 child 都会把它整条盖掉**。

浮层的 child 是 `Column(顶栏, Divider, Expanded(DictionaryPopupWebView))`（`dictionary_popup_layer.dart:791`），WebView 铺满顶栏以下全部区域、且 in-app 时 `transparentDocumentBackground: false`（文档背景不透明）⇒ 左/右/下三边的直边段描边被逐像素盖住，只有顶栏那一段、和圆角处被 `Clip.antiAlias` 裁出 WebView 的几段弧还看得见。

### 修复

不把描边挪回 foreground（那会让 BUG-1692 回归），而是**给描边让位**：`borderOnForeground: false && showBorder` 时

```dart
Padding(padding: EdgeInsets.all(1))          // 描边 strokeAlignInside，占内侧 [0,1]
  → ClipRRect(borderRadius: cardRadius - 1)  // 内圈半径，圆角处 child 也压不到弧上
    → child
```

`padding` 参数语义不变（仍是最内层的内容内边距）。`borderOnForeground: true`（纯 Flutter 子树，描边本就盖得住）和 `showBorder: false` 都不内缩，既有布局零变化。

### 验证

**Windows 真机 A/B（2026-09-06，同一机器/同一窗口 rect/同一深色主题）**

跑法：`tool/run_windows_itest.ps1 -Visible` + 一个临时探针用例（`launchFushiTestApp` → `seedDictionary` → `HomePage.debugSelectTab(dictionaries)` → `HomeDictionarySearchDebug.debugOpenPopup('testword')` → 长驻 90s），外部 `Graphics.CopyFromScreen` 抓**合成后**的真实像素（`captureFlutterFrame` 结构性不含平台视图纹理，在本 bug 上只会给假绿；PrintWindow 对 Flutter/WebView 是白屏）。探针已删除，不入库。

几何（app 真跑，`RenderBox.localToGlobal`，逻辑 px）：

| | surface | 浮层 WebView |
|---|---|---|
| 修复前 | `(180.0, 240.0) 402.0×201.0` | `(180.0, 276.0) 402.0×165.0` ← 左边界与 surface **完全重合**、宽度占满 |
| 修复后 | `(180.0, 240.0) 402.0×201.0` | `(181.0, 277.0) 400.0×163.0` ← 四边各让出 1 |

像素（窗口 rect `240,72 1440×888`，浮层左边界 `x=608/609`、右边界 `x=1410/1411`，描边色 `rgb(67,71,78)`，浮层内外背景同为 `rgb(17,19,24)`）：

| 采样行 | 修复前 | 修复后 |
|---|---|---|
| `y=580`（顶栏区，Flutter 画） | ✅ 左右都有描边 | ✅ 左右都有描边 |
| `y=700`（WebView 区） | ❌ 左右全是 `(17,19,24)`，**零描边像素** | ✅ 左右都有描边 |
| `y=800`（WebView 区） | ❌ 同上 | ✅ |
| `y=860`（WebView 区） | ❌ 同上 | ✅ |

与用户报告截图（浅绿主题）的现象逐条对上：顶栏有边、往下就没了。

**测试 / 静态**

- `flutter test test/widgets/ test/settings/md3_design_system_static_test.dart` → 580 tests PASSED（含新 4 例 + BUG-1692 守卫 6 例）。
- `flutter test test/pages/` → 3315 完成、1 例失败（`home_video_page_menu_test.dart` 的封面缓存回收，与本改动无因果）；**单跑该文件 15 tests 全绿** ⇒ 并发伪红。
- `flutter analyze` → 6 个 warning 全部是既有的、与本改动无关（`theme_notifier.dart` / `video_discovery_acquisition_dialogs.dart` / `theme_page_transitions_guard_test.dart`）。
