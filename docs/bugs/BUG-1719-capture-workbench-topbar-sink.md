## BUG-1719 · 游戏捕获工作台顶栏分段条下沉跳动
- **报告**：2026-08-18（用户截图反馈批 H，TODO-2937）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/settings_shared.dart` 的 `estimateSegmentedStripWidth`（改前 ~880 行）：Material `SegmentedButton` 把每段铺成同一宽度（最宽段的固有宽，framework `_calculateHorizontalChildSize`），分段条自然宽 = 段数 × 最宽段；旧估算却按各段自身宽求和，对段长不一的条系统性低估（游戏 zh 六段：求和 392 vs 真实等宽 567）。捕获工作台页头动作药丸把标题位挤窄后恰落进「求和 ≤ 可用 < 等宽合计」区间：`FushiSegmentedStrip` 误判「摆得下」，框架把每段钳到比「捕获工作台」更窄 → 标签折两行 → 分段条比兄弟页签高 8px（48→56），切页签顶栏肉眼可见下沉/跳动（widget 测量：monitor 条 Rect 高 56/其余 48，段内容框 40 vs 32）。
- **[x] ① 已修复** — `estimateSegmentedStripWidth` 语义改为等宽合计（段数 × max(每段估宽)，新增 `segmentedStripCellWidth`；字形估宽按 CJK 1.0em / 窄字 0.62em 分档，避免拉丁文案被高估逼进滚动）；`FushiSegmentedStrip` 摆得下时用 tight `SizedBox` 钉在估算等宽总宽（≥ 真实固有宽，永不被钳窄折行），三档回退：统一段宽下限 → 自然等宽 → 横向滚动，任何一档每段都不窄于最长标签，几何跨宿主/窗宽恒定。提交见本分支 todo-2937-topbar-ui。
- **[x] ② 已加自动化测试** — `fushi/test/pages/game_topbar_geometry_bug1719_test.dart`（六子区分段条 top/height 跨 1000/1440/2560px 全等 + 「捕获工作台」永远单行；已变异实测：把估宽乘 0.62 复刻旧低估 → 三档全红）。
- **备注**：同 PR 顺带（TODO-2937 子项 2）：书架/漫画/视频/游戏四模块顶栏分段收敛到共享 `LibrarySectionTabs`，统一每段最小宽 98px（`fushi/test/pages/library_section_tabs_uniform_test.dart` 守卫）。
