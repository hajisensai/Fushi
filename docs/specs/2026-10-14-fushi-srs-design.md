# Fushi SRS 设计（定稿：集合版 8 + 第六轮审查修正【修9】）

> 状态：2026-10-14 实现中（分支 `worktree-fushi-srs`）。本文件是 SRS 的**唯一设计真相源**，取代 QQ 里流转的修订版 / 集合版 txt。
> 结构：先列【修9】（第六轮审查 `docs/reviews/2026-10-14-srs-review-round6.md` 的逐条处理与代码位置），
> 再列实现现状与已知缺口，最后是集合版 8 原文（作为契约正文；被【修9】改掉的地方以【修9】为准）。
> 审查记录：第四轮 `docs/reviews/2026-10-14-project-review.md`（HBK-AUDIT-001～009），第五轮 `docs/reviews/2026-10-14-srs-review-round5.md`（7.md），第六轮 `docs/reviews/2026-10-14-srs-review-round6.md`（9.txt）。

## 产品约束（用户 2026-10-14 追加）

- SRS 整体是一个默认关闭的模块（`ModuleId.srs`，「外观 → 模块」里打开；`ModuleId.defaultEnabled` 只有它为 false）。没打开的用户看不到任何入口。
  **2026-10-16 更新**：出厂默认改为开（新装默认 Fushi 复习；升级上来的老用户由 `PreferencesRepository.settleSrsMiningTargetInstallDefault` 一次性显式写关、不提醒），见 `ModuleId.srs` 文档。正式版构建屏蔽（PR #2237）已撤回，五端各通道都提供复习模块。
- 新手引导里有 SRS 步骤，但只有模块已开启时才进入步骤序列；向导不替用户勾选 SRS 模块。
- 所有页面同时适配 MD3 与 Apple 两套设计系统，并带动效（仓库规则）。

## 【修9】第六轮审查的处理

按审查自己的建议，先把第 1、2、3、5 条写成确定性模拟器的固定用例、确认旧方案会失败，再改铁律。
模拟器：`packages/fushi_srs/test/simulator_test.dart`（固定用例 + 120 个固定种子的随机序列，五条断言，失败自动缩减）。
变异实测：去掉因果闭包（第 1 条的修法）后，固定用例与 6 个随机种子变红；恢复后全绿。

| # | 问题 | 处理（替代集合版 8 的规则） | 代码 / 测试 |
|---|---|---|---|
| 1 | 铁律 H 的支配不传递：ctx = cursor 前缀，没有因果投递 | ctx 改为**按已应用记录统计的因果闭包**：应用一条记录时把它的 dot 与它自己的 ctx 一起并入本机上下文。任何含 a.dot 的上下文都 ⊇ a.ctx，支配可传递，丢掉被支配的记录安全 | `fushi_srs/lib/src/causal_context.dart`、`field_edit.dart`（`SrsEditWriter.apply`）、`event_store.dart`；固定用例「a ← b ← c」 |
| 2 | vv 装不下不连续的 dot（新化身重新发布的旧事件、改回 / 确认、备份合并） | ctx 用 dotted version vector（连续前缀 vv + 额外 dot 集合 cloud），按已应用记录统计，不按已读批次 | 同上；固定用例「由新化身重新发布的旧 dot」「改回覆盖全部候选」 |
| 3 | 收到对端 HLC 不钳位，快钟设备把所有人推到未来 | `HlcClock.receive` 用 `min(远端, S(e)+10min)` 推进；S 未知时只推进到本机可信时间 + 10 分钟 | `hlc.dart`；固定用例「时钟快一年的对端」 |
| 4 | 钳位在「离线久、发布晚」时失效 | 保证写准确：领先量上限 = min(时钟偏差, 发布延迟 + 10 分钟)，不是 10 分钟。anchored 来源的事件时间本身可信；wall 来源且排序键被钳位 = timeUncertain，不进优化器 | `ordering.dart` 文件头；`srs_optimizer.dart` 的 `_timeUncertain` |
| 5 | 锚点与它自己那条来源 revlog 同刻，靠 eventId 哈希定先后 | 锚点 HLC 计数器取 1：`(T, 1, "anki")`，来源 revlog 为 `(T, 0, "anki")`，锚点恒在后 | `anki_import_rules.dart` 的 `srsImportAnchorHlc`；固定用例 50 张卡 |
| 6 | 只有导入日志有 ankiRevlogType，原生日志没有 | **所有日志**在创建时写 `reviewType`（复习前的队列：learn / review / relearn / filtered / manual / rescheduled），之后不推导 | `review_log.dart` 的 `SrsReviewType`、`card_ops.dart` |
| 7 | 「找不到 config.id 就按名字匹配本机已有项」让 ID 依赖本机状态 | 按名字回退只用纯函数 `UUIDv5(noteTypeId, "field-name/"+名字)`，不看本机；之后带上 ankiNum 只记成该项的别名属性，ID 不换 | `ids.dart` 的 `fieldByName` / `templateByName`；`entities.dart` 的 `SrsFieldDef.ankiNum` |
| 8 | 内置 Lapis 的 ID 规则与通用规则冲突；每台设备都会写一遍内置定义 | 内置笔记类型走通用规则（固定 ankiNum = hash53("fushi/builtin-notetype/lapis")，导出再导入回到同一 ID）；内置定义版本化：用户没改过的项不写修改记录、跟随代码，改过之后才由修改记录决定 | `ids.dart`、`entities.dart`（`SrsBuiltinNoteType`）、`fushi_engine/lib/srs/srs_builtin.dart` |
| 9 | （原文缺失） | — | — |
| 10 | 两台设备各自自动优化，冲突列表经常出现 | 优化器写的参数组标为机器产出（`SrsFieldEdit.machine`）；生效值仍按 sortKey，但胜者与败者都是机器产出时不进「同步冲突记录」 | `field_edit.dart` 的 `visibleLosers`；`srs_optimizer.dart`；固定用例 |
| 11 | 跨算法比较用训练集内评估；「训练条数 ≥ 当前条数才采用」让参数在条数变少后永远更新不了 | 跨算法比较用 fsrs-rs 的时间序列切分外样本评估（`evaluate_with_time_series_splits`，C ABI `evaluate_tss`）；删掉训练条数条件，同算法新旧参数只比同一份数据上的 log loss | `native/fushi_fsrs/src/lib.rs`、`srs_optimizer.dart` |
| 12 | FSRS-7 的 elapsed 粒度没定 | 钉定 rev 有 `next_states_with_elapsed_days(f32)`，FSRS-7 训练保留小数 delta_t。C ABI 一律传**小数天**；FSRS-7 用 (毫秒差 / 一天)，FSRS-6 与 Anki 一致按翻日后的日序号取整。另：FSRS-7 的记忆状态多一个 `stability_fast`，日志结果里一起存 | `lib.rs`、`valid_logs.dart` 的 `srsElapsedDays`、`fsrs_engine.dart` 的 `SrsMemory.stabilityFast` |
| 13 | 生成门在查询层渲染模板太慢、PR2 用不上 | 卡片缓存表 `srs_cards_cache.hidden`（本机、可重建、不同步）在笔记 / 笔记类型变化时算好，查询只读这一列 | `tables.dart`、`srs_db_store.dart` 的 `_refreshNote` |
| 14 | 多设备按需生成卡片，初始 deckId 不确定 | 笔记有「首选牌组」字段（`SrsFieldKeys.noteDeck`）；卡片没有自己的 deck 修改记录时取它，再没有取默认牌组。生成本身不写任何记录 | `entities.dart` 的 `SrsCardFlags.materialize` |
| 15 | 铁律 E 改 uid 会把已同步的 profile 和其它设备断开 | 采用对方 uid 的条件加上「**从未发布过批次**」（`SrsSyncLocalState.everPublished`） | `sync_engine.dart`、`srs_db_store.dart`、备份合并步骤 |
| 16 | 日界统一不完整：谁覆盖谁没定 | SRS 与统计页共用一个本机值 `stats_day_reset_hour`；profile 设置行里的 `dayRolloverHour`（同步值）存在时以它为准。默认 4 点只在**用户第一次打开 SRS 模块、且从没自己设过日界**时写入（`AppModel.setModuleEnabled`）：SRS 默认关闭，没开 SRS 的用户统计口径不变 | `srs_db_store.dart` 的 `dayContext`、`app_model.dart` |
| 17–18 | StatSourceKind.book 含漫画；漫画 / 在线小说 / 在线视频的定位形状 | SourceRef 新增 `manga`（作品 + 章节 + 页码 + 可选 OCR 框）、`onlineNovel`（源 + 小说 URL + 章节 URL + 偏移）、`onlineVideo`（源 + 作品 URL + 剧集 URL + 时间区间） | `source_ref.dart` |
| 19 | PR7 安全：text/plain 跨站 POST、path 读任意文件、url SSRF、服务端无当前 profile | 核对后更严重：Fushi API 实际监听所有网卡（`yomitan_api_server_manager.dart` 传 `allowLan: true`）。兼容层加 Origin 白名单、无 key 时只收回环、storeMediaFile 的 path / url 默认禁用、url 打开时拒绝回环 / 私网；profile 由宿主传入 | `fushi_engine/lib/srs/ankiconnect/` |
| 20 | termKey 只按词形，同形异读合并 | termKey 拆成词形 + 读音两段，查询有读音就两段都比；`SrsTermStatus` 带 `cardCount` | `term_status.dart`、`srs_notes_cache.reading_key` |
| 小 | 探针文件位置 | 探针在写入者自己的目录（`srs_asset_store_directory.dart`、`sync_engine.dart`） | 测试「探针文件写在写入者自己的目录」 |
| 小 | 互联「取响应头」与「统一用探针文件」不一致 | 统一用探针文件 + 列目录 modifiedAt；Nextcloud 的 X-OC-MTime 是客户端自报时间，本仓写入不带这个头 | `sync_asset_store.dart` 注释 |
| 小 | handOff 卡回导两种结果 | 卡片归属只由显式移交事件（handOff，两个方向，「收回」也是 handOff）决定；导入锚点的 scheduler 恒为常量、不参与归属判定 | `valid_logs.dart` 的 `SrsCardHistory.scheduler`、`anki_import_rules.dart` |
| 小 | Anki 里遗忘的卡回导保留旧状态 | 来源卡是新卡但有排程相关 revlog（含重置那条 Manual）照常写锚点；只有「新卡且没有任何排程相关 revlog」才不写 | `srsDecideAnchor`；单测「遗忘过的卡」 |
| 小 | utcOffsetMin 与翻日时刻 | 每条日志存 `utcOffsetMin` 与 `dayRolloverHour`（事件内容） | `review_log.dart` |
| 小 | 复习时长谁来写 | 评分时把 `durationMs` 写进日志；学习统计的 `StatSourceKind.srs` 接入放在统计页那一期（见缺口） | `card_ops.dart` |
| 小 | fushi-ext 导入另一个 profile 时 revokesId | 日志 id 与 revokesId 用同一个函数 `SrsIds.remappedLog` 重映射 | `ids.dart` |
| 小 | 第 0 步「一天左右」 | 估算不成立；本分支已做完可本机做的部分（fsrs-rs 钉定 rev 的签名核对、Windows / Android arm64 构建、FFI 冒烟、优化器在合成数据上的耗时：6000 张卡约 0.45 秒）。需要真机 / 真实 Anki 集合的项目列在缺口里 | — |
| 小 | 依赖 fushi_anki 的限制 | fushi_srs 不依赖 fushi_anki（零依赖内核）；Lapis 定义在 fushi_engine 里从 `fushi_anki_core.dart` 取，受引擎纯度守卫约束 | `srs_builtin.dart` |

### 本轮额外发现并修掉的问题（实现中）

- 备份恢复语义：恢复 = 本机数据整体换成备份内容并换新化身；模拟器最初的内存副本把备份叠加在现有数据上，导致备份之后的本机事件滞留未发布、各端不收敛（随机种子 1、4、24…）。已修。数据库副本：本机状态与缓存表不进备份，`SrsDbStore.open` 发现「有事件、无本机状态」即判为覆盖恢复：换新化身、全部重新发布、重建缓存。
- v117 迁移在没有 profiles 表的合成旧库上 ALTER 失败（`_tableExists` 守卫已补）。

## 笔记类型管理与「更改笔记类型」（2026-10-15，分支 `pr/srs-note-types`）

用户反馈「没有地方能改笔记类型」。补齐 Anki 的笔记类型管理与 Change Note Type，规则全部落在铁律 C / D / H 之内：

- 结构编辑（铁律 D）：新建（基础类型 / 克隆）、改名、加 / 删 / 改名 / 调序字段、加 / 删 / 改名 / 调序模板、改模板与 CSS、
  选词条字段，都只写笔记类型这一行的修改记录（每个字段定义、模板定义各是一个字段键，按项合并）。新建项的 ankiNum 随机、
  ID 由 noteTypeId + ankiNum 派生（铁律 C），导出写进 Anki 的 config.id。调序只给 ord 真变了的项写记录（内置项没动过的继续跟随代码）。
  删字段按 rslib 语义把模板里对它的引用一起去掉（条件段保留段内内容）；删模板 / 删字段 / 删笔记类型都是软删除，删笔记类型连同它的笔记。
  内置 Lapis：可以改，不能删笔记类型、不能删内置字段（挖词与词状态按内置 fieldId 读写）。代码：`fushi_srs/lib/src/note_type_ops.dart`、
  `fushi_engine/lib/srs/srs_note_type_store.dart`。
- 更改笔记类型：笔记身份记录不可变，换类型写笔记的修改记录 `noteType`（设置类：并发换成不同类型时最后修改生效、进同步冲突记录）；
  字段值按「新字段 ← 旧字段」映射写到新 fieldId（旧字段的值留在修改记录里，读时忽略，换回原类型时还在）。
  卡片 ID 由 (noteId, templateId, clozeOrd) 派生，换类型后必然是新卡；新卡上写 `historyFrom/<旧 cardId>` = true（每个前身一个键，
  集合语义，两台设备加同一个前身是同值、不冲突）。新卡的复习历史 = 自己 + 全部前身卡的日志（`SrsDbStore.history` 按血统收集），
  卡片标志（暂停 / 埋卡 / 旗标 / 牌组）自己没有记录的键沿最近的前身继承。**复习日志一条不改**（铁律 F：事件创建即不可变）；
  别的设备在收到换类型之前复习旧卡，那条日志同步过来后自然进入新卡的历史。一份历史就是一张逻辑卡，铁律 B 的导入等价判定在同一份历史内不再比 cardId。
  普通 → 普通按用户的模板映射；涉及填空类型时按 Anki「序号不变」：第 i 个模板 ↔ c(i+1)。没有去处的旧卡在查询层隐藏（生成门），历史留在日志里。
- 导出 / 回导：导出的 revlog 归到新卡（Anki 看到的是一张带完整历史的卡）；fushi-ext 多一项 `logCards`（前身卡日志 → 它在包里归的卡），
  同 profile 回导时日志原样落回前身卡并补上前身链接，另一个 profile 回导时日志重映射到新卡。
- 界面：牌组列表 ⋯ →「笔记类型」（`srs_note_types_page.dart` → `srs_note_type_editor_page.dart` → `srs_template_editor_page.dart`，
  模板编辑器带实时预览）；笔记编辑页的类型行与浏览页批量操作走 `fushi/lib/src/srs/srs_change_note_type.dart` 的
  `showSrsChangeNoteTypeFlow`。

## 释义样式去重（2026-10-16，分支 `pr/srs-style-dedup`）

Yomitan 导出释义时每部词典内联一份 `<style>`，同一部词典的每张卡都带同一份。开发版制卡历史实测：最近 50 条释义平均
11.7 万字符 / 卡，其中 7.1 万是样式；全部 208 条只有 7 种不同的样式块。每条笔记一份 → 数据库、同步批次、备份同比放大。

- **表示**（fushi_srs `style_dedup.dart`，冻结）：笔记字段值里**无属性**的 `<style>`…`</style>`、正文 ≥ 512 码元、不在
  `<script>` 里的块，换成 `<link rel="stylesheet" href="_fushi_style_<sha1(css)>.css">`；样式正文存成同名共享媒体文件
  （下划线开头，Anki「检查媒体」不删）。文件名只由内容决定 → 各设备各自去重得到逐字节相同的值；展开是逐字节还原。
- **为什么是共享媒体文件、不是新表**：媒体已经按内容哈希同步（只传对方没有的）、随「复习」备份打包，不用升 schema、
  不用为样式另开一条同步通道；新表方案（落库占位、读出展开）要么让同步批次继续带全文（省不了流量），要么新增一种同步实体。
- **落库**（`SrsDbStore._store` → `_compactEdit`）：一切修改记录落库都经这里——本机写（制卡、笔记编辑、制卡历史导入、
  AnkiConnect 加卡 / 改卡、浏览页批量）、`.apkg` 导入、对端事件——只动 `note` 的 `f/<fieldId>` 字符串值。
  `SrsDbStore.open(styles:)` 不给样式库时一律原样落库（无头服务端、测试、备份合并步骤临时打开的副本）；
  这样落下的行由下面的存量迁移在 app 下次打开 store 时补上。
- **合并语义不变**：`_sameValue`（冲突判定、no-op 判定的唯一口径）对字符串按去重规范形比较，内联样式与引用行同值。
  所以同一内容由两台设备（一台去重、一台没有）并发写下不进「待裁决」；用户把原文再存一遍是 no-op。
  这是「事件创建即不可变」的唯一表示层例外：同 ID 的记录可能一端存内联、一端存引用，`_store` 按 ID 去重，二者在合并里同值；
  id / dot / ctx / hlc 一律不动。
- **对外的读展开**（`SrsDbStore.expandStyles` / `expandFields`）：`renderCard`（文件还没同步到时删掉引用行，不让 WebView
  请求相对地址；渲染结果与去重前逐字节相同，卡面外壳照旧按内容哈希登记样式）、`.apkg` 导出（自包含：展开回内联、不带样式文件，
  AnkiDroid / AnkiMobile 对字段里 `<link>` 的支持未验证）、AnkiConnect `notesInfo` / `cardsInfo` 的字段值、制卡回读
  `SrsMiner.fieldsByName`（出处卡片的乐观并发检查要求读回与写入一致）、模板编辑器的示例笔记。
- **编辑器里看到的**：笔记编辑页是原始 HTML 输入框，用户看到的是一行 `<link>`（几十 KB 的 CSS 不再塞进输入框）。原样保存是
  no-op；删掉这一行就是删掉该词典的样式（与在 Anki 里删 `<style>` 等价）；粘贴进来的大样式保存时照样去重。
  浏览页的「查找替换」作用在引用表示上（搜 CSS 文本不再命中）。
- **导入回读**：Fushi 导出的包本来就是内联样式，回导时重新去重；字段里是引用行、包里带同名样式文件的包（例如手工处理过的），
  按包内文件校验哈希后展开再去重。
- **媒体同步**：`srsReferencedMedia` 把字段里的样式引用算进被引用媒体，样式文件与图片 / 音频同一条通道上传下载。
  对端先收到事件、后收到样式文件时，卡面暂时没有词典样式，下一轮媒体同步后恢复。
- **存量迁移**（`SrsDbStore.compactStoredStyles`，打开 store 后在后台跑）：按 rowid 游标分批（每批一个事务），把已落库的
  记录就地换成引用表示；游标记在本机状态里，可中断可续，幂等；恢复备份后游标归零。**不产生任何新事件、不进发件箱**：
  零同步流量，每台设备迁移自己的库。若改用「写新的修改记录」迁移，每台设备都要把所有带样式的字段（去掉样式后）重新发布一遍
  ——开发版 50 / 208 条分别约 2.7 MB / 12 MB，再乘以设备数，且各端都会收到别人的那一份。
  服务器上已发布的旧批次仍是内联样式（不改），新设备首次同步下载它们后由自己的迁移去重；之后写的快照是引用表示。
- **实测**（`packages/fushi_engine/test/srs/srs_style_dedup_real_data_test.dart`，开发版库只读副本）：修改记录总字节
  50 条 6795 KB → 2731 KB（40.2%）、208 条 30560 KB → 12275 KB（40.2%），共享样式文件 7 个 / 189 KB；逐张渲染与去重前一致。
- 代码：`fushi_srs/lib/src/style_dedup.dart`、`fushi_engine/lib/srs/srs_style_store.dart`、`srs_db_store.dart`；
  测试：`fushi_srs/test/style_dedup_test.dart`、`fushi_engine/test/srs/srs_style_dedup_test.dart`、
  `fushi/test/srs/srs_style_dedup_app_test.dart`。

## 自动全量备份与按时间点恢复（2026-10-17，分支 `pr/srs-auto-backup`）

对标 Anki 的「备份」：定期全量快照 + 恢复到某个时间点，详见 [2026-10-17-srs-auto-backup-restore.md](2026-10-17-srs-auto-backup-restore.md)。
要点：恢复**不是**覆盖恢复（那样别的设备一同步，备份之后的事件就全回来了），而是先并入备份事件，再把差异写成新事件——
字段写一条支配本机已见一切记录的修改记录（新建的软删除、删掉的恢复），备份之后的有效日志写 undo，
仍不一致的卡写 manual 日志照抄备份时的状态。这些新事件随同步传播，恢复时本机已见过的旧数据被支配、回不来。

**铁律 A 追加 ③′（恢复照抄状态的起点）**：带 `extra.restoreOf` 的 manual 日志（不是重置）是记忆状态 S/D 的起点，
与导入锚点同一套规则：结果里有同算法（`extra.memAlg`）的记忆状态就直接用，否则由 ease + 间隔做 SM-2 换算，
再接上它之后的有效评分（`valid_logs.dart` 的 `srsIsRestoreState`）。被它取代的评分已被撤销、不在有效历史里，
不这样做下一次评分就从零重算。

## 实现现状（分支 worktree-fushi-srs）

| 计划项 | 位置 | 状态 |
|---|---|---|
| PR1 fushi_fsrs | `native/fushi_fsrs/`：JSON C ABI，FSRS-6/7，小数 elapsed，可取消优化器，外样本评估，纯 Rust zstd | 完成。Windows x64 / Android arm64 本机构建；五平台脚本；`native-fsrs-gate.yml`；`build-multiplatform.yml`、`release.yml`、`release-desktop.yml`（Windows/macOS）、`release-server.yml` 编译并核对随包 |
| PR1 fushi_srs | `packages/fushi_srs/`：ID、HLC、DVV、修改记录合并、sortKey/S(e)、有效日志、S/D 输入、排程策略、新卡预算、同步协议、Anki 搜索子集、FFI | 完成；确定性模拟器 120 种子 + 全部历史反例为固定用例 |
| PR2 数据层 | schema v117（`profiles.uid` + 8 张 srs_* 表），`fushi_engine/lib/srs/srs_db_store.dart` | 完成；恢复备份自动换新化身 |
| PR3a 添卡 | 编辑页；挖词目标「Fushi 复习」（`fushi/lib/src/srs/srs_mining.dart`，Anki / 复习 / 两者）；制卡历史批量导入；AnkiConnect 兼容层 | 完成 |
| PR3b Anki 导入（新旧格式）与导出 | `fushi_engine/lib/srs/apkg/` | 完成（导出为旧格式 + fushi-ext） |
| PR4 复习页 | `fushi/lib/src/pages/implementations/srs/` | 完成；MD3 / Apple；空格 / 1–4 / Ctrl+Z / 手柄；连续撤销 |
| PR5 接线 | 默认关闭的模块（首页「复习」tab）、新手引导、同步冲突页、查词弹窗复习标记（app 内 / app 外 / 浏览器扩展） | 完成 |
| PR6 自动优化 | `srs_optimizer.dart` + `fushi/lib/src/srs/srs_optimization_scheduler.dart`（空闲时后台 isolate） | 完成 |
| PR7 AnkiConnect | `fushi_engine/lib/srs/ankiconnect/`，挂在 Fushi API 根路径 | 完成；仅 SRS 开启时可用 |
| 浏览页增强 | `fushi_engine/lib/srs/srs_browse.dart`（快照 + 搜索 + 排序 + 卡片 / 笔记模式；搜索求值对象与 AnkiConnect 共用）、`srs_browse_ops.dart`（批量操作，每个一个事件批次 + 撤销）、`fushi/lib/src/pages/implementations/srs/srs_browse_*.dart` | 完成；搜索子集补 `flag:` `card:` `edited:` `is:buried` `prop:ivl/due/reps/lapses/s/d` `re:` `字段:re:`（`rated:` `prop:ease/pos/r` `nc:` `dupe:` 等仍明确报不支持）；「更改笔记类型」只留了入口（`SrsBrowsePage.onChangeNoteType`） |
| 第三期同步 | 协议 + `srs_asset_store_directory.dart`；七个后端的服务器时间；媒体按内容哈希同步（`srs_media_sync.dart`）；备份合并（铁律 E） | 完成 |
| 多目录同步（2026-10-19） | 一台设备同时用云盘 + 互联、本机作 host 时自己的目录也参与：`fushi_srs` 引擎按目录记进度 + 本机批次留存（schema v121 `srs_sent_batches`）+ 转发；目录身份 `fushi/lib/src/srs/srs_directory_key.dart`；host 目录装配 `srs_app_runtime.dart` | 完成；见下文「多目录传输」。模拟器加桥接 / 双目录拓扑随机种子 |

### 已知缺口（需要真机 / 外部条件，或留到下一期）

- 第 0 步里只能在真机 / 真实 Anki 上做的项：Anki 导出 → 导入 → 回导的 mod 实测、真实 revlog 与 Anki 的 S/D 对拍、iOS 伞形静态库真机链接、移动端优化器耗时与内存、Lapis JS 宿主依赖、bookKey 跨设备身份结论。
- 复习页卡面媒体（虚拟域拦截、`[sound:]` 播放）只在测试替身下验证过，没有在真机 WebView 上跑过。
- 「含睡眠的开机单调时钟」：纯 Dart 拿不到，退到本进程 Stopwatch（同一进程内改系统时间不影响，进程重启后重新校时）。
- iOS：伞形 crate `native/fushi_ios_umbrella/` 已就绪，Runner 还没切换，iOS 包里暂无排程内核（SRS 只能浏览、不能复习）。
- 发布 workflow 的 fushi_fsrs 步骤还没在 Actions 上真跑过。
- 无头服务端还没有 SRS 装配（AnkiConnect 兼容层只在 app 侧挂；`fushi_server/lib/src/host_bindings.dart` 留了 TODO）。
  客户端照常经互联把 SRS 文件写进服务端的同步目录、彼此经它同步；服务端自己不读不写 SRS 数据。
  app 作为 host 时自己参与（2026-10-19 起，`SrsLocalDirectory`）。
- 媒体：删除不跨设备传播；无引用文件的本机回收（30 天宽限）未做。
- 学习统计 `StatSourceKind.srs`、到期提醒、阅读器着色与「标为已知」属第二期。

---

以下为集合版 8 原文（契约正文）。

```text
Fushi SRS 实现计划（集合版 8，2026-10-14）

本版是集合版，取代修订版 5 / 修订版 6 与审查意见 6.txt / 7.md，以后只看这一份：
  · 底稿：修订版 5（计划本体）。
  · 【修6】排程算法：默认 FSRS-7，只支持 FSRS-7 / FSRS-6，不做 RWKV（用户 2026-10-14 定）。
  · 【修8】第五轮审查（7.md，取代 6.txt；6.txt 的 16 条已全部含在 7.md 里）的 A-1～A-7、B-1～B-3、C-1～C-6 全部并入。
    本版并入时对 7.md 做了三处修正，见下方「第五轮审查的处理」末尾。
修订版 2 / 3 / 4 / 5 的【改】【新】【修3】【修4】【修5】标记保留，便于对照。
被【修8】取代的旧规则直接删掉，不再并列；被取代的是哪条，写在对应【修8】段落里。

第五轮审查（7.md）的问题与本版处理：
  A 档 · PR2 冻结前必须改（协议层）
  A-1 「整批拒收」与「cursor 只推进无缺口前缀」冲突；v6 的「把 S 写进事件内容」又与 A-2 的「外流前冻结」冲突
        → 事件创建即不可变；取消整批拒收，改为排序键钳位；发布时服务器时间 S 作为带外元数据（批次信封 + 快照映射）；
          排序键 sortKey = (min(hlc, S + 10 分钟), writerId, eventId)（铁律 F）
  A-2 发布门修改未发布事件，但备份 / 快照 / 导出可能已带走它们
        → 删掉发布门的有界修正，事件内容任何环节都不改（铁律 F）；「取哈希小的」只剩兜底
  A-3 importAnchor 用 Anki 卡片 mod 时刻，往返导入会覆盖 Fushi 状态（前提待实测）
        → 第 0 步先实测；锚点时刻改取来源最后一条排程相关 revlog；该 revlog 等价于原生日志时不写锚点（铁律 C）
  A-4 S/D「从最近锚点起算」与 Anki 口径不一致
        → 锚点只决定队列与到期；S/D 输入按 rslib 规则：revlog 完整用完整历史，不完整才从锚点做 SM-2 换算（铁律 A）
  A-5 定义缺口：模板删除 / 条件模板变空的卡、新卡出卡顺序、导入事件并列、导出与等价判定范围
        → 生成门扩到模板（铁律 D）；新卡按 (note createdAt, cardId) 出卡（PR4）；排序键含 eventId（铁律 F）；
          导出排除已撤销日志、等价只比评分类（铁律 B）
  A-6 停止人工反例审查，改用确定性多设备模拟器
        → fushi_srs 里写模拟器，作为 PR2 冻结的前置门（PR1）
  A-7 可编辑字段的并发修改会「晚写静默覆盖」
        → 可编辑字段改为「带因果上下文的修改记录」，用版本向量判因果；并发且值不同 = 冲突，按字段分三级处理（铁律 H，新增）
  B 档 · 冻结时一并定下的数据契约
  B-1 出处做成有类型的一等字段 → srs_notes.source（SourceRef，PR2）；bookKey 跨设备身份与 MinedSentences 归属列入第 0 步
  B-2 学习统计的来源种类与「今天」口径 → StatSourceKind 加 srs（PR2）；日界统一为一个设置（待你拍板默认值，见「待定」）
  B-3 词状态查询接口 → PR2 只定签名与本机索引（termKey），实现放 PR5
  C 档 · 实现阶段
  C-1 词状态回流到查词弹窗（第一期），阅读器着色与「标为已知」（第二期）→ PR5 / 第二期
  C-2 同步层做成通用层 → packages/fushi_engine/lib/sync/ 下的通用事件日志同步（第三期「传输」）
  C-3 服务端时间几乎都能拿到 → AssetEntry 加 modifiedAt，serverTime() 统一用探针文件（铁律 F）
  C-4 iOS 直接上伞形 staticlib → 前提 4 / PR1，删掉第 0 步的「验证会不会撞」
  C-5 服务端随包、空格键、模块注册、动效、新手引导 → PR1 / PR4 / PR5
  C-6 计划文档本身 → 定稿写进 docs/specs/；内置 Lapis 的 fieldId 由 LapisNoteType 的字段键派生（铁律 C）
  并入时对 7.md 的修正（2026-10-14 核对 develop）：
  1. C-6 说 docs/reviews/2026-10-14-project-review.md「在上游和本地都不存在」，不准确：它在未合并分支
     codex/srs-rev4-review（提交 ccb085d620）上，develop 里没有。定稿前把它合进 develop，或在 spec 里改引分支提交。
  2. A-7 / C-2 说互联视频 / 有声书播放位置「已在 PR #2177 改为三方判定」，不准确：#2177 目前仍是 OPEN，没合并。
  3. A-1 第 3 点「同一事件出现在多个批次时，以 cursor 序最早的那份为准」：cursor 只在单个写入者内部有序，
     跨写入者没有全序，各端结论可能不同。改为取所有已见批次 S 的最小值（与收到顺序无关），见铁律 F。

修订版 6 的说明：
【修6】在修订版 5 基础上只改排程算法：默认算法由 FSRS-6 改为 FSRS-7，并支持 FSRS-7 / FSRS-6 两种算法；
不做 RWKV（用户 2026-10-14 定，理由见文末「不采纳」）。
修订版 5 的说明：
本版（修订版 5）在修订版 4 基础上修掉第四轮审查（docs/reviews/2026-10-14-project-review.md，HBK-AUDIT-001～009，
Codex 对修订版 4 的协议反例审查）提出的问题，改动点用【修5】标出；
修订版 2 / 3 / 4 的【改】【新】【修3】【修4】标记保留，便于对照。

== 【修6】排程算法：默认 FSRS-7，支持 FSRS-7 / FSRS-6 ==

两种算法的定位：
  算法    默认  能在哪算                          用户参数                    说明
  fsrs7   是    五个平台 + 无头服务端              34 个，可自动优化            新建牌组的默认
  fsrs6   否    五个平台 + 无头服务端              21 个，可自动优化            与官方 Anki 26.09.3 一致；从 Anki 导入、已有 FSRS-6 参数的牌组先用它

为什么默认 FSRS-7（数字见「修订依据」的 srs-benchmark 一条）：
1. Fushi 的学习 / 重学步长都在当天以内（PR1 的硬规则），所以应该看「含当天复习」那张表。
   在那张表上，FSRS-7 的 log loss 是 0.3206，FSRS-6 是 0.3842；
   连未优化的 FSRS-7 默认参数（0.3399）都比优化后的 FSRS-6 好。
   新用户前几周数据不够、跑不了优化，这段时间的体验取决于默认参数的质量。
2. 不含当天复习时，FSRS-7 也略好（0.3401 对 0.3460）。只有一种情况 FSRS-6 占优：
   FSRS-6 已经用用户数据优化过，而 FSRS-7 还在用默认参数（0.3460 对 0.3620）。
   这正是「从 Anki 导入、带优化后 FSRS-6 参数」的牌组，所以这类牌组先保留 fsrs6，
   等 FSRS-7 在同一份数据上评估更好时再自动切换（PR6）。
3. 公式型，34 个参数，和 FSRS-6 在同一个 crate、用同一组接口（排程 / 由历史重建记忆状态 / 优化 / 评估）。
   五端都能算，结果写进日志同步，铁律 A 不用改形状。

第四轮审查的问题与本版处理（9 条全部成立，逐条核实过）：
  001 新设备从一份快照起步，版本向量互不支配，删了旧目录后可能永远读不到它的数据
        → 起步读「每个活跃写入者的最新快照」；删目录另需全部活跃对端读完（第三期「传输」）
  002 墓碑物理回收后，合并旧备份 / 退役设备回归会让已删数据复活
        → 墓碑永不物理删除，只清空字段值、保留时钟（「瘦身墓碑」）
  003 importAnchor 的 ID 确定了，内容（HLC、writerId、结果）却随导入时刻变，同 ID 异内容不收敛
        → 导入事件 = 不可变内容，HLC 与结果全部由来源数据确定性算出；发布元信息与事件内容分离（铁律 C）
  004 noteTypeId 含结构哈希，Anki 侧加一个字段就整套 ID 重生成，旧卡接不上历史
        → 去掉结构哈希；字段 / 模板 ID 取 .apkg 里的稳定 config.id，文件里没有就按名字；已有 ID 永不重生成（铁律 C）
  005 Fushi 自建笔记导出再导入，按 guid 派生出新 noteId，往返身份断裂
        → Fushi 导出的 guid 编码 noteId，字段 / 模板 / 笔记类型的 Anki id 由 Fushi ID 哈希派生，回导可逆；
          导入复习与原生复习按确定性等价规则去重（铁律 C / B）
  006 未来 HLC 在合并中照样胜出，正常端之后的修改永远赢不了
        → 批次带发布时的服务器时间，读方确定性拒收超前事件；删掉「接收侧 24 小时上限」（铁律 F）
          【修8】「拒收」已被第五轮审查 A-1 取代：改为排序键钳位，不拒收
  007 用当前偏差平移全部未发布事件，会把原本正确的时间改坏，dueAt 也没跟着改
        → 不再整体平移；事件时间取「可信时间」（服务器校时 + 同次开机单调时钟），只对可证明错误的事件做有界修正（铁律 F）
          【修8】「有界修正」已被第五轮审查 A-2 取代：事件创建即不可变，可证明有错的事件只从训练集排除
  008 日志结果没有 lastReviewedAt / reps / lapses / scheduler，导入或手动改期后 elapsed 算错
        → 结果载荷补齐，elapsed = 评分时刻 − lastReviewedAt（铁律 A）
  009 自校验只保证单文件完整，cursor / vv 可能越过缺口
        → 批次号连续、cursor / vv 只表示无缺口前缀、重传同号同内容（第三期「传输」）

第三轮审查的问题与修订版 4 的处理（保留）：
  致命
  1  旧化身目录删除后，之后才加入的设备读不到它写过的数据（不转发 + 快照只含本机改动）
       → 快照改为「完整合并状态 + 版本向量」，旧目录在被某个活跃快照覆盖后才可删（第三期「传输」）
  2  多设备独立创建「同一个东西」拿到不同随机 ID：内置牌组 / Lapis、导入的笔记、导入的 revlog、导入映射
       → 确定性 ID 规则表（铁律 C）
  3  填空卡一个模板出 N 张卡，UUIDv5(noteId, templateId) 表达不了
       → cardId = UUIDv5(noteId, templateId, clozeOrd)（铁律 D）
  重要
  4  铁律 A 里「最后一条日志的结果」与「折叠函数重放队列 / 学习步」是两个状态来源，并发复习后会分叉
       → 卡片排程状态只有一个来源：最后一条有效日志；删掉重放（铁律 A）
  5  「undo 只撤销末条」只在本机检查，合并后仍可能出现基于被撤销日志算出的后续日志；撤销后的状态未定义
       → 写明合并后的语义与撤销后状态（铁律 B）
  6  SyncAssetStore 没有 rename；.done 标记要两次写入
       → 批次 / 快照 / cursor 文件自校验（头部带长度与哈希），校验不过视为不存在；第 0 步该项关闭
  7  backup_merge_engine 按 Profile 名字合并，SRS 行带的 profileUid 会成孤儿；
     「无 SRS 数据才允许改 uid」与首启内置牌组互相卡死
       → Profile 合并规则（铁律 E），「无数据」改为「无用户笔记」
  8  旧版 app 合并到新模型版本的参数组后无法使用
       → 旧版回退本版本默认参数排程、不回写（铁律 F）
  次要
  9  HLC 不防时钟漂移                         → 发布前用后端服务器时间校验，重写未发布事件的 HLC（铁律 F）
  10 新卡节流在长中断后预算归零               → 预算下限、「数据不足」按有复习的天数（第一期补充）
  11 软删除行永不回收；已删笔记仍会被生成卡片   → 墓碑回收规则、生成门（第三期 / 铁律 D）
  12 .apkg 新格式的 zstd 纯 Dart 无成熟实现    → 解码放进 fushi_fsrs Rust 库（PR1 / PR3b）
  13 「恢复默认」后下一轮自动优化立即覆盖      → 恢复默认重置触发基线（PR6）
  事实修正
  14 「仓库里第一个进 iOS 的 Rust 库」不成立：native/fushi_p2p 已有完整 iOS 链路
       → 照抄该链路；新增「两个 Rust staticlib 同链」为第 0 步必验项

== 修订依据（实测，沿用）==

- native/fushi_anki_sync/Cargo.lock 锁定的 fsrs 是 6.6.2（来自 Anki 26.09.3 的 rslib），不依赖 burn，
  只用 ndarray / rayon / rand 等纯 Rust 包（共 42 个 crate），没有系统库依赖。
- 实测（最小 cdylib，opt-level=z + LTO + strip）：Windows x64 只含排程 110 KB，含优化器 201 KB；
  Android arm64 含优化器 373 KB。优化器在合成数据上跑通，输出 21 个 FSRS-6 参数。
- 许可证 BSD-3-Clause，可以直接链进 app 本体。
- native/fushi_anki_sync（PR#1719 已合）是 AGPL 独立进程，只管往 Anki 加卡和同步，不当 Fushi 的排程内核。两者并存。
- 仓库里没有 Anki 模板渲染器。lapis_style_editor_page 的预览只是拿 CSS 拼一张样例卡（buildLapisStylePreviewHtml）。
- 现有删除墓碑（SyncTombstoneKind / tombstones.part.dart）是「对端删了 → 本机弹确认」语义，SRS 不用它。
- 【修3】Profiles.id 是本机自增 int（tables.dart Profiles），不同设备上的同一个 id 不代表同一个 profile。
- 【修4】iOS 已有 Rust 静态库链路：native/fushi_p2p/build_ios_staticlib.sh 产出 .a 与 xcconfig 片段，
  fushi/ios/Flutter/{Debug,Release}.xcconfig 以 #include? 可选引入，Runner 的 OTHER_LDFLAGS 经
  $(FUSHI_P2P_LDFLAGS) 做 -force_load，Dart 侧 DynamicLibrary.process()；CI 在 build-multiplatform.yml
  与 release-desktop.yml 的 iOS job 里构建。fushi_fsrs 照抄这条链路，不从零搭。
- 【修4】同步后端契约 SyncAssetStore（packages/fushi_engine/lib/sync/sync_asset_store.dart）只有
  ensureNamespace / ensureFolder / listChildren / findAsset / putAsset / getAsset / getJsonAsset / putJsonAsset /
  deleteAsset，没有 rename。ObfuscatingSyncBackend 只混淆 putAsset / getAsset 的字节，JSON 方法纯委托（明文）。
- 【修4】backup_merge_engine.dart 合并 profiles 是「按名字取并集 + 跨库 id 重映射」（文件头注释与 v105 段）。
- 【修5】.apkg 的笔记类型格式里，字段与模板配置可以带稳定 id（proto/anki/notetypes.proto：Field.Config.id = 9、
  Template.Config.id = 8，「used for merging notetypes on import」），导入的笔记类型另记 original_id（= 10）；
  rslib 导入时按它们做字段 / 模板映射（apkg/import/notes.rs 357–420）。这些是可选字段，文件里可能没有。
- 【修5】SyncAssetStore 的 AssetEntry 只有 id / name / isFolder / sizeBytes，没有修改时间；
  读服务器时间要在契约里新增方法（见铁律 F）。
- 【修5】fsrs 6.6.2 的 Rust 方法名是 memory_state（接受独立 starting_state），next_states 消费 days_elapsed；
  计划里的 memory_state_from_history 是自家 C ABI 的名字。
- 【修6】srs-benchmark（open-spaced-repetition/srs-benchmark README，10,000 个集合；
  含当天复习那张表的评估量是 519,296,315 条复习）。三列依次是 Log Loss↓ / RMSE(bins)↓ / AUC↑：
    含当天复习：RWKV-Instant 0.2660 / 0.0321 / 0.8450；RWKV-Curve 0.2974 / 0.0544 / 0.7964；
                FSRS-7 0.3206 / 0.0615 / 0.7475；FSRS-7 默认参数 0.3399 / 0.0895 / 0.7283；FSRS-6 0.3842 / 0.0985 / 0.6830。
    不含当天复习：RWKV-Instant 0.2773 / 0.0250 / 0.8329；RWKV-Curve 0.3193 / 0.0540 / 0.7683；
                FSRS-7 0.3401 / 0.0634 / 0.7167；FSRS-7 默认参数 0.3620 / 0.0910 / 0.7029；FSRS-6 0.3460 / 0.0653 / 0.7034。
  参数量：FSRS-7 34 个、FSRS-6 21 个、RWKV 2,762,884 个。
  RWKV 不按单个用户训练：用 5,000 个用户训练，在另外 5,000 个上评估，再交换一次。
- 【修6】fsrs-rs 的 FSRS-7 还没发版。最新 release 是 v6.6.2（2026-08-28），只有 FSRS-6。
  主干已有 model_v7 / inference_v7 / training_v7 / parameter_initialization_fsrs7 / parameter_clipper_v7。
  JSchoreels fork 钉的是 git rev 0a5737406a0c5c7a5259b144738cbe4a0b649d76：比 v6.6.2 新 70 个提交，
  Cargo.toml 的版本号仍写 6.6.2，依赖仍不含 burn（ndarray / rayon / wide / priority-queue 等），许可仍是 BSD-3-Clause。
- 【修6】JSchoreels/anki（非官方 fork，26.09.3+fsrs7，build 102，2026-10-12）。
  每个预设可选 FSRS-6 / FSRS-7 / RWKV-Curve / RWKV-Instant，界面推荐 RWKV-Instant 管复习、FSRS-7 管回退到期日。
  · RWKV 只在桌面跑：手机客户端不加载 RWKV 后端，照常用 FSRS / SM-2 排程。
  · RWKV-Instant 必须配一个「回退到期日计算器」（FSRS 或 Curve），给手机同步和统计写到期日。
  · RWKV 状态缓存只在本机，不进集合、不同步。
  · 实现代码在 rslib/src/rwkv/（AGPL）。权重文件 qt/aqt/rwkv_inference/RWKV_trained_on_5000_10000.bin，11 MB，
    格式魔数 ARWKVWEIGHTS1，D_MODEL = 128。
  · 资源实测（fork 的 RELEASE.md）：22.4 万条复习时，建状态峰值 2.01 → 1.43 GB（优化后）；
    int8 状态缓存 1,247 MB → 395 MB，进程峰值 528 MB，log loss 基本不变；重建加保存约 11 秒。
- 【修6】srs-benchmark 仓库没有许可证（GitHub API 的 license 字段为空），RWKV 权重的再分发许可不明。
- 【修6】官方 Anki 26.09.3（fushi_anki_sync 钉的版本）只有 FSRS-6，不认识 FSRS-7 参数。
- 【修8】以下为第五轮审查引用、并入时在 develop 上复核过的事实：
  · develop 的 schema 是 v116（database.dart schemaVersion）；Profiles 表没有 uid；AssetEntry 没有修改时间。
  · 仓库没有 HLC / 版本向量实现，也没有 known / learning / new 的词状态。查词弹窗只有 AnkiConnect 查重的 ✓ / +
    （popup.js 的 duplicateCheck → ankiconnect_repository.dart）。
  · 已有三套同步模型：aggregate（每设备一个文件，统计取 MAX、收藏取并集、学习段按 uid 墙钟 LWW）、
    文件箱（三方基线 + 冲突弹窗）、互联 live（host 为真相源；书籍进度三方判定；视频 / 有声书播放位置目前是纯 LWW，
    改三方判定的 PR #2177 尚未合并）。
  · 单写者文件的现成范式：packages/fushi_engine/lib/anki_sync/pending_mine_relay.dart（app 侧另有一份同名装配）。
  · MinedSentences 已有 bookKey / sectionIndex / 字符偏移，视频存 startMs，没有 profileId；
    collections_page.dart 已实现跳回原文。
  · StatSourceKind / ActivityMediaKind 只有 book / video / game；跨域换算在 media_kind_mappings.dart。
  · 统计页的「今天」= 偏好 stats_day_reset_hour（0..23，默认 0，按设备本地时间），写入时定 dateKey，历史不重分桶。
  · 全局 _neutralizeBareSpace（fushi/lib/src/shortcuts/global_navigation.dart:595）在没有文本框聚焦时吞掉裸空格。
  · Lapis 模板与 LapisNoteType.defaultFieldMappings 在 packages/fushi_anki/lib/src/lapis_note_type.dart（:62）。
  · 新手引导现在教的是「去 Anki 里打开 FSRS」（onboarding_wizard_page.dart 的 ankiFsrsTutorialSteps）。
  · 无头服务端只发 Linux x64 与 Windows x64，随包原生库按 bin/../lib/<裸名> 定位（release-server.yml）。
  · 7 个同步后端的列目录元数据里都有服务端时间，只是没映射进 AssetEntry：
      Google Drive modifiedTime（列目录 fields 里补上）、OneDrive lastModifiedDateTime、Dropbox server_modified、
      WebDAV getlastmodified（PROPFIND 里补上）、FTP / SFTP 条目修改时间（FTP 的 LIST 对新文件只到分钟、时区不定，须用 MDTM）、
      互联取响应头。
  · 仓库本体与 Lapis 模板都是 GPL-3.0，许可兼容。

== 三个产品目标（用户 2026-10-14 定，不变）==

1. 上手简单：一个默认牌组（笔记类型 Lapis）+ 全部默认值（记忆率 80%、Anki 默认步长）；
   参数优化在后台自动做、不弹提示；高级设置默认收起。
2. 同步不烦人：后台自动同步，没有冲突弹窗、没有删除确认、没有「需要完整同步」；改设置只传一行。
   【修8】唯一的例外是同一条笔记内容在两台设备上被并发改成不同的值（铁律 H 内容类）：不弹窗，
   只在复习页 / 编辑页显示「待裁决」标记，用户方便时再选。用户写的内容不能静默丢失，这一条优先于「零提示」。
3. 不围绕挖词：笔记 = 字段 + 卡面模板；挖词只是四种添卡途径之一。

== 前提假设（需要你确认）==

1. 与 Anki 并存，一张卡只归一方排程：srs_cards.scheduler = 'fushi' | 'anki'。
   导出到 Anki 并选择「交给 Anki 排程」后 scheduler 改成 'anki'，卡在 Fushi 里只读、不进复习队列（handOff 事件）。
   挖词时同时勾「Fushi SRS」和「推 Anki」默认只进其中一个（设置里选），两个都勾要显式打开并提示会重复排程。
2. 复习单位 note → card：一次挖掘生成一个 note，默认一张「识别卡」。
3. 数据按 Profile 隔离：牌组、笔记类型、笔记、卡片、日志都带 profileUid（【修3】不是本机 int profileId，见铁律 E）。
4. 内核全部走 fsrs-rs FFI（用户 2026-10-14 拍板），五个平台 + 无头服务端一致：
   排程（next_states）、由历史重建记忆状态（memory_state_from_history）、优化器（compute_parameters）、
   效果评估（evaluate）都调同一份 Rust，不维护第二套公式。
   【修6】FSRS-6 与 FSRS-7 都走这份 FFI，每个接口多一个 algorithm 参数。
   版本不再钉成与 fushi_anki_sync 同一版（那版没有 FSRS-7），改钉 fsrs-rs 的 git rev（Cargo.lock 锁死）；
   FSRS-7 进 crates.io 正式版后换成正式版。
   FSRS-6 与 Anki 数值一致这一条仍要保证：第 0 步用同一份真实 revlog，对比新 rev 与 6.6.2 的 FSRS-6 结果。
   【修4】iOS 照 fushi_p2p 的现成链路编静态库（aarch64-apple-ios + aarch64-apple-ios-sim），
   -force_load 链进 Runner，Dart 侧 DynamicLibrary.process() 取符号。
   【修8】iOS 直接做伞形 staticlib（C-4）：两个由同一工具链编出的 Rust staticlib 同时 -force_load，
   std 符号几乎必然重复，不再「先验证会不会撞」。新建一个 iOS 专用 crate 依赖 fushi_p2p 与 fushi_fsrs、
   统一导出两边的 C ABI，Runner 只 -force_load 这一个库（还省一份 std 的体积）；其它平台仍各自出库。
   上层策略（学习 / 重学步长、确定性 fuzz、最大间隔、翻日）在 Dart 里参照 rslib 实现。
   同步传的是结果（铁律 A），不同 CPU 的浮点尾数差别不影响同步一致性。

== 数据模型铁律（PR2 定死）==

A. 日志是唯一事实来源，每条日志自带结果。【修4】卡片排程状态只有一个来源。
   - 每条日志存「这次操作后」的完整排程状态：due（见铁律 G）、scheduledDays、queue（new / learning /
     review / relearning）、learningStep、stability、difficulty，
     【修5】以及 lastReviewedAt（最近一次真实评分的时刻，与本条日志的操作时刻分离）、reps、lapses、scheduler。
     各事件类型怎么填这四项（写死，缓存清空后据此原样恢复，不从历史累计）：
       · review：lastReviewedAt = 本次评分的可信时间；reps + 1；Again 且原队列为 review 时 lapses + 1；scheduler 不变。
       · manual 改到期 / 改间隔、reschedule：四项全部沿用上一条有效日志的结果（不是评分，不动 lastReviewedAt）。
       · manual 重置（设为新卡）：lastReviewedAt = 空，reps = lapses = 0。
       · importAnchor：取来源值——Anki 卡片的 reps / lapses；lastReviewedAt = 该卡最后一条 Anki 评分类 revlog 的时刻
         （没有就空）；scheduler = 'fushi'。
       · handOff：只把 scheduler 改为 'anki'，其余沿用。
       · undo：不是有效日志，不产生结果（状态回到剩下的最后一条有效日志）。
     下次评分的 elapsed = 评分时刻 − lastReviewedAt（空 = 新卡），不用最后一条日志的操作时刻：
     10 月 1 日评分、14 日导入或改期、当天再评分，elapsed 仍是 13 天。
   - 【修4】卡片排程状态 = 「最后一条有效日志」的结果（有效日志的定义见铁律 B；没有有效日志 = 新卡初始状态）。
     【修8】「最后一条」一律按排序键 sortKey 定（铁律 F），不按原始 HLC。本文其它地方说「HLC 最大」的，同样指 sortKey。
     显示、选卡、评分时的起点（队列、学习步、到期）全部取它；卡片表上的这些列只是缓存，随时可从该日志读回，不重算。
     删掉修订版 3 的「学习步、队列 = 折叠函数按日志重放」：重放会在并发复习后得出与最后一条日志不同的队列 / 学习步，
     造成界面显示的到期与评分实际起点不一致。
   - 做一次新复习时的输入：
       · 队列、学习步、lastReviewedAt、reps、lapses、scheduler = 最后一条有效日志的结果。
       · 【修8】记忆状态 S/D 的输入按 rslib 的规则选（A-4，替代修订版 5 的「从最近锚点起算」）。
         锚点只决定队列与到期，不截断 S/D 的历史：
         ① 取该卡最近一次「重置」（manual 重置）之后的全部有效评分日志，含从 Anki 导入的（被判为等价的导入日志已排除）。
         ② 这段历史完整（第一条是学习类评分）→ memory_state_from_history(这段历史, 当前参数)，
            从新卡状态算起，与锚点无关。
         ③ 不完整（第一条不是学习类：Anki 那边历史被裁掉、或卡片来自没有 revlog 的旧集合）→
            以最近一条 importAnchor 为起点：锚点有 FSRS 记忆状态且与当前算法相同就直接用；
            否则用 fsrs-rs 的 memory_state_from_sm2 由锚点的 ease + 间隔换算，再接上锚点之后的有效评分。
         ④ 起点的具体输入（取哪个时刻的 ease / 间隔、天数怎么算）逐项照 rslib 的实现，第 0 步拿真实集合对拍。
     日志里存的 S/D 只是这次算出的结果，不作为下次的输入。所以改参数后不用改任何一行，
     每张卡在下次复习时自然按新参数重算（等价于 Anki 改参数时的「重算记忆状态」，只是推迟到复习那一刻、只算这一张）。
   - 【修6】算法同理：「当前参数」指牌组当前算法的参数组（铁律 F）。
     FSRS-6 和 FSRS-7 的 S/D 不能互作输入：日志里存的 S/D 本来就不作输入，切换算法后，
     下次复习用新算法从历史重算，旧日志一行不改。
     锚点的起点换算（只在上面第 ③ 种情况用到）：锚点带 Anki 的 FSRS-6 记忆状态、而牌组是 fsrs7 时，
     能否把它当 FSRS-7 的 starting_state，由第 0 步实测决定；不能就走 SM-2 换算。
   - 【修4】【修8】所以 fushi_srs 里的「折叠函数」只做两件事：按 sortKey 找出最后一条有效日志；
     按上面 ①～③ 收集 S/D 的输入交给 FFI。不做状态机重放。
   - 用户标志单独成列：suspended（bool）、buriedUntilDay（日历日序号或空）。
     【修8】并发修改按铁律 H 的标志类处理：最后修改生效，被覆盖的值进同步冲突记录，可一键改回。
   - 别的设备只读结果，不重算；两台设备永远不需要算出同一个浮点数。

B. 一切会改变排程的动作都是日志事件：
   - review：评分（rating 1–4，duration）。
   - manual：手动改到期日 / 设为新卡（重置）/ 改间隔，对应 rslib 的 Manual；「重置」同时是记忆状态的新起点。
   - reschedule：用户主动点「立即重排整组」时写，对应 rslib 的 Rescheduled。
   - importAnchor：从 Anki 导入时记下那一刻 Anki 的到期、间隔、队列、ease / 记忆状态；之后的状态从锚点开始算。
   - handOff：卡片移交给 Anki 排程。
   - undo：带 revokesId。【修3】协议上只允许撤销「该卡当前最后一条有效日志」。
     【修8】界面上支持连续撤销（与 Anki 一致，用户 2026-10-14 定），协议不变，见 PR4「撤销栈」。
   【修4】有效日志与撤销的合并语义（写死，不靠本机检查保证）：
   - 有效日志 = kind 不是 undo、且没有被任何 undo 的 revokesId 指向的日志。undo 本身永远不是「最后一条有效日志」。
   - 【修5】导入复习与原生复习的等价（解决往返导入的重复复习，005）：
     从 Anki 导入的评分日志（origin = anki）与本库原生评分日志（origin = fushi）若满足
     「同一 cardId、同一 rating、导入日志的 Anki revlog id（= 复习毫秒时刻）与原生日志 occurredAt 相差不超过 1 秒」，
     视为同一次复习，导入的那条不算有效日志（不进状态、统计、训练集）。
     【修8】等价判定只针对评分类 revlog（Anki 的 Learn / Review / Relearn），Manual、Rescheduled、Filtered 等类型
     不参与（A-5）；导入日志的类型写在事件内容里，判定仍只看两条日志自身。
     判定只看这两条日志自身的内容，任何设备、以任何顺序收到它们，结果都相同；不依赖本机先做过一次判重，
     也不依赖导出映射表是否已同步。同一张卡 1 秒内两次相同评分在真实使用中不会发生；
     导出时 revlog 撞号的 +1 ms 偏移落在容差内（铁律 C）。
   - 撤销后卡片状态 = 剩下的有效日志里 sortKey 最大的那条的结果；一条都不剩 = 新卡初始状态
     （例如撤销的是新卡的第一次评分）。
   - 被撤销的日志从统计与优化器训练集排除，但保留在日志表里（只追加）。
   - 并发情形：A 撤销了 L，B 离线时已基于 L 写了 M。合并后 L 无效、M 仍有效且是最后一条，卡片状态 = M 的结果。
     M 的起点含有 L 的影响，这是接受的偏差：到期日只偏一个间隔，下一次复习的 S/D 用全部有效历史重算（L 已排除），
     之后自动收敛。不为此级联撤销 M（级联会让 B 的真实复习凭空消失）。
   - 撤销撤销（redo）不支持：undo 不能被 undo 指向。
   每条日志另存 paramsHash 和 algorithm，只作出处和优化器输入，不参与正确性。
   【修6】algorithm 取实际用来排这一次的算法：fsrs6 / fsrs7（替代原来的 fsrsVersion 列）。
   paramsHash 带算法前缀：fsrs6:<参数哈希>、fsrs7:<参数哈希>。
   【修6】切换算法时历史日志不重算，新复习用新算法；切到 fsrs6 / fsrs7 且该算法参数组还是默认值时，
   自动触发一次优化（PR6）。

C. 所有实体 ID 全局唯一（UUIDv7 文本），日志 ID 由写入设备生成，同步时按 ID 取并集。
   【修4】例外：凡是「多台设备可能各自独立创建出同一个东西」的实体，ID 一律确定性生成（UUIDv5），
   合并后自然是同一行，不出重复。规则表（NS = Fushi SRS 固定命名空间 UUID）：
     · 内置笔记类型 Lapis：UUIDv5(NS, profileUid + "/builtin-notetype/lapis")；
       其字段 / 模板 ID 是写死在代码里的常量（UUIDv5(NS, "builtin/lapis/field/<键>") 等），所有 profile 共用同一组
       fieldId / templateId（它们只在所属笔记类型内部有意义）。
       【修8】<键> 就是 LapisNoteType.defaultFieldMappings 的字段键（packages/fushi_anki/lib/src/lapis_note_type.dart），
       模板正文也从那里取，不在 fushi_srs 里再复制一份；挖词的字段映射同样沿用那边（C-6）。
     · 内置默认牌组：UUIDv5(NS, profileUid + "/builtin-deck/default")。
   【修5】笔记 / 笔记类型 / 字段 / 模板统一用「来源标识 → 确定性 ID」，Fushi 自建与 Anki 导入走同一条规则，
   导出再导入天然回到原身份（004 / 005）。来源标识就是 Anki 那边认得的东西，Fushi 新建时自己随机生成一个：
     · 笔记：每条笔记有 guid（Anki 格式的随机串；Fushi 新建时生成，从 Anki 导入时用原 guid）。
       noteId = UUIDv5(NS, profileUid + "/note/" + guid)。guid 一经生成永不改变，导出时原样写给 Anki。
       不再有「Fushi 自建笔记 UUIDv7、导入笔记 UUIDv5」两套身份。
     · 笔记类型：每个笔记类型有 ankiNum（53 位正整数；Fushi 新建时随机生成，从 Anki 导入时取
       config.original_id，没有就取来源笔记类型 id）。noteTypeId = UUIDv5(NS, profileUid + "/notetype/" + ankiNum)。
       导出时 ankiNum 就是写进 .apkg 的笔记类型 id；对方若因撞号改了 id 并把原值记进 original_id，回导仍能对上。
       不再含结构哈希：Anki 侧加字段 / 改模板不改变笔记类型身份。
     · 字段 / 模板：每项有 ankiNum（53 位；Fushi 新建时随机生成，导入时取 Anki 的 Field.Config.id / Template.Config.id）。
       fieldId = UUIDv5(noteTypeId, "field/" + ankiNum)，templateId = UUIDv5(noteTypeId, "template/" + ankiNum)。
       导出时 ankiNum 写进对应的 config.id。
       文件里某项没有 config.id 时：先按名字匹配本机该笔记类型下已有的字段 / 模板；
       匹配不到才用 UUIDv5(noteTypeId, "field-name/" + 名字) 新建。不提示、不分版本处理——
       Fushi 只认文件内容，不关心文件是哪个程序、哪个版本生成的。
     · 重复导入时的结构变化（004）：已有的 fieldId / templateId 永不重新生成。
       来源新增的字段 / 模板 → 新增（新 ID）；来源改名 / 调序 → 改对应项的名字 / 顺序；
       来源删掉的项 → 本地不删（只在导入报告里列出）。
       笔记类型 kind 不同（普通 ↔ 填空）→ 不更新这个笔记类型，这些笔记记入导入冲突报告由用户处理（与 rslib 的做法一致）。
     · 卡片：见铁律 D（由 noteId + templateId + clozeOrd 派生，上面几项稳定，卡片身份就稳定）。
     · srs_import_map 与 srs_anki_id_map 只作查询加速和撞号记录，任何身份判定都不依赖它们
       （设备没同步到这两张表，算出来的 ID 也一样）。
   【修5】导入事件是不可变内容（003）：
     · 从 Anki 导入的 revlog：id = UUIDv5(cardId, "anki-revlog/" + Anki revlog id)；
       HLC = (Anki revlog id 对应的毫秒时刻, 0, "anki")；origin = anki；结果列由来源算出。
     · 【修8】importAnchor（A-3，替代修订版 5 的「取 Anki 卡片 mod 时刻」）：
       锚点时刻 T = 该卡在来源里最后一条排程相关 revlog 的时刻（评分类与 Manual / Rescheduled 都算，Filtered 不算）。
       id = UUIDv5(cardId, "anki-anchor/" + T)；HLC = (T, 0, "anki")。
       结果 = 来源卡片的到期（换算成日历日，见铁律 G）、间隔、队列、ease 或记忆状态（Anki 开了 FSRS 时）、
       reps、lapses、lastReviewedAt（铁律 A）。
       不写锚点的情况：
         - 这条最后的 revlog 按铁律 B 等价于某条原生日志（Fushi 导出 → Anki 没复习 → 回导）：Fushi 的状态已经是最新的，
           往返一次是空操作；
         - 来源卡片是新卡（Anki 里从没学过）：状态就是新卡初始状态，不需要锚点。
       来源卡片不是新卡、但一条排程相关 revlog 都没有（来源集合裁掉了历史）：T = 来源集合的创建时刻 crt。
       这仍只由来源决定，并且早于任何真实的 Fushi 复习，不会盖过原生日志。
       为什么不用 mod：改旗标、移牌组、（待实测）导入 .apkg 都会刷新 mod，锚点会晚于 Fushi 最后一次复习、
       成为最后一条有效日志，往返一次就改写了状态。第 0 步先做一次「导出 → 导入 → 回导」实测记录 mod 前后值；
       即使导入不改 mod，「改旗标 / 移牌组改 mod」这半条成立，结论不变。
     · 这些事件的全部内容（含 HLC 和结果）只由来源数据决定，不含导入设备的时刻、writerId、本机参数或本机设置。
       两台设备在不同时间导入同一份导出，得到逐字节相同的事件。
     · 事件内容与发布元信息分离：published、本机 changeSeq、收到的时间等只存在本机，不属于事件内容，不参与合并。
     · 同 ID 内容必须相同。若出现同 ID 异内容（只可能是 bug 或数据损坏）：取内容哈希较小的一份（确定性），
       记诊断日志，不静默。【修8】事件创建后任何环节都不再修改（铁律 F），这条只是兜底，不是常规路径。
     · 时间顺序自然正确：A 导入（锚点 = Anki 的过去时刻）后又复习了 R（现在），之后 B 才导入同一份导出 →
       锚点 HLC 早于 R，R 仍是最后一条；B 导入的是一份更新的 Anki 导出（用户在 Anki 里又复习过）→
       新锚点时刻晚于 R，以 Anki 的最新状态为准——都是「真实发生更晚的事件赢」。
     · 来源时刻晚于导入设备可信时间 10 分钟以上的卡（Anki 那边时钟坏了）：本次不导入，列进导入报告。
     · 用户要「用导入的排程覆盖 Fushi 的当前排程」时，写一条新的 manual 事件（本机 HLC），不改写锚点。
   用户在某台设备上主动新建的复习日志、牌组仍用 UUIDv7——它们是不同的事件，本来就该是不同的行。
   重复导入同一 guid 的笔记：按导入选项「更新笔记」（对齐 Anki ImportAnkiPackageOptions，默认「较新时」）
   决定是否写入：较新时 = 来源笔记 mod 晚于本机该笔记内容键最后一条修改记录的 HLC 物理时刻；
   始终 = 内容不同就写；从不 = 不写。只写与本机物化值不同的项。【修8】写入时按铁律 H 生成本机的
   字段修改记录（带本机因果上下文），与别的设备的并发修改照常判冲突。
   其余导入选项（默认值都与 Anki 相同）：
     · 更新笔记类型（较新时 / 始终 / 从不）：管名字、CSS、模板正文、已有字段 / 模板的名字与顺序；
       合并时来源新增的字段 / 模板不受它限制。
     · 合并笔记类型（默认关）：关时若来源与本机同一笔记类型的字段 / 模板不是同一组，来源笔记类型另建一份，
       ankiNum = hash53("notetype-dup/" + 来源 ankiNum + "/" + 字段 / 模板组成)，仍是来源确定性 ID（铁律 C），
       同一结构再导入回到同一份；本机同 guid 的已有笔记记冲突、不更新（与 rslib 相同）。开时按上面「结构变化」合并。
     · 包含排程（默认关）：关时不写 revlog / 锚点 / fushi-ext 日志、不导入暂停，去掉 marked / leech 标签，
       卡片全部为新卡；报告给出「作为新卡导入」与未导入的 revlog 数。
     · 包含牌组预设（默认关）：关时新建牌组不写来源预设（用默认设置）。
     · .colpkg 走同一条合并路径（Anki 会整库替换，Fushi 不替换、不删本机数据）。
     · 上次的选择记在 app 偏好 srs_import_anki_options（不进复习事件存储）。
   【修5】导出 Anki 时的数字 id（全部确定性，不用「时间戳 + 撞号 +1」）：
   - 笔记类型 / 字段 / 模板 = 各自的 ankiNum；笔记 guid = 笔记的 guid；
     Anki 笔记 id / 卡片 id = noteId / cardId 哈希出的 53 位正整数（Anki 导入按 guid 认笔记，数字 id 撞了它会自己换）。
   - 【修8】只导出有效日志：被 undo 撤销的日志、undo 本身、被判等价的导入日志都不导出（A-5）。
   - revlog id 在 Anki 里就是复习时刻，只能用原生日志 occurredAt 的毫秒值；同一份导出里撞号时按日志 ID 排序依次 +1 ms。
     回导时按铁律 B 的等价规则认回原生日志（容差 1 秒、同卡同评分），撞号偏移在容差内。
   - 同一张卡重复导出用同一组 id / guid，Anki 端更新而不是新增。
   fuzz 种子 = hash(cardId) 转 u64 再加 reps，确定性；结果写进日志，种子只影响「这次」的间隔。

D. 笔记字段与卡面模板都按稳定 ID 存，不按位置、不按名字。【修3】模板也纳入，卡片 ID 确定性生成。
   - 笔记类型里每个字段有永不改变的 fieldId，每个卡面模板有永不改变的 templateId
     （用户新建的为 UUIDv7，内置 / 导入的按铁律 C 确定性生成）；名字和顺序只是它们的属性。
   - 笔记的字段值存成「fieldId → 值」。
   - 卡片引用 templateId，不用 templateOrd。
   - 【修4】cardId = UUIDv5(noteId, templateId + "/" + clozeOrd)。普通模板 clozeOrd 固定为 0；
     填空（cloze）类型笔记只有一个模板，按正文里出现的 c1…cN 各生成一张卡，clozeOrd = N。
     笔记类型增加 kind（standard / cloze）属性；srs_cards 增加 clozeOrd 列。
     两台设备各自为同一笔记生成同一张卡（加模板、编辑字段让条件模板变非空、新增 cN、补全缺失卡片）
     得到同一个 ID，合并后是同一行，不会出重复卡。
     被软删除的卡再次生成时就是复活同一行（清 deletedAt，【修8】按铁律 H 合并）。
   - 【修4】生成门：笔记已软删除时，不为它生成或复活任何卡；它的卡片在查询层一律不可见、不进队列
     （不逐张写 deletedAt，避免一次删除产生一批同步）。
     【修8】同一道门还挡三种情况（A-5），都在查询层判定、不写行：
       · 卡片的模板已被删除（模板定义带 deletedAt）；
       · 条件模板对这条笔记渲染为空（与 Anki 一样，正面为空的卡不出现）；
       · 填空卡的 cN 已从正文里删掉。
     条件恢复（模板复活、字段又填上、cN 又加回）时，卡片随之重新可见，复习历史还在（同一个 cardId）。
   - 【修3】模板正文内部按 fieldId 存引用（{{fld:<fieldId>}}），编辑器显示与导出 Anki 时换成字段名，
     导入 Anki 时把名字解析成 fieldId。所以改字段名只改字段定义这一项，模板正文一个字都不动，
     不会和对端同时改模板的操作冲突。
   - 给笔记类型加 / 删字段、改名、调顺序、加 / 删模板、改模板 / CSS，都只改 srs_note_types 这一行，
     笔记和卡片一行都不动（加模板时新卡由各设备按需确定性生成），同步只传这一行。
   - 【修3】这一行内的字段列表与模板列表逐项合并（按 fieldId / templateId，每项各自是铁律 H 的一个字段键），
     不是整个列表一起 LWW：两台设备离线各加一个字段，合并后两个都在。
   - 加字段：旧笔记里没有这个 fieldId，读出来当空值，不回填。
   - 删字段 / 删模板：只在定义上标 deletedAt；笔记里残留的值读时忽略，由后台压缩回收（不产生同步）。
   - 与 Anki 互通：导入时按铁律 C 生成 ID；导出时按当前顺序排成 Anki 的位置数组，
     卡片的 ord 由 templateId 在当前模板顺序中的位置算出（填空卡的 ord = clozeOrd - 1，与 Anki 一致）。

E. 【修3】Profile 有全局身份 profileUid。
   - Profiles 表加 uid 列（UUIDv7，迁移时为存量行生成）。SRS 表一律存 profileUid，同步路径用 profileUid。
     本机自增 int 只留在本机内部用。
   - 新设备第一次接入同步时，选「关联到已有的 profile」（列出同步目录里已有的 profileUid 和名称）或「新建」。
   - 【修4】关联时本机 profile 改用对端的 uid，条件是本机该 profile「没有用户笔记」（只有内置行不算有数据）。
     改 uid 时删掉本机的内置牌组 / 内置 Lapis 行（它们的 ID 由 profileUid 派生，会随对端数据按新 uid 重新出现），
     不做任何 ID 重映射。有用户笔记时只能新建一个本机 profile 来关联。
   - 【修5，2026-10-28，取代上一条「有用户笔记时只能新建」与「同步路径不做 ID 重映射」】三台设备各自随机生成 uid、
     都叫「Default」、两台都有笔记的实测状态下，旧判定按名字匹配到多个候选就静默保持（新设备永远按自己的空 profile
     同步），两边都有笔记时只提示一次。改为：
       1. 只有「有用户笔记」（或没有说明文件、不知道有没有）的同一 profile 才算候选；本机没有笔记且候选恰好一个 → 自动采用。
       2. 候选多于一个、或本机与对方都有笔记 → 进复习页时弹窗让用户选：采用某一份 / 保持本机独立（按位置 + 候选记住，
          不再提示）/ 稍后。
       3. 本机有笔记时选定 = **并入**（`srs_profile_merge.dart` `srsMergeProfileUid`）：把旧 uid 下全部用户数据改写到
          目标 uid 后作为本机新操作落库并同步出去，两边数据都保留。改写是同步路径上唯一的 ID 重映射：按「这份数据当初就在
          目标 uid 下创建时的 ID」重算所有由 uid 派生的 ID（内置行、笔记 `note(uid,guid)`、牌组、笔记类型、字段 / 模板、
          卡片、导入日志），派生输入还原不出的用确定性兜底；修改记录的写入者整体改名，与旧记录不相交。可中断重跑。
       4. 换了 uid 的设备在同步目录里留下的旧目录（只有本设备写过、又不是本机任何 profile）由之后的关联步骤清掉，
          不再成为别的设备的候选。
   - 【修4】备份合并（backup_merge_engine）的 SRS 规则，同样不做 ID 重映射：
       1. 本机有同 uid 的 profile → SRS 行直接并入（按 ID 取并集 / 可编辑字段按铁律 H 合并，与同步同一套合并函数）。
       2. 否则本机有同名 profile 且它没有用户笔记 → 该 profile 采用备份的 uid（同上一条，删内置行），再并入。
       3. 否则 → 为备份的 uid 新建本机 profile，名称「<原名>（备份）」，SRS 行并入它。
     既有的「按名字合并 + 重映射 id」继续只用于非 SRS 表（统计、历史等），不改它的行为。
     PR2 把这条写成 backup_merge_engine 的独立步骤，并加「同名不同 uid」「同 uid」「同名有用户笔记」三种用例。

F. 【修3】【修8】时间、排序键与服务器时间 S。
   - HLC = (物理毫秒, 计数器, writerId)，按字典序比较；本机发出事件时取 max(本机可信时间, 已见过的最大 HLC) 推进，
     收到对端数据时用对端的 HLC 推进本机时钟。
   - 【修5】第一层：事件时间取「可信时间」，不直接取墙钟（沿用）。
       · 每次同步成功时，从同步后端取服务器时间，记下锚点 (服务器时间, 开机单调时钟读数, 本次开机 ID)。
         开机单调时钟用「含睡眠」的那种（Android elapsedRealtime、Linux CLOCK_BOOTTIME、Darwin mach_continuous_time、
         Windows QueryInterruptTime），手动改系统时间不影响它；第 0 步逐平台确认可用。
       · 写事件时，若本次开机已有锚点：可信时间 = 锚点服务器时间 + 单调时钟经过量，timeSource = anchored。
         开机后还没同步过：可信时间 = 墙钟，timeSource = wall。
       · occurredAt、HLC 物理部分、学习卡的 dueAt 全部由可信时间算出。同一次开机内用户把系统时间改快改慢，
         记录下来的时间不受影响。
   - 【修8】事件创建即不可变（A-1 / A-2）。
       · occurredAt、HLC、结果列都取创建时的值。之后任何环节（发布、备份、写快照、导出 .apkg、同步、合并）
         都不再修改事件内容；事件 ID 与内容哈希只覆盖这份内容。
       · 删掉修订版 5 的第二层「发布门有界修正」：备份 / 快照 / 导出可能在发布前就带走未发布事件，事后修改会造成
         同 ID 异内容；导出到 Anki 的那份时间对不上，铁律 B 的 1 秒等价判定失效，复习被重复计入（A-2）。
       · 删掉修订版 5 的第三层「读方整批拒收」：被拒批次让 cursor 要么永远卡住（后续批次读不到、目录清不掉），
         要么越过它（写入者本地有、其它端没有，永久分叉）；快照不经过批次判断，又是一种分叉（A-1）。
       · 代价：时钟走错的设备上，事件的 occurredAt / dueAt 按错的时间存下来，不再事后修正。
         影响限于那一个间隔，下次复习的 S/D 按全部有效历史重算后收敛；优化器按下面的 timeUncertain 排除这些事件。
   - 【修8】发布时服务器时间 S 是带外元数据，不进事件内容。
       · 批次信封（文件头）写发布时的服务器时间 S（第三期「传输」）。
       · 每条事件的 S(e) = 所有已见到的、包含 e 的批次的 S 的最小值。
         同一事件出现在多个批次（例如恢复备份后由新化身重新发布）时取最小值，结果与收到顺序无关。
       · 快照写入它已知的「事件 ID → S」映射，从快照起步的设备与读批次的老设备算出同一个 S(e)。
       · 只经备份 / 快照拿到、映射里也没有的事件：S(e) 未知，先按原始 HLC 排序；见到批次后重算。
         只要事件最终都会被发布，所有端最终拿到同一个 S(e)、算出同一个顺序。
       · 永远不会被发布的事件（写入者退役前没发出去、只存在于旧备份里）：所有持有它的副本都没有 S，按原始 HLC 排序，
         各端口径一致。恢复那份备份的设备会以新化身重新发布它们（第三期「写入者身份」），之后 S 已知，全体重算。
   - 【修8】排序键 sortKey（A-1）：
       · 钳位 HLC：HLC 物理部分超过 S(e) + 10 分钟时，物理部分换成 S(e) + 10 分钟，计数器不变；否则原样。
       · sortKey(e) = (钳位 HLC 的物理部分, 计数器, writerId, eventId)。eventId 兜底，同毫秒的导入事件（writerId 都是 "anki"）
         也有确定的先后（A-5）。
       · 「最后一条有效日志」、撤销后的状态、铁律 H 设置类字段的「最后一次显式修改」，一律按 sortKey。
       · 钳位只影响排序，不改任何存储值。时钟走快的设备，其事件在排序里最多领先 S + 10 分钟，
         不可能长期压住之后的正常修改。
       · timeUncertain 是派生值，不存进事件：timeSource = wall 且物理时间超过 S(e) + 10 分钟，或早于该写入者上一批次的 S，
         即可证明时间有错。这类事件不进优化器训练集。
       · 本机墙钟与服务器时间相差超过 10 分钟时，同步状态里提示一次「系统时间不准」；被钳位的事件记诊断日志。
   - 【修8】serverTime()（C-3）：SyncAssetStore 的 AssetEntry 加 modifiedAt（服务端修改时间），七个后端都从列目录元数据映射
     （修订依据有逐后端字段）。serverTime() 统一做法：写一个探针文件，再读回它的 modifiedAt。FTP 必须用 MDTM，
     LIST 对新文件只到分钟、时区不定。预计七个后端都能实现；第 0 步逐个确认，真拿不到的后端才不提供 SRS 同步。
   - 日志的 occurredAt 存可信时间，只用于显示、统计、喂给优化器（间隔计算）。日志另存 timeSource（anchored / wall）。
   - 【修8】可编辑字段（牌组 / 笔记类型 / 笔记 / 卡片 / profile 设置）的合并改由铁律 H 处理，
     不再是修订版 5 的「fieldClock：每个字段键取 HLC 较大的值」。
   - 【修6】牌组的算法与参数组分开存、分开合并（替代修订版 5 的「先比模型版本，新模型那组赢」）：
     · algorithm（fsrs7 / fsrs6）与 algorithmAuto 合成一个字段键，一起写、一起合并（铁律 H 设置类）。
       算法是用户的选择，不是版本先后，不能按「新的赢」合并。
       algorithmAuto 为真时允许 PR6 自动把 fsrs6 换成 fsrs7。新建牌组与导入牌组为真；用户手动选过算法就置假，之后不再自动改。
     · 每种 FSRS 算法各一个参数组：fsrs6Params、fsrs7Params。各自是一个整体字段键
       （参数、paramsHash、algorithmRev、optimizedAt、训练条数、logLoss），按铁律 H 设置类合并。
       分开存之后，切换算法不会丢掉另一种算法的参数，也不可能把 FSRS-6 参数套到 FSRS-7 上。
   - 【修4】【修6】本机不认识的情况（旧版 app 收到新算法，或新 algorithmRev 的参数组）：
     algorithm 与参数组原样保留、不改写、不回传。本机按「fsrs7 → fsrs6」顺序，取第一个本机能用的算法排程：
     参数组可用就用参数组，不可用就用该算法本版本的默认参数。日志 algorithm 写实际所用的算法。
     设置里显示「此牌组的算法 / 参数来自更新版本，本机暂用 X」。
     本机不为不认识的 algorithmRev 跑自动优化（避免旧版产出的参数组在合并中输掉、白算一场）。

G. 【修3】到期日与翻日。
   - 翻日时间和时区作为 profile 级设置同步（存在 SRS 的 profile 设置行里，按铁律 H 设置类合并）。
     所有设备按同一个时区、同一个翻日点算「今天是第几天」。
   - 【修8】日界与统计页统一（B-2）：
       · 现状：统计页的「今天」= 偏好 stats_day_reset_hour（默认 0 点、按设备本地时间），而本计划原定 SRS 默认凌晨 4 点、
         按 profile 时区。两边对「今天复习了多少」的计数会不一样。
       · 改为一个设置「日界」：SRS 的翻日时间就是 stats_day_reset_hour，两处读写同一个值；
         SRS 同时把它存进 profile 设置行同步，统计页从这里读。
       · 默认值 4 点（用户 2026-10-14 定）：SRS 与统计页都默认凌晨 4 点，与 Anki 一致，熬夜复习算前一天。
         统计页 stats_day_reset_hour 的默认值由 0 改为 4。只改「用户没设过」的默认值：用户自己设过的值保留不动。
         统计历史不重分桶（统计域的既有规则），改动只影响之后写入的段；升级后第一天的分桶会有一次 0→4 点的过渡，
         在更新说明里写一句。
       · 时区：SRS 排程用 profile 时区；统计 dateKey 仍按设备本地时间（统计域既有规则）。
         只有设备时区与 profile 时区不同（旅行）时两边计数会差一天以内，接受，并在统计说明里写明。
   - 处于 review 队列的卡存 dueDay；处于 learning / relearning 队列的卡存 dueAt（毫秒时间戳）。日志与卡片缓存都按这个规则存。
   - 【修5】dueDay 是「日历日序号」（1970-01-01 起的天数，表示一个日历日期），不再相对 profile 的纪元日。
     时区与翻日时间只用来回答「现在算哪一个日历日」，不参与 dueDay 的存储。
     这样导入锚点能只靠来源数据算出 dueDay（Anki 的到期日序号 + 来源集合的创建日 → 日历日期），
     不依赖导入设备当时的 profile 设置，满足铁律 C「导入事件内容只由来源决定」。删掉 srs_profile_settings 的纪元日。
   - buriedUntilDay 存日历日序号。

H. 【修8】可编辑字段的并发修改：用版本向量判因果，不用时间判胜负（A-7，新增）。
   复习日志只追加、并发都保留，不受本条影响。本条管的是可修改的状态：
   笔记字段值；笔记类型的字段 / 模板定义（逐项）与 CSS；卡片的 suspended / buriedUntilDay / deckId / 旗标；
   各行 deletedAt；牌组设置（名称、上限、步长、记忆率、algorithm、参数组）；profile 设置（日界、时区）。
   - 修改记录：每次修改一个字段键，产生一条记录：
       dot = (writerId, changeSeq)；
       ctx = 修改时本机已应用的版本向量 {writerId → 已应用的最大 changeSeq}（含自己）。
             对端部分正好等于本机 cursor 已应用的批次前缀的 changeSeq 上界，不需要另记；
       新值；HLC（只用于排序键）。
     修改记录也是事件：创建即不可变，随批次同步、进快照。
   - 判因果：记录 b 支配记录 a，当且仅当 b.ctx[a.writerId] ≥ a.changeSeq，即 b 的作者修改时已经看见了 a。
   - 合并：每个字段键只保留「没有被任何其它记录支配」的记录（多值寄存器）。
       · 只剩一条，或剩下的几条值相同：没有冲突，这个值就是当前值。
       · 剩下多条且值不同：并发冲突，按下面分级处理。
       · 被支配的记录可以立即丢弃，以后再收到也能当场判出被支配（拿它和剩下的记录比 ctx），所以不需要保留历史。
       · 结果只由记录集合决定，与收到顺序、时钟快慢无关。
   - 冲突时所有类别都一样：并发的候选全部留在集合里，谁也不丢；当前生效值取 sortKey 较大的候选（确定性）。
     这个候选集合本身就是冲突记录，不另建表。各类别的差别只在于要不要用户处理：
       · 内容类：笔记字段值、笔记类型的字段 / 模板定义与 CSS。
         字段状态标「待裁决」，复习页 / 编辑页提示用户在候选间选择或手动合并。
         笔记内容被覆盖就真丢了，所以必须由用户定。
       · 【修8】标志类与设置类（用户 2026-10-14 定方案 C：自动生效 + 冲突记录 + 一键改回）：
           标志类：卡片的 suspended、buriedUntilDay、旗标、deckId；
           设置类：牌组设置、algorithm（与 algorithmAuto 同一个键）、参数组、profile 设置（日界、时区）。
           界面状态类（2026-10-16 补）：牌组的 collapsed（牌组列表里收起子牌组，对应 Anki deck `collapsed` /
           Deck.Common.study_collapsed）。同样是修改记录、随同步、最后修改生效，但被覆盖的候选不进「同步冲突记录」
           （两台设备各自开合是常态，不是冲突）。.apkg 导入首次建牌组时读 Anki 的值，导出写回 decks JSON 的 collapsed。
         · 当前生效值就是 sortKey 较大的候选（最后一次修改胜出，与 Anki 的口径一致，但按字段而不是整张卡）；
           同步不停下来等用户。
         · 被覆盖的候选留在集合里，进「同步冲突记录」。同步状态里出现不弹窗的提示，例如
           「同步时有 3 处冲突，已按最后修改处理」；点开是列表，每条显示两边的值、来自哪台设备、什么时候改的，
           可以逐条改回、全部改回或全部确认。设置类还在该设置项旁显示「已被另一台设备的修改替换」。
         · 「改回」或「确认」都写一条新修改记录，ctx 覆盖全部候选，冲突在所有设备上随之消失。
         · 用户不处理就算默认接受。30 天后只在本机的列表里隐藏，不写任何记录，避免每台设备各写一份。
           没有处理的候选继续留在集合里，开销是每个字段几十字节。
         · 批量操作产生的冲突（例如一端批量暂停 200 张、另一端取消了其中一部分）在列表里按「设备 + 操作时间」归成一组，
           可以整组改回。
         · 为什么不在冲突时直接问用户：卡片在任何时刻都必须是「进队列 / 不进队列」之一，问之前也得先有个默认值；
           批量操作会产生成百上千条询问，违背产品目标 2。标志与设置都可逆，自动处理 + 可改回就够了。
   - 删除（deletedAt）与并发修改：删除优先，行保持已删。若被删的笔记在另一端有并发的内容修改，
     这些修改留在行里，作为一条内容类待裁决项：「另一台设备删除了这条笔记，这里有未同步的修改：恢复 / 确认删除」。
     不静默丢掉用户写的内容。
   - 列表逐项：笔记类型的每个字段定义、每个模板定义各自是一个字段键。两端离线各加一个字段 → 两个不同的键，不冲突。
   - 本机存储：srs_field_edits（修改记录，只保留未被支配的；同步）+ 各行的 fieldState 缓存
     （字段键 → 未被支配的记录 id 列表；本机可重建，不同步）。替代修订版 5 的 fieldClock 列。
   - 瘦身墓碑（第三期「墓碑」）：行被删满 90 天后，清空字段值，但保留每个字段键未被支配记录的 dot 与 ctx。
     之后合并旧备份带回的旧修改，会被这些记录支配，赢不了；真正并发的新修改按上面「删除优先 + 待裁决」处理。
   - 模拟器（A-6）断言：并发修改同一字段时，任何一端的值都不会在没有冲突记录的情况下消失。

== 第 0 步：剩余验证（一天左右）==

- 【修8】最先做（十分钟，决定铁律 C 锚点规则的定稿，A-3）：在当前 Anki 版本上做一次「导出 → 导入 → 回导」，
  记录卡片 mod 的前后值；另记「改旗标 / 移牌组」是否刷新 mod。结论写进 spec。
- 【修4】【修8】编 iOS 伞形 staticlib（前提 4，C-4：一个 crate 依赖 fushi_p2p 与 fushi_fsrs）的真机 + 模拟器版本
  和 macOS arm64 的 fushi_fsrs，量体积；在 iOS 模拟器里写一个最小 Flutter 调用（next_states + compute_parameters
  各一次 + 一个 fushi_p2p 符号），确认 DynamicLibrary.process() 取得到两边的符号。
  不再验证「两个库分别 -force_load 会不会撞」，直接做伞形库。
- 用 Anki 导出的真实 revlog 对比 Anki 算出的 stability / difficulty 与 FFI 结果，确认数值一致；
  【修8】按铁律 A 的 ①～④ 分别对拍：revlog 完整的卡（从完整历史重建）、revlog 不完整的卡（从锚点 SM-2 换算），
  起点输入逐项照 rslib。
- 用真实牌组在桌面、Android 中端机、iOS 上量优化器耗时和峰值内存，定 PR6 的触发门槛和移动端运行条件。
  【修6】FSRS-6 与 FSRS-7 各量一遍。FSRS-7 有 34 个参数和分窗训练（training_windowed / analytic_v7），开销预计更大。
- 【修6】FSRS-7 相关：
  · 用钉定的 fsrs-rs git rev 重新编五个平台的库、量体积（修订版 5 的 110 / 201 / 373 KB 是 6.6.2 的数）。
  · 同一份真实 revlog，新 rev 的 FSRS-6 结果与 6.6.2 一致（保住与 Anki 26.09.3 的数值一致）。
  · 核对 FSRS-7 的 next_states / memory_state / compute_parameters / evaluate 签名与 FSRS-6 的差异，
    写进 C ABI 设计；未发版 API 只在 fushi_fsrs 这一层暴露，Dart 侧不感知 rev。
  · FSRS-7 能否接受 FSRS-6 的 S/D、或 SM-2 换算出的状态作 starting_state（铁律 A【修6】的锚点规则）。
  · 拿 JSchoreels fork 导出的、FSRS-7 预设的 .apkg，确认它的参数存在哪里（deck config 的哪个字段、几个数），
    供 PR3b 映射。
- 【修4】同步后端能力项已核实、关闭：契约里有 listChildren / putAsset / getAsset / deleteAsset，没有 rename；
  原子发布改用自校验文件（第三期「传输」），不需要 rename，也不需要 .done 标记。
  【修5】剩两项实测：
  · 【修8】各后端（Google Drive、OneDrive、Dropbox、WebDAV、FTP、SFTP、互联）用「写探针文件 → 读回 modifiedAt」
    实现 serverTime()（铁律 F，C-3）；列目录元数据里都有服务端时间，预计全部可用，FTP 确认 MDTM 可用。
    真拿不到的后端不提供 SRS 同步。
  · 五个平台「含睡眠的开机单调时钟」与本次开机 ID 的取法（铁律 F 第一层），确认改系统时间、睡眠唤醒后读数正确。
- 【修3】把 Lapis 的模板与 JS 放进纯 WebView 跑一次，确认它是否依赖 Anki / AnkiDroid 的宿主 API
  （pycmd、AnkiDroidJS 等），列出需要在宿主里补的最小接口。
- 【修8】出处与归属（B-1，冻结 PR2 前要有结论）：
  · bookKey 在不同设备上是不是同一个身份（同一本书在两台设备导入，bookKey 是否相同）。不是的话，
    出处要改用跨设备稳定的书籍身份（与互联 / 同步现用的书籍身份对齐），否则同步过去的卡跳不回原文。
  · 视频 / 有声书的媒体身份同样核对一遍（出处里存的是哪个键）。
  · MinedSentences 没有 profileId：批量导入时一律归入「执行导入时的当前 profile」，导入前在对话框里写明。
- 【修8】导出兼容：手工做一个带额外 fushi-ext 条目的 .apkg（新旧两种格式各一个），用 Anki 26.09.3 导入，
  确认 Anki 正常导入、不报错（源码上 Anki 只按名字取 meta / 数据库 / 媒体清单，见第三期「Anki 互通」）。
放弃条件：iOS 伞形静态库链接不上。退路是 iOS 先不跑优化器、只用同步来的参数，排程仍走 FFI；
连排程符号都取不到，才考虑 iOS 单独用 Dart 移植。
【修6】FSRS-7 的退路：钉定 rev 在某个平台编不过、或 FSRS-6 数值对不上 6.6.2 时，
PR1 先只出 FSRS-6（钉 6.6.2），默认算法临时回到 fsrs6，schema 照样带 algorithm 与 fsrs7Params，
FSRS-7 等 fsrs-rs 正式发版后补上；新建牌组的 algorithmAuto 为真，届时 PR6 会自动切到 fsrs7。

== 第一期 MVP（【修8】8 个 PR）==

【修3】顺序调整：PR6（自动优化）排在 PR4（复习页）之后，先让「添卡 → 复习」整条链路可用，再加自动优化。
依赖：PR1 → PR2 → PR3a / PR3b（可并行）→ PR4 → PR5 → PR6；【修8】PR7（AnkiConnect 兼容）依赖 PR2 + PR3a，可与 PR4 之后并行。
【修8】建议顺序（7.md「建议顺序」）：
  1. 第 0 步最先做 A-3 的 mod 实测（十分钟），据此定稿铁律 C 的锚点规则。
  2. 本版已按 A-1～A-5、A-7 改完铁律；PR1 先交付确定性多设备模拟器（A-6），用它把铁律 F 的新方案
     连同修订版 5 / 第五轮审查里的历史反例一起跑过。
  3. 模拟器全绿，才冻结 PR2 的数据契约，同时定下 B-1～B-3（PR2 冻结门）。
  4. 实现阶段按 C 档推进。PR3b 保留在第一期，新旧两种格式一起做（用户 2026-10-14 定）。
  5. 不再做第 6 轮人工反例审查；以后的协议改动一律先进模拟器。

PR1：内核包
- native/fushi_fsrs/：薄 C ABI，四类接口 next_states / memory_state_from_history（含 SM-2 起点换算）/
  compute_parameters / evaluate。compute_parameters 支持进度回调和取消标志。
  【修6】每个接口带 algorithm（fsrs6 / fsrs7），两种算法都编进同一个库；另导出各算法的默认参数与参数个数，
  供 Dart 侧校验。依赖钉 fsrs-rs git rev（前提 4）。
  【修4】另加 zstd 解码接口（zstd crate），供 PR3b 解 .apkg 新格式（collection.anki21b、媒体清单），
  五个平台共用，Dart 侧不另引 zstd 依赖。
  构建脚本、prebuilt/、native-fsrs-gate.yml 照 native/fushi_torrent/ 与 native/fushi_p2p/ 的模式做；
  五个平台全出：Windows x64、Android arm64、Linux x64、macOS arm64、iOS 静态库，
  【修4】iOS 接入照 fushi_p2p：build_ios_staticlib.sh 生成 xcconfig 片段，fushi/ios/Flutter/*.xcconfig 可选 include，
  【修8】Runner OTHER_LDFLAGS 改为只 -force_load 伞形库（替换现有的 $(FUSHI_P2P_LDFLAGS)），CI 的 iOS job 改编伞形库。
  【修8】无头服务端（C-5）：服务端只发 Linux x64 与 Windows x64，fushi_fsrs 的这两份 prebuilt 进 release-server.yml
  的随包步骤，按 bin/../lib/<裸名> 定位；服务端缺库时 SRS 能力判不可用，不崩。
- packages/fushi_srs/：纯 Dart，不依赖 Flutter（app 和无头服务端共用）。
  内容：FFI 绑定（库缺失时能力判不可用，不崩溃）、上层策略（步长、确定性 fuzz、最大间隔、翻日）、
  【修3】HLC 实现、【修4】确定性 ID 生成（铁律 C 规则表 + cardId 含 clozeOrd）、
  【修4】「最后一条有效日志」选取与 S/D 输入收集（铁律 A / B，不做状态机重放）。
- 【修6】fushi_srs 里定义 SrsAlgorithm 枚举（fsrs7 / fsrs6）与「本机可用算法」判定，
  回退顺序 fsrs7 → fsrs6 只在这里写一次（铁律 F【修6】）。
- 【修8】fushi_srs 里另有：排序键 sortKey 与 S(e) 计算（铁律 F）、版本向量与修改记录的支配判定、
  多值寄存器合并与三级冲突规则（铁律 H）。
- 【修8】确定性多设备模拟器（A-6，PR2 冻结门）：放在 fushi_srs 的测试里，固定随机种子，可重放。
  · 随机组合：各设备的操作序列（评分 / 撤销 / 改字段 / 改设置 / 删除 / 导入 / 导出回导）、投递顺序、时钟偏差（含跳快跳慢）、
    备份与恢复（含「备份在发布之前做」）、清理旧目录、设备退役后回归（含「退役前有未发布事件」）、快照起步的新设备。
  · 断言五件事：① 最终收敛（所有端状态逐字节相同）；② 删除不复活；③ cursor 不越过缺口；
    ④ 同一事件 ID 在所有端内容一致；⑤ 并发修改同一字段时，任何一端的值都不会在没有冲突记录的情况下消失（A-7）。
  · 必须先把已知反例写成固定用例：修订版 5 的「整批拒收 vs cursor」、「发布门修改已外流事件」、
    v6 两条修法之间的矛盾（7.md A-1），以及 HBK-AUDIT-001～009。
  · 失败时打印最小复现序列（自动缩减）。
- 单测：对照 fsrs-rs 测试向量（【修6】FSRS-6 与 FSRS-7 各一套）；
  【修6】切换算法后下一次复习按新算法从历史重算、旧日志不变；不认识的算法按回退顺序排程且日志如实记录；
  有效日志选取对每种事件类型（含 undo、并发 undo + 后续复习、撤销到无日志、
  importAnchor 后再复习、重置）各有用例；同一组日志不管以什么顺序收到，选取结果都相同；
  【修3】HLC 在时钟回拨 / 时钟超前设备下的顺序用例；
  【修5】可信时间：同次开机内改系统时间不影响记录；
  【修8】事件不可变：发布、备份、快照、导出前后事件字节相同；S(e) 取最小值且与收到顺序无关；
  超前事件在排序里被钳到 S + 10 分钟，正常端在它之后的修改最终胜出；只经备份拿到、S 未知的事件先按 HLC 排、
  见到批次后各端重算出同一顺序；
  【修8】铁律 H：因果先后的修改后者胜出、无提示；并发的内容类修改两值都保留并标待裁决；裁决后冲突消失；
  标志类与设置类：sortKey 较大者生效、被覆盖的候选留在冲突记录里、改回 / 确认后各端冲突消失、
  30 天隐藏不产生任何写入；删除与并发编辑；
  【修8】锚点：Fushi 导出 → Anki 不复习 → 回导，不写锚点、状态不变；来源无 revlog 的非新卡锚点时刻 = crt；
  【修8】S/D 输入：revlog 完整的卡忽略锚点、从完整历史重建；不完整的从锚点 SM-2 换算；
  【修8】生成门：模板删除、条件模板为空、cN 被删的卡不进队列，条件恢复后同一 cardId 带着历史回来；
  【修8】等价判定只比评分类 revlog；导出不含已撤销日志；
  【修5】结果载荷：评分后隔 13 天导入 / 改期再评分，elapsed 仍为 13 天；清空缓存重建后 lastReviewedAt、reps、
  lapses、scheduler 与重建前一致；
  【修4】确定性 ID：两台设备独立生成同一 (noteId, templateId, clozeOrd) 得到同一 cardId，
  独立导入同一 guid / 同一 revlog / 同一笔记类型得到同一 ID，内置牌组 / Lapis 在同一 profileUid 下 ID 相同；
  【修5】导入事件：同一份导出在不同时刻、不同 writer 导入，事件逐字节相同；一端导入后已复习，
  另一端晚些再导入同一份导出，以任意接收顺序合并，状态一致且旧锚点不盖过新复习；
  【修5】往返身份：Fushi 新建 → 导出 → Anki 改字段 / 加字段 / 改名 / 调序 / 加模板 / 复习 → 同端与另一端回导，
  断言只有一条笔记、原 fieldId / templateId / cardId 不变、原生复习不重复、Anki 里的新复习接在后面。

PR2：数据层（schema 取合并时的下一个空号，当前 develop 是 v116，按升级清单补齐全部硬编码版本号）
- 【修3】Profiles 加 uid 列（迁移为存量行生成 UUIDv7）。
【修8】本节所有 fieldClock 列一律换成 fieldState 缓存（铁律 H：字段键 → 未被支配的修改记录 id 列表，本机可重建、不同步），
下面不再逐处标注。
- srs_profile_settings：profileUid、日界（【修8】与 stats_day_reset_hour 同值，铁律 G）、时区、fieldState
  （铁律 G；【修5】没有纪元日）。
- 【修8】srs_field_edits（铁律 H，事件，只追加，同步）：id、profileUid、目标表与行 id、字段键、dot（writerId、changeSeq）、
  ctx（版本向量 JSON）、新值、hlc。本机只保留未被支配的记录。
- 【修8】srs_event_server_time（铁律 F，本机，可由批次与快照重建）：eventId、S(e)。快照写出时把它作为「事件 ID → S」映射带上。
- srs_decks：profileUid、名称、目标保留率（默认 80%）、每日上限、步长、
  【修6】algorithm（默认 fsrs7）、algorithmAuto（默认真）、
  【修6】fsrs6Params / fsrs7Params 两个参数组（各含参数、paramsHash、algorithmRev、optimizedAt、训练条数、logLoss，
  各自整体合并，见铁律 F）、
  autoOptimize（默认开）、【修4】optimizeBaselineAt / optimizeBaselineCount（PR6 触发基线）、fieldState。
  【修3】参数只挂在牌组上，没有「预设」概念。
  【修8】牌组树与参数继承（替代 Anki 的预设，避免小牌组攒不够数据）：
  · srs_decks 加 parentDeckId（牌组层级，对应 Anki 的「父::子」）与 paramsMode（inherit / own）。
  · 子牌组默认 inherit：算法、参数组、目标保留率都用最近一个 own 祖先的；顶层牌组恒为 own。
    每日上限、步长等仍是每个牌组自己的。
  · 自动优化（PR6）在 own 牌组上跑，训练数据 = 它整棵子树里所有 inherit 后代的有效复习（遇到 own 的后代就停，那棵归它自己）。
  · 用户可在子牌组设置里改成「单独设置参数」（own），会拷一份祖先当前的参数作为起点。改 own 祖先的参数时，
    设置页写明「影响以下 N 个子牌组」。
  · parentDeckId 与 paramsMode 按铁律 H 设置类合并。成环（两端并发把 A 挪到 B 下、B 挪到 A 下）时，按 deckId 字典序
    较小的那个视为顶层，确定性打破环，并进同步冲突记录。
- srs_note_types：profileUid、【修5】ankiNum、【修4】kind（standard / cloze）、
  字段定义列表（每项 fieldId / 【修5】ankiNum / 名称 / 顺序 / deletedAt）、
  【修3】模板定义列表（每项 templateId / 【修5】ankiNum / 名称 / 顺序 / 正文（按 fieldId 引用）/ deletedAt）、CSS、
  fieldState（逐项：字段定义、模板定义各自一个键）。默认只内置 Lapis（ID 按铁律 C 确定性生成）。
- srs_notes：profileUid、noteTypeId、【修5】guid（必填，noteId 由它派生，不可修改）、字段值（fieldId → 值）、
  【修8】source（出处，有类型的一等字段，B-1，见下）、媒体引用、createdAt、fieldState（按 fieldId 逐字段，铁律 H）。
  【修8】termKey：本机缓存列（不同步、可重建），由笔记类型指定的「词条字段」归一化得到，供词状态查询建索引（B-3）。
  笔记类型为此加一项 termFieldId（内置 Lapis 指向其词条字段；用户自建的可在笔记类型设置里选，没选就不参与词状态）。
- 【修8】出处 SourceRef（B-1，PR2 冻结数据形状，功能在 PR3a / PR4 / 第二期实现）：
  · kind：book / video / audiobook / game / web / manual / anki（导入）。
  · 按 kind 带定位：book = 书籍身份 + sectionIndex + 字符偏移区间；video / audiobook = 媒体身份 + startMs / endMs；
    game = 游戏身份 + 可选截图引用；web = URL；manual / anki 无定位。
  · 「书籍身份 / 媒体身份」用哪个键按第 0 步对 bookKey 跨设备身份的结论定，冻结前必须有结论。
  · 用途：复习页「回到原文」（复用 collections_page.dart 已有的跳回逻辑）、播放视频 / 有声书原声片段。
  · 未知 kind 原样保留、不解析（与日志的「不认识的字段原样保留」同一规则）。
- srs_cards：id（= UUIDv5(noteId, templateId + "/" + clozeOrd)）、profileUid、noteId、【修3】templateId、【修4】clozeOrd、
  deckId、scheduler、suspended、buriedUntilDay、fieldState；
  排程缓存列 queue / dueDay / dueAt / scheduledDays / learningStep / stability / difficulty / reps / lapses /
  lastReviewedAt / lastLogId（缓存，不进 fieldState、不同步）。
- srs_review_log：只追加。id、profileUid、cardId、kind（review / manual / reschedule / importAnchor / handOff / undo）、
  rating、revokesId、【修3】hlc、occurredAt（【修5】可信时间）、【修5】timeSource（【修8】timeUncertain 改为派生值，不存，铁律 F）、
  【修5】origin（fushi / anki）、【修8】ankiRevlogType（导入日志的来源类型：Learn / Review / Relearn / Filtered / Manual / Rescheduled，
  等价判定与 S/D 输入按它分类，A-4 / A-5）、
  durationMs、paramsHash、【修6】algorithm（fsrs6 / fsrs7，替代 fsrsVersion；导入的 Anki revlog 一律记 anki——
  Anki 的 revlog 本身不记当时用的算法，按导入时的牌组配置去猜会违反铁律 C「导入事件只由来源决定」）、【修3】writerId（导入事件固定为 "anki"），
  加上「这次操作后」的结果列（dueDay / dueAt、scheduledDays、queue、learningStep、stability、difficulty、
  【修5】lastReviewedAt、reps、lapses、scheduler，见铁律 A）。以上全部是事件内容，同 ID 必须相同。
  字段语义对齐 Anki revlog，导出时可以直接映射。
- 【修5】srs_log_local（本机发布元信息，与事件内容分离，不同步）：logId、published、本机 changeSeq、收到时间。
  【修8】已删掉「未发布日志允许有界修正」：事件创建即不可变（铁律 F）。
- srs_anki_id_map：fushiId、kind（note / card / revlog）、ankiId（【修5】只记导出撞号时的实际值，身份判定不依赖它）。
- 【调研】srs_import_map：来源笔记类型 ID → 本地 noteTypeId（【修5】去掉结构哈希；只作查询加速，ID 本身按铁律 C 确定性生成）；
  日志另加 formatVersion、utcOffsetMin（见文末「对照 Anki 已知问题后的补充」）。
- 删除用软删除（deletedAt 作为普通字段，【修8】按铁律 H 合并，删除优先），不用 SyncTombstoneKind。
- 【修8】学习统计契约（B-2，属于数据契约，随 PR2 冻结）：
  · StatSourceKind 加 srs（复习时长写进 study_segments，一次复习会话一段）；ActivityMediaKind 视需要同步加。
  · 同步 wire、media_kind_mappings.dart 的跨域换算、各处对这两个枚举的穷尽 switch 一起改，PR2 里一次改全。
  · 日界统一见铁律 G。
- 【修8】词状态查询接口（B-3，PR2 只定签名，实现在 PR5）：
    Future<Map<String, SrsTermStatus>> lookupTermStatus(String profileUid, List<String> terms)
    SrsTermStatus = { cardId, noteId, queue（new / learning / review / relearning）, suspended, dueDay 或 dueAt, deckId }，
    一个词对应多张卡时取「最需要复习的一张」并带上卡数。
  按 termKey 索引查询，terms 先做与 termKey 相同的归一化。
  【修5】墓碑永不物理删除（见第三期「墓碑」）。
- 【修3】每行带 changeSeq（本机单调递增改动序号，只在「本机产生的改动」时递增，见第三期「回声」）。
- 评分 = 一个事务：算新状态 → 写日志 → 更新卡片缓存。
- 【修4】backup_merge_engine 加 SRS 合并步骤（铁律 E 三条规则），备份合并与同步合并调用同一套合并函数。

PR3a：添卡（手动 / CSV / 挖词）
- 手动新建：默认用 Lapis 填字段；也能选用户自建的笔记类型。
- CSV 导入。
- 挖词：挖掘链路的目标里加「Fushi SRS」，与推 Anki 互斥默认（见前提 1）；已有的 MinedSentences 可批量导入。
  【修8】挖词时把出处写成 SourceRef（B-1）；MinedSentences 批量导入按第 0 步的结论归入执行导入时的当前 profile，
  出处由它已有的 bookKey / sectionIndex / 字符偏移 / startMs 转换。
- 判重用 isDuplicate*，处置走 DuplicatePolicy；媒体存储与去重复用现有逻辑。

PR3b：Anki 导入（.apkg / .colpkg，含复习历史）
- 单独一个 PR：新格式是 zstd 压缩的 collection.anki21b + protobuf 媒体清单。
  【修4】zstd 解码走 fushi_fsrs 的 FFI 接口（PR1），不引入 Dart zstd 依赖。
  【修8】新旧两种格式在 PR3b 里一起做（用户 2026-10-14 定，替代「先 legacy 后新格式」）：
  · 新格式（Anki 2.1.50 起的默认导出）：collection.anki21b（zstd 压缩的 SQLite）+ protobuf 媒体清单 + zstd 压缩的媒体文件。
  · 旧格式：collection.anki2 / collection.anki21（Anki 导出时勾「兼容旧版本」，或老版本 Anki 的导出）。
  · .colpkg（整库备份）同样两种格式都认。
  · 解出 SQLite 之后两种格式走同一条导入路径，差别只在解包这一层；两种格式各用一份真实导出做对拍测试。
  只支持旧格式会让大多数用户第一次导入就失败（要回 Anki 改导出选项），所以不拆。
- 每张卡导入时按铁律 C【修8】的规则写 importAnchor（时刻取最后一条排程相关 revlog；往返无变化与新卡不写），
  再把 Anki 的 revlog 原样作为历史日志带进来（带 ankiRevlogType）。队列与到期从锚点开始；
  【修8】S/D 按铁律 A 的 ①～③ 从完整历史或锚点计算，不从锚点截断。
  【修4】笔记 / 卡片 / 笔记类型 / revlog / 锚点的 ID 全部按铁律 C 确定性生成：两台设备离线导入同一个 .apkg，
  同步后不出重复笔记、不出重复复习、优化器训练集不翻倍。
- 笔记类型一起带进来：【修5】fieldId / templateId 按铁律 C 由 Anki 的 Field.Config.id / Template.Config.id 派生
  （来源没有时按名字匹配本机已有项，再不行按名字派生），不再按 ord；模板正文里的字段名换成 fieldId 引用；
  【修4】Anki 的填空类型映射为 kind = cloze，卡片按 Anki ord + 1 得到 clozeOrd；
  【修5】重复导入时的结构变化按铁律 C 处理（已有 ID 永不重生成、kind 不同记冲突），导入报告列出新增 / 改名 / 来源已删的项。
- 【修8】牌组层级与预设（用户 2026-10-14 让我定）：Anki 的「父::子」牌组名转成 parentDeckId。
  同一个 Anki 预设被多个牌组共用时：这些牌组的最近公共祖先若也用同一预设，祖先设为 own、它们设为 inherit；
  否则每个牌组各自 own、各拷一份预设参数，导入报告里列出「预设 X 被拆到 N 个牌组」。
- 【修8】学习 / 重学步长（用户 2026-10-14 定）：Fushi 只允许当天以内的步长。来源步长里 ≥1 天的项（如 1d、3d）截掉，
  剩下的照用；全被截掉时用默认步长。导入报告列出「牌组 X 的步长 1d 3d 已移除，改由 FSRS 安排」。
- 【修6】牌组算法与参数的映射（导入的是牌组设置，不是事件，【修8】按铁律 H 写本机修改记录）：
  · 来源预设开了 FSRS 且参数是 FSRS-6（21 个）→ algorithm = fsrs6，参数写进 fsrs6Params，algorithmAuto = 真
    （PR6 在同一份数据上评估 FSRS-7 更好时自动切换）。
  · 来源是 JSchoreels fork 的 FSRS-7 预设 → algorithm = fsrs7，参数写进 fsrs7Params（存放位置按第 0 步实测）。
  · 来源是 fork 的 RWKV-Curve / RWKV-Instant 预设（Fushi 不支持 RWKV）→ 看它的 FSRS 回退设置：
    回退是 FSRS-7 → algorithm = fsrs7；回退是 FSRS-6 → algorithm = fsrs6；回退是 Curve 或没有 → fsrs7 默认参数。
    相应参数写进对应参数组，导入报告注明「RWKV 预设已改用 FSRS-x」。
  · 来源没开 FSRS（SM-2）→ algorithm = fsrs7，参数为默认值，复习历史照常进训练集。
  · 参数个数或取值不合法 → 不写这组参数，牌组用默认参数，导入报告里列出原因（与 PR1 的参数校验同一个函数）。
  · 以上只在首次建牌组时写入。重复导入时牌组已存在，algorithm 与参数一概不动。
    导入写的是本机的新修改记录，若照写会盖掉用户在 Fushi 里做过的选择。
- 【修5】回导 Fushi 自己导出的包：guid、笔记类型 / 字段 / 模板的数字 id 都是 Fushi 写出去的，按同一规则派生回原 ID；
  其中的复习按铁律 B 的等价规则认回原生日志，不重复。

PR4：复习页
- 新写 Anki 模板渲染器（纯 Dart，进 fushi_srs）：{{字段}}、{{#}}/{{^}} 条件、{{FrontSide}}、
  furigana: / kana: / kanji: / text: / cloze: / tts: 过滤器；类型答案先不做。
  渲染前把 {{fld:<fieldId>}} 解析成当前值；【修4】cloze: 按卡片的 clozeOrd 决定挖空哪一处。
  卡面在 WebView 里显示（Lapis 带 JS），复用 lapis_style_editor_page 的 WebView 外壳与死亡守卫；
  【修3】按第 0 步结论补 Lapis 需要的最小宿主接口。
- 四个评分按钮带间隔预览；撤销 / 暂停 / 埋卡 / 编辑。
- 【修8】撤销栈（连续撤销，与 Anki 一致，用户 2026-10-14 定）：
  · 本机维护一个会话级撤销栈，记录本次使用中按顺序做过的操作：评分、暂停 / 取消暂停、埋卡、改旗标、移牌组、编辑笔记、删除。
    Ctrl+Z / 撤销按钮每按一次撤一步，可以一直往回撤。
  · 撤评分：写 undo 事件指向那条评分日志。按倒序回撤时，它总是那张卡当前的最后一条有效日志，满足铁律 B 的协议限制。
  · 撤其它操作：写一条新的修改记录，把字段改回操作前的值（铁律 H，新记录支配原记录）；撤删除 = 清 deletedAt。
  · 例外：栈里某一步之后，另一台设备同步来了同一张卡的更新复习（那条评分已不是最后一条有效日志），这一步不能撤。
    提示「这张卡已在其它设备上复习过，无法撤销这一步」，跳过它继续往回撤。
  · 撤销本身也能被撤销？不支持（与铁律 B「不支持 redo」一致）。撤销栈不同步，换设备不能撤别的设备的操作。
- 【修8】新卡出卡顺序是确定性的（A-5）：按 (笔记 createdAt, cardId) 升序，多台设备看到同一顺序。
  导入笔记的 createdAt 取来源笔记 id（Anki 笔记 id 就是创建毫秒时刻），同样只由来源决定。
  到期复习的顺序沿用「可提取度从低到高」（见「第一期补充」）。
- 【修8】冲突提示（铁律 H）：卡片的笔记有待裁决字段时，复习页顶栏显示一个标记，点开进编辑页选择；不打断复习。
- 【修8】出处（B-1）：卡片有出处时，提供「回到原文」（复用 collections_page.dart 的跳回逻辑）；
  视频 / 有声书出处可播放原声片段。
- 键盘、手柄（A 确认）、触屏手势，纳入焦点所有权体系（WebView 键盘桥）。
  【修8】空格键（C-5）：全局 _neutralizeBareSpace（global_navigation.dart:595）在没有文本框聚焦时吞掉裸空格，
  而 Anki 用户习惯用空格翻面 / 评 Good。复习页要显式接管空格：在页面焦点作用域内先于全局中和处理，
  翻面前 = 显示答案，翻面后 = Good；只在复习页生效，不改全局「焦点确认不走空格」的规则。
- 卡面里可以播放音频 / TTS，也可以查词。
- 带动效（FushiEntranceScope、FushiPressScale、fushiMotionDuration），MD3 与 Apple 两套都接；
  顶栏动作走 FushiFloatingTopBar 的 adaptiveOverflow。

PR5：接线
- 模块入口与设置项（全局设置）。【修8】新模块在 ModuleId 与 module_registry 里注册（C-5）；
  新页面一律带动效、接 MD3 与 Apple 两套设计系统（仓库规则）。
- 【修8】词状态回流到查词弹窗（C-1，第一期的产品重点）：
  · 实现 PR2 定下的 lookupTermStatus，接到与 AnkiConnect 查重同一个桥上
    （popup.js 的 duplicateCheck → ankiconnect_repository.dart 那条链路旁加一个 SRS 来源）。
  · 弹窗显示「已在复习、状态是什么、到期时间」，点击直接打开那张卡。
  · Fushi SRS 与 Anki 同时有这个词时两者都显示，不互相覆盖。
  · 阅读器里按卡片状态给词着色、批量「标为已知」放第二期。
  不做这一步，SRS 就只是一个内嵌的 Anki 复刻，「为什么不用 Anki」站不住。
- 【修8】同步冲突记录（铁律 H 方案 C）：同步状态里的不弹窗提示与冲突列表页（逐条 / 整组 / 全部改回或确认），
  设置类在设置项旁显示「已被另一台设备的修改替换」；内容类的待裁决项也列在同一页，点开进编辑页。
  页面带动效、焦点驱动可操作，MD3 与 Apple 两套都接。
- 【修8】新手引导（C-5）：onboarding_wizard_page.dart 现在只教「去 Anki 里打开 FSRS」。
  改为按用户选的复习目标分流：选 Fushi SRS 的不再显示 Anki FSRS 教程（Fushi 默认就是 FSRS-7）；选 Anki 的保留原教程。
- 【修6】牌组设置的「高级」里加「排程算法」：FSRS-7（推荐，默认）/ FSRS-6。
  切换后写 algorithm 并把 algorithmAuto 置假；旁边说明「新算法从下一次复习起生效，已排好的到期日不变；
  要立即生效请用『立即重排整组』」。
- 纳入 createBackup / restoreBackup。【修3】恢复备份后本机换新化身号（见第三期），不复用旧 writerId。
  【修4】备份合并按铁律 E 的 SRS 规则走。
- i18n 一律走 i18n_sync.dart。
- 无头服务端暴露只读的到期统计（可选）。

PR6：FSRS 自动优化（用户 2026-10-14 要求进第一期；五个平台都跑；【修3】排在 PR4 之后）
- 什么时候跑（全自动，不弹提示）：
  · 某牌组有效复习日志首次达到门槛（按第 0 步实测与 fsrs-rs 最少样本要求定），之后相对触发基线
    （optimizeBaselineAt / optimizeBaselineCount）每新增一定比例的复习、或距基线满 30 天，再跑一次；
  · 只在后台 isolate 里跑，复习页打开时不跑；移动端只在前台空闲时跑，被打断就取消，不留半成品。
  · 进度和结果只在设置里能看到。
  · 【修4】【修6】本机不认识当前参数组的 algorithmRev 时不跑（铁律 F）。
- 【修6】优化哪一组：
  · algorithm = fsrs7 → 优化 fsrs7Params。
  · algorithm = fsrs6 → 优化 fsrs6Params；algorithmAuto 为真时，同一轮再训练一次 FSRS-7。
    用 evaluate 在同一份数据上比较「新 FSRS-7 参数」与「当前 FSRS-6 参数」，FSRS-7 的 log loss 更低才切换：
    写入 fsrs7Params，algorithm 改为 fsrs7，algorithmAuto 保持真，两个字段键在同一次修改里写（同一个 ctx）。否则什么都不改。
    这一步不弹提示，设置里的优化历史记一条「已改用 FSRS-7（log loss a → b）」。
  · algorithmAuto 为假（用户手动选过）→ 只优化当前算法，不跨算法比较、不切换。
- 用什么数据：这个牌组的全部有效 review 日志（被 undo 撤销的不算；manual / reschedule / importAnchor 作为时间断点），
  过滤规则照 rslib 准备 FSRS 训练数据的做法；导入的 Anki 历史也算。
- 什么时候采用新参数（【修3】条数判断放在这里，不放在合并规则里）：
  用 evaluate 在同一份数据上比较新旧参数的 log loss，新参数更好、且本次训练条数 ≥ 当前参数组的训练条数，才写入；
  否则保留现有参数。写入时生成一条修改记录，按铁律 H 设置类整组合并。
  当前参数组是用户手动设的 / 默认值（训练条数 0）时，只比 log loss。
- 【修4】用户点「恢复默认参数」或手动改参数时，同时把触发基线重置为「此刻 + 当前有效复习条数」：
  下一轮自动优化要等再新增一定比例的复习或满 30 天才跑，不会在下一次空闲时就把用户的选择覆盖掉。
  设置里在「恢复默认」旁说明这一点。想彻底停用就关自动优化开关。
- 采用后怎么生效：只改牌组这一行、只同步这一行；每张卡在下次复习时用新参数（铁律 A），不重排整组。
- 多设备：两台都跑出结果时，按铁律 H 设置类（sortKey 较大者胜出，留替换记录）各参数组各自取一组，不会出现 A 的参数配 B 的 hash；
  FSRS-6 与 FSRS-7 的参数分开存，不可能互相套用。可选：设置里指定「只在这台设备上优化」。
- 设置（高级设置里，默认收起）：自动优化开关（默认开）、「立即优化」、上次优化时间与效果、恢复默认参数。
- 测试：门槛与触发判定、撤销日志被排除、新参数更差 / 训练条数更少时不采用、
  「恢复默认」在合并中胜过更早的自动优化结果、【修4】恢复默认后触发基线被重置、不认识的模型版本不跑、
  取消后不落半成品，都写纯函数单测；CI 用合成日志跑一次真实 FFI。
  【修6】另加：fsrs6 牌组在 FSRS-7 评估更好时自动切换、更差时不动；algorithmAuto 为假时不切换；
  两端并发「一端自动切到 fsrs7、一端用户手动选 fsrs6」时，按铁律 H 设置类合并，结果确定且留替换记录。

PR7：【修8】AnkiConnect 兼容层，并入 Fushi API（用户 2026-10-14 要求）
目的：让 Yomitan、asbplayer 等只认 AnkiConnect 的工具，不改代码就能直接往 Fushi SRS 里加卡、查重、打开卡片。
- 现状（2026-10-14 核对 develop）：
  · Fushi 只是 AnkiConnect 的客户端（packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart），
    仓库里没有 AnkiConnect 服务端。
  · 已有对外的「Fushi API 服务」：fushi/lib/src/sync/yomitan_api_server.dart，默认端口 19633，
    只听本机（可选开放局域网），可选 Fushi API key 鉴权（x-api-key / Bearer / body token 等），按 REST 路径分发；
    共用逻辑在 packages/fushi_engine/lib/sync/remote_lookup_routes.dart 与 fushi_remote_api_handlers.dart。
    浏览器扩展只连它（/api/duplicate、/api/mine 等）。
- 整合方式：不另起服务，AnkiConnect 协议作为 Fushi API 的又一组接口。
  · 协议：AnkiConnect v6，POST 到根路径「/」，body = {action, version, params, key?}，响应 {result, error}。
    Fushi API 现有路径都在 /api/、/serverVersion 等下面，根路径 POST 不冲突。
  · 处理逻辑写在 packages/fushi_engine/lib/sync/ 下（与 remote_lookup_routes 同层，纯 Dart），
    app 的 Fushi API 服务与无头服务端 fushi_server 都挂上，服务端上的 SRS 同样能被 Yomitan 写入。
  · 鉴权沿用 Fushi API key：AnkiConnect 客户端把 key 放在 body 的 key 字段（Yomitan 支持配置 API key），
    现有中间件已认 body token，补上认 key 字段即可。没设 key 时只接受本机请求（与现在一致）。
  · 端口：默认就是 Fushi API 的 19633，用户在 Yomitan 里把 AnkiConnect 地址填成 http://127.0.0.1:19633。
    另提供一个可选开关「同时监听 8765（AnkiConnect 默认端口）」，给改不了地址的工具用。默认关：
    8765 通常被 Anki 自己的 AnkiConnect 占着；打开时端口被占就不监听，并在设置里提示原因。
  · 防自环：Fushi 自己的 AnkiConnect 客户端（推 Anki 那条链路）若指向的正是本机这个兼容端点，就拒绝并提示，
    否则「推 Anki」会写回 Fushi 自己。判据：兼容端点的 version 响应之外，另有一个 Fushi 专用的识别接口。
- 写到哪里：兼容端点只操作 Fushi SRS（当前 profile）。它不转发给真正的 Anki；要推 Anki 的用户继续用原来的链路。
- 支持的动作（Yomitan 实际调用的 20 个全部覆盖，来源 yomitan ext/js/comm/anki-connect.js；再加 Fushi 客户端自己用的）：
  · 基础：version（返回 6）、requestPermission、apiReflect、multi、sync（触发一次 Fushi SRS 同步，立即返回）。
  · 牌组 / 笔记类型：deckNames、deckNamesAndIds、createDeck、modelNames、modelNamesAndIds、modelFieldNames。
    牌组名用 Anki 的「父::子」形式，映射到牌组树（parentDeckId）；笔记类型与字段按名字映射。
  · 笔记：addNote、addNotes、canAddNotes、canAddNotesWithErrorDetail、findNotes、notesInfo、updateNoteFields、addTags。
  · 卡片：findCards、cardsInfo、suspend。
  · 媒体：storeMediaFile（data / path / url 三种来源，按内容哈希存）。
  · 界面：guiBrowse（在 Fushi 里打开卡片浏览并带上查询）、guiEditNote（打开笔记编辑页）。
  · 不支持的动作返回 AnkiConnect 风格的错误「unsupported action」，不崩。
- 数字 id：AnkiConnect 用整数 id。笔记 / 卡片 / 牌组 / 笔记类型的整数 id 就用铁律 C 导出 Anki 时那套确定性派生
  （UUID 哈希出的 53 位正整数、笔记类型用 ankiNum），同一个对象在导出包与 AnkiConnect 里的 id 一致；
  反查用本机索引（srs_anki_id_map 扩展，或按需建的本机映射表，不同步）。
- 查询语法：findNotes / findCards / guiBrowse 实现 Anki 搜索语法的一个子集，至少覆盖 Yomitan 查重发出的形式
  「"deck:牌组名" "字段名:值"」，外加 deck:（含子牌组）、note:、tag:、is:new / is:due / is:suspended、nid: / cid:、
  added:N、裸词全文、AND / OR / 否定 / 括号 / 通配符 *。字段比较按 Anki 规则（不区分大小写、去 HTML）。
  不支持的语法返回明确错误，不静默返回空结果（否则查重会误判为「不重复」）。
- 加卡语义：addNote 的 options（allowDuplicate、duplicateScope = deck / collection / deck-root、
  duplicateScopeOptions）按 AnkiConnect 的定义实现；加进来的笔记走 PR3a 同一条添卡路径（guid 生成、确定性 ID、
  媒体去重、判重用 isDuplicate*）。出处（SourceRef）：外部工具加的卡 kind = web 或 manual，能拿到来源 URL 就带上。
- 与查词弹窗的关系：浏览器扩展与 app 内弹窗继续走 Fushi 自己的 /api/duplicate、/api/mine，
  它们在 PR5 已经接上 SRS（C-1）；AnkiConnect 兼容层只服务外部工具，两边共用同一套 SRS 服务函数。
- 测试：
  · 每个动作的请求 / 响应形状契约测试，对照 AnkiConnect 文档的示例；
  · 用 Yomitan 的 anki-connect.js 请求形状跑一遍查重（canAddNotesWithErrorDetail + findNotes 的组合）与加卡；
  · 查询子集：Yomitan 查重的转义规则（含引号、冒号、通配符的词）；
  · 防自环、8765 被占、无 key 时拒绝非本机请求；
  · 现有 fushi/integration_test/support/fake_ankiconnect.dart 可当协议参考，但兼容层要对真实客户端行为测。

== 第二期：Fushi 的差异化 ==

- 「标为已知」批量导入：从 Anki 牌组或词频表导入。
- 【修8】阅读器按卡片状态给词着色、阅读中批量「标为已知」（C-1 第二期部分，复用 PR5 的 lookupTermStatus）。
- 统计页：保留率、到期预测、热力图；复习时长接入 study_segments（【修8】StatSourceKind.srs 的契约已在 PR2 定下，
  这里只做页面）。
- 到期提醒：移动端本地通知，桌面托盘角标。
- 遗漏卡（leech）检测；自定义学习（只复习某本书的词、提前复习）。
- 「推荐记忆率」：用 fsrs-rs 的最优保留率模拟给出建议值，只在设置里显示，不自动改。

== 第三期：同步与 Anki 互通 ==

同步什么：
- 复习日志：只追加，按 ID 取并集。卡片状态 = 按 sortKey 排序的最后一条有效日志（【修3】不用墙钟；【修4】有效的定义见铁律 B；
  【修8】sortKey 见铁律 F）。
- 【修8】牌组 / 笔记类型 / 笔记 / 卡片 / profile 设置的可编辑字段：按铁律 H 合并（修改记录 + 版本向量）。
  设备 A 改记忆率、设备 B 改每日上限，是两个不同字段键，两个都保留；
  改同一个字段时，有因果先后的后者胜出，并发的按内容 / 标志 / 设置三级规则处理，不会静默丢值。
- 卡片排程缓存不同步，收到日志后只更新涉及的卡（读最后一条有效日志，不重算）。

改卡组设置不会触发全组同步：
- 改名称 / 每日上限 / 步长 / 记忆率 / 参数，只改 srs_decks 这一行的某几个字段，同步只传这一行。
- 新参数在每张卡「下次复习」时生效（铁律 A），卡片本身不动，不产生额外同步。
- 只有用户主动点「立即重排整组」，才由那台设备给每张卡写一条 reschedule 日志（一小批日志，不是整组快照）。

两台设备同时离线复习同一张卡：
- 两条 review 日志都保留（都进历史，优化器也会用），卡片状态取 sortKey 较大的那条。没有冲突弹窗。

【修8】做成通用同步层（C-2）：
- 这会是仓库里第四套同步模型（aggregate / 文件箱 / 互联 live 之外）。把「单写者批次 + 自校验文件 + 快照 + 版本向量 + HLC
  + 带外 S + 修改记录合并」做成 packages/fushi_engine/lib/sync/ 下的通用事件日志同步层，SRS 是第一个使用者；
  无头服务端与互联直接复用，以后别的域（例如播放位置、收藏）也能迁过来。
- 单写者文件的模式照 packages/fushi_engine/lib/anki_sync/pending_mine_relay.dart 做。
- 引擎纯度规则照旧：不 import Flutter / 插件，平台边界走引擎装配点。

【修3】写入者身份（化身号）：
- writerId = deviceId + 化身号。全新安装、恢复备份、清数据后重新接入时，生成新的化身号。
- 新化身从批次号 1 开始写在自己的新目录下，对端把它当作一台新写入者读，不会因为序号回退漏读。
- 【修4】读取时按 writerId 区分「自己」，不按 deviceId：本机新化身必须把本机旧化身目录当作别人读一遍
  （备份之后旧化身写的改动只在那里）。
- 【修5】本机发现自己的写入者目录已不存在（被当作退役设备清理过），立即换一个新化身号，
  未发布的本机改动进新化身的批次；绝不在已删除的目录名下续写旧批次号。
- 旧化身目录不再增长，按下面的退役规则清理。

传输：
- 硬规则：同步目录里每个文件只由一个写入者写（批次、快照、cursor 都在写入者自己的目录下），其它设备只读。
  普通网盘（Google Drive / WebDAV / Dropbox / FTP，以后的 iCloud、阿里云盘）都能直接当同步通道，
  网盘层面不会出现文件级冲突。以后任何改动都不能引入「多个写入者写同一个文件」。云盘（文件箱）和互联走同一份格式。
- 【修5】批次：编号连续、内容先冻结再上传（009）。
  · 每个写入者的批次号从 1 开始连续递增，没有空号：srs/<profileUid>/<writerId>/batch-<批次号>。
  · 发布时先在本机「发件箱」里把批次冻结下来：分配批次号，写入 changeSeq 区间 [from, to]（与上一批的 to 首尾相接）、
    正文与发布时取得的服务器时间 S（铁律 F，【修8】只写在批次信封里，不改正文里的任何事件），然后才上传。
    冻结后内容不再改变。
  · 上传失败、或上传成功但响应丢失：用同一个批次号、同样的字节重传，直到用 findAsset 确认文件存在且长度、哈希一致。
    上一批确认之前不发下一批，所以写入者这一侧不会产生空号。
  · Google Drive 等允许同名多文件的后端可能因重传出现两份同名批次：内容必然逐字节相同，读方任取一份校验通过的；
    写入者确认后删掉多余的副本。
- 【修4】【修5】文件自校验，不用改名：
  · 批次、快照、cursor 文件一律以固定头开始：魔数、格式版本、writerId、批次号（快照写所含最大批次号）、
    changeSeq 区间、发布时服务器时间 S、正文长度、正文 SHA-256。
  · 读方先校验头与哈希；长度不足、哈希不符（写到一半、传输截断）一律视为「这个文件还不存在」，下一轮再读。
  · 【修8】批次头的 S 用于计算批次内每条事件的 S(e) 与排序键钳位（铁律 F）；不再整批拒收，任何批次都照常应用、cursor 照常推进。
  · 批次与快照写完不再修改；cursor 是单写入者的「最新值」文件，读到坏的就沿用上一次读到的值。
  · 全部经 putAsset / getAsset（字节接口）读写，不走 putJsonAsset：这样开启「防扫盘混淆」时，
    笔记正文与复习记录也会经 ObfuscatingSyncBackend 混淆，与书本内容同等对待。
  iCloud 备注：读之前要先触发下载占位文件并等它完成。
- 【修5】读取进度只表示无缺口的前缀（009）：
  · 本机对写入者 W 的读取进度 cursor[W] = 最大的 b，使 W 的第 1…b 批（或覆盖了这段前缀的快照）都已应用。
  · 对 W 严格按批次号顺序应用；看到 b+2 而 b+1 还不可见（云盘列表延迟、上传未完成）时，本轮对 W 停在 b，
    下一轮再试，不跳过、不提前确认。
  · 只有 cursor 推进才写回本机 cursor 文件；快照的版本向量 vv 也只记这种无缺口前缀。
    因此 cursor / vv 永远不会宣称覆盖了实际没应用的批次，清理条件也不会被提前满足。
- 【修3】回声：应用对端改动时不递增本机 changeSeq、不重新发布；只有本机产生的改动进本机批次。
  （合并结果是确定的，每台设备读全部写入者的批次就能得到同一结果，不需要转发。）
  这条只在「所有设备读同一个目录」时成立；一台设备用多个目录时见下面「多目录传输」的转发规则
  （2026-10-19）——单目录时转发条件永不成立，行为与本条一致。
- 媒体按内容哈希存，只传对方没有的文件；文件名就是哈希。
- 【修4】快照 = 完整合并状态（不只是本机改动）：
  · 写入者定期在自己目录下写快照，内容是本机此刻的完整 SRS 合并状态（该 profile 的全部行与全部日志，
    含墓碑），外加版本向量 vv：{ 每个写入者 → 本快照已包含的无缺口批次前缀 }（含自己，
    【修5】也含目录已被删除的写入者——vv 条目只增不减，跟着完整状态一起传下去），
    【修8】以及它已知的「事件 ID → S」映射（铁律 F）。读快照的设备据此算出与读批次的设备相同的 S(e)。
  · 快照写成后，本写入者 ≤ vv[自己] 的旧批次在本目录内被它覆盖。
  · 快照是单调的：后写的快照包含先写的快照里的全部数据（完整状态只增不减，墓碑也保留）。
  · 回声规则不变：增量批次仍只含本机改动；只有快照包含别人的数据。快照不改变合并结果
    （合并是幂等的，重复读到同一行 / 同一条日志没有影响）。
- 【修5】新设备起步（以及退役后回归、或发现自己 cursor 指向的目录已不存在的设备）：
  · 读同步目录里「每一个」现存写入者的最新快照，逐个流式合并（幂等，顺序无关）；
    起步 vv = 各快照 vv 的逐项最大值。
  · 再对每个现存写入者 W，从 vv[W] + 1 开始按批次号读增量（规则同上：无缺口才推进）。
  · 不再「只挑一份覆盖最广的快照」：版本向量可能互不支配（审查 001 的反例），只读一份会漏掉
    只存在于另一份快照里的、已删目录写入者的数据。读全部快照的代价是设备数 × 快照大小，设备数很少，可以接受。
  · 逐个批次 / 快照流式应用，不把整份数据读进内存。
- 【修4】对端的增量读取：对写入者 W，本机 cursor[W] + 1 < W 最早仍存在的批次号时（中间的已被 W 的快照覆盖并清理），
  读 W 的最新快照，再读之后的增量；否则直接读增量。
- 【修3】【修4】【修5】旧批次清理与写入者退役：
  · 写入者 W 只删自己目录里「已被自己的快照覆盖、且所有活跃对端的 cursor[W] 都已越过」的旧批次；
    对端 cursor 写在对端自己目录的 cursor 文件里。
  · 某个设备的 cursor 文件超过 90 天没更新，视为退役，不再阻挡清理；它若再次上线，按上面的「起步」流程重新读全部快照。
    设置里也可以手动「移除这台设备」。
  · 【修5】整个写入者目录 W（被替代的旧化身、退役设备）可删，必须同时满足：
      1. 所有活跃对端的 cursor[W] 都已到达 W 的最后一批——现有设备都已拿到 W 的全部数据；
      2. 至少一个活跃写入者的最新快照 vv[W] 到达 W 的最后一批——之后起步的新设备读全部快照时一定能拿到 W 的数据。
    条件 2 可以传递：持有 W 数据的那个写入者以后自己被删时，它同样要满足条件 2，而它的数据（含 W 的）已经在
    别的活跃快照里（快照单调）。所以数据永远至少存在于一份活跃快照中。不满足条件的目录永不删除。
- 【修5】墓碑永不物理删除（002）：
  · 修订版 4 的「90 天后物理删除墓碑」取消。物理删除后，旧备份或退役设备带回来的旧行会在按 ID 取并集的合并里
    被当作新行插入，已删数据复活，而且删除时钟已丢、无法裁决。
  · 改为「瘦身墓碑」：行被删除满 90 天后，本地清空它的字段值、媒体引用与笔记正文，只保留 id、deletedAt、
    【修8】以及每个字段键未被支配修改记录的 dot 与 ctx（不留值，铁律 H）。之后无论合并哪份旧备份或旧快照，
    带回来的旧修改都被墓碑里的记录支配，赢不了，行保持已删且为空；真正并发的新修改按铁律 H「删除优先 + 待裁决」处理。
  · 墓碑代价是每行几十到一百多字节，十万条删除也只有十 MB 量级；日志表只追加，本来就不删。
  · 被删笔记的卡片不单独写墓碑（铁律 D 的生成门），不受影响。
- 【修8】时钟：事件不可变，发布时只在批次信封上写 S；读方按铁律 F 计算 S(e) 与 sortKey，不拒收、不修改事件。

多目录传输（2026-10-19，`packages/fushi_srs/lib/src/sync/sync_engine.dart`）：
- 起因：一台设备同时开着云备份与互联时，app 对每条通道各跑一轮 `syncOnce`，而写入者身份、批次号、
  读取进度、冻结批次全局只有一份——批次只传到先跑的目录（传完就清掉了冻结批次），第二个目录里
  找不到本写入者，被误判成「已被当作退役清理」，每轮换一次化身。另外本机作为互联 host 时，它不是
  任何一条通道的客户端，自己完全不参与 SRS 同步（客户端写进来的文件没人读，它的卡也发不出去）。
- 目录只是传输介质，不是数据的归属：写入者身份、批次号、对每个写入者的 cursor 全局一份
  （第 n 批冻结后逐字节不变，在哪个目录读到都一样）。按目录记（`SrsDirectoryState`，键是调用方给的
  稳定目录身份）：本写入者在这里确认到第几批、这里是否出现过本写入者目录、是否起步过、快照写到哪、
  这里的写入者与它们列出过的最大批次、哪些写入者在这里「活着」、本机替谁转发到第几批。
- 冻结即分配批次号并进本机留存（`srs_sent_batches`），每个目录各自从留存里按序补传；留存到「最近
  30 天内同步过的所有目录」都确认为止（上限 5000 批）。落后得比留存还久的目录写一份快照补齐；读方在
  「下一批不在、但有覆盖到更后面的快照」时改读快照（不再只在第一批之前有缺口时才读）。
- 首次发布事件的 S 在冻结时就定下（不等某个目录确认：落后的目录可能直接用快照补齐）。
- 换化身：只在「这个目录出现过本写入者、现在不见了」时（旧版本状态没有按目录的记账，找不到就按
  退役处理一次）。换化身时本机全部事件由新化身重新发布：旧化身的批次流作废，本机转发过的数据也随之
  作废，新批次流带着全部数据才重新成立下面转发记账依赖的不变式。
- 转发：从目录 D 读到写入者 W 的数据，而本机另一个已起步的目录 D' 里 W 不活着（从没出现过、cursor
  文件超过留存期没更新、或已被同一台设备更高的化身取代——它不会自己把这些批次传进 D'），本机原先没有、
  这次新落地的事件，以及 S 因此变小的事件，进本机发件箱，随本机批次带到所有目录。批次头新增可选的
  `fs`（事件 ID → 原 S）：早已发布过的事件不取信封 S，取它带着的原 S，否则只看得到转发的设备算出的
  S(e) 与别人不同。每条事件在每台设备上只落地一次、S 只会变小，转发必然终止。单目录时 D' 不存在，与
  回声规则一致。兼容：`fs` 是信封里的可选键，旧版本照常解码、把信封 S 套到全部事件上——只影响转发 /
  重新发布的事件的 S，而多目录在此之前本来就不工作；全部设备升级后一致。
- 不变式：本机持有的每条事件，要么在本机当前批次流里，要么由在那个目录里活着的写入者送达。每轮核对：
  本机读到 W 的进度超过 D 已有的（列出过的、起步时快照 vv 覆盖的、本机转发过的）且 W 在 D 不活着，
  就把全部事件重新发布一次（目录刚起步时补历史、写入者停止来 D 时补它在别处的后续）。
- 目录身份（app）：互联 = 所连 host 的 hostId（本机 host 自己的目录用本机设备 id，同一个值）；云盘 =
  后端类型 + 账户 / 服务器；开了防扫盘混淆单独算一个目录。
  拿不到稳定身份（账户还没认出来、服务器地址没配）时这一轮不同步该后端，不建「空身份」目录。
- 坏文件：自校验通过、内容解不出来的批次 / 快照 / cursor 文件不抛异常，记进报告跳过（不删）；坏批次
  不越过，改读覆盖它的快照，其它写入者照常。
- 本机作为 host：已配对设备经互联写入 SRS 命名空间后，去抖 3 秒只跑本机目录（host 经本机文件系统读写，
  不触发自己）。
- 发件箱按 `maxEventsPerBatch`（5000）切批：全量重新发布 / 大包导入不再是一个巨型批次。
- 验证：确定性模拟器的桥接（只连云盘 / 两边都连 / 只连 host）、三台都连两个目录两种拓扑各 60 个固定
  种子；开发中另跑过单目录 / 桥接 / 双目录 / 链式（四台三目录）各 2000 个种子与 150 步长序列各 400 个。

Anki 互通：
- 导出 .apkg（含 revlog，Anki 能接着排程），数字 id / guid 按铁律 C 确定性派生（【修5】不依赖 srs_anki_id_map），重复导出不重复建笔记；
  模板正文里的 fieldId 引用换回字段名，卡片 ord 按 templateId 的当前位置算（填空卡 ord = clozeOrd - 1）。
- 【修6】导出时的算法：官方 Anki 只认 FSRS-6。
  revlog 与算法无关，Anki 会按它重算记忆状态，排程历史不丢。
  牌组预设里写 fsrs6Params（有就写，没有留空），不写 FSRS-7 参数。
  牌组是 fsrs7 时，导出对话框提示一句「Anki 里会改用 FSRS-6，建议在 Anki 里点一次优化」。
- 可选「交给 Anki 排程」：导出后写 handOff，卡片在 Fushi 里变只读。
- .apkg 读写可以考虑交给 fushi_anki_sync 的 rslib（仅桌面和服务端），移动端走纯 Dart 解析（zstd 走 fushi_fsrs FFI）。
- 【修8】Fushi 能完整导入自己导出的卡组（用户 2026-10-14 要求）：
  · 不另立私有格式，仍然导出标准 .apkg（Anki 照常能导入）。Fushi 专有、Anki 没有地方放的数据，
    写进包里一个额外的条目 fushi-ext（zstd 压缩的 JSON，带格式版本号）。
    Anki 读包时只按名字取 meta、collection.anki2 / .anki21 / .anki21b 与媒体清单
    （rslib import_export/package/meta.rs:72–94、colpkg/import.rs:145），多出来的条目直接忽略，不影响 Anki 导入。
    第 0 步拿 Anki 26.09.3 实际导入一次带 fushi-ext 的包确认。
  · fushi-ext 里放：
      - 牌组：algorithm / algorithmAuto、fsrs6Params / fsrs7Params（含 algorithmRev）、parentDeckId / paramsMode、
        日界等 Fushi 特有设置；
      - 笔记：SourceRef（出处）、termFieldId；
      - 复习日志：完整的 Fushi 日志（含原日志 id、kind、结果列、sortKey 所需的 hlc / writerId、undo 关系），
        而不只是 Anki revlog 能表达的那部分；
      - 卡片的 scheduler（fushi / anki）。
  · 导入时：包里有 fushi-ext 就按它恢复全部 Fushi 数据，revlog 只作校验；没有就按普通 Anki 包导入（PR3b）。
  · 身份规则不变（铁律 C）：
      - 导回同一个 profile：noteId / cardId 由 profileUid + guid 派生，与原来相同；日志保留原 id，按 ID 取并集，不会重复。
      - 导入另一个 profile 或另一台设备的新 profile：noteId / cardId 按新 profileUid 重新派生；
        日志 id = UUIDv5(新 cardId, "fushi-log/" + 原日志 id)，确定性，重复导入同一个包不会重复。
  · 经过 Anki 再导回来（Fushi 导出 → Anki 修改 → Anki 再导出）：Anki 导出的包不再带 fushi-ext，
    但 guid、笔记类型 / 字段 / 模板的 ankiNum 都还在，按铁律 C 认回原笔记；本地已有的出处、参数等 Fushi 数据保留不动
    （重复导入默认不覆盖本地，铁律 C）。新导入的笔记才会缺这些数据。
  · .colpkg（整库）导出同理：带 fushi-ext，导回时恢复整个 profile 的 Fushi 数据。
  · 测试：Fushi 导出 → Fushi 导入（同 profile、新 profile、新设备）三种情况逐字段比对；Fushi 导出 → Anki 导入
    确认 Anki 正常；Fushi → Anki → Fushi 往返确认不重复、本地 Fushi 数据不丢。

== 主要风险 ==

- Anki 模板渲染器要新写（PR4），Lapis 自带 JS，可能依赖 Anki 宿主 API（第 0 步核实）；复习页是 WebView，
  焦点和手柄要走 WebView 键盘桥。
- .apkg 新格式需要 zstd + protobuf（PR3b；【修4】zstd 走 Rust FFI）。
- 【修4】【修8】iOS：链路已有（fushi_p2p），直接做伞形 staticlib；风险收窄为伞形库本身能否链接（第 0 步）。
- 自动优化在移动端的耗时与内存（第 0 步实测后定门槛与运行条件）。
- 【修6】FSRS-7 钉的是 fsrs-rs 未发版的 git rev，正式发版前 API 或参数个数可能还会变。
  对策：只在 fushi_fsrs 的 C ABI 里暴露；参数组带 algorithmRev，加载时按 rev 校验参数个数；
  发版后若参数形状变了，旧参数组判不合法、回退默认参数并重新优化（与 #4278 的处理同一条路）。
  第 0 步编不过就按「FSRS-7 的退路」先只出 FSRS-6。
- 【修5】【修8】serverTime() 预计七个后端都能实现（列目录元数据里都有服务端时间）；真有实现不了的，那个后端不提供 SRS 同步。
- 【修8】事件不可变之后，时钟走错的设备上的 occurredAt / dueAt 不再事后修正，那一个间隔会偏（铁律 F 写明的代价）。
  排序不受影响（钳位），优化器排除可证明有错的事件；用户侧只看到「系统时间不准」提示。
- 【修8】铁律 H 让可编辑字段的合并从「按字段取 HLC 大的」变成「修改记录 + 版本向量 + 三级冲突」，实现与测试量明显增加，
  还要新做冲突裁决界面（编辑页 / 复习页标记）。对策：放进 C-2 的通用同步层统一实现，模拟器断言⑤兜底。
- 【修8】冻结 PR2 前有两项外部依赖：模拟器全绿（A-6），bookKey 跨设备身份的结论（B-1）。任何一项没有结论都不冻结。
- 【修5】起步要读全部现存写入者的快照，设备多、牌组大时首次同步慢；墓碑永久保留，表只增不减（瘦身后每行百字节量级）。
- 【修3】profileUid 是对现有 Profiles 表的迁移，影响 profile 相关的其它同步与备份路径；
  【修4】备份合并的 SRS 规则已定（铁律 E），PR2 仍要查全其它按 profile id / 名字关联的调用方。
- 【修4】快照包含完整合并状态，大牌组的快照文件较大（预估每万张卡 + 十万条日志量级在 PR2 后实测）；
  写快照的频率按批次累计大小触发，不按时间。
- schema 号会被并行 PR 抢，合并时再定版本号。
- 【修8】AnkiConnect 兼容层（PR7）的难点是 Anki 搜索语法：Yomitan 查重依赖 findNotes 的结果，语法支持不全会把
  重复判成「不重复」。对策：子集外的语法明确报错，不返回空结果；按 Yomitan 真实请求做测试。
  另一个风险是「推 Anki」链路误指向 Fushi 自己的兼容端点形成自环，PR7 里有识别与拒绝。

== 对照 Anki 已知问题后的补充（【调研】2026-10-14，来源：ankitects/anki 与 AnkiDroid issue、
   forums.ankiweb.net、community.ankihub.net；编号对应调研总结）==

PR2 前必须定（影响数据格式）：
- 【调研】日志与批次文件带格式版本号；不认识的日志类型、不认识的字段原样保留、原样转写，不解析、不回写、不计统计。
  （Anki 曾两次出事：服务端增量同步丢了新加的 decay 字段 #4169；AnkiDroid 新增的 type=5 重排日志被旧版桌面
  当学习卡写回，统计凭空多出几千次复习。）
  【修4】不认识的日志类型也不参与「最后一条有效日志」的选取（旧版只按自己认识的类型定卡片状态）。
- 【调研】每条日志另存 utcOffsetMin（设备当时的 UTC 偏移）和当时的翻日时刻，统计按小时 / 按天时不受旅行影响（#2062）。
- 【调研】只有 review 类日志进统计和优化器训练集；manual / reschedule / importAnchor / handOff / undo 一律不进
  （Anki 把 Set Due Date 和重排混成同一个 Manual 类型，导致优化器算出 6.67 年的间隔 #3357 / #2998）。
- 【调研】埋卡到期解除不写日志，由 buriedUntilDay 和「今天」直接推出，否则每台设备每天都会产生一批写入。
- 【调研】值没变的编辑不产生改动（no-op 不递增 changeSeq），避免云盘文件被无意义刷新（#5128 误报冲突）。
- 【调研】新增 srs_import_map：Anki 来源的笔记类型 ID → 本地 noteTypeId（【修5】不含结构哈希）。重复导入同一牌组时复用，
  不会每导入一次就复制出一份笔记类型（#2482 / #2693）。笔记身份统一按 guid 匹配
  （【修4】并由 guid 确定性派生 noteId，见铁律 C）。

第一期补进对应 PR：
- PR1：fuzz 保证 Good / Easy 的新间隔不小于上次间隔（#4431）；学习 / 重学步长只允许当天以内（超过 1 天的值
  在设置里直接拒绝），绕开 FSRS 与跨日学习步的冲突（#3712，论坛 48237）。
- PR1：参数加载时按【修6】algorithm + algorithmRev（FSRS-6 21 个、FSRS-7 34 个）校验参数个数与取值范围，
  不合法就回退默认参数并在设置里显示原因（#4278）。
- PR3b / 导出：媒体收集要扫描模板与字段里的全部 src（含 iframe）和下划线开头的静态文件（#1895）。
- PR4：模板渲染器用 rslib 的 template.rs / cloze.rs 测试用例做对拍；卡片 HTML 默认带 lang 属性
  （避免汉字被渲染成中文字形，AnkiDroid #19431）。
- PR6：样本门槛按「过滤之后真正进训练集的条数」判断，不按原始日志条数（#2999）；每次参数变化记一条历史，设置里可看。
- 第三期：新设备起步时逐个批次流式应用，不把整份数据读进内存（iOS 低内存设备首次同步被杀 #5716）；
  媒体一个文件一个对象、不打 zip 包；媒体变更只认内容哈希。媒体删除不跨设备传播，
  由各设备回收不再被引用的文件（【修8】文件变成无引用后保留 30 天宽限期再删，期间恢复笔记图还在；
  同步目录里的媒体按同样规则由写入它的设备回收）（Anki 的媒体删除会传播到其它设备，误删后全线丢图）。

第一期补充（用户 2026-10-14 定，替代「回归模式 / 请假」，零界面）：
- 新卡数按复习量自动调节（PR1 策略 + PR4 选卡）：今天的新卡数 = 每日新卡上限 × 系数。
  到期复习数 ≤ 每日复习预算时系数为 1；超过预算按比例减少；超过预算的 2 倍时当天不出新卡。
  每日复习预算默认 = 最近 30 天日均复习数 × 1.5，【修4】日均只按「有复习的天」平均（中断的天不拉低预算），
  且预算不低于「每日新卡上限 × 10」（长时间中断后回来、只有少量到期卡时照常出新卡）；
  【修4】「数据不足」= 最近 30 天里有复习的天数少于 7 天，此时预算 = 每日新卡上限 × 10。
  挖词带来的新卡同样受这个上限约束，自然解决挖词倦怠，不另做「待学池」。
  【修8】显示（用户 2026-10-14 定；不弹窗，但不再是完全零界面）：新卡被缩减时，在新卡数量旁边说明原因。
  · 牌组列表与复习入口的新卡数显示成「新卡 5 / 20」，旁边一行小字「今天到期较多，新卡减为 5 张」；
    超过预算 2 倍时显示「今天到期较多，暂停出新卡」。没缩减时不显示这行字。
  · 牌组设置的「每日新卡上限」旁说明这条规则（到期多时会自动减少新卡）。
  · Anki 的新卡数是固定的，从 Anki 过来的用户看到数字变少会以为是 bug，所以这行字必须有。
- 复习顺序默认按可提取度从低到高（最快遗忘的先复习），长时间中断后先救最快遗忘的卡。

第二期候选：
- 判重三选一：打开已有卡 / 把新例句追加到已有卡 / 另建一张（多义词）（Yomitan #693）。
- Lapis 常用开关做成原生设置（图片位置、例句假名显示、NSFW 模糊等，Lapis #45）。
（不做：FSRS 健康检查卡片——它检查的步长、参数优化、积压三项在本设计里已被规则或自动化消掉，
  实际保留率本来就在统计页。【修8】原来这里还不做「此设置影响以下牌组」，现在有了牌组树参数继承，
  改 own 牌组的参数会影响 inherit 的子牌组，所以要做，见 PR2 srs_decks「牌组树与参数继承」。）

第四期：共享牌组更新（用户 2026-10-14 定为正式阶段；AnkiHub 的核心痛点）
- 每条笔记记录上游来源（订阅的牌组）和上游基线版本，本地修改存为独立覆盖层，上游更新永远不写覆盖层
  （AnkiHub 靠标签标记「保护」，标签本身会被更新覆盖，用户几小时的修改一次全丢）。
- 收到上游更新时按字段三方合并（基线 → 上游新版 vs 本地）：只有上游改了就更新，只有本地改了就保留，
  两边都改了就保留本地并标记「上游有新版」，用户可在笔记上对比并一键取上游。
  不再有 AnkiHub「保护字段 = 收不到更新」的二选一。
- 上游改字段名 / 调字段顺序：稳定 fieldId 下只是改显示名，不丢数据（AnkiHub 官方原话：改字段名不受支持、会丢数据）。
- 身份统一用 guid；同一 guid 来自多个订阅源时，让用户选跟随哪一个（AnkiHub 同笔记在两个牌组里被来回改）。
  【修4】订阅来的笔记同样按 guid 确定性派生 noteId（铁律 C），多台设备各自拉取同一上游不出重复。
- 排程完全不受上游影响：上游只更新笔记内容，用户的复习日志与卡片状态不动。
- MVP 的 schema 不为此预留列，到时再加（只新增列和表，不破坏现有数据）。

调研中不采纳的建议：
- 「新参数让间隔突变时先等用户确认」：违背「不弹提示」的目标；改由 evaluate 判断（新参数更差就不采用）
  加参数历史兜底。
- 「卡片状态按全部日志的复习时间重放得出」：两台设备离线复习同一张卡时，我们取 sortKey 较晚那条的结果作为到期日，
  不重放；但下一次复习会用全部历史重算记忆状态（铁律 A），所以偏差只持续一个间隔、之后自动收敛。
  换来的是「别的设备只读结果、不需要算出同一个浮点数」。【修4】铁律 A 已据此删掉队列 / 学习步的重放，两处口径一致。
- 【修4】「undo 级联撤销之后基于它算出的日志」：会让另一台设备上真实发生的复习凭空消失，偏差又会在下一次复习收敛，
  不值得。改为写明合并语义（铁律 B）。
- 【修4】「第一期只做添卡 → 复习，把 PR3b / PR6 挪到第二期」（第三轮审查的范围建议）：PR6 进第一期是用户
  2026-10-14 拍板，保持不变；PR3b 是否后移待你决定（它与 PR3a 并行、不在主链路上，后移不影响其它 PR）。
  【修8】已定（用户 2026-10-14）：PR3b 留在第一期，新旧两种格式一起做。
- 【修8】第五轮审查 6.txt 的「把发布时服务器时间 S 写进每条事件的内容」：与「外流前冻结事件」互相矛盾
  （备份 / 导出可以发生在发布之前甚至离线，那时拿不到 S）。改为 S 带外（铁律 F）。
- 【修8】6.txt 的「把词状态整套塞进 PR2」：会拖慢协议冻结。PR2 只定签名与本机索引（B-3），实现在 PR5。
- 【修8】7.md A-1 的「同一事件在多个批次时以 cursor 序最早的那份为准」：cursor 只在单个写入者内部有序，
  跨写入者没有全序，各端结论可能不同。改为取所有已见批次 S 的最小值（铁律 F）。

- 【修6】支持 RWKV（Curve / Instant 都不做；用户 2026-10-14 定）。它在 benchmark 上最准
  （含当天复习 log loss：Instant 0.2660、Curve 0.2974，FSRS-7 0.3206），但有四个问题：
  1. 资源：22.4 万条复习时建状态峰值 1.43 GB，int8 状态缓存 395 MB，重建加保存约 11 秒。
     fork 自己也只在桌面跑，手机端回退 FSRS。Fushi 五端同等，移动端算不了。
  2. 状态覆盖整个集合：回放全部卡的全部复习，一张卡的复习、或同步进来的一条旧复习都会改变其它卡的预测。
     与铁律 A「每张卡只看自己的历史」不同形，要另立本机缓存、标脏重放、回退等规则，还会让同一张卡在两台设备上的
     间隔预览暂时不同。
  3. 许可：实现代码是 AGPL（fork 的 rslib），权重所在的 srs-benchmark 仓库没有声明许可证，再分发许可不明。
  4. RWKV-Instant 不产出权威到期日，要另配回退计算器写到期日，到期日有两个来源，违反铁律 A / G。
  以后若 fsrs-rs 或 Anki 官方提供可在移动端运行、许可明确的版本，再重新评估。
  schema 不为它预留列：algorithm 是枚举文本，以后加值不破坏现有数据；铁律 F 的回退规则已覆盖「本机不认识的算法」。
  从 fork 导入的 RWKV 预设按 PR3b 的映射改用 FSRS。
- 【修6】「FSRS-7 未发版，先默认 FSRS-6 等正式版」：默认参数的质量差距太大（含当天复习时 0.3399 对 0.3842），
  而钉 git rev 的风险已经由 C ABI 隔离 + algorithmRev 校验 + 退路兜住，不值得等。
- 【修5】第四轮审查（Codex）的 9 条全部采纳，没有不采纳项；Next Scope 要求的「不可变事件格式、完整排程结果格式、
  导入身份迁移表、同步恢复 / GC 状态机」分别落在铁律 C、铁律 A、铁律 C、第三期「传输」。

== 【修8】已拍板事项（原「待定」）==

1. （已定）日界默认 4 点，统计页也默认 4 点（用户 2026-10-14），见铁律 G。
2. （已定）PR3b 留在第一期，新旧两种格式一起做（用户 2026-10-14）。
3. （已定）标志类与设置类冲突用方案 C：最后修改自动生效，被覆盖的值进同步冲突记录，可逐条 / 整组 / 全部改回（用户 2026-10-14），
   见铁律 H。
目前没有待定项。

== 下一步 ==

【修8】替代修订版 5 的「再做一轮协议复核」：不再做人工反例审查，改由模拟器验证（A-6）。
1. 第 0 步：先做 A-3 的 mod 实测，再做其余验证（含 B-1 的 bookKey 身份核对）。
2. 开 worktree，把本版写成设计文档 docs/specs/2026-10-14-fushi-srs-design.md（C-6）。
   审查记录 docs/reviews/2026-10-14-project-review.md 目前只在未合并分支 codex/srs-rev4-review（ccb085d620）上，
   一并合进 develop，或在 spec 里改引那个提交；第五轮审查（7.md）也作为审查记录放进 docs/reviews/。
3. PR1 先交付 fushi_srs 的模拟器，跑过铁律 F / H 的新方案与全部历史反例。
4. 模拟器全绿、B-1 有结论后，冻结 PR2 数据契约（连同 B-1～B-3）。
```
