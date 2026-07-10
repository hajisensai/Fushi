## BUG-685 · 安卓app外查词弹窗上下滑不动点击无反应（隐藏热槽屏内截触摸）
- **报告**：2026-07-10（用户：安卓查词弹窗有可能基本上下滑不动，点击也没反应，可以左右滑动关闭）· TODO-1379
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart:503-512`（修复前行号，`_buildLayer` 隐藏分支）。

### 根因（真实代码路径取证）
TODO-951 症状C 给 app 外查词窗（PopupDictionaryPage：系统 PROCESS_TEXT / hibiki://lookup / 悬浮字幕点字）配了**常驻隐藏热槽**（`visible=false` 的 `DictionaryPopupEntry`，WebView 全程挂载预热）。隐藏分支此前只在**卡片局部坐标系**把层挪到 `left: cardWidth + 8` 并套 `IgnorePointer`：
- 卡片局部 ≠ 屏幕：卡片居中/贴锚渲染在全屏透明窗里，卡宽 < 窗宽时（用户 popupMaxWidth 设小、宽屏/横屏、锚定分支窄卡），停靠点 `卡片原点 + cardWidth + 8` **仍落在窗内**（如 800 宽窗 + 300 宽卡 → 停在 ~556px，屏内）。
- BUG-135 已确立：Android `InAppWebView` 是**原生平台视图**，`IgnorePointer` 只挡 Flutter 命中测试，**挡不住原生视图直接截获触摸**；且旧分支无 `Visibility` 包裹，隐藏层还被不透明绘制。
- 于是停在屏内的隐形原生 WebView 吃掉活动弹窗区域的上下滚动与点击（WebView 内手势全死），而横滑关闭是 Flutter 层 `SwipeDismissWrapper`（Listener）手势，故幸存——精确对应症状「上下滑不动、点击没反应、只能左右滑动关闭」。「有可能」= 几何依赖（卡宽/窗宽/入口分支）。
- 与 TODO-1336（`_isClosing` 闭锁）同属 warm 复用状态机家族、不同残留；另三宿主（reader `base_source_page` / video·首页 `dictionary_page_mixin`）已走共享 `parkedPopupLayer`（`dictionary_popup_layer.dart:241-260`，真·屏外 `screen.width + 8` + `Visibility(maintain*)`），本页是唯一未收口的表面。

### 修复（隐藏层收口到共享 parkedPopupLayer，真·屏外停靠）
`_buildLayer` 可见/隐藏分支统一改走共享 `parkedPopupLayer`（BUG-135 停靠几何单一真相）：`pos = Rect.fromLTWH(0, 0, cardW, cardH)`（可见=满卡，与原 `Positioned.fill` 等价），`screen = MediaQuery.sizeOf(context)`（窗口尺寸；卡片原点 ≥ 0 ⇒ 卡局部 `screen.width + 8` 必在窗外，原生视图放行触摸），隐藏层经 `Visibility(maintainState/Size/Animation)` 保持真实尺寸预热。消除本页自造的「卡片局部停靠」特殊情况，四宿主同机制。

- **[x] ① 已修复** — `git commit `b76984982``。`hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`：`_buildStack` 增量出 `cardHeight`、`_buildLayer` 改签名 `cardSize` 并将双分支收口为 `parkedPopupLayer(pos, visible: entry.visible, screen: MediaQuery.sizeOf(context))`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_dictionary_parked_offscreen_test.dart`（真 widget 几何，fake InAppWebViewPlatform 下真渲染热槽）：① 隐藏热槽 `topLeft.dx ≥ 窗口宽 + 8`（真屏外）+ 保持真实尺寸预热 + Flutter 层不可命中（hitTestable 找不到）+ 经 `Visibility(maintainState/Size)` 收口；② warm 复用循环不回归：搜索提交后同一热槽（`webViewKey` 不变）翻可见、回屏内、可命中。对旧实现做过必红验证（几何断言 ~556 < 808 红）。守卫同步：`popup_dictionary_page_test.dart` 源码守卫改断 `parkedPopupLayer(` + 禁 `left: cardWidth + 8`；`video_warm_popup_offscreen_guard_test.dart`（BUG-135 中央守卫）补第四宿主断言。TODO-1336 闭锁 / nested / external fixes 相关 32 例全绿。
- **备注**：
  - 平台视图触摸截获行为无 headless 测试（BUG-135 同口径），「真屏外几何」是可落地的最强断言。
  - **真机验收待做**：本机无 Android 设备（`adb devices -l` 空）。真机路径：查词弹窗打开 → 上下滑动 + 点击应响应 → 关闭 → 再开（warm 复用）→ 再滑动/点击仍响应。
