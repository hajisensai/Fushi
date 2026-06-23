## BUG-413 · 打开错误日志卡顿(单TextField全量512KB无虚拟化)
- **报告**：2026-06-23（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  原 `HibikiLogPanel` 用单个 `TextField(maxLines:null, expands:true)` 把最大 ~512KB
  全量日志一次性在 UI 线程做 `TextPainter.layout`（无行虚拟化），数万行 monospace
  首帧 layout 几百 ms~数秒 → 打开「错误日志」卡顿。非 IO 非解析（日志在
  `ErrorLogService.init()` 已异步读入内存 `_persistedLog`，打开页零文件 IO）。次因：
  `getFullLog()`（`hibiki/lib/src/utils/misc/error_log_service.dart:245`）在
  `ErrorLogPage`（旧 StatelessWidget）的 `build()` 里同步拼全部条目，每次 rebuild 重算。
  panel 被 `ErrorLogPage` + `DebugLogPage` 共用（后者已在 initState 拼一次，是对照）。
- **[x] ① 已修复**（commit 350faa9be）—
  - 渲染懒加载：`HibikiLogPanel` 从「单 TextField 整段」改为 `SelectionArea` +
    `ListView.builder`（`hibiki_material_components.dart` `_HibikiLogPanelState`），按行
    懒构造，只对视口内行做 layout，首帧恒定。选区/复制由 `SelectionArea` 跨行提供，
    自定义 `contextMenuBuilder` 在默认复制/全选之上保留旧「分享选区」`shareAction`。
  - BUG-119 不回归：`ListView` 仍挂 `_LogSelectionScrollController`，拖拽选区期间除
    指针贴边的合法边缘自动滚动外，一律拦掉把视口往光标/extent 拽回的程序化
    `jumpTo`/`animateTo`；Listener 仍把指针 Y 喂给该 controller。SelectionArea 套纯
    `Text`（无 EditableText caret）本就没有旧的 caret bringIntoView 来源，gate 作纵深防御。
  - 拼接移出 build：`ErrorLogPage` 改 StatefulWidget（`error_log_page.dart`），initState
    拼一次缓存进 `_log`，监听 `ErrorLogService` 仅在新错误进来时重拼，build 只读缓存。
    `DebugLogPage` 本就 initState 拼一次（count 在 build 是 O(1)），无需改。
- **[x] ② 已加自动化测试** —
  `hibiki/test/widgets/log_panel_scroll_select_guard_test.dart`（BUG-119 守卫已随结构
  平移更新）：① widget 行为断言面板用 `SelectionArea`+`ListView.builder`、controller 为
  带拽回拦截的自定义类型、`childrenDelegate` 是 `SliverChildBuilderDelegate`（懒构造），
  且不再有 TextField/SelectableText/SingleChildScrollView；② 新增大日志（5000 行）懒加载
  守卫，断言视口内构造的 `Text` 远小于 5000，证明虚拟化生效（旧的整段渲染会一次性 layout
  全部）；③ 源码守卫断言 ListView.builder+SelectionArea 接 `_LogSelectionScrollController`，
  旧的整段一次性渲染构造调用消失。`hibiki/test/pages/log_pages_export_test.dart` /
  `log_pages_static_test.dart` 保持绿（导出/复制/另存为不变）。
- **备注**：分支 `todo-762-log-lazy`。只修渲染卡顿；磁盘文件单会话无界本次不做（不扩面）。
  导出/复制/分享/另存为全部保留（pages 仍喂同一份 `getFullLog()` 字符串）。
