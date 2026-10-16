## BUG-3447 · rail-toggle-right-edge-flicker
- **报告**：2026-10-16（用户：录屏「展开，收起侧边栏会导致右边闪烁」，Windows 首页 dashboard）
- **真实性**：✅ 真 bug（10-14 `83b1303c03`「rail motion keeps content width」引入的回归）。录屏逐帧（20 fps）：展开 / 收起侧栏过渡期间，右上顶栏动作只剩 3 个（静止时 5 个）、「今日」卡右侧「14 分钟」被裁掉，弹簧结束那一帧才全部弹回。根因 `fushi/lib/src/utils/adaptive/adaptive_navigation.dart` `NavRailSyncedContent`（原包在 `home_page.dart` 整个 `Expanded` 内容区上）：为省掉保活 tab 的逐帧重排，过渡期间把**整个可见内容区**钉在两态里较宽一端的宽度、随 rail 边缘平移并 `ClipRect` 裁掉右侧溢出——可见内容的右缘整段过渡越出窗口被裁，结束（展开）/ 开始（收起）时一次性重排，表现为右边内容消失再弹回。
- **[x] ① 已修复** — 钉宽只作用于**被 Offstage 藏起的保活 tab**（它们不绘制，宽度错一点看不见，省重排的收益主要在它们身上）：`NavRailSyncedContent` 加 `hidden` 参数，`home_page.dart` 的 `buildBody` 在每个保活 tab 外包 `NavRailSyncedContent(hidden: visible != tab)`，内容区根上那层去掉。可见 tab 照常随 rail 逐帧重排（与拖窗口边缘同一代价）。提交见本分支 `fix(home): stop clipping visible content during nav rail toggle`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/nav_rail_content_sync_test.dart`：可见探针每帧屏幕右缘恒等于窗口右缘且逐帧重排（>5 次）、藏起探针过渡中至多重排一次、静止后两者宽度一致；展开 / 收起两个方向。变异实测：让 `hidden` 失效（恢复旧的全量钉宽）后两条「可见内容逐帧跟随」用例变红。
- **备注**：未在真 app 里录屏复测；可见 tab 逐帧重排的帧耗时代价未实测（10-14 那次掉帧主要来自 Offstage 保活 tab 一起重排，这部分仍被省掉）。
