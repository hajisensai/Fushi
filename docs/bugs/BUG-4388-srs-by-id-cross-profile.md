## BUG-4388 · 复习库按实体 ID 的读写不看 profile：点名 A 的命令能读 / 改 / 删 B 的笔记、卡片、牌组、笔记类型
- **报告**：2026-11-11（代码审查发现，PR #3304 审到多 profile 宿主入口时提出；与该分支里的
  `BUG-4388-srs-by-id-access-not-profile-scoped.md` 是**同一个问题**——那份只在无头服务端的控制通道入口加了核对，
  本条在根上收口。两份撞号，由 `bug.dart settle` 改号。）
- **真实性**：✅ 真 bug（`packages/fushi_engine/test/srs/srs_profile_ownership_test.dart` 在修复前的 develop 上复现：
  一份 srs.db 开两个 profile 的 store，A 的 store 拿 B 的 ID 能读到 B 的笔记 / 卡片 / 修改记录 / 复习历史，
  能改字段、删笔记、搁置 / 重排 / 作答 B 的卡、改 B 的牌组与笔记类型）。
  - 前提：一份 `srs.db` 可以同时放几个 profile（app 的多份配置、无头服务端一门语言一份），实体 ID 却是整库主键
    ——`srs_entities` / `srs_notes_cache` / `srs_cards_cache` 的主键是 `id`，修改记录按 `(entity_kind, entity_id)`、
    复习日志按 `card_id` 归到实体上。profile 之间互不干扰全靠「一个 profile 的操作只指向它自己的实体」
    （ID 派生里带 uid，`packages/fushi_srs/lib/src/ids.dart`），而这条前提没有任何地方核对。
  - 根因（写）：内核三个产生本机操作的入口都不看目标实体记在谁名下，直接追加操作再投影：
    `native/fushi_fsrs/src/store/sync2/mod.rs:2165`（`sync2_apply_local`）、
    `native/fushi_fsrs/src/store/sync2/sched_local.rs:172`（`sync2_sched_local`）、
    `native/fushi_fsrs/src/store/sync2/mod.rs:2387`（`sync2_append`：彻底清除 / 冲突解决）。投影按 ID 落：
    `project_entity`（`mod.rs:1252`）、`land_edit`（`mod.rs:1397`）、`project_log`（`mod.rs:1495`）都不带
    `profile_uid`，于是一条 A 的操作改掉 B 的投影行，B 名下的修改记录还会被这条「并发」写入支配掉。
  - 根因（读）：`SrsDbStore` 按 ID 的 Drift 直读不带 `profile_uid`：
    `packages/fushi_engine/lib/srs/srs_db_store.dart:2586`（`_entityRow`，笔记 / 笔记类型 / 牌组的身份记录）、
    `:2594` / `:2612` / `:2657`（刷新预读的身份记录 / 修改记录 / 日志）、`:1074`（`noteFieldKeyValues`）、
    `:3144`（`_historyInput`）、`:3771`（`cardRows`）、`:3864`（`cardRow`）、`:5052`（`cardsOfNote`）、
    `:5038`（`cardIdsInDecks`）、`:3481` / `:3510`（删牌组时按牌组找笔记 / 卡片），
    `packages/fushi_engine/lib/srs/srs_note_type_store.dart:156`（`cardsOfNotes`）；评分预览在内核
    `mod.rs:2606`（`sync2_preview`）。
  - 受影响的调用面：凡是把调用方给的 ID 原样交给 store 的入口——远程复习主机
    （`packages/fushi_engine/lib/srs/srs_remote_store.dart:1180` 的方法表，点名 A、参数里给 B 的 ID）、
    app 控制通道（`fushi/lib/src/ops/ctl_srs_routes.dart`：读一条笔记、批量改字段 / 查找替换、重复笔记合并 / 标记）、
    切换配置前留在 UI 里的 ID。
- **[x] ① 已修复** — 归属核对落在内核的本机写命令（新文件 `native/fushi_fsrs/src/store/sync2/ownership.rs`，
  唯一判据 `foreign`）：`apply` / `sched` / `sync2_append` 在追加操作**之前**问它，指向别的 profile 实体的那一项
  不追加、不投影（`apply` 的回包 `foreign` 交回下标）；评分预览同样先问。`SrsDbStore` 按 ID 的直读一律加
  `profile_uid` 条件，`editFields` / `editFieldsBatch` / `writeEdits` 的返回值去掉没落库的记录。别的 profile 的 ID
  对调用方表现为「不存在」。
- **[x] ② 已加自动化测试** — 内核 `native/fushi_fsrs/src/store/sync2/tests_ownership.rs`（apply / sched /
  purge / preview、没人的 ID 照常落）；engine `packages/fushi_engine/test/srs/srs_profile_ownership_test.dart`
  （store 的读与四十多个写入口、远程复习主机路由、自己的 ID 照常生效）；app 控制通道
  `fushi/test/ops/ctl_srs_profile_ownership_test.dart`。
- **备注**：
  - 远端操作（收段 / 导入备份，`transport.rs`）不设闸：那是「集合里的对端写了什么」，拒绝投影会让本机与只有
    这一个 profile 的设备算出不同的状态摘要，属同步语义，要另行设计。
  - 「哪里都没有的 ID」照旧可以写（换笔记类型时给还没生成的卡写血统、导入时同批先后到），所以在原始 store API
    层面「别人的 ID」（写入是空操作）与「没人的 ID」（落一条悬空记录）仍可区分；先读后写的入口（路由层）两者都是
    「不存在」。
  - PR #3304 在无头服务端控制通道入口加的 `_requireInTarget` 与本修复是同一条前提的两层：本修复合入后那一层
    只剩「更早回 404」的作用，可删可留。
