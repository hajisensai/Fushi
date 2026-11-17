## BUG-4836 · 新代同库 A 拿 B 的实体 ID 写下的悬空操作，A 的集合并入 B 之后改到 B 的笔记 / 卡片（BUG-4626 新代并入场景）
- **报告**：2026-11-18（SRS gen4 第四波 G9-5d 复核发现；交接 `docs/specs/2026-11-15-srs-gen4-handoff.md` §26 T1 节「BUG-4626 判据在新代放宽」
  与「第四波 G9-5 续」节「没做 / 交出去」）。归属：G9 身份 / 设计（内核取舍）；第五波 G9 身份收尾已修。
- **真实性**：✅ 真 bug（2026-11-17 在分支 `pr/srs-gen4-g9-5d-link-flow` 上实测：下面的复现用例 `flutter test` exit 1，1 条执行，
  `Expected: '鳥'` / `Actual: '被 A 改'`）。
  - 场景：同一份 `srs4.db` 里有 A、B 两份 profile（两个集合）。A 的 store 拿 B 的笔记 / 卡片 ID 改字段、标签、旗标、暂停。
    协议 3 在追加前拒绝（BUG-4626 的修复，`ownership.rs` `foreign`）；新代不拒绝，落成 A 集合日志里指向「本集合不存在的 ID」
    的悬空操作，B 当时看不到。之后另一台设备上的 B 经 `.fushisrs` 确认并入 A 的集合（`srsExportFushiSrs` → `srsImportFushiSrs`，
    内核 `import` + `collection_adopt`）——设计稿 2026-11-11 §2「ID 不再按 uid 加盐、并入 = 操作并集」，这些悬空操作随并集
    对 B 的同名实体生效：B 的笔记字段变成 A 写的值。
  - 根因（写入口不设闸）：`native/fushi_fsrs/src/store/gen4/cmd/writes.rs:31`（文件头「没有跨 profile 的归属判定」：按
    「别的集合的实体在这里根本不可见」放掉了协议 3 的 `ownership.rs` 闸）与 `:886`（`apply`：直接 `apply_in` 追加，不核对
    实体是否属于本集合 / 本库别的集合）。
  - 根因（并入是无条件并集）：`native/fushi_fsrs/src/store/gen4/identity.rs:430`（`adopt_foreign`，`Joined` 后两个集合的操作
    全部并进同一个派生层）、`:572`（`absorb_foreign`，半截并入收尾同口径）；`.fushisrs` 并入入口
    `native/fushi_fsrs/src/store/gen4/cmd/fushisrs.rs:415`（`import`）。
- **[x] ① 已修复**（第五波 G9 身份收尾，分支 `pr/srs-gen4-w5-identity-tail`，提交 `e7ad8988eb`）— 选修法 1「写入口归属闸」：
  新文件 `native/fushi_fsrs/src/store/gen4/cmd/writes_owner.rs`（唯一判据 `Session::foreign`）。一条本机操作指向的实体（修改的实体、
  标签的笔记、清除的实体、日志的笔记 / 卡）在库里**别的集合有**（`ent_ix.id` / `alias_ix.canon` / `cards.id`）、**本集合一点痕迹都
  没有**（身份记录、别名类、卡片行、修改 / 日志 / 标签索引行、这一批要建的实体；先不收尾查、没查到再收尾查一遍）时不写：
  `apply_in`（`apply` / `change` / `import_drafts` / 意图命令）那一项 `landed: false`、下标进回包 `foreign`；`purge` 跳过并回
  `foreign`；`sched` 按「没有这张卡」跳过（撤销计入 `blocked`）。库里只有一个集合时一条查询就放行。SCHEMA 40021 → 40023，三个
  按 ID 跨集合查的部分索引 `ent_id` / `alias_canon_any` / `cards_id`（条件 `col > 0` 只有归属闸的查询写，既有执行计划不变）。
  - 为什么不选修法 2（并入时丢悬空操作）：闸只决定本机要不要写下一条操作，写下之后的传播 / 收段 / 导入 / 并入语义一个字不改，
    几台设备算出的状态仍只由同一份操作集合决定，并集照样收敛；修法 2 要给「并入时不存在」定跨设备一致的判据，还会误丢合法的
    先写后有（同批先后到、换笔记类型时血统先于卡）。
  - 不误拦合法写：ID 不加盐后两个集合导入同一份内容会有同一个 ID——本集合有痕迹就照写；「哪里都没有的 ID」照写（同协议 3）；
    同批里先写修改、后建实体照写；换笔记类型时先改类型后写新卡血统，收尾后新卡已物化，照写。
  - 挡不住闸之前已写下的悬空操作：新代还没发布、协议 3 有 `ownership.rs` 闸且 ID 带盐，迁移来的日志里不存在这种存量。
- **[x] ② 已加自动化测试** — 内核 `native/fushi_fsrs/src/store/gen4/cmd/writes_owner_tests.rs`（经 C ABI：A 写 B 的字段 / 整列表
  标签 / 清除一条都不落、`foreign` 交回下标；两边都有的 ID 同批先改后建、单独再改、哪里都没有的 ID、B 写自己的都照常；单集合库
  照旧；`THEIRS_SQL` / `OURS_SQL` 执行计划走索引）；engine 端到端 `packages/fushi_engine/test/srs/srs_profile_ownership_merge_test.dart`
  （上面的复现用例，补了「A 的日志一条不多」的断言）；`srs_profile_ownership_test.dart` 的判据从「A 多出的操作与不存在的 ID 一样多」
  收紧为「不多于」、批量改卡「别人的卡不落、不存在的卡落悬空记录」。变异实测：`foreign` 恒放行 → 内核用例红，还原后工作区干净。
- **备注**：
  - 同库两集合互不并入时没有后果（A 的悬空操作只在 A 的集合里，B 看不到）；只有 A 的集合之后并进 B（本机或别的设备确认并入、
    `.fushisrs` 导入）才生效。
  - BUG-4626（协议 3）的修复与测试不受影响；本条是新代换代后同一前提的新场景，单独一条以免改动已结案的 4626。
