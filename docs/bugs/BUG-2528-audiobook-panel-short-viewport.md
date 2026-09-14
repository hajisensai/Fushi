## BUG-2528 · 有声书面板在矮窗（手机横屏）下分段条以下的内容滚不出来

- **报告**：2026-09-14（用户：截图，阅读器内「有声书」面板，横屏；分段条「资源 / 章节 / 设置」以下一片空白，滑不出来）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_audiobook_panel.dart:132-172`（上游 `017429cd40`）：面板恒为 `Column(mainAxisSize: min)` + 固定的「标题行 + 信息卡 + 分段条」+ `Flexible(SingleChildScrollView(tab 内容))`。`Flexible` 在可用高度不足时**不会报 overflow，而是被压到 ~0**——固定部分实测占 312dp，而手机横屏走的是 `chrome.part.dart` 的 bottom sheet 路径、高度只有 `0.9 × 屏高`（768×348dp 下 ≈313dp）。widget test 实测：tab 视口只剩 **1.2px**、`maxScrollExtent ≈ 18.8`（且那 18.8 属于被压扁的内层视口），于是资源 / 章节 / 设置三个 tab 的内容既看不见、也滚不出来。因为没有 overflow 异常，旧测试（宿主固定 700dp 高）完全照不到。
- **[x] ① 已修复** — `reader_audiobook_panel.dart` 的 build 外面加 `LayoutBuilder`：可用高度 ≥ `kReaderAudiobookPanelPinnedMinHeight`（440dp = 固定部分 312 + 至少 128 的 tab 视口）才保留「信息卡钉住 + tab 独立滚」的既有形态；低于它就把整块面板（含信息卡）放进一个 `SingleChildScrollView` 一起滚。无界高度（父级自己是滚动容器）时两层 viewport 都不套。判据抽成纯函数 `readerAudiobookPanelPinsHero`。修在面板层，bottom sheet / 右侧侧栏两种呈现形态同时覆盖。提交：见本分支。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audiobook_panel_test.dart`：
  - 「矮窗（手机横屏）：整块面板可滚，分段条以下的内容能滚出来」——768×348dp、宿主高 `0.9×348`，断言滚动区高度覆盖整块面板、`maxScrollExtent > 0`，且拖到底后 tab 内容 `hitTestable`。回填旧实现（恒 pinned）后该测试红在 `Expected: > 156.6 / Actual: 1.2`。
  - 「高窗：信息卡仍钉住，只有 tab 内容滚」——420×800dp，滚章节列表后封面 `top` 不变，钉住形态无回归。
- **备注**：横屏下即使能滚，信息卡仍占掉几乎整屏；若要进一步优化可在「矮且宽」时改双栏（左信息卡 / 右 tab），属独立改动，不在本条范围。
