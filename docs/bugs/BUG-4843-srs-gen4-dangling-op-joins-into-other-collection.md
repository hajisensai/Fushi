## BUG-4843 · 新代同库 A 拿 B 的实体 ID 写下的悬空操作，A 的集合并入 B 之后改到 B 的笔记 / 卡片（BUG-4626 新代并入场景）
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
  - **复核补修**（2026-11-18，提交 `089ff6b293`）：第一版闸漏了两类写入，复核实测都能在并入后改到 B——
    ① 身份记录：`target()` 对 `Body::Entity` 返回 None、`apply_in` 还把它直接放进同批要建的实体（`Born`），A 写一条 B 的笔记的
    身份记录（伪造 guid、换成 A 的笔记类型）就落了，并入后按「规范 JSON 最小者胜」顶掉 B 的笔记类型与 guid；带着它的同批修改也借它
    过了闸。② profile 设置实体：它不在 `ent_ix` / `alias_ix` / `cards` 留痕迹，A 拿 B 的 uid 改翻日时刻照样写，并入（盐取并集）
    后成了 B 的设置。现在：身份记录先各自过闸，只有过了闸的才进 `Born`；笔记身份记录的 ID 由自己内容派生（`v5(NS, note/<guid>)`）
    的照写（两个集合各自导入同一个包 / 同一份挖词历史就该是同一个 ID），对不上的按判据判；牌组、笔记类型的身份记录不判（规范 ID
    按全名 / Anki 编号派生，内置的在每个集合都是同一个常量）；profile 设置实体按「ID 是别的集合的 profile uid / 盐、又不是本
    集合的」判（`PROFILE_SQL`，同协议 3 `ownership.rs`），规范值永远放行。`sched` 的闸补了内核测试。
  - 残留（已知、不修）：伪造一条 guid 与 B 的笔记**一致**、但笔记类型换成别的的身份记录仍会过闸（它与「别的集合独立导入同一份
    内容」在写入口分不出来）；并入时两份身份记录按「规范 JSON 最小者胜」取一份，这是并入的通用规则。正常的写入口不会这样写
    （复核报告的复现用的是伪造的 guid）。
- **[x] ② 已加自动化测试** — 内核 `native/fushi_fsrs/src/store/gen4/cmd/writes_owner_tests.rs`（经 C ABI：A 写 B 的字段 / 整列表
  标签 / 清除一条都不落、`foreign` 交回下标；两边都有的 ID 同批先改后建、单独再改、哪里都没有的 ID、B 写自己的都照常；单集合库
  照旧；`THEIRS_SQL` / `OURS_SQL` 执行计划走索引）；engine 端到端 `packages/fushi_engine/test/srs/srs_profile_ownership_merge_test.dart`
  （上面的复现用例，补了「A 的日志一条不多」的断言）；批量改卡「别人的卡不落、不存在的卡落悬空记录」。变异实测：`foreign` 恒放行 →
  内核用例红，还原后工作区干净。
  - 复核补测（`089ff6b293` 及其后的测试提交）：第一版把 `srs_profile_ownership_test.dart` 写入口矩阵的判据从 `==` 改成了「不多于」
    并称之为收紧，实际是放宽——某个入口没过闸时别人的 ID 与不存在的 ID 落一样多的悬空记录，「不多于」照样通过，上面两类泄漏就是
    被它盖住的。现在按入口断言「A 为别人的 ID 一条都不写」：只碰别人 ID 的入口断言 A 的日志长度不变，同时写自己实体的入口
    （只有 `dismissDuplicates 自己的 + 别人的`，实测得出）断言 A 的真相里没有指向别人 ID 的操作；远程路由那组断言
    别人的 ID 落 0 条。内核新增 `another_collections_identity_records_are_not_written`、
    `another_collections_profile_settings_are_not_written`、`sched_skips_another_collections_cards`；并入端到端补「A 写 B 的笔记的
    身份记录、A 拿 B 的 uid 改翻日时刻 → 并入后 B 的笔记类型 / guid / 翻日时刻不变」。变异实测（各自单独改、跑完还原）：身份记录
    恒放行 → 身份记录用例红；profile 判据恒放行 → profile 用例红；`sched` 闸关掉 → `sched` 用例红；内容派生放行关掉 → 「两边都有
    的 ID」用例红。
- **备注**：
  - 同库两集合互不并入时没有后果（A 的悬空操作只在 A 的集合里，B 看不到）；只有 A 的集合之后并进 B（本机或别的设备确认并入、
    `.fushisrs` 导入）才生效。
  - BUG-4626（协议 3）的修复与测试不受影响；本条是新代换代后同一前提的新场景，单独一条以免改动已结案的 4626。
