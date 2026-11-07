## BUG-1692 · macOS 查词浮层 WebView 完全收不到指针事件（点击/拖拽全失效，Flutter 外壳正常）
- **报告**：2026-08-17（用户：「查词框不能交互，点击任何地方都没反应」；追问后确认平台＝mac、入口＝剪贴板浮窗／视频字幕查词／首页词典页搜索／阅读器划词**四个全中**）
- **真实性**：✅ 真 bug，**已在用户自己的 `/Applications/Hibiki.app` 1.2.0(885) 上用 CGEvent 真实点击复现**（非合成事件、非集成测试环境）。
- **[x] ① 已修复** — 根因见下方「根因（已定位）」，三处落地：
  - `fushi/lib/src/pages/implementations/dictionary_popup_layer.dart` — 浮层 surface 传 `borderOnForeground: false`；尺寸拖拽把手包 `RepaintBoundary`
  - `fushi/lib/src/utils/components/fushi_material_components.dart:3136` — `FushiPopupSurface` 新增 `borderOnForeground` 参数（默认 true，不改既有观感）
  - `fushi/lib/src/pages/implementations/reader_fushi_page.dart` + `reader_fushi/chrome.part.dart` — 阅读器排在 WebView 之后的 chrome（macOS 标题栏拖拽区 / 顶部进度 pill / 底栏）各包 `RepaintBoundary`
- **[x] ② 已加自动化测试** — `fushi/test/tools/bug_1692_platform_view_overlay_guard_test.dart`（6 例：`borderOnForeground` 透传的 widget 行为 + 四处「平台视图之后必须有 RepaintBoundary / 不得 foreground 描边」的源码守卫）；另有先前落的命中测试探针 `fushi/integration_test/popup_hittest_probe_itest.dart`（用 `document.elementFromPoint()` 而非 `.click()`），补既有测试的结构性盲区。
- **iOS 侧**：2026-11-05 在 `upstream/develop`（`df8bddcd161`，Flutter 3.47.6）iPhone 17 模拟器 / iOS 27 上用 XCUITest 真实触摸复验，**浮层 WebView 点击 / 拖拽全部到 DOM，无同类问题、无需修复**；回归用例 `fushi/integration_test/ios_popup_real_touch_itest.dart`。证据与命令见文末「iOS 状态」。
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

### 根因（已定位，2026-08-17）

**不在本仓 widget 树的「哪个组件挡住了」，而在 macOS engine 的平台视图命中测试模型。**

`FlutterCompositor.mm` 合成每一帧时，对每个平台视图，遍历排在它**之后**的 backing-store 图层，把它们的 `paint_region` 与该平台视图求交后写进 `FlutterMutatorView` 的 `_hitTestIgnoreRegion`；而 `FlutterMutatorView.mm` 的命中测试是：

```objc
- (NSView*)hitTest:(NSPoint)point {
  CGPoint localPoint = point;
  localPoint.x -= self.frame.origin.x;
  localPoint.y -= self.frame.origin.y;
  for (const auto& region : _hitTestIgnoreRegion) {
    if (CGRectContainsPoint(region, localPoint)) {
      return nil;              // ← 事件根本不进 WKWebView
    }
  }
  return [super hitTest:point];
}
```

即：**平台视图之上但凡压着 Flutter 绘制，那块区域的鼠标事件就不给平台视图。**

放大成「整块失聪」的是 Flutter 侧的图层合并规则：**同一个 RepaintBoundary 内、平台视图之后的所有绘制会合并成一张 PictureLayer，其 cull rect = 该 RepaintBoundary 的整个矩形**。于是右下角一个 12×12 的拖拽把手，就能让整块 WebView 一个鼠标事件都收不到。

**实测证据**（`debugDumpLayerTree()`，临时诊断已撤）：

```
TransformLayer                                  ← 页面级 RepaintBoundary 内
 ├─ child 1: PictureLayer   (0,0,1206,693)      ← WebView 之前（背景，无害）
 ├─ child 2: OffsetLayer → PlatformViewLayer    ← 阅读器 WebView (AppKitView)
 └─ child 3: PictureLayer   (0,0,1206,693)      ← WebView 之后，整窗 ⇒ 全域忽略
```

浮层侧同构，两张「整个浮层大小」的 PictureLayer 压在浮层 WebView 之后：

```
ClipPathLayer (FushiPopupSurface / Material, Clip.antiAlias)
 ├─ child 1..2: PictureLayer                    ← 顶栏、背景（之前，无害）
 ├─ child 3: OffsetLayer → PlatformViewLayer    ← 浮层 WebView
 └─ child 4: PictureLayer (0,0,384.7,346.2)     ← Material 描边（foregroundPainter）★
child 2 (surface 同级): PictureLayer (0,0,384.7,346.2)  ← 尺寸拖拽把手 ★
```

两个 ★ 各对应一条解法：

1. **拖拽把手 / 阅读器 chrome** → 各自包 `RepaintBoundary`，让 cull rect 收缩到自身，忽略区随之收缩成小块（阅读器实测从 `(0,0,1206,693)` 变成 `(0,0,1206,28)` + `(0,0,121.6,24)` 两小条）。
2. **Material 描边** → `Material.borderOnForeground` 默认 `true`，`RoundedRectangleBorder` 的描边走 `CustomPaint.foregroundPainter`、画在子节点**之后**，且描边天然横跨全域，`RepaintBoundary` 救不了。只能改成在子节点**之前**绘制（`FushiPopupSurface.borderOnForeground: false`）。透明背景的 WebView 仍能透出下面的描边，真机实测**观感无变化**。

**为什么「结果区能点、浮层不能点」**：结果区那个 WebView 之上恰好没有 Flutter 绘制（它是所在页面最后绘制的东西），不进忽略区；浮层则被描边 + 把手整块盖住。同一个 `DictionaryPopupWebView` 组件，命运由**宿主的绘制顺序**决定——这也是之前七组「改浮层自身结构」的对照实验全部失败的原因：改错了层。

**影响面比报告更广**：同一机制下，阅读器正文 WebView 在 macOS 上同样**整块失聪**（点击翻页、划词全部无效）——本次一并修复并真机验证。

### 修复验证（真机 CGEvent 点击，2026-08-17）

| 步骤 | 修复前 | 修复后 |
|---|---|---|
| 阅读器正文点击（翻页/选词） | ❌ 进度恒为 `0 / 95580 0.00%`，无高亮 | ✅ 命中并高亮 `testword` |
| 阅读器划词唤出查词浮层 | ❌ 无浮层 | ✅ 浮层弹出，两条词典释义 |
| 浮层内 WebView：收藏 ☆ | ❌ 无反应 | ✅ 星标变实心橙 ★ |
| 浮层内 WebView：词典条目折叠 `▾` | ❌ 无反应 | ✅ `HibikiGeneratedTestDict` 折叠成 `▸`，相邻条目不受影响 |
| 浮层描边观感 | — | ✅ 无变化 |

中间还做了一次**判据实验**：把阅读器 WebView 临时移到 Stack 末尾（最后绘制），点击立刻恢复 —— 反向坐实「之后绘制的 Flutter 内容」才是唯一变量。

### iOS 结论：**本 bug 不影响 iOS**（已实测 A/B，2026-08-17）

> 2026-11-05 注：下面这段对 iOS 命中模型的描述只对当时的引擎成立。Flutter 3.47 起
> `FlutterTouchInterceptingView.hitTest:` 会**同步问框架**命中路径里有没有平台视图
> （`platformViewShouldAcceptTouchAtTouchBeganLocation` → `PlatformDispatcher.onHitTest`），
> 判据是框架的**命中测试**（不是 macOS 那种按绘制求交的粗矩形）。结论「不受影响」在
> 3.47.6 上已重新实测成立，见文末「iOS 状态」。

iOS embedder 与 macOS 不是同一套模型：Flutter 画在平台视图之上的内容进的是
`FlutterOverlayView`，而它以 **`userInteractionEnabled = NO`** 创建，**根本不参与命中测试**；
触摸路由由 `FlutterTouchInterceptingView` 上的手势识别器 + Flutter 自己的命中树决定。
也就是说 iOS 上**不存在** `_hitTestIgnoreRegion` 这种「粗矩形吞掉整块平台视图输入」的机制。

实测 A/B（iPhone 17 Pro 模拟器 / iOS 26.5，cliclick 注入真实触摸，走真实 UIKit 命中链；
容器里灌入 macOS 开发库的 `fushi.db` + `dictionaryResources/` 两部测试词典）：

| 构建 | 结果区点词唤出浮层 | 浮层内 WebView 折叠 `▾` | 浮层内 ★ 收藏 |
|---|---|---|---|
| **修复前**（`0870424fe^`） | ✅ 弹出 | ✅ 折叠成 `▸` | — |
| **修复后**（`0870424fe`） | ✅ 弹出 | ✅ 折叠成 `▸` | ✅ 实心 ⇄ 空心 |

即 iOS 修复前后行为一致、都正常 ⇒ **iOS 从未受影响，本次修复对 iOS 零回归**。
结论范围因此收敛为：**macOS 独有**。

（真机 iPhone 侧只完成了「装上并跑起来」——物理设备没有触摸注入通道
（`devicectl` 不提供，`idevicescreenshot` 在 iOS 26 上失效），逐项点测需人工；
鉴于模拟器 A/B 已给出确定结论，未再强求。）

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

### 附带发现②：`disableContextMenu` 在 macOS 端**无效**（改了也没用）

试过把 macOS 并入 `disableContextMenu`（`isWindowsPlatform || macOS`）——真机复测
**原生菜单照旧弹出**。该设置在 flutter_inappwebview 的 macOS 实现里没有接到
WKWebView 的对应开关（Windows 是 fork 里专门接的 `put_AreDefaultContextMenusEnabled`）。
要压制 macOS 原生菜单，得走别的路（如 JS 侧 `contextmenu`/`selectstart` 拦截，或
WKWebView 的 `WKUIDelegate`）。该改动已撤回。

### 附带发现①：macOS 没屏蔽 WKWebView 原生上下文菜单

`dictionary_popup_webview.dart` 的 `disableContextMenu: isWindowsPlatform` —— **只在
Windows 关**。macOS 真机实测：在查词**结果区**单击词，弹出的是系统的
「Look Up "xxx" / Translate / Search with 谷歌 / Copy…」原生菜单，而不是 app 的查词浮层；
文字被选中后该菜单还会反复抢占。这与本 bug 是否同源未定，但它本身就干扰 macOS 上的
「点词查词」交互，应单独确认是否要把 macOS 一并纳入 `disableContextMenu`。

### host-owned 指针兜底：已实现，**未取得验证**

按 Windows 同款思路做过一版最小实现（macOS 上给 WebView 外包 `Listener`，`onPointerUp`
时把 Flutter 局部坐标交给 `document.elementFromPoint(x, y)` 并合成
`mousedown/mouseup/click`）。**没能验证**：复测时结果区的点词查词本身只弹系统 Look Up
菜单、浮层无法稳定打开，`[hostclick]` 探针未取得一次有效输出。该实现已从分支撤回。
第二次尝试同样失败：`disableContextMenu` 在 macOS 无效（见附带发现②），菜单照旧抢占，
`[hostclick]` 仍无输出（结果区的指针被 WebView 吃掉、Flutter `Listener` 本就收不到，
属预期；关键是浮层始终没能稳定打开）。

**下次验证的正确姿势**：别再用「点结果区的词」这个入口——它必然撞上系统选词菜单。改用
**阅读器划词**或**剪贴板浮窗**把浮层打开（测试库里有 `Pagination Test Book` 可用），
再对浮层内的按钮验证 host-owned 转发是否生效。

### 下一步（**已作废**，保留为思路留痕）

> 2026-08-17 更新：根因已由 `debugDumpLayerTree()` + engine 源码（`FlutterMutatorView.mm` /
> `FlutterCompositor.mm`）定位并修复，见上方「根因（已定位）」。以下三条是定位前的推测方向，
> **都不必再走**。其中第 2 条对 `dictionary_popup_input_bridge.dart` 注释前提的质疑是对的
> （macOS 上指针确实不是「被 WebView 直接吃掉」），但结论指向的 host-owned 兜底（第 3 条）
> 是**不必要的**：根因在绘制顺序，不需要合成事件转发，原生鼠标输入已恢复。

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

**已验证（2026-11-05，`upstream/develop` `df8bddcd161`，Flutter 3.47.6）：浮层 WebView 收得到真实触摸，iOS 无同类问题，未改产品代码。**

环境：Mac（Xcode 27.2）上 iPhone 17 模拟器 `4DDB6CD0-A321-4EA8-B8E5-4B043B5ABFDA` / iOS 27；
真实触摸由 XCUITest 走模拟器 HID 通道投递（经 UIKit `hitTest:` → `FlutterTouchInterceptingView`
→ WKWebView，与手指同一路径），不是 JS `.click()`、不是 `tester.tap`。

命令（Mac，`fushi/` 下）：

```bash
TAG=popuptouch bash integration_test/support/run_sim_touch_itest.sh 4DDB6CD0-A321-4EA8-B8E5-4B043B5ABFDA
# → 00:44 +1: All tests passed!  RUN_END rc=0
```

用例 `fushi/integration_test/ios_popup_real_touch_itest.dart`（真 app：首页词典查「猫」→ 真触摸点结果区
词头 → 弹出嵌套浮层 → 浮层内逐项真触摸；每步读 WebView 里 capture 阶段的 DOM 事件探针）：

| 步骤 | 落点（逻辑 px） | 框架命中路径含该平台视图 | DOM 收到 | 结果 |
|---|---|---|---|---|
| 结果区点词头「猫」 | (31.0, 168.4) | ✅ | `pointerdown/touchstart/pointerup/touchend/click`（`RT`） | ✅ 弹出嵌套浮层 |
| 浮层内点收藏 ☆ | (289.1, 293.1) | ✅ | 同上五件，`click` 落在 `.favorite-button` | ✅ `favorited false→true`，截图 ★ 变实心 |
| 浮层区域扫描 ×8（中心、四角、左右中、下中，内缩 8px） | 可见卡片 `(7,257.7)-(395,451.7)` 内 | 7 处 ✅ / 右下角 ❌ | 7 处 ✅ / 右下角无事件 | ✅ 与框架判定逐点一致；右下角是 Flutter 的尺寸拖拽把手，该归 Flutter |
| 浮层内竖拖（按住 0.6s 后拖） | (201,305.7)→(205,431.7) | — | `touchmove` ×27 | ✅ 原生选区「猫
Generated Japanese lookup」 |
| 浮层 Flutter 外壳点 × | (366.8, 232.5) | — | — | ✅ 浮层关闭 |

附带观测：前一轮把拖拽做成横拖时，DOM 收到 78 个 `touchmove`，同时浮层被「滑动关闭」
（`_BodySwipeDismissDetector`，iOS 默认开）关掉——指针同时到了 WebView 与 Flutter 的滑关手势，属预期。

**为什么 iOS 不会出现 macOS 那种整块失聪**：3.47 的 iOS 判据是框架 `hitTestInView` 的命中路径
（`GestureBinding._handleHitTest`：路径里有 `NativeHitTestTarget` 即交给平台视图）。描边是纯绘制、不参与
命中，拖拽把手只占右下角自己的命中区——扫描结果正好是「只有右下角归 Flutter」。

**测试装置的根因（顺带修掉的结构性盲区）**：此前多份记录（BUG-3482、BUG-3876）写「`flutter test` 下
平台视图收不到 XCUITest 真触摸」，只当成环境限制绕开。根因是：`GestureBinding.initInstances` 把
`onHitTest` 设到 `binding.platformDispatcher`，集成测试绑定里那是 `TestPlatformDispatcher`，它没实现
`onHitTest` 的 setter（`flutter_test/lib/src/window.dart` 的 `noSuchMethod` 直接返回 null），真
dispatcher 的 `onHitTest` 一直是 null → 引擎拿 `HitTestResponse.empty` → 所有平台视图拒收触摸。
`fushi/integration_test/support/ios_real_touch.dart` 的 `IosRealTouchSession` 把同一判据装到真
`PlatformDispatcher.instance.onHitTest`，并打开 `shouldPropagateDevicePointerEvents`。
**对照**：同一用例把这一行去掉重跑，结果区点词 `RESULT-AREA events=[]`（Flutter 收到了 Down/Up，
WebView 零事件）——坐实上述根因，也说明不装它时 iOS 真触摸用例必然假红。

装置：`fushi/integration_test/support/ios_touch_tapper/`（XCUITest 投递器，xcodegen 生成工程）+
`support/run_sim_touch_itest.sh`（编排：等 flutter 的 Xcode 构建结束再起投递器、把日志里的
`[ios-touch] TAP` 行桥成请求文件、每次触摸后截一张真屏）。

证据（Mac）：`~/dev/popuptouch-evidence-20261105/pass/`（`popuptouch-itest.log`、`popuptouch-tapper.log`、
`shots/t000–t011.png`，`t001.png` 为点收藏后的浮层）与 `control-no-onhittest/popuptouch-itest.log`。

真机：Mac 配对着 iPhone 17（`HUAWEI 17`），但真机没有触摸注入通道，未测；iOS 引擎的命中判据在
模拟器与真机上是同一份代码。

<details><summary>2026-08 的旧状态（已过时，留痕）</summary>

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

</details>
