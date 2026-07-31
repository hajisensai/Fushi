## BUG-1315 · 未选线程门控把无线程身份的行（WebSocket/Textractor 端点）永久丢弃
- **报告**：2026-08-01（用户：develop 全量体检，主行=2452 第①②④组）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:678-690`
  （修复前）的 `workbenchLines`：`if (selectedKey == null) return const <TexthookerLineEntry>[];`
  以及 `:713-723` 的 `selectedSessionLines` 同款早退。
  PR#555（`a835ed93c` feat(gal): IPC v12 线程预览区 + 取消自动选文本线程，BUG-1193）
  把「未选线程」的语义从**全部线程**改成**一行都不发布**。这个契约变更对**带线程身份
  的行**是有意且正确的（Luna 中日文混流必须由用户显式选）。
  但它把判据写成了「有没有选过线程」而不是「这一行归不归一条被排除的线程」，于是
  **不带线程身份的行**被连坐：
  - `hibiki/lib/src/sync/texthooker_ws_client.dart:118-122`
    （WebSocket / Textractor / mpv WS 源）appendLine 时**不传** `textThreadKey`；
  - `hibiki/lib/src/mining/galgame_audio_source.dart:1968-1969`
    `threadId == 0` 时 `textThreadKey` 也为 `null`。
  这类行永远不进线程目录（`texthooker_service.dart:395-398` 显式跳过 null/空 key），
  也就永远没有下拉项能选中它；而选择器本身按
  `texthooker_page.dart:1409` 的 `enabled: textThreads.isNotEmpty` 置灰。
  **结果是一个用户无法自救的死角**：纯 WS/Textractor 用户的捕获工作台永久空白，
  浮窗与制卡（`gal_hook_text_overlay_controller.dart:322` 消费 `selectedSessionLines`）
  一并归零。这不在 BUG-1193 的意图范围内——没有线程身份的行本就没有歧义可消。
- **[x] ① 已修复** — `hibiki/lib/src/mining/gal_hook_session_controller.dart`
  新增 `_publishesUnderSelection(entry, selectedKey)` 单一谓词，取消
  `selectedKey == null` 的早退分支，`workbenchLines` 与 `selectedSessionLines` 共用它：
  带线程身份的行仍须 `key == selectedKey`（BUG-1193 契约逐字保持），
  无线程身份的行无条件放行。四种组合由一条谓词覆盖，特殊情况消失。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/texthooker_page_test.dart`
  新增「BUG-1315：无线程身份的行不受线程选择门控，未选线程也必须发布」：
  同一页面同时喂一条带 `textThreadKey` 的 hook 行和一条 WebSocket 行，
  断言前者**不可见**（守住 BUG-1193）、后者**可见**（守住本 bug）。
  两条断言同在一个用例里，任一方向的回归都会红。
  变异实测：把谓词的 `return true` 改成 `return false` → 该用例连同
  `renders incoming lines reactively` / `clear button empties the list` /
  `embedded mode reuses parent scaffold` 共 4 条转红；反向替换还原后 15/15 转绿。
- **备注**：同一根因还连带修好了 develop 上另外 6 条既有红——
  `test/lookup/gal_hook_text_overlay_controller_test.dart`（5 条，症状是
  `asynchronous overlay state did not settle`）和
  `test/lookup/gal_hook_overlay_voice_controls_test.dart`（1 条），
  它们都用不带 thread key 的 `appendLine` 喂行，浮窗因 `selectedSessionLines`
  恒空而永不 settle。体检报告（主行=2452）把它们分在①②组，实为同一个 bug。
  `test/mining/gal_capture_audio_integrity_test.dart:376-388` 的 v12 契约守卫
  （`selectTextThread(null)` 后 `workbenchLines` / `selectedSessionLines` 必须为空）
  用的是 `threadId: 7` 的带身份行，修复后仍然绿——契约没有被松动。

### 追加（gal overlay 专线独立复核，2026-08-01）

第①②组（gal overlay 6 条）由独立线程在自己的 worktree 上对照复核，确认与本条同根因：
把本条修复单独应用到 `origin/develop` 上，那 6 条 6/6 转绿、原本就绿的 3 条不变；把谓词
的放行分支变异成 `return false` 后 6 条原样转红。**结论成立，无需另修。**

同一轮复核发现修复的**第一版谓词写过头**：`if (key == null || key.isEmpty) return true;`
让无身份行**在用户已经选定线程时也照样发布**。这不是本条要修的东西，而是一处新引入的
行为变更——`origin/develop`（以及 v12 之前）在选定线程时都只发布该线程的行：

- 实测对照（同一个探针，只换 `gal_hook_session_controller.dart`）：
  `origin/develop` → `selectedSessionLines=1`、浮窗显示引擎行；
  第一版谓词 → `selectedSessionLines=2`、浮窗显示 **WebSocket 行**。
- 危害落在 galgame 侧：浮窗 `latest` 在两个来源之间跳；且无身份行不会写
  `_lineTextEventIdCache`（只有 `TexthookerLineSource.engineHook` 行会写，
  `gal_hook_session_controller.dart:3330-3332`），逐句语音配对拿不到 `textEventId`，
  只能退回时间戳兜底窗 —— 正是 BUG-1193 记录过要避开的 BUG-1159 失败链。

- **[x] 已收敛** — 放行分支改为 `return selectedKey == null;`：未选线程时无身份行发布
  （本条正方向不变），已选线程时让位（隔离不变量恢复成 v12 之前的行为）。
- **[x] 已加自动化测试** — `hibiki/test/lookup/gal_hook_overlay_thread_isolation_guard_test.dart`
  两条用例分别钉住两个方向。变异实测：改回 `return true` → 只有「已选线程不得混入」那条红；
  改成 `return false` → 只有「未选线程仍须发布」那条红；正确实现下 2/2 绿。
  相邻定向套件（`texthooker_page_test` / `gal_capture_audio_integrity_test` /
  `texthooker_service_test` / 上述两个 overlay 测试）合计 62/62 绿，`flutter analyze` 零问题。
