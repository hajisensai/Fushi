## BUG-1474 · hook 选择弹窗过小/标题截断/预览只有一句
- **报告**：2026-08-09（用户：哈吉千歳）
  - 原话：刚 hook 时的进程选择弹窗过小、标题截断；文本应显示 2~3 句。
- **真实性**：✅ 真 bug。⚠️ 用户描述里混了**两个**弹窗，改错文件会白干：
  - **窗口选择器** `_showExternalWindowPicker`（`fushi/lib/src/pages/implementations/texthooker_page.dart`）
    列的是 Win32 窗口（hwnd/title/pid），`ExternalWindowInfo` 里**根本没有文本字段**；
  - **捕获设置弹窗** `gal_capture_setup_dialog.dart`（刚 hook 上、首次出现候选线程时自动弹）
    列的是文本线程，**带捕获文本预览**。「显示 2~3 句」只可能落在这一个。
  - 三处缺陷：
    1. 窗口选择器是**裸 `SimpleDialog`，一条尺寸约束都没有**，走 Flutter 默认
       minWidth 280 + intrinsic 宽度；同文件的音轨弹窗早就用 `SizedBox(width: 520)`。
    2. 两个弹窗的行标题都吃 `FushiListItem` 的 `titleMaxLines` 默认值 1
       （`fushi_material_components.dart`）。线程 label 形如
       `TextRender · 0x459f50 · #1a2b`，必被切。
    3. 捕获设置弹窗宽度**硬编码 900**，而 `AlertDialog` 默认 insetPadding 左右各 40 ——
       窗口宽 < 980 时那个 900 被父约束挤压，两栏跟着变窄。
    4. 预览「只有一句」**不是 UI 限制**：该行早就写着 `maxLines: 3`，缺的是数据 ——
       native 线程预览区是全量快照、**每线程恒一条**
       （`fushi/lib/src/sync/texthooker_service.dart` 的 `applyTextThreadPreviews` 注释原文）。
- **[x] ① 已修复**
  - 窗口选择器每行套 `SizedBox(width: 560)` 给出可用宽度；标题 `titleMaxLines: 2`。
  - 捕获设置弹窗宽度改成 `(screen.width - 80).clamp(320, 900)`；线程标题 `titleMaxLines: 2`。
  - 放宽标题行数一律**逐调用点显式做**，不改 `FushiListItem` 默认值 —— [[BUG-1184]] 已经
    因为改默认值把窄容器里的调用点撑破并回退过一次，两处新调用点的父容器高度都是自由的。
  - 多句预览：新增 `TexthookerTextThread.recentPreviewTexts` +
    `TexthookerService._threadPreviewHistory`（native thread id → 最近 ≤3 句，新→旧，
    同句不重复入环，线程从快照消失则历史一并清）。累积必须发生在**替换快照之前**，
    替换之后就再也分不出「这句是新的还是上一轮那句」。`texthookerThreadSubtitle`
    新增 `recentTexts` 参数，非空时一句一行取代单句；缺省 `const []` ⇒ 旧行为逐字等价。
  - 顺带消掉一个真隐患：`TexthookerTextThread` 原先有**四处手写全字段构造**，加字段就得
    改四处、漏一处即该字段被静默清空。新增 `copyWith`，纯拷贝的两处
    （预览合流、`disambiguateThreadLabels`）改走它，结构上不可能再漏。
  - 工具栏那个**下拉**仍保持单句：单行控件塞三行会撑破布局，且用户诉求指的是选择弹窗。
- **[x] ② 已加自动化测试** — 新建
  `fushi/test/mining/texthooker_thread_preview_history_test.dart`（7 用例）：跨轮询累积顺序、
  环上限 3、同句不重复入环（逐字重绘引擎的常态）、线程消失时历史一并走、
  `clearTextThreadPreviews` 清干净、`texthookerThreadSubtitle` 的多句与回退两条路径。
  既有守卫 `texthooker_window_picker_guard_test.dart` /
  `texthooker_attach_running_game_guard_test.dart` / `md3_design_system_static_test.dart` /
  `texthooker_page_test.dart` 一并复跑，89 tests PASSED。
