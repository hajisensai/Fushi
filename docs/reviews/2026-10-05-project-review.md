# 2026-10-05 阅读器划词审查与修复

## Scope

- 原待审提交：`bf45baa6d9`，基座 `0bf948e4a7`，11 文件。原 `pr-upstream` / `pr1-review` 及 `develop` 未修改。
- 修复在独立分支 `review/reader-selection-bf45baa` / worktree `.worktrees/reader-selection-audit` 完成。用户明确授权从审查进入修复，最终要求不再 adb、验证后构建 debug APK。
- 覆盖 JS 几何命中/触摸会话、分页/连续/VN 失效、Flutter 菜单/覆盖路由及竖排避让。发现、刮削、galgame、发布不在范围内。

## Findings

### HBK-AUDIT-192 — P1 — 连续模式手柄第一次移动先被捕获监听清掉
- status：implemented_unverified；Node 事件链已复现并验证修复，最终未真机复验。
- 原 `reader_pagination_scripts.dart:1279` 把滚动意图当位移；capture touchmove 在手柄 target listener 前清选区，仅检查 dragAnchor 不检查 activeHandle。
- 修复：noteUserScroll 只清恢复锚；真实连续 scroll 按坐标变化处理并保护活动拖选。显式分页/程序化位置变化强制失效。
- 测试：`reader_selection_viewport_behavior_test.js`，274 场景，包含无位移、capture→target、原生范围、CSS/wrapper 和宿主通知；10种 mutation 检出。

### HBK-AUDIT-193 — P2 — 只清 JS 或只处理侧栏，漏掉宿主操作条及有声书导入
- status：implemented_unverified；独立 Overlay widget 已复现覆盖路由上仍可点击，不冒充 DOM 手柄真机像素证据。
- `chrome.part.dart:402/2141`，`navigation.part.dart:1816`，`webview.part.dart:2056`：路由前统一清理；modal depth 在 await 前锁住迟到菜单；无音频→导入/SRT重导/对齐/转录均经同一边界。JS clear/drag-start 通知 Flutter，只移除条、不反调 JS。
- 验证：`reader_selection_overlay_lifecycle_guard_test.dart` 接线/先后守卫和现有学习计时、图集、动作条测试。BUG-3049。

### HBK-AUDIT-194 — P2 — VN 重建及程序化翻页漏清理、迟到松手复活旧手柄
- status：implemented_unverified；生产 JS 行为已验证。
- `reader_visual_novel_scripts.dart:2602` 必须在 detach 前强制清，不能套用活动拖选保护。分页实际位移收口在 `setPagePosition:2565`，覆盖 fragment/char/progress/audio 定位；同位置与 limit 不清。
- selection 验证 ranges/anchor 仍连接，晚到 end 不确认其它选区。BUG-3048。

### HBK-AUDIT-195 — P2 — 竖排工具条与球重叠；后续边缘 clamp 又压住选中字
- status：implemented_unverified；真实 headless Chrome 10/10、Flutter 布局行为通过，最终未再 adb。
- `chrome.part.dart:443` 原来只看首字 rect+假定48px高度。现在菜单附两球完整 `handlesRect`，两角经过真实缩放链映射，delegate 根据实际子高度避让并考虑安全区。
- 后续用户指出 clamp 压字：`positionSelectionHandles:2049` 改用完整 touch target 的候选布局，排除**所有选区行片段**及另一球；合法位置不存在时隐藏、不改选择。独立新增不相交断言避免“在屏内=正确”的错误判据。BUG-3050 / BUG-3046。

### HBK-AUDIT-196 — P2 — 测试全绿不能证明手柄解析顺序及实时反馈
- status：automated_verified（测试覆盖补强）；触屏整体仍 implemented_unverified。
- 初始16条对解析顺序mutation仍全绿：#15被elementsFromPoint救回，#16不走moveSelectionHandle。新测试覆盖无API/另一API回退、异常恢复、begin/update实时坐标、旧wrapper normalize、晚到事件、原地整词/拖后最终点、边缘和内部不遮字。
- 最终37场景，26种mutation均检出，Node缺失显式失败不再skip。真实Chrome trusted touchmove在release前已更新位置，不能外推为Android合成帧已验。

### HBK-AUDIT-197 — P3 — 简报基座语义及编号说明不准确
- status：documented / renumbered。
- git对象对照确认基座和待审提交均保留 `reader_settings.dart`、fromHover、VN getMatchableOffset委托；slop通过常量仍为10。未发现本提交回退这些上游行为，不能按简报说它们已移除。
- 初始BUGS索引不同步；并发远端占用2951–2954。使用仓库工具将本任务依次迁为2958（拖选）、2959（切页）、2960（覆盖层）、2961（竖排），新增2957（压字回归），未手工改号。（2026-10-07 合入前因与 develop / 并行分支撞号，再用 `bug.dart renumber` 依次迁为 3047 / 3048 / 3049 / 3050，压字回归 2957→3046。）

## 验证证据

- Flutter 3.44.0；25个定向测试文件 **299条通过、exit 0**：`.codex-test/reader-selection-audit/occlusion-final-validation.log`。
- Node drag **37场景 / 26个mutation**；viewport **274场景**。这是行为断言数量，不与Flutter计数相加宣称同一种验收。
- Headless Chrome：`.codex-test/reader-selection-audit/headless-selection/run-2026-10-05T11-37-24-610Z/report.json`，10 PASS/0 FAIL，真实DOM/Range/TreeWalker/Popover，浏览器已退出。
- 全量 analyze、最终 APK 的退出码/时间/哈希以 `.codex-test/reader-selection-audit/occlusion-final-analyze.log` 和 `android/` 最终记录为准。先前15:14和18:53 APK均不是最后压字补修的产物。
- 用户明确停止 adb 后未再调用设备；不宣称 Android/iOS 的 paginated/continuous/VN 最终真机验收通过。

## Next Scope

- 用户验收最新包：横/竖排单字、多行拖动中实时跟随、页顶/底不压字，三个模式切页及打开有声书（已绑定/未绑定）、导航、图集、统计。
- 极密正文/小视口没有两个32px合法触控区时，目前不压字而隐藏手柄；如需始终可拖，需要单独确认遮挡/边距交互设计，不能隐式扩选或缩小目标。
- 不 push、不合并，由作者决定后续集成。
---

## 2026-10-05 继续审查用户手改（不修改业务代码）

### Scope

- 审查原未提交手改，期间被用户侧提交为 `0c06dcde92`、`7b900d904b`；以 `7b900d904b` 中的正文锚点 + 独立 `handlesBoxes` 为对象。8px 手柄定位回退已由用户明确要求，不将它误报成本轮新引入的手改缺陷。
- 重点：`reader_selection_toolbar_layout.dart` 的摆放策略、JS→Dart→Flutter 新盒子字段、相邻守卫。未运行 adb、未构建、未改业务/正式测试。
- 审查期间 worktree 发生另一次合并（曾出现 chrome 冲突标记、未解析 liquid_glass_widgets），完整 widget suite 因并发中间态装载失败，不能归因于这次手改。布局文件及其测试与审查快照的 SHA256 一致。

### Findings

#### HBK-AUDIT-198 — P2 — 跨列竖排错误使用全局最上球，仍会将操作条翻到下方
- status：reproduced，未修复。
- 位置：`fushi/lib/src/reader/reader_selection_toolbar_layout.dart:82–90`。
- 起点在右列中部、终点在下一列顶部时，两球的 y 顺序与选区起止顺序相反。首选位置被起始球挡住后，算法取所有球的最小 top；末端球贴页顶，就把“所有球上方不可用”当成“选区头部上方无空间”，直接进入下方路径。
- 直接执行生产 delegate 的证伪用例：视口400×700，工具条384×48，首字(300,260,24,24)，两球盒(296,236,32,32)/(216,56,32,32)。输出 **y=324**；**y=180** 在首字及两球上方/之间留足8px且完全可见。这些球盒符合现有 GAP=8 定位公式。
- 修复建议：以上方首字锚点为基准，只跨过实际阻挡当前候选的球；或按各障碍的上下边界枚举小量候选，优先保持头部附近的合法位置。不要用所有球的全局 top/bottom 再造并集式行为。
- 同根补充：页顶首字(350,0,24,24)、球盒(346,0,32,32)/(306,104,32,32)，在400×700内输出y=144；y=40本来已经合法、更贴近头部。

#### HBK-AUDIT-199 — P2 — 最后的 clamp 会重新把操作条压回球上，且并非总是空间不足
- status：reproduced，未修复。
- 位置：`fushi/lib/src/reader/reader_selection_toolbar_layout.dart:95–107`。
- `lowest + gap` 未检查 fits/blocked，最后 `clamp(minTop,maxTop)` 之后也不验证碰撞。
- 实例：视口400×180（小窗/矮视口），工具条384×48，首字(350,0,24,24)，两球盒(346,0,32,32)/(306,104,32,32)。首选下方y=64碰到末球，改成y=144又越界，clamp为 **y=124**，条覆盖y=124–172，与末球 **104–136重叠12px**。而 **y=40–88** 在两个球之间、离正文及球均留足8px，确有可用位置。
- 修复建议：对最终位置再次做 in-bounds + obstacle 校验；先检查球之间合法空隙，不把clamp视为碰撞安全保证。若确实无解，应显式声明降级策略，而不是混同此类可解场景。

#### HBK-AUDIT-200 — P2 — 改了生产锚点契约却没更新 nonmodal 相邻守卫
- status：confirmed_source_contract，未修复。
- 位置：`fushi/test/reader/reader_selection_action_bar_nonmodal_guard_test.dart:36`。
- 仍要求 `data.handlesRect ?? data.rect`，但生产 `_buildSelectionActionBar` 已改成两个独立映射。复用同一源码切片与 contains 判据：5359c57be3为true，手改为false；这是确定性的过期守卫，不应通过恢复错误的union锚点来满足测试。
- 建议：改为锁定 `selectionRect` 来自正文、`gripBoxes` 逐盒映射，同时保留非模态/销毁/payload清理断言。

### 已核对而未报为生产缺陷

- `fireSelectionMenu` 在手柄定位后确实发送 handlesBoxes；Dart parser 与 chrome 消费未断链。横/竖排、popover/no-popover四组真实生产函数回放均输出两个有限的32×32盒子、正确并集与独立首字rect。不存在应为这次修改再增加API版本门的证据。
- 新增盒子的回退逻辑没有发现高可信生产错误；是否空列表/无效输入应退回并集与现实现一致。
- 当前37场景/24 mutation并未保护新增发送行：内存删除 `payload.handlesBoxes = this.selectionHandlesBoxes();` 后37场景仍绿。因此该绿不能证明新链路被测试锁住；这是补测建议，不另报实际生产故障。

### 验证与局限

- `.codex-test/reader-selection-audit/manual-review/layout_probe_test.dart` 直接import生产delegate，三个用例已执行并复现上述坐标与无碰撞替代位置；测试断言是“观测错误成立”，通过不等于业务正确。
- 数值证据：`manual-review/layout-evidence.json`；桥接与过期守卫证据：`manual-review/payload/probe-output.txt`。
- 第一轮多suite运行中有3个证伪用例通过，但6个suite因并发合并/依赖中间态装载失败，整体exit1。保留 `manual-review/flutter-tests.log`，不将编译失败计成手改回归。只读审查没有改依赖、没有解决别人的合并冲突。
- 最终受限重跑日志：`manual-review/isolated-tests.log`；不宣称完整App/widget/真机已验证。
- 由于worktree正在进行用户侧合并，本轮只追加报告和本地证据，**不提交，以免将别人的stage内容一并提交**。

### Next Scope

- 修正候选摆放后补：竖排跨列（起点y大于终点y）、页顶两球间恰好有空位、小窗/安全区/大字号，断言“如果存在无碰撞候选，最终结果必须无碰撞且保持首字附近”。
- 新增 handlesBoxes 的 emit→parse→map 回归及 mutation，补跑 nonmodal 守卫。合并/依赖稳定后再跑原8个widget布局用例。
#### 本轮受限重跑结果补充

`manual-review/isolated-tests.log` 最终 **18通过 / 1失败，exit1**。三个生产delegate证伪用例执行成功；其余通过含数据解析。唯一失败为 `reader_selection_action_bar_nonmodal_guard_test.dart:36` 的过期锚点字符串断言，已实际跑出，不再只是源码预测。因此HBK-AUDIT-200状态提升为 reproduced-test-failure。业务文件未由本审查修改；当前合并现场仍由用户侧处理。
#### 审查结束时的外部状态变化

用户侧已完成合并 `0a6e0accdb`，随后 `reader_selection_toolbar_layout.dart` 又出现新的未提交修改。**本轮三项结论限定为已固定的 `7b900d904b`/审查快照，不将刚出现的新修改宣称为已审或已修。** 本轮没有修改任何业务代码或正式测试；仅提交审查报告，源码改动保持用户所有。