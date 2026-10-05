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
- 验证：`reader_selection_overlay_lifecycle_guard_test.dart` 接线/先后守卫和现有学习计时、图集、动作条测试。BUG-2960。

### HBK-AUDIT-194 — P2 — VN 重建及程序化翻页漏清理、迟到松手复活旧手柄
- status：implemented_unverified；生产 JS 行为已验证。
- `reader_visual_novel_scripts.dart:2602` 必须在 detach 前强制清，不能套用活动拖选保护。分页实际位移收口在 `setPagePosition:2565`，覆盖 fragment/char/progress/audio 定位；同位置与 limit 不清。
- selection 验证 ranges/anchor 仍连接，晚到 end 不确认其它选区。BUG-2959。

### HBK-AUDIT-195 — P2 — 竖排工具条与球重叠；后续边缘 clamp 又压住选中字
- status：implemented_unverified；真实 headless Chrome 10/10、Flutter 布局行为通过，最终未再 adb。
- `chrome.part.dart:443` 原来只看首字 rect+假定48px高度。现在菜单附两球完整 `handlesRect`，两角经过真实缩放链映射，delegate 根据实际子高度避让并考虑安全区。
- 后续用户指出 clamp 压字：`positionSelectionHandles:2049` 改用完整 touch target 的候选布局，排除**所有选区行片段**及另一球；合法位置不存在时隐藏、不改选择。独立新增不相交断言避免“在屏内=正确”的错误判据。BUG-2961 / BUG-2957。

### HBK-AUDIT-196 — P2 — 测试全绿不能证明手柄解析顺序及实时反馈
- status：automated_verified（测试覆盖补强）；触屏整体仍 implemented_unverified。
- 初始16条对解析顺序mutation仍全绿：#15被elementsFromPoint救回，#16不走moveSelectionHandle。新测试覆盖无API/另一API回退、异常恢复、begin/update实时坐标、旧wrapper normalize、晚到事件、原地整词/拖后最终点、边缘和内部不遮字。
- 最终37场景，26种mutation均检出，Node缺失显式失败不再skip。真实Chrome trusted touchmove在release前已更新位置，不能外推为Android合成帧已验。

### HBK-AUDIT-197 — P3 — 简报基座语义及编号说明不准确
- status：documented / renumbered。
- git对象对照确认基座和待审提交均保留 `reader_settings.dart`、fromHover、VN getMatchableOffset委托；slop通过常量仍为10。未发现本提交回退这些上游行为，不能按简报说它们已移除。
- 初始BUGS索引不同步；并发远端占用2951–2954。使用仓库工具将本任务依次迁为2958（拖选）、2959（切页）、2960（覆盖层）、2961（竖排），新增2957（压字回归），未手工改号。

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