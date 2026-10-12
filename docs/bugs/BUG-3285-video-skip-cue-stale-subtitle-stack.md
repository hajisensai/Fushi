## BUG-3285 · 上/下一句跳转旧字幕残留、新句被顶高
- **报告**：2026-10-11（应用内反馈 #Ac_Y5qveTy，Android vivo V2339FA：「往回退一句的话当前句还会保留一瞬间在下面然后前一句出现在上面，然后这前一句都会一直待在上面，播到下一句才回到正常高度」，截图里上一句与当前句上下两行并排）
- **真实性**：✅ 真 bug（沿真实代码路径定位）。
  - 上 / 下一句（按钮 / 双击 / 快捷键）都走 `VideoPlayerController.skipToCue`：先发 seek，再置「主动跳转目标」快照 `_seekTargetCueIndex`。seek 落地前 125ms tick 读到的仍是旧位置（还在原来那句里），`_applySeekTargetSnap` 把**代表 cue** snap 到目标句，但**渲染集** `_activeRenderIndices`（`fushi/lib/src/media/video/video_player_controller.dart:3592`）仍按滞后旧位置求时间活动集，再把代表 cue 并进去 → 渲染集 = {旧句, 目标句}；preRoll 落点（目标句起点前 180ms）同样会把目标句之前那条的尾巴并进来。
  - overlay 槽位表 `_syncGroupSlots`（`video_subtitle_overlay.dart`）把先在屏的旧句留在锚点槽、目标句追加到上方槽；旧句退场后锚点侧死槽按 BUG-698 不变量保留，目标句就一直悬在上一行，直到下一句占回锚点槽——正是用户描述的「当前句残留一瞬 → 上一句出现在上面 → 一直待在上面到下一句」。BUG-743 只修了相邻 cue 边界（闭区间）与大屏 MarginV，BUG-796 只修了普通 seek，都不覆盖 skipToCue 在途这条。
- **[x] ① 已修复** — 新增纯函数 `VideoPlayerController.cueRenderPositionMs`：skipToCue 在途（快照非空、代表 cue 已 snap 到目标、实时位置不在目标句区间内）时，渲染集按**目标句起点那一刻**取样——目标句开场时真实在屏的 cue（含真正重叠的招牌字幕，TODO-1312 不回归）照常并排，旧句 / preRoll 尾巴不再混入；落进目标句后、或快照清除后恒用实时位置。`_activeRenderIndices` 改用它取样。提交 `ba0f08b258`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_skip_cue_render_set_test.dart`（4 例：上一句滞后旧位置只渲染目标句；下一句旧位置与 preRoll 窗口只渲染目标句、落地后正常跟随；与目标句重叠的 cue 仍一起渲染；纯决策表）。变异实测：把取样改回实时位置后 4 例全红，还原后全绿。
- **备注**：真机（Android 小屏 + 查词弹窗）复测未做；单测覆盖的是控制器渲染集这一层，overlay 槽位行为由既有 BUG-743 / BUG-698 测试守着。
