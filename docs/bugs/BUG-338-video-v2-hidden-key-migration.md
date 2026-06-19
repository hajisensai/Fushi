## BUG-338 · 视频控制v2迁移隐藏键静默移除
- **报告**：2026-06-19（用户：TODO-598 / 551 审计·中危回归）
- **真实性**：✅ 迁移逻辑本身**无丢失**（验真后定为「数据不丢，但迁移意图隐式」）。根因路径 `hibiki/lib/src/media/video/video_control_customization.dart:1048-1057`（`_decodeSlots`）。
  - 沿真实代码路径验证：v2 布局把用户从播放器移走的全部按钮塞进单个 `hidden` 槽（`encodeV2ForTests`）；v3 改用显式 `removed` 集合，不再持久化 `hidden` 槽（`encode` 第 926 行 `if (slot != VideoControlSlot.hidden)`）。
  - 升级解码时，v2 `hidden` 槽里的每个键都会进入 v3 的 `removed` 集合（仍可从调色板还原），**按钮状态（不在播放器上）逐键无损保留**。
  - 经验证据（probe 测试，五个学习键全部隐藏）：`speed/subtitleList/favoriteSentence/favoriteSentences/settings` 解码后均 `isOnPlayer=false` 且 `removedItems` 包含——无一丢失。`settings` 虽 `pinnedOnTouch` 但跨平台仍可移除，故同样保留。唯一不进 `removed` 的是 `playPause`（`pinnedRequired`，永不可隐藏），由 `_normalize` 正确回填到播放器——这是设计正确，不是丢失。
  - 结论：审计所述「控制键消失却不知」实为**用户在 v2 自己隐藏的按钮在 v3 继续保持隐藏（可还原）**，是正确行为，非真回归。但旧实现把 hidden→removed 迁移混在 `_decodeSlots` 内联 `continue` 里，**迁移意图隐式、且无多键守卫测试**——这才是要硬化的点。
- **[x] ① 修复** — 把 v2 `hidden`→v3 `removed` 迁移抽成自文档命名的纯函数 `_migrateV2HiddenKeysAsRemoved`，使「升级时保留每个旧 hidden 键为 removed（可还原）、绝不静默丢键」成为代码里显式、集中、不可被随手破坏的契约。行为零变化（对现有 v3 用户与 v2 升级用户均等价），无新增 i18n。提交：见 worktree 提交哈希。文件：`hibiki/lib/src/media/video/video_control_customization.dart`。
- **[x] ② 加自动化测试** — `hibiki/test/media/video/video_control_layout_test.dart`：① `TODO-598: every v2 hidden key survives migration as a removed key`（五学习键全隐藏，逐键断言 off-player + 在 removed，含 `settings`）；② `TODO-598: a v2-hidden key stays removed after a full v3 encode round trip`（解码 v2 → 编码 v3 → 再解码，断言隐藏键仍 removed 且为稳定不动点）。把迁移助手改成 no-op（撤掉修复）后两条测试同时转红，证明守卫真实生效。
- **备注**：纯持久化模型逻辑修复 + 守卫，无 widget/真机路径，不需设备复测。`flutter analyze` 0；`flutter test test/media/video/` 全绿（844 通过 / 2 跳过 / 0 失败）。
