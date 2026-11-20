## BUG-4907 · 新代同库 A 拿 B 的实体 ID 写下的悬空操作，A 的集合并入 B 之后改到 B 的笔记 / 卡片（BUG-4626 新代并入场景）
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
  - ~~残留（已知、不修）~~（第六波已收口，见下一条）：当时的说法有两处不对——① 伪造一条 guid 与 B 的笔记一致、只换笔记类型的
    身份记录「在写入口分不出来」：分得出来，B 的定义就在同一个库里，比一下结构即可；② 牌组 / 笔记类型的身份记录「不判、对它们的
    修改仍判」：实测（第五波第二轮复核）它们不判却进 `Born`，同批对 B 的牌组 / 笔记类型的修改借它过闸。
  - **第六波收口**（2026-11-18，分支 `pr/srs-gen4-w6-identity-gate`，提交 `9862498f08`）——归属判据改成**内容寻址**，定在身份
    记录上（`writes_owner.rs` 文件头「身份记录：内容寻址的归属」，`Session::foreign_record`）：库里有别的集合、别的集合里有 X 的
    痕迹时，本集合为 X 写身份记录必须同时满足 ① 能自证——ID 由这条记录（牌组再加同批的名字 / 父牌组）按规范规则重算得出（笔记
    `note/<guid>`、笔记类型 `notetype/<Anki 编号>`、牌组 `deck/<全名>` 及备选（前一个已被本集合占着才轮得到，同 Dart
    `deckIdForNew`）、内置默认牌组常量；卡片没有合法的身份记录来源，永远自证不了）；② 结构与库里每个有 X 定义的集合的定义相同
    （笔记 guid + 笔记类型、笔记类型 Anki 编号 + 种类，各按自己的别名表归一后比；`createdAt` 不算结构）。例外只有一条：与本集合
    此刻的定义逐字相同的重发（不带新内容）。不满足的不写、不进 `Born`，同批借它作保的修改一并不写。字段 / 模板是笔记类型上的
    `fieldDef/` / `tmplDef/` 修改，跟着笔记类型的归属走。
    - 为什么不选「首个身份记录的作者集合定归属、并入时作者 ≠ 归属的修改不生效」：合法的「两个集合各自导入同一份内容」里后建的
      一方并入后对自己那份写的修改与复习全部失效（丢复习记录）；作者集合要进操作格式、`derive.rs` 冻结判定与重建恒等都要重做；
      它同样分不出内容完全一致的那种。写入口的判据不改并入语义，并集照样收敛（同第五波的论证）。
    - 剩下的、按定义不算「别人的」：A 拿出的身份内容与 B 的**完全一致**（同 guid + 同笔记类型、同 Anki 编号与种类、同全名）——
      内容寻址下这就是同一个实体，与「A 独立导入了同一份内容」逐字节相同，之后 A 对它的修改并入后作用到合成的那一份，是设计
      里的并集语义。
    - 取舍：库里另一个集合已有同 guid、不同笔记类型的笔记时，本集合导入这条笔记不写（`foreign`，同 Anki「同 guid 异笔记类型」
      跳过）；`createdAt` 不同的照写。
    - `createdAt` 不算结构的代价：拿到 B 的 guid 的一方写一条同 guid、同笔记类型、`createdAt` 更小的记录能过闸，并入时「规范
      JSON 最小者胜」可能拿它顶掉 B 的 `createdAt`——只影响 B 这条笔记的新卡次序，不碰内容、复习与排程；ID 是 v5 哈希、反推不出
      guid，要先知道 B 的 guid 才做得到。接受，不修。
  - **第六波复核跟改**（2026-11-20，同分支）：上面「导入这条笔记不写」在 Dart 侧是**静默**的——Dart 不读回包 `foreign`，
    `.apkg` 导入（`srs_apkg_import.dart` `_flush`）与文本导入（`srs_text_import.dart` `flush`）照记「已添加」，卡片实际不存在：
    同一个包 / 同一份 CSV 被同库两份 profile 导入、两边落到不同笔记类型（`.apkg` 不合并笔记模板时 `_mapNoteType` 的副本类型、
    文本导入用户选的类型）时，后导入的一方悄悄少了这些笔记。Anki 跳过时会报告，这里不报，违背「不能让用户出问题」。修法（根因
    是回包契约没被消费，且下标本身对不上）：
    - 内核 `writes.rs` `apply_in`：`foreign` 改报**调用方输入下标**（`Origin`，同 `edits` 第 7 列）——以前报筛掉初值项之后的
      位置，`import_drafts` 筛掉过初值项时对不上草稿；
    - Dart `SrsDbStore.importDrafts` 返回 `SrsImportDraftsResult`（`existed` + `foreignNotes`：回包 `foreign` 指向的笔记身份记录
      草稿的笔记 ID）；两个导入路径落库后才计数，被拒的记 `conflictNotes`（新原因 `otherProfileNoteType`，导入报告文案
      `srs_import_report_conflicts_other_profile`：另一份配置已有同一批笔记、属于另一个笔记类型，用同一个笔记类型 / 打开「合并笔记
      模板」再导入），不加 `notesAdded` / `cardsAdded`；它的卡片计数整份不进报告（第二轮复核起按 `_CardTally` 落了才并进，见下）；
    - `.apkg` 导入落库时按新笔记的卡带上日志的笔记（`importDrafts(cardNotes:)`，第一轮叫 `logNotes`）：新笔记的卡还没有缓存行，
      以前日志只带卡、目标是「哪里都没有的卡」，笔记被拒时它的复习照样悬空落进本集合、进统计与日历；带上笔记后跟着笔记一并不落。
  - **第六波第二轮复核跟改**（2026-11-20，同分支）：
    - 报告计数：第一轮只退回了复习数 / 重置为新卡数，`fushiLogsRestored`、`revlogsVerifiedByExt`、`revlogsAlreadyPresent`、
      `revlogsNotInExt`、`anchorsWritten`、`futureCards` 仍按已导入计。根因是按卡的计数直接记进报告、被拒后逐个减回。改成一条
      笔记的卡片计数记在 `_CardTally`（`srs_apkg_import.dart`，`_importNote` 的卡片循环与 `_importCardSchedule` 只记这里）：已有
      笔记当场并进报告，新笔记随 `_PendingNewNote` 等落库回包，落了才并进、被拒的整份不计——从同一个「被拒」判断推出，不再
      逐个计数器打补丁。来源包里卡已删除的 revlog（BUG-4657）不属任何笔记，仍直接记报告。
    - 卡片级修改：第一轮没改的「被拒笔记的卡片修改（新卡位置、牌组、暂停，目标是副本类型派生的卡 ID，哪里都没有）按『哪里都
      没有的 ID 照常写』落成悬空修改」修掉。内核 `writes.rs` `apply_in`：**卡片修改带笔记**（输入项的 `note`，同日志带笔记）时，
      除了卡自己过闸，它的笔记也过闸——笔记是别人的（同批身份记录被拒的那条笔记没进 `Born`，别的集合有、本集合没有）就一并不写，
      下标进回包 `foreign`；只加严，不带笔记、笔记是本集合的 / 同批要建的 / 哪里都没有的，结果同以前。Dart `_applyInput` 给卡片
      修改按 `cardNotes` 带上笔记，`.apkg` 新笔记的卡全在里面。
    - 没选「内核按被拒笔记 × 模板推出卡 ID 一并拒」：填空题的卡序号来自笔记字段（`{{cN}}`，上不封顶，别名层要靠字段史补上限外
      的序号），副本类型的模板又常在同一批才建，内核要在写入口重做一遍 Dart 出卡规则才推得全，推不全的照样漏；调用方本来就是按
      笔记 × 模板派生出这些卡 ID 的，声明给内核即可精确闭合（取舍写在 `writes_owner.rs` 文件头「卡片修改带笔记」）。
    - 仍没覆盖：同 profile 回导 / 旧卡接链补的 `historyFrom` 链接（`_historyLinks`）在导入末尾经 `writeEdits` 单独写、不带笔记。
      新笔记要走到这条路须 fushi-ext 同 profile 且前身卡在本集合、或撞上认不出笔记的旧卡，被拒笔记几乎走不到；没构造出能触发的
      路径，不为它加未测的过滤，记在交接第六波节。
    - 这层保护只在两个集合同处一个库时有：分在两台设备各自导入时都能写进去，日后并入仍按「规范 JSON 最小者胜」二选一笔记类型
      （同 guid 异笔记类型是 ID 只由 guid 派生的固有代价，设计 2026-11-11 §2）。两份 profile 只在用户确认并入时才合到一起，
      这一条记在交接第六波节「没做」。
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
  - 第六波补测（`9862498f08`、`c0191271be`）：内核 `native/fushi_fsrs/src/store/gen4/cmd/writes_owner_merge_tests.rs`——每种
    实体一条「A 写 B 的 ID → A 的集合导出、在另一个库里确认并入 B（`joined`）→ B 的实体视图（`entity_views`：定义、活着的修改、
    标签、日志、缓存行）与并入前逐字相同」：笔记（用 B 真实 guid、只换笔记类型的记录 + 同批改字段，残余二）、卡（卡片身份记录
    + 旗标、暂停、`sched` 重置）、牌组（身份记录 + 同批改名，残余一；冒充内置）、笔记类型（编号对不上 / 换成 cloze / 存量随机 ID
    抄同样内容）、字段（`fieldDef/`）、模板（`tmplDef/`）；合法场景：两个集合独立建同一份内容（含内置实体、`createdAt` 不同）并入
    合成一份且两边的写都在、牌组备选 ID、子牌组按父牌组全名、迁移库双盐别名类（`tests_class.rs`）、经 `.fushisrs` 带进来的存量
    同号实体重发自己的定义。变异实测 10 项（牌组 / 笔记类型不判、不比别的集合的定义、去掉重发例外、备选不往后试、不按父牌组
    全名、笔记类型 / 笔记 / 卡片自证恒真、内置牌组恒自证、笔记自证恒假）各自单独改都有用例转红，还原后工作区干净。
  - 第六波复核跟改补测：内核 `import_drafts_reports_foreign_at_the_callers_input_index`（初值项筛掉后被拒项按原输入下标报；变异
    「按筛掉后的位置报」→ `left: [0]` / `right: [1]` 转红）；engine `srs_apkg_import_test.dart`「同库另一份 profile 已有同 guid、
    另一个笔记类型的笔记」（不合并导入：记 `otherProfileNoteType`、`notesAdded` / `cardsAdded` 为 0、`reviewLogsImported` 比只有一份
    profile 的对照少 1——同次导入里别的笔记的复习照常计数、P2 没有
    这条笔记也没有它的复习；合法场景：合并笔记模板再导入照常加上、复习落下）与 `srs_text_import_test.dart`「GUID 列的 guid 在同库
    另一份 profile 里是另一个笔记类型的笔记」（记冲突、同批别的行照常；同一个笔记类型照常导入）。
  - 第六波第二轮复核跟改补测：内核 `card_edits_carrying_a_rejected_note_are_not_written`（`import_drafts` 里被拒笔记的两条卡片修改
    进 `foreign`、不写；同批要建的笔记 / 本集合已有的笔记 / 哪里都没有的笔记的卡、不带笔记的哪里都没有的卡照写；`apply` 同一个闸，
    同一张卡不带笔记照写）；engine `srs_apkg_import_test.dart` 组「被拒的笔记整份不计、卡片修改不落」三条——每条先断言 P2 的报告
    与「包里没有 g4」的单 profile 对照**整份 `toJson` 逐项相同**（只多 g4 一条冲突），再按场景断言对照里 g4 确实贡献了：fushi-ext
    恢复 / 校验 / 包外 revlog / 日志 / 锚点各 1；未来卡记进 `futureCards`；新卡位置与暂停写在 g4 的卡上（P2 同样那几张卡一条修改都
    没有）。
- **备注**：
  - 同库两集合互不并入时没有后果（A 的悬空操作只在 A 的集合里，B 看不到）；只有 A 的集合之后并进 B（本机或别的设备确认并入、
    `.fushisrs` 导入）才生效。
  - BUG-4626（协议 3）的修复与测试不受影响；本条是新代换代后同一前提的新场景，单独一条以免改动已结案的 4626。
