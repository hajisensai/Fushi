## BUG-909 · 移除发布版残留的竖排取证探针（TODO-792/753 系列 + 753-DIAG）
- **报告**：2026-07-19（守卫审计批·死代码清理）
- **真实性**：✅ 真（取证已完成的一次性诊断打点，注释自述「零行为变化 / read-only」，发布版未剥离，常驻按句/翻页热路径）。
- **[x] ① 已清理** — 探针函数 + 全部调用点整体移除，见下。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_viewport_diag753_guard_static_test.dart`（由「断言探针存在」改写为「断言探针不再存在」的清理守卫）。
- **备注**：纯观测代码移除，无运行时行为变化，无需真机复测；`flutter test` 门禁交集成时统一跑。

### 现象 / 问题
`hibiki/lib/src/reader/reader_pagination_scripts.dart` 里残留 TODO-792 竖排翻页漂移取证探针簇：
`[792-REVEAL]` / `[792-REVEAL-RB]`（`scrollToRange` 内）、`[792-RPITCH]` / `[753-DIAG]`（`_diag753` helper）、
`[792-TURN]`（`_diagTurn` helper）。它们走 `console.log → onConsoleMessage → debugPrint → DebugLogService`，
取证目标（竖排列周期失配 δ）早已由后续修复（realpitch 容器高度对齐纯 V，见
`reader_vertical_realpitch_fix_guard_test.dart`）坐实并根治，探针遂成死代码，却仍常驻按句 reveal /
手动翻页 / init / resize 热路径。按 CLAUDE.md「取证完成即删，不用门控常量保留死路径」直接移除。

### 零副作用确认（逐个核对函数体）
- `[792-REVEAL]`：读预算好的 `rect/currentScroll/anchor/targetScroll/context`，仅 `console.log`（try/catch）。不改 DOM/scrollTop/状态。
- `[792-REVEAL-RB]`：rAF 内仅 `self.getPagePosition(context)`（getter）+ `console.log`；同块业务 `setPagePosition` 保留。
- `_diag753`（`[753-DIAG]`/`[792-RPITCH]`）：整函数只读——读 computed style / getScrollContext / getClientRects / caret，写的 `_diag753Seen` 仅自身去重态，随函数一并删。
- `_diagTurn`（`[792-TURN]`）：rAF 内 `getPagePosition` + `caretRangeFromPoint`（只读）+ `console.log`；写的 `_turnSeq` 仅自身序号态。调用在 `setPagePosition` 之后、`return "scrolled"` 之前，删调用不影响返回值。

### 清理位置（`hibiki/lib/src/reader/reader_pagination_scripts.dart`，行号为移除前）
- `scrollToRange`：`:2036-2057` 主探针 `[792-REVEAL]` if 块 + 前导注释；`:2075-2086` rAF 内 `[792-REVEAL-RB]` if 块。保留 `alignToPage`/BUG-875 短路/`setPagePosition` 业务。
- `_diag753` helper（含 `[753-DIAG]`/`[792-RPITCH]`）：`:2540-2668` 整体删（含前导注释）。
- `_diagTurn` helper（`[792-TURN]`）：`:2669-2727` 整体删（含前导注释）。
- 调用点：`paginate` forward `:2345`、backward `:2353` 的 `this._diagTurn(...)`；`initialize` 末尾 `:2776-2777` `_diag753('init')`；`updatePageSize` `:2802-2803` `_diag753('resize')`。

### 配套引用清理
- `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:875-880`：`[806-TAP]` 探针（TODO-806，**不在**本次范围，保留）注释里对已删除 `[792-REVEAL]` 的引用更新为不再点名该探针，保留口径说明「WebView CSS 视口像素」。
- `hibiki/test/reader/reader_tap_coord_probe_guard_test.dart`：`[806-TAP]` 守卫 prose 中对 `[792-REVEAL]` 的两处引用改为泛指「DebugLogService 门控」（断言语义不变，仅去除对已删符号的指向）。

### 测试守卫
`hibiki/test/reader/reader_viewport_diag753_guard_static_test.dart`（改写）：静态扫描断言
`reader_pagination_scripts.dart` 不再出现 `792-REVEAL` / `792-REVEAL-RB` / `792-RPITCH` / `792-TURN` /
`753-DIAG` 及 `_diag753` / `_diagTurn`，且 `webview.part.dart` 不再引用 `792-REVEAL`。任一探针回潮 → 转红，
挡住后续 merge/cherry-pick 把死探针带回热路径。
