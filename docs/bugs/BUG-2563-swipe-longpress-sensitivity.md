## BUG-2563 · 滑动翻页灵敏度不足且设置项方向反了；长按选择不灵敏、没有高亮
- **报告**：2026-09-16（用户：滑动翻页灵敏度还不够高，参照一下 hoshi reader 怎么做的，并且调高上限 / 长按选择也不够灵敏并且好像没有高亮）
- **真实性**：✅ 真 bug，三条独立根因。

  **① 滑动翻页阈值本身偏钝** —— `reader_settings.dart` `baseSwipeDistPx = 44` /
  `baseSwipeFastDistPx = 22`，速度门 `900` px/s 写死在三处 JS
  （`webview.part.dart:988`、`:1126`，`reader_fushi_page.dart:649`）。
  参考实现 Hoshi-Reader-Android `SwipePageTouchListener.kt:37,46` 只有一个判据：
  `|dx| >= 72` **原始设备像素** 且 `|dx| >= |dy|`，而那个 72 **不做 density 换算**
  （同文件 `ReaderWebView.kt:735` 明明有 `androidPixelsToCssPixels`，翻页阈值刻意
  不用），所以 3x 屏手机上的有效阈值只有 **24 CSS px**——本仓的 44 差不多是它的
  1.8 倍。速度门更悬殊：Hoshi 没有任何自定义速度阈值，只靠 Android `GestureDetector`
  内部的 fling 下限（`scaledMinimumFlingVelocity`，平台默认 50 dp/s）；本仓要 900 px/s，
  比 Android `ViewPager` 的 400 dp/s 还高一倍多，**「快速短滑」那条路实际上几乎从不触发**。

  **② 灵敏度设置项的方向是反的** —— `swipe_page_turn_sensitivity` 存的是**阈值倍数**
  （`swipePageTurnDistThresholds` 里 `base * s`，值越大阈值越大 = **越迟钝**），而
  `settings_schema_reading.dart` 上这条 slider 的标题是「滑动翻页灵敏度」，且**没有**
  `titleReadout`（紧邻的「滚轮翻页间隔 (450)」有）。于是用户「想更灵敏 → 往右拖」，
  拿到的恰恰是更迟钝，而且看不到数值、无从发现自己拖反了。用户报「不够灵敏」时
  多半正处在这个反向端。

  **③ 长按选择 arm 门控用错了命中判据（「不灵敏」与「没高亮」的同一个根因）** ——
  `reader_selection_scripts.dart` 的 `lpsAllowed` 用 `getCharacterAtPoint` 决定要不要
  起长按计时器，而该函数为**查词**服务，命中 scan 边界（空白/标点）时
  `if (this.isScanBoundary(text[offset])) return null`。长按落在标点、句读、行首缩进
  上因此 **连计时器都不 arm**：既不会进入拖选、也不会建立选区，自然一个像素的高亮
  都没有。用户看到的「不够灵敏」和「好像没有高亮」是同一件事的两面。
  两个阈值也偏严：`delayMs = 400`、`slop = 10`。10px 是全仓最紧的触摸容差
  （连续模式边界手势 12px、翻页 24px），且要求手指在**整个**长按时限内始终停在
  10px 半径内，实际上比单击还难触发；400ms 这条则是同一个 app 里唯一没跟上
  BUG-536（弹窗长按 500→250ms，理由同样是「等待时间太长」）的长按路径。

- **[x] ① 已修复** — `pr/swipe-longpress-sensitivity`
  - 阈值对齐 Hoshi 的有效值：`baseSwipeDistPx` 44→**24**、`baseSwipeFastDistPx` 22→**12**、
    速度门 900→**300** px/s。速度门同时从三处 JS 字面量提成
    `baseSwipeFastVelocityPxPerSec`，随灵敏度一起缩放，经 `ReaderEngineConfig.swipeFastVelocity`
    下发（install + liveUpdate 两条通道都带上）。
  - 灵敏度语义翻正：值即灵敏度本身（越大越灵敏，阈值取 `base / s`），取值域
    0.5–3.0。**换新 key** `swipe_page_turn_sensitivity_v2`——旧 key 存的倍数与新语义
    互为倒数，同一个 key 无法区分「旧值 2.0（最迟钝）」与「新值 2.0（很灵敏）」，
    沿用会把老用户的设置整个翻反。旧值走**读时取倒数**换算，不写盘：
    `applyPrefsSnapshot` 是不跑迁移的只读旁路（`resolveEffectiveReaderSettings` 走它），
    写盘迁移只挂 `loadFromPrefsSnapshot` 会让两条路径读出不同手感。
    slider 补上 `titleReadout`，用户看得到档位。
  - `dist` 的下界取 `tapSlopPx + 1`：低于它，一次净位移不到查词轨迹半径的横向抖动
    就会翻页，点词会被翻页整片吃掉（tap 判轨迹半径、swipe 判净位移，轨迹半径恒 ≥ 净位移）。
  - 长按命中测试**分层**：新增 `getSelectableCharacterAtPoint`（几何 + 可见性，
    **不**剔除词边界），`getCharacterAtPoint` 变成它之上加一层 `isScanBoundary` 剔除。
    `lpsAllowed` / `beginRangeSelection` / `updateRangeSelection` / `moveSelectionHandle`
    四个**选择**入口改走前者，查词入口 `selectText` 仍走后者（零回归）。
    BUG-1797 的可见性收口留在几何层，页边距上的点照旧不可选。
  - `delayMs` 400→**280**（对齐 BUG-536 的结论，仍远高于轻点、仍早于 WebView 原生
    长按 ~500ms）、`slop` 10→**16**（仍小于翻页距离门 24，滑动翻页照样能在 arm
    阶段被 slop 取消，两者不互抢）。

- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/swipe_page_turn_sensitivity_test.dart`（重写）：钉死
    **语义方向**（更大 = 更灵敏 = 阈值更小）、新取值域、三个阈值的具体值、
    旧倍数值的倒数换算（2.0→0.5 / 0.5→2.0 / 1.0 不变 / 新 key 覆盖旧值）、
    最灵敏档仍高于 tap slop，以及「默认必须比修复前更灵敏」的回归护栏。
  - `fushi/test/reader/reader_longpress_drag_select_guard_test.dart`：新增
    「命中测试分层」一组——几何层**不得**含 `isScanBoundary`、查词层**必须**含且
    必须复用几何层、arm 门控必须走选择命中；并钉死 280ms / 16px（16²=256）。
  - `fushi/test/reader/reader_selection_handles_guard_test.dart`：扩选与手柄拖动
    改钉选择命中。
  - `fushi/test/reader/spread_page_turn_input_test.dart`：默认值单一真值守卫改按
    getter 语义断言，并新增**读序**守卫（新 key 必须先于旧 key 被读、旧值必须取倒数）。
  - `fushi/test/reader/reader_paged_touch_swipe_behavior_test.{dart,js}`：node 真跑的
    手势行为 harness 以前**自带第二份硬编码阈值 44/22 且没有速度门**，于是生产阈值
    一改它既不转红、也不再验真正的判据（`velocity >= undefined` 恒 false，「快速门」
    那条用例其实是靠距离门碰巧过的）。改成由 Dart 侧把
    `swipePageTurnDistThresholds(1.0)` 经 argv 传入，用例位移改用从阈值派生的
    `SHORT_DX`（落在 tap slop 与距离门之间），快慢两条只差时长——「同样的距离，
    快的翻页、慢的是死区」成为被执行出来的事实。

- **备注**：
  - 真机触屏手感（长按拖选、滑动翻页）只能在真触屏 WebView 验（离屏 `pointer: fine`
    不触发 `@media (pointer: coarse)`），**本条尚未真机复测**，以上为源码/行为级证据。
  - 范围外但相邻：漫画阅读器 overlay 另有一套**独立硬编码**的滑动判据
    `manga_overlay_html.dart:1264`（`ax >= 72 || (ax >= 36 && vel >= 900)`），比阅读器
    改动前还钝一倍，且不受本设置项控制。本次未动。
  - Hoshi 侧另一个值得记的事实：它**没有**任何用户可调的翻页灵敏度设置，长按选择
    也完全是 WebView 原生（`SwipePageTouchListener.onTouch` 返回 `false` 放行事件流，
    全仓零 `ActionMode`）。所以「参照 hoshi」= 参照它的**阈值取值**，不是照搬架构。
