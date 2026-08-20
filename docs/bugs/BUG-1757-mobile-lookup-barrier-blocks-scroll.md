## BUG-1757 · 手机上查词弹窗滚动卡住——两条候选根因已实测排除，症状待用户澄清场景
- **报告**：2026-08-20（用户：「手机上下滚动查词弹窗的时候查词，容易卡住，就是基本上滚动不了」）
- **真实性**：⚠️ **待定**——用户原话有歧义（"弹窗自身滚不动" vs "弹窗开着时正文滚不动"），
  两种解读对应完全不同的修法。本轮把**手势层**的两条候选根因实测排除，并顺手把 barrier
  接线收口成单一原语；**用户报的症状本身尚未定位**，等用户确认场景后继续。
- **[ ] ① 未修复** — 症状未定位，见下「待澄清」。本轮落地的是结构收口（不是该 bug 的修复）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/lookup_dismiss_barrier_test.dart`（新原语手势契约
  + 把「barrier 填充盒对 hit test 实心」这条实测事实写成可执行注记）、
  `fushi/test/utils/barrier_swipe_dismiss_tracker_test.dart`（判轴/阈值纯函数，新增 6 条判轴用例）、
  `fushi/test/pages/barrier_swipe_close_surfaces_guard_test.dart`（四表面接线守卫，已变异实测）。

### 已实测排除的候选根因（别再重走）

**① barrier 的横拖识别器霸占手势竞技场堵死 platform view —— 不成立。**

这条链条本身是自洽的、且在别处真实存在过（BUG-1242 就是它）：
`HorizontalDragGestureRecognizer` 对纯纵向拖动既不 accept 也不 reject（`monodrag.dart` 的
`possible` 分支只在 `hasSufficientGlobalDistanceToAccept`——只看 dx——为真时才 resolve），
而 `rendering/platform_view.dart` 的 `_PlatformViewGestureRecognizer` 在 `acceptGesture`
之前把所有事件塞进 `cachedEvents` 一个不转发。推下来「弹窗一开正文就滚不动」严丝合缝。

**但实测否定了它。** 用真的 `PlatformViewSurface`（即 InAppWebView 在 Android 上的底座）
当下层做对照实验：

| 盖在上面的东西 | 平台视图收到的指针事件 |
|---|---|
| 无 | 14 |
| 只有 tap 的 translucent `GestureDetector`（**带**透明 `ColoredBox` 子节点） | 0 |
| 只有 tap 的 translucent `GestureDetector`（**不带**子节点） | 14 |
| 不带任何手势的裸 `ColoredBox` | 0 |
| 旧写法（tap + `onHorizontalDrag*`） | 0 |
| 新原语 `LookupDismissBarrier` | 0 |

真正挡住下层的是 barrier 的**透明填充盒**（`ColoredBox` / `Container(color:)`）——它对
hit test 是实心的，下层 platform view 根本进不了 hit test 结果、也就从不参与竞技场。
识别器怎么写都不影响这一点。

**推论（重要）**：「查词弹窗开着时，正文完全收不到触摸」是 dismiss barrier 的**既有设计**
（点它是要关窗，不是要穿透），不是手势 bug。要改属于产品行为变更。

**② 弹窗自身的 WebView 手势配置抢走纵向滚动 —— 不成立。**

`dictionary_popup_webview.dart:1384-1391` 是全 app 唯一传了非空 `gestureRecognizers` 的
WebView（`LongPressGestureRecognizer(250ms)` + `VerticalDrag` + `HorizontalDrag`），曾怀疑
读释义时手指停顿 >250ms 会让 long-press 先赢、把滚动吃掉。实测同款配置：

- 按下即纵向滑：14 个事件（全部转发）
- 按住 300ms 再纵向滑：14 个事件（全部转发）
- 空集合识别器（阅读器 WebView 那条路）：14 个事件
- 按住 300ms 不动直接抬手（纯长按）：2 个事件（符合预期，长按走选词）

弹窗自身的手势链在滚动这件事上是健康的。

**③ 隐藏热槽停在屏内截触摸（BUG-692 / BUG-135 家族）—— 本轮复核未发现问题。**

用户这次的措辞与 BUG-692 原始报告高度相似（「基本上下滑不动，点击也没反应」），故重点复核
了各宿主传给 `parkedPopupLayer`（`dictionary_popup_layer.dart:298-320`，停到 `screen.width + 8`）
的 `screen`：`base_source_page.dart` 用整窗 LayoutBuilder 约束；`home_dictionary_page.dart`
的 LayoutBuilder 在 `FushiAppUiScaleNeutralizer` **内层**、坐标系即真实屏幕空间。两处几何正确。
（未逐一复核 video / popup_dictionary_page / floating_lyric_lookup_host。）

### 待澄清（决定下一步修哪儿）

用户原话可拆成两种读法，修法完全不同：

- **A「弹窗自身滚不动」**：手势层已排除（见 ②），需往 WebView 内部 / 具体宿主查。
  仍未排除的次要嫌疑：弹窗右下角 18×18 的 resize 把手（`_PopupResizeGrip`，
  `dictionary_popup_layer.dart:1287-1323`，`opaque` + pan 识别器）在**移动端也开着**
  （`base_source_page.dart:774`、`dictionary_page_mixin.dart:689` 都传 `showResizeGrip: true`），
  手指落在右下角滑动会被它吃掉；以及 `_BodySwipeDismissDetector` 每次 pointerDown 都
  `setState`（`dictionary_popup_layer.dart:1177`）导致含平台视图的子树重建。
- **B「弹窗开着时正文滚不动」**：这是 barrier 实心遮挡的设计（见 ①）。手机上 tap barrier 会
  关窗，但**滑动**既不关窗也不透传，手指划过去毫无反应——体验上就是「卡住」。若要改，
  方向是「barrier 上的纵向滑动 → 关闭弹窗」（Flutter 无法把已被上层吞掉的事件补发给
  platform view，做不到真正的滚动透传，用户仍需两次手势）。属产品决策。

### 本轮实际落地的改动（结构收口，非该 bug 的修复）

四个表面（`base_source_page` = 阅读器/有声书、`video_fushi_page`、`home_dictionary_page`、
`texthooker_page`）此前各自手拼 `GestureDetector(onTap* + onHorizontalDrag*)` + 透明填充盒，
并各持一份 `BarrierSwipeDismissTracker` + 三个转发方法——同一手势语义复制四份、判轴完全
交给竞技场。收口成唯一原语 `LookupDismissBarrier`
（`fushi/lib/src/utils/misc/lookup_dismiss_barrier.dart`）：

- 横拖改走不入竞技场的 raw `Listener` + **显式判轴**（沿用 BUG-1242 在弹窗本体上确立的范式），
  判轴规则从「隐含在竞技场 accept/reject 时序里」变成可单测的代码；
- 灵敏度在 `begin` 时定死一次，`update`/`end` 不再重复接收（少一个「每次要传对」的参数）；
- 行为等价：横向过阈关一层、未过阈不关、开关关闭时惰性、鼠标横拖照样关（TODO-716 的桌面
  初衷）、tap 带全局坐标——既有行为测试 `base_source_page_barrier_swipe_close_test.dart` 全绿。

守卫做了变异实测，其中一次变异暴露了守卫自身的假阳性：`shouldShowLookupDismissBarrier(`
含子串 `LookupDismissBarrier(`，导致把真原语换成手拼 `GestureDetector` 后守卫仍绿；已加左
词边界正则修正（细节写在守卫文件注释里）。

- **备注**：`texthooker_page.dart` **仍然存在**——`barrier_swipe_close_surfaces_guard_test.dart`
  原注释称「其页面已随 galgame 字幕并入查词弹窗而移除」是过期信息，本轮已把它加回守卫覆盖。
