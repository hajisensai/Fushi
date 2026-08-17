## BUG-1692 · macOS 查词浮层 WebView 完全收不到指针事件（点击/拖拽全失效，Flutter 外壳正常）
- **报告**：2026-08-17（用户：「查词框不能交互，点击任何地方都没反应」；追问后确认平台＝mac、入口＝剪贴板浮窗／视频字幕查词／首页词典页搜索／阅读器划词**四个全中**）
- **真实性**：✅ 真 bug，**已在用户自己的 `/Applications/Hibiki.app` 1.2.0(885) 上用 CGEvent 真实点击复现**（非合成事件、非集成测试环境）。根因层尚未定位到 `file:line`，已排除三条候选，见下。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — 已先落**命中测试探针** `fushi/integration_test/popup_hittest_probe_itest.dart`（用 `document.elementFromPoint()` 而非 `.click()`），补上既有测试的结构性盲区；浮层侧的守卫待根因定位后补。
- **备注**：既有 `popup_dictionary_test.dart` 用 `element.click()` 直接派发事件，**绕过 DOM 命中测试**，因此本 bug 在它下面永远是绿的——这是它测不出「点不动」这类问题的结构性原因，不是用例写漏。

### 现象（真机实测矩阵，macOS 26.6 / M4 / Hibiki 1.2.0(885)）

| 操作对象 | 真实点击结果 |
|---|---|
| 查词**结果区** WebView：点词 | ✅ 有效（嵌套浮层就是这么点出来的） |
| 查词**结果区** WebView：`+` 制卡 | ✅ 有效（按钮组变为「已添加 ✓ / 在 Anki 中打开」） |
| **浮层**顶栏 `A+` / `A−` / `×`（Flutter 画的） | ✅ 有效（字号确实变大） |
| **浮层**外部 barrier（点浮层外面关栈） | ✅ 有效 |
| **浮层内** WebView：点词查嵌套 | ❌ 无任何反应 |
| **浮层内** WebView：按住拖拽选文字 | ❌ 选不中任何字符 |

即：**同一个 `DictionaryPopupWebView` 组件，挂在结果区能收指针，挂在浮层里完全收不到**；浮层的 Flutter 外壳与 barrier 都正常，坏的只有浮层内的平台视图。点击与拖拽同时失效 ⇒ 不是「click 坐标映射偏了」（对比 Windows 侧 BUG-1652 那类旧光标坐标问题），而是**该 WKWebView 整体拿不到指针输入**。

### 已排除的候选（勿重走）

1. **「滑动关闭弹窗」的 `Transform`+`Opacity` 包装**（`dictionary_popup_layer.dart` `_BodySwipeDismissDetector.build`）。
   该开关是 Apple 与 Windows 在弹窗指针链路上**唯一**的默认值分叉（`reader_settings.dart::defaultSwipeToClose`：Windows/Linux false、macOS/iOS/Android true），开启时把平台视图包进 `Transform.translate` + `Opacity`，一度是头号嫌疑。**真机对照实测：关掉该开关后，浮层内点词仍然毫无反应**，排除。
2. **BUG-1651 的弹窗自适应高度回路**（`onContentMetrics → setState(autoFitHeight)`）。该实现只存在于**本地未推送**的提交 `64d6a2bdc`，`origin/develop` 与用户运行的发布版都不含它，不可能是本 bug 成因。
3. **「WKWebView 视口塌陷成 0×0 导致命中恒空」**。macOS 集成测试里确实抓到过 `innerHeight/innerWidth = 0` + `elementFromPoint` 返回 null，但**同一探针重跑得到 `innerHeight 478 / innerWidth 1083`、`hitIsSelf: true`**，且截图证实跑集成测试时 macOS 上根本没有可见窗口 ⇒ 那组 0 值是**离屏 + 布局未稳的瞬时伪影**，不是产品事实。任何基于「视口 0」的推论都必须先确认窗口可见。

### 指针到底有没有到 WebView：到不了（已定性）

在浮层**有真实词条**（非 no-results 面板）的状态下按住拖拽选字，**一个字符都选不中**。
文本选择是 WKWebView 自己的行为、不经过 popup.js 的任何绑定，因此这条排除了
「指针到了、只是 JS 没绑点词」的可能：**指针根本没到达浮层的 WKWebView**。

### 决定性观测：事件根本没进浮层的 WebView

给 `DictionaryPopupWebView` 注入 DOM 探针（`mousedown`/`mouseup`/`click`/`pointerdown`
四个事件 capture 阶段 `console.log`，经 `onConsoleMessage` 回到 Dart 日志），两个实例
装的是**同一份**脚本：

```
[probe] installed                                   ← 结果区实例
[probe] installed                                   ← 浮层实例
点结果区的词：
[probe] pointerdown @66,30 tag=SPAN cls=expression
[probe] mousedown  @66,29 tag=SPAN cls=expression
[probe] mouseup    @66,29 tag=SPAN cls=expression
[probe] click      @66,29 tag=SPAN cls=expression
点浮层内的词：
（无任何输出）
```

⇒ 浮层的 WKWebView **一个鼠标事件都收不到**，连 `pointerdown` 都没有。不是 JS 绑定、
不是 DOM 命中、不是 `pointer-events`——事件在进入 WebKit 之前就丢了。

### 对照实验（每条都改代码、重新构建、真机 CGEvent 点击复测）

| # | 改动（仅 macOS 分支） | 结果 |
|---|---|---|
| A | `parkedPopupLayer` 不再把隐藏层停到屏外（`left: screen.width + 8` → 保持 `pos.left`） | ❌ 仍点不动 |
| B | 可见态旁路 `Visibility(maintainSize)` + 入场淡入 `_PopupEntranceFade`/`AnimatedOpacity` | ❌ 仍点不动 |
| C | `_BodySwipeDismissDetector` 的 `Listener` 由 `HitTestBehavior.opaque` 改 `deferToChild` | ❌ 仍点不动 |
| D | 浮层不挂根 Overlay、改由页面内 `Stack` 渲染 | ❌ 仍点不动 |
| A+B+C+D | 四项**同时**应用（排除多因叠加） | ❌ 仍点不动 |
| E | 不 seed 常驻热槽，每次查词新建 WebView（排除「热槽 WebView 创建时隐藏在屏外导致 NSView 永久失聪」） | ❌ 仍点不动 |
| F | 浮层可见时**不渲染**结果区 WebView，使浮层成为唯一平台视图（排除重叠平台视图事件路由） | ❌ 仍点不动 |
| G | `FushiPopupSurface` 的 `Clip.antiAlias` 圆角裁剪改 `Clip.none`（排除 clip mutator） | ❌ 仍点不动 |

所有诊断改动均已从分支撤回（只是实验，不入库）。

### 结论：范围已压到 Flutter widget 层之外

浮层与结果区用的是**同一个 widget 类、同一份注入脚本**；把两者之间所有 Flutter 侧差异
（包装、挂载位置、实例复用、重叠、裁剪）逐一消除后，行为差异**依然存在**。因此根因不在
本仓的 widget 代码，而在 **macOS 平台视图层**：`AppKitView` / Flutter macOS embedder 的
事件路由，或 `flutter_inappwebview_macos` 的 `FlutterWebViewController`（`NSView` 子类，
`webView.frame = self.bounds` + `autoresizingMask`，见 pub-cache 1.1.2）在**动态创建 /
频繁改尺寸**的实例上不接管鼠标。

### 下一步（需要原生侧手段，非 Dart 侧试错）

1. 用 Xcode 的 **Debug View Hierarchy** 或 lldb 打印两个 `WKWebView` 的 `NSView` 层级、
   `frame`、`hitTest:` 结果，直接对比「收得到」与「收不到」的实例差在哪。关键怀疑：
   浮层实例的 NSView 未被加入响应链，或其祖先某层 `hitTest:` 返回 nil。
2. Flutter SDK 侧：`RenderAppKitView.updateGestureRecognizers` 在 macOS 上是空实现
   （`rendering/platform_view.dart`，带 `TODO flutter#128519`），基类 `_handleGlobalPointerEvent`
   对每次 PointerDown 调 `rejectGesture()`。`dictionary_popup_input_bridge.dart:162-168`
   的注释断言「Android / iOS / macOS / Linux：WebView 是真正的原生视图，指针被它直接吃掉」——
   **该前提在 macOS 上与实测矛盾**（同一平台，结果区吃得到、浮层吃不到）。
3. 可行的兜底方案：把 macOS 并入 **host-owned 指针路径**（`hostOwnsDictionaryPopupPointerInput`
   目前仅 Windows true），由 Flutter 侧 `Listener` 接管指针并经 JS 桥转发坐标——Windows
   fork 已验证这条路可用，代价是需要为 macOS 补一套坐标转发。

### iOS 状态

**未验证**。原因是 iOS 模拟器在最新 develop 上**根本构建不起来**：
`fushi/ios/build_aidoku_runtime.sh` 硬性要求 `PLATFORM_NAME == iphoneos`，模拟器直接 `exit 1`；
绕过该 gate 则链接阶段缺 `libfushi_aidoku_runtime.a`。这挡住的不只是漫画源，而是
**所有 iOS 集成测试**（查词、阅读器等与 Aidoku 无关的用例一并无法在模拟器上跑）。

本 PR 顺带修掉这条构建门（`build_aidoku_runtime.sh` 按 `PLATFORM_NAME` + `ARCHS`
逐架构构建 + lipo），实测 `flutter build ios --debug --simulator` 已能产出
`Runner.app`，iOS 集成测试全面解锁。

解锁后在 iPhone 17 Pro 模拟器上跑命中探针：**结果区 WebView 命中正常**
（`innerHeight 509 / innerWidth 402`，favorite / mine 均 `hitIsSelf: true`、
`inViewport: true`，用例 All tests passed）。与 macOS 结果区结论一致。
**iOS 的浮层侧仍未验证**——探针目前只覆盖结果区，且模拟器上的真实触摸注入需要
桌面解锁后用 CGEvent 点模拟器窗口。
