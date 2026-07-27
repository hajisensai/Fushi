## BUG-1137 · gal 制卡分类标签误标 video：来源枚举缺 game 且默认值静默兜底
- **报告**：2026-07-27（用户：gal 一键制卡的卡片在 Anki 里标签仍是 `hibiki video`，要求统一这块代码，不再每次手动补标签）
- **真实性**：✅ 真 bug。根因两层：
  1. `AnkiMiningSource` 枚举只有 `book` / `video`（`packages/hibiki_anki/lib/src/anki_models.dart:413`），游戏来源根本没有对应分类标签；
  2. `ImmersionMiningRequest.source`（`hibiki/lib/src/mining/immersion_mining_request.dart:74`）与 `buildExternalWindowRequest`（`hibiki/lib/src/mining/external_window_mining.dart:38`）都带 `= AnkiMiningSource.video` 默认值，gal 场景卡协调器 `gal_hook_mining_coordinator.dart:224` 构造请求时没传 `source`，被静默兜底成 video → 卡片打上 `video` 标签。texthooker 页无绑定窗口时的 fallback 纯文本卡走 `dictionary_page_mixin` 默认映射，同理被标成 `book`。
- **[x] ① 已修复** — 本分支（PR 随附）：
  - 枚举加 `game`，`BaseAnkiRepository` 加 `gameTag = 'game'` 并入 `_categoryTagForSource` 映射；
  - **消灭默认值**：`ImmersionMiningRequest.source` 与 `buildExternalWindowRequest` 的 `source` 改必填，所有调用点显式声明来源（漏传=编译错，不再静默 video）；
  - gal 场景卡协调器显式 `source: AnkiMiningSource.game`，并按「自动添加书名到标签」开关把游戏窗口标题接入 `bookTitleTag`（与 reader 书名 / video 番名同语义，同走 `sanitizeTitleTag`）；
  - texthooker 页覆写 mixin 新开的 `miningSource` getter 为 `game`（统计口径不动，标签与统计两个维度）；
  - 互联转发 `_forwardedSourceFromName` 补 `'game'`；17 语言 `anki_tag_include_category_hint` 文案补 game 描述。
  - 既有误标 `video` 的旧卡不迁移不重写（Never break userspace）。
- **[x] ② 已加自动化测试** —
  - `packages/hibiki_anki/test/mining_tag_and_parallel_test.dart`：game 来源 → `['hibiki','game']` 两后端行为测试；
  - `hibiki/test/pages/mining_default_tags_wiring_static_test.dart`：新增守卫「gal 制卡链路显式声明 game 来源，source 无静默默认值」（③处：request 必填、协调器 game、texthooker 覆写）+ `gameTag` 存在 + i18n 文案含 game；
  - `hibiki/test/mining/external_window_mining_test.dart`：source 显式透传断言。
- **备注**：坏数据结构（枚举缺值）+ 隐式默认值（漏传不报错）是根因；修法是补值域并把「来源」变成编译器强制的显式声明，而不是在 gal 调用点打一个 `source: video→game` 补丁完事。
