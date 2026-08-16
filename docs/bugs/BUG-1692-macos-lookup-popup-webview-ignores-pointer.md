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

### 下一步排查方向（按优先级）

浮层与结果区的结构差异只剩这几条，逐条证伪即可收敛：
1. 浮层挂在**根 Overlay**（`home_dictionary_page.dart::_syncPopupOverlay` / `_buildPopupOverlay`），结果区挂在页面 widget 树内 —— Apple 平台视图在 `OverlayEntry` 子树里的命中路径。
2. 浮层特有的 `Visibility(maintainSize:…)` + `Positioned`（隐藏层停到 `screen.width + 8` 屏外，BUG-135）。
3. 浮层入场淡入（`_PopupEntranceFade` / `AnimatedOpacity`）——即便静止在 opacity=1，仍可能影响 Apple 平台视图的 mutator 链。
4. `_BodySwipeDismissDetector` **无条件**存在的 `Listener(behavior: HitTestBehavior.opaque)`（关掉滑关开关后它仍在，只是 child 不再套 Transform/Opacity）。
5. Flutter SDK 侧：`RenderAppKitView.updateGestureRecognizers` 在 macOS 上是空实现（`rendering/platform_view.dart`，带 `TODO flutter#128519`），且基类 `_handleGlobalPointerEvent` 对每次 PointerDown 调 `rejectGesture()`；`input_bridge.dart` 里 `hostOwnsDictionaryPopupPointerInput = isWindowsPlatform` 的注释假设「macOS 上 WebView 直接吃掉指针」，该前提与框架现状冲突，需复核。

### iOS 状态

**未验证**。最新 develop 上 iOS 模拟器**无法构建**：`fushi/ios/build_aidoku_runtime.sh` 硬性要求 `PLATFORM_NAME == iphoneos`，跳过它则链接阶段缺 `libfushi_aidoku_runtime.a`，而本机未装 `aarch64-apple-ios-sim` target（脚本明示不为模拟器下载组件）。iOS 侧要么真机验证，要么另行支持模拟器架构构建。
