## BUG-698 · 两条字幕同显时字幕盒随活动集增减跳动（组内堆叠槽位不稳定）
- **报告**：2026-07-10（用户：「两个字幕同时存在，就会时不时地自动跳一下」）· TODO-1372（TODO-1341/BUG-684 多字幕分离的后续缺陷，独立修，不动 1341 验收状态）
- **真实性**：✅ 真 bug。沿 `hibiki/lib/src/media/video/video_subtitle_overlay.dart` 真实渲染路径复核（origin/develop `cdcef9b86`）：
  - **triage 原判「`cues.first` 代表翻转改变组锚定 / `forceTop` 每帧重算来回跳」不成立**：1341 的分组键 `_positionKey`（旧 `:497-511`）已把 \pos（4 位小数）、锚点（`av:ah`）、MarginV（取整）钉进组键，`forceTop`、`_alignFor`、`_paddingFor` 全是组键的纯函数——组内代表怎么翻转都不改变定位几何（widget 复现试验同样证实）。
  - **真实机制①（跳动本体）：组内堆叠槽位不稳定**。`_positionCueGroup`（旧 `:524-533`）把组内活动 cue 按活动集顺序直接塞 Column，贴锚那一格的归属随集合增减翻转：底部组（主字幕）——重叠窗口内新 cue 抢走贴底格、**已在屏的 cue 被顶上去**；顶部组（副字幕置顶）——前一条离场、**后一条补位上跳**。字幕轨常见的相邻 cue 时间小重叠让这在正常播放中反复发生 =「时不时地自动跳一下」；双字幕（主+副两轨）同显时两层各自都会跳，感知强烈。
  - **真实机制②（同源叠印）：分组键对语义等价位置分家**。「anchor 缺省」（SRT 无 markup，键 `a:-1:-1:-1`）与「显式底部居中 + MarginV<=0」（键 `a:2:1:0`）渲染路径完全同构（缺省即底部居中；`_scaledMarginV` 对 <=0 都回退基线），却分成两组 → 重叠时**两组叠印在同一位置互相压字**（复现测试实测 dy 差 0.0）而非堆叠。
  - 已排除字幕驱动 seek（控制器 tick 只重选 cue 从不 seek）；\pos/锚点/MarginV 各异的组各就各位属 1341 正确行为，不在本 bug 范围。
- **[x] ① 已修复** — `git commit e95792e6c`。`hibiki/lib/src/media/video/video_subtitle_overlay.dart`：
  1. **组内跨帧稳定槽位（libass「Collisions: Normal」碰撞语义的槽位版）**：新增 `_groupSlots`（「层前缀|分组键」→ 槽位列表，锚点侧在前）+ `_syncGroupSlots`。不变量：**已在屏的 cue 在其可见期内槽位不变**——新进 cue 先补最靠锚点的空槽、没有才追加远端（不挤动任何在屏 cue）；cue 离场后若远端仍有在屏 cue，其槽保留为**隐形占位**（`IgnorePointer`+`Opacity(0)` 渲染原盒保高度，`registerHits:false` 不登记查词命中、无收藏角标）；远端空槽立即裁掉；组内全部离场 → `build` 里按当前活动集清扫状态，下一条回到锚点侧基线。Column 渲染方向按组的生效竖直锚：底部锚组 slot0 贴底（新 cue 往上长）、顶部锚组 slot0 贴顶（新 cue 往下长）。
  2. **分组键语义归一**：`_positionKey` 把「anchor 缺省」归一为底部居中索引、「MarginV<=0」归一为无 MarginV——渲染完全相同的 cue 必然同组堆叠，不再两组叠印。MarginV>0 / \pos / 非默认锚的键值与 1341 行为一致。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_overlay_dual_snap_test.dart`（6 例，修前 6 挂 5、修后全绿）：① 底部组重叠进入：在屏 cue 不动、新 cue 排上方；② 重叠离场：剩余 cue 由占位撑住不坠回贴底格；③ 槽位复用链（甲乙丙丁）：补空槽不挤动在屏 cue、组空后重置回贴底基线；④ 隐形占位不可查词（占位区域命中 null、在屏 cue 照常命中）；⑤ 顶部组（副字幕）：前一条离场后一条不补位上跳；⑥ 键归一：anchor 缺省与显式底部居中(MarginV=0) 重叠时堆叠分离（修前 dy 差 0.0 叠印）。全量 `flutter analyze`（含 test）No issues；`test/media/video` 1402 例全绿（2 例既有 skip），BUG-684 守卫 `video_subtitle_multi_full_test.dart`、BUG-651 守卫 `video_subtitle_dual_position_test.dart`、TODO-1312 `video_subtitle_multicue_test.dart` 零回归。
- **备注**：
  - **对 1341 的影响评估**：不同 \pos/锚点/MarginV 的组仍各就各位（分组与定位路径未动语义，只归一了「渲染完全相同」的键）；副字幕置顶/遵自带位置的判据原样保留。变化仅在**组内**：重叠时新 cue 改排远离锚点一侧（旧：贴锚侧顶飞旧 cue），与 libass/VSFilter 碰撞方向一致。
  - **槽位粒度取舍（诚实标注）**：占位按「离场 cue 的原盒尺寸」保高度；若新 cue 复用空槽且高度不同（多行 vs 单行），其远端在屏 cue 会随差值小幅移动——像素级冻结需逐 cue 高度测量反馈，复杂度不成比例，槽位粒度已消除全部整格跳动。中部锚组（罕见）Column 对称外扩，增减仍有半高偏移，接受。
  - **运行时验收待用户**：真机双字幕（主+副）播放含相邻 cue 时间重叠的片段，确认字幕不再偶发跳动（widget 测试已证渲染几何）。
