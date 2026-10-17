## BUG-3324 · iOS 阅读器查词关闭后滑动自动弹出复制框并卡顿（未复现）
- **报告**：2026-10-13（用户：hajisensai/Fushi#2108「远古bug：小说在查词后，关闭查词窗口后并进行翻左右滑动等等操作时，会自动触发复制框，而且经常因此导致卡顿、卡死等」，iPhone 截图：正文横向停在两栏之间、两个选区手柄被 clamp 在屏幕左缘那一栏上、「搜索 / 复制 / 收藏」操作条弹出）
- **真实性**：❌ **未复现**（现象真实，产生路径未找到）。截图能读出的：正文不对齐页边（大概率是滚动模式），手柄在最左那一栏的字上——即手指在左缘起手、长按拖选识别器（`fushi/lib/src/reader/reader_selection_scripts.dart` `longPressDragGestureScript`：touchstart 起 400ms 计时器，位移超过 tap slop 取消）在这次触摸上触发了。
  - 已否定的假设：「查词屏障盖住 WebView 时，WKWebView 的 JS 先收到 touchstart、而 touchmove/touchend 被 Flutter 平台视图的 `FlutterDelayingGestureRecognizer` 扣到手势结束才放行，计时器在陈旧触摸上触发」。iOS 26.5 模拟器 + 最小 Flutter app（`flutter_inappwebview` 6.1.5 / ios 1.1.2、`isTextInteractionEnabled:false`、复刻 `LookupDismissBarrier` 结构）+ XCUITest 真实触摸，Flutter 3.47.6 与 3.44.0 各一轮：屏障在场时 3.47.6 下 JS **零事件**（引擎在 UIKit hitTest 时同步问框架，WebView 不在命中路径里）；3.44.0 下 touchstart 后 3–4ms 即 touchcancel（`lpsReset` 清计时器）。屏障上横滑 / 慢滑 / 点按 / 原地按住 800ms，长按计时器都没触发；屏障关闭后的下一次横滑事件流实时、正常。
  - 装置里唯一能复现复制框的路径是**无屏障时手指 400ms 内位移不到 tap slop**（按住不动再滑）——这是长按选择本身的语义（BUG-2919 的取舍），不是缺陷。
  - 未覆盖：真机触摸节奏 / 120Hz 采样、Fushi 完整组件树（弹窗 WebView 热槽、滚动模式「继续滚动即关闭弹窗」经 `PointerRouter` 把同一根手指的后续位移转给正文的路径）。
- **[ ] ① 未修复** — 没有可证实的根因，不做靠延迟 / 时间窗 / 特判掩盖的改动。需要报告者补充：阅读模式（翻页 / 滚动 / VN）、关闭查词窗的方式（点空白 / 横滑 / 滚动正文）、iOS 版本，最好附一段录屏。
- **[ ] ② 未加自动化测试** — 同上。
- **备注**：同一 issue 的「复制框看不到选中范围」是另一条真 bug，见 [BUG-3323](BUG-3323-webkit-highlight-anonymous-block.md)，已修。取证装置与原始日志在本机 `D:/hibiki-tmp/issue2108/touchprobe/`（不入库）。
