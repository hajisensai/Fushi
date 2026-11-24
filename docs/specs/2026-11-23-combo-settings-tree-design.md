# 组合（Combo）设置树与共享复习库：设计与分期

日期：2026-11-23
拍板来源：拍板台 `design-combo-node-split`（做）、`design-srs-shared-library`（方案 a）
状态：阶段 1 已实现（PR #4268）；阶段 2 已实现（见 §3.2，PR #4306）；阶段 3 已实现（见 §3.3）；阶段 4 已实现（见 §4.5）；阶段 5 已实现（见 §4.6）；阶段 6 已实现（见 §5.1）

## 1. 要解决的问题

现状（已在代码核实）：

- Profile 是整包：`profile_settings` 存一整份快照（category ∈ `pref` / `anki` / `dictionary_meta` /
  `remote_dictionary_meta`，旧快照还有 `dictionary` / `reader`），`ProfileRepository.applyProfile`
  切换时整份覆盖活偏好，「快照里没有的键」直接删掉活偏好。
- 绑定三层：作品 `book_profiles`、语言 `language_profiles`、媒体类型 `media_type_profiles`。
  语言 / 媒体类型命中时整包切换激活配置；作品命中时走会话覆盖层 `WorkProfileScope`，只接管
  `WorkProfileScope.isWorkScopedPrefKey` 那些键 + Anki 字段 + 查词词典过滤。
- 旧解析顺序（`ProfileRepository.resolveBoundProfileId`）：**作品 → 语言 → 媒体类型**。
- 复习数据按 Profile 归属：集合身份是 `profiles.uid`；同一 guid 落到另一个 Profile 的副本笔记类型
  时被实体归属闸拒掉（`srs_apkg_import.dart` 的 `SrsImportIssueReason.otherProfileNoteType`，
  BUG-5005），所以同一份 .apkg 导入第二个 Profile 整批跳过。

后果：想「视频制音频卡、漫画小说制句子卡」（工单 #336）只能拆两个 Profile，词典、主题、复习库
跟着一起分开；给一部作品换字体也得整包换。

## 2. 目标模型

### 2.1 设置树

设置组织成一棵树：模块 → 子组 → 叶子。**继承 / 拆分的最小单位是叶子**，不是单个键：
同一叶子里的键必须一起取自同一层。典型例子是笔记类型与字段映射——字段映射只对它那个笔记类型
有意义，两者分别取自不同层会拼出无效的制卡目标。

阶段 1 登记的树（`fushi/lib/src/profile/combo/fushi_settings_tree.dart`；节点 id 是持久化名，冻结）：

| 叶子 id | 含义 | 认领的键（引用单一真相源） | 可在哪些层拆 |
|---|---|---|---|
| `mining.target` | 制卡目标（Fushi 复习 / Anki） | pref `srs_mining_target` | 作品 / 媒体类型 / 语言 |
| `mining.deck` | 牌组 | anki `selectedDeckId/Name`；pref `srs_mining_deck_id` | 同上 |
| `mining.note_type` | 笔记类型与字段映射 | anki `selectedNoteTypeId/Name`、`fieldMappings`；pref `srs_mining_note_type_id`、`srs_mining_field_mappings` | 同上 |
| `mining.tags_dupes` | 标签与查重 | anki `tags*`、`allowDupes`、`overwriteScope`、`duplicateScope` | 同上 |
| `mining.card_content` | 卡面内容 | anki `compactGlossaries`、`embedMedia` | 同上 |
| `appearance.theme` | 主题 | `ThemeNotifier.isProfileThemePrefKey` | 同上 |
| `appearance.fonts` | 字体 | 阅读器命名空间里的 `ReaderSettings.fontPersistenceKeys` | 同上 |
| `appearance.reader_style` | 阅读样式 | 阅读器命名空间 `src:reader_fushi:*`，除字体与应用级键 | 同上 |
| `appearance.subtitles` | 字幕 / 悬浮歌词样式 | `WorkProfileScope.videoSubtitleStylePrefKeys`、`floating_lyric_*`（窗口位置除外） | 同上 |
| `dictionary` | 词典启用与顺序（缺行逐行继承，见 §2.2） | 整个 `dictionary_meta`、`remote_dictionary_meta` category | 同上 |
| `input.shortcuts` | 快捷键等应用级输入映射 | `WorkProfileScope.appLevelReaderPrefKeys` | 媒体类型 / 语言 |
| `srs.library` | 复习库归属（合成项） | `combo/srs_library` = `shared` \| `own` | 作品 / 媒体类型 / 语言 |
| `other` | 其他设置（兜底） | 未被认领、又非设备本地的键 | 媒体类型 / 语言 |

- 设备本地 / 凭据 / 本安装状态键（`ProfileKeys.isExcludedPref`）不归组合管理，照旧只在活偏好里。
- 「可在哪些层拆」保持今天的行为边界：作品层只能拆今天作品会话已接管的那些（作品级键 + Anki +
  词典）；`other` 与快捷键今天只随整包切换生效，新模型也不允许在作品上拆。
- 新加设置：落进已有叶子的匹配规则，或新开叶子；不登记会落 `other`。守卫测试
  `fushi/test/profile/fushi_settings_tree_test.dart` 查「作品级键必须落在作品层可拆的叶子」「Anki
  快照字段必须落在制卡叶子」「真实快照行至多被一个叶子认领」。

### 2.2 组合与继承

- 只有一个**默认组合**，所有叶子都有值（合成叶子缺值时按树上的默认补齐）。
- 其他组合只记录**单独设置的叶子**，每个被拆的叶子带它那组键的完整值；叶子内缺的键 = 在这一层
  「未设置」（代码默认值），与今天 `applyProfile` 删掉「快照里没有的键」同义。
  例外：一行一个独立对象的叶子（`absentKeysInherit`，目前只有 `dictionary`）缺的行逐行继承下一层——
  Profile 只拥有词典「怎么排、开不开」，不拥有「装了哪些」（BUG-1994，`applyProfile` 对快照里没有的
  词典行保持当前值）。迁移比较只看快照里有的行：快照缺行不算差异，否则每个在新词典导入前建的 Profile
  都会被误判成「单独设置了词典」；默认组合此刻没有、快照里有的行算差异（阶段 3 改：服务器词典目录
  还没拉到时那一行不在默认组合里，丢掉就丢了这份配置对它的选择，BUG-4693 的对账读的正是它）。
- 生效顺序：**作品 → 媒体类型 → 语言 → 默认**。每个叶子各自往下找，取第一个单独设置了它、且该
  叶子允许在那层拆的层；越层拆分被忽略并报告（`ResolvedSettings.ignoredSplits`）。
- 编辑：改一个继承中的值自动拆出所属叶子（复制当前生效值再改）；「恢复继承」撤销拆分；可以对
  子组整体拆 / 恢复（能拆的叶子全拆）。作品上可直接拆，生成一个挂在作品上的匿名组合，之后可以
  「存成组合」给别的作品复用。
- 作品里有「最终生效值」表：每个叶子的值与来源层 / 来源组合（`ResolvedSettings.sources`）。

> **有意的行为变化**：媒体类型从低于语言改成高于语言（拍板定的顺序）。同时绑了语言与媒体类型
> 且两者冲突的用户，迁移后媒体类型那份生效。迁移报告要列出这类冲突（见 §3.3）。

### 2.3 实现位置

- 通用结构与解析（`SettingsTree`、`resolveCombos`、`splitNode` / `restoreInheritance` /
  `writeSetting` / `diffAgainstDefaults`）在 `packages/fushi_engine/lib/profile/combo/`：纯 Dart、
  无 I/O，app 与无头服务端（`fushi_server` 的 profile hub）共用，和 `profile_document.dart` 同处。
- 不放 Rust：这是 Drift 持有的偏好表上的语义层，无重计算、无大块数据跨边界；状态（偏好 / 快照）
  本来就在 Dart 侧的 Drift 里，搬进 Rust 只会多一份镜像。符合「Rust 胖核心」规则的适用条件判断
  （规则针对新**计算型**子系统）。
- Fushi 的具体登记在 app（`fushi_settings_tree.dart`），因为键集合的单一真相源（主题、作品级键、
  Anki 字段、字体键）都在 app。

## 3. 持久化与迁移（阶段 2～3）

### 3.1 持久化名冻结

表名、列名、偏好键、category 一律不改：`profiles`、`profile_settings`、`media_type_profiles`、
`book_profiles`、`language_profiles` 原样沿用，只改语义层。新增的持久化名只有：

- `profile_settings` 新 category `combo`（`kComboSyntheticCategory`）：
  - key `srs_library`：复习库归属合成项；
  - key `srs_shared_uid`（只在默认组合上）：共享复习库的集合 uid（§4.1）；
  - key `split:<叶子 id>` value `1`：这个组合单独设置了该叶子（区分「拆了但叶子内键都未设置」与
    「继承」）；
  - key `role` value `default` | `named` | `work_local`：默认组合 / 用户建的普通组合 / 作品上直接拆出
    的匿名组合（UI 不列入组合列表）。**有 `role` 行 = 这份 Profile 已是组合格式**，没有 = 存量整份
    快照（阶段 2 加了 `named`：否则「什么都没拆」的普通组合没有任何 `combo` 行，会被误认成存量快照）。
    默认组合不写 `split:*`（所有叶子都有值）。编解码在引擎 `combo_rows.dart`（服务端共用）。
- 非默认组合的 `profile_settings` 只保留被拆叶子的行 + 上述 `combo` 行。

### 3.2 读写路径（阶段 2，已实现）

实现落点：`fushi/lib/src/profile/combo/combo_repository.dart`（`ComboRepository`）、
`packages/fushi_engine/lib/profile/combo/combo_rows.dart`（行编解码）、`ProfileRepository`
（`currentSettings` / `resolveBindingLayers` / `loadWorkComboView` / 写入路由）、`WorkProfileScope`
（`enterCombos`、按叶子来源路由写入）。

- 存量整份快照（迁移前的全部 Profile）**读时**按 `diffAgainstDefaults` 化成差异再参与解析。单层时
  与旧版「整包取快照」的生效值逐键一致（与默认相同的叶子取默认 = 同一个值），多层时逐叶子往下找——
  媒体类型 / 语言层由此不再整包切换。阶段 3 把这份差异一次性落库后就不再走这条。
- 作品会话写入：落到该键所属叶子的**来源组合**；叶子在继承默认组合时落到优先级最高的绑定层（在
  那里拆出）——作品会话永远不写全局。Anki 只写相对此刻生效值变了的字段，按叶子分组落库。
- Android 弹窗进程：`work_profile_session` 的值改成 `<作品层>,<媒体类型层>,<语言层>:<写入次数>`，
  弹窗按同样的层重新解析；旧格式 `<id>:<次数>` 当作作品层。
- 会话制卡落哪份复习副本（过渡）：复习落点的牌组 id（`mining.deck`）与笔记类型 id
  （`mining.note_type`）只在所在副本里有意义，取用户选过具体 id 的那几个叶子的来源（都没选过则取
  两个叶子的来源），多个候选取优先级最高的层（`WorkProfileSession.miningProfileId`）；只看牌组
  叶子会让「牌组用默认、笔记类型是绑定配置自建的」落进激活副本、自建类型回落 Lapis。**阶段 4 已
  换成 `srs.library` 解析，`miningProfileId` 已删**（§4.5）。
- `resolveProfileId` / `resolveBoundProfileId`（浏览器扩展按「浏览器」媒体类型选一份配置）顺序同步
  改为 作品 > 媒体类型 > 语言。
- **阶段 2 刻意没动、留给阶段 3 的点（阶段 3 已做，见 §3.3）**：生产路径不产生组合格式的行（只有 `ComboRepository.saveDocument`
  会写，供迁移 / 编辑页调用），所以 `applyProfile` / `snapshotCurrentSettings` / `copyProfile` / 导出 /
  备份合并仍按整份快照处理行。阶段 3 迁移落库前必须先改它们：切换默认组合时 `applyProfile` 要按
  「默认之上的生效值」应用组合格式的 Profile（否则 prune 会删掉没拆的设置），`snapshotCurrentSettings`
  只用于默认组合（否则会把差异文档覆盖回全量快照）。`loadSettingsView` 已能读组合格式。

原设计要点：

- 组合仓库层：`ComboRepository` 读写上述行，产出 `ComboDocument` / 默认值 map；写入一律经
  `writeSetting` / `splitNode` / `restoreInheritance`，事务内落库。
- 运行时解析：打开作品时按 (作品 uid, 媒体类型, 归一化语言) 组装最多三层，`resolveCombos` 得到
  生效值，交给现有作品会话覆盖层（`WorkProfileScope`）——会话的 `prefs` / `ankiOverrides` / 查词
  视图改由解析结果填充，读侧消费者不变。媒体类型 / 语言层不再整包切换激活配置
  （`applyProfile` 只用于默认组合）。
- 不在作品里（首页、设置页）时生效值 = 默认组合；`active_profile_id` 语义收窄为「默认组合 id」。
- 扩展 Profile 适配层（`extension_profile_adapter.dart`）、浏览器扩展 / 互联的「选一个配置」只读
  视图（`loadSettingsView`）改为解析某个组合在默认之上的生效值。
- 按配置记的本机停放值（`perProfileDeviceLocalPrefs`）按组合 uid 停放，规则不变。

### 3.3 迁移（阶段 3，已实现）

实现落点：规划是引擎纯函数 `packages/fushi_engine/lib/profile/combo/combo_migration.dart`
（`planComboMigration` + `ComboMigrationReport`）；落库在 `ProfileRepository.normalizeCombos`
（`ensureDefaultProfile` 末尾调，只在主进程）；报告提示 `combo_migration_report_dialog.dart`（首页首帧
串行弹框之一 + 配置管理页「组合迁移报告」行）。与下面原设计的差异：

- 不挂在 Drift schema 升级里（那里拿不到 Anki 设置 / 复习库），而是**幂等的归一**：检测到「没有
  默认组合」「有存量快照」「多于一份默认组合」任一种就跑，所以旧备份恢复、合并导入带进来的存量
  快照 / 第二份默认组合下次启动（或进配置页）也会收敛。多余的默认组合降级成差异，它的共享库不是
  留下那份的共享库时拆成 `srs.library = own`。`role` 值不认识（更新版本写的）的 Profile 一行不碰。
- 迁移备份：原行（剔凭据 / 设备本地偏好）整份写 `<support>/combo_migration_backups/combo_<ms>.json`，
  写不了就整个不迁；落库在一个事务里。
- 报告存本机偏好 `combo_migration_report`（JSON）+ `combo_migration_notice_pending`，两键不进快照。
- 复习库判据用 `srsProfileHasUserData`（铁律 E 的「有数据」：笔记、自建牌组、改过的预设 / 内置
  笔记类型、复习日志都算），比原文「有用户笔记」宽——只建了牌组的 Profile 不会被当成空的并进
  共享库。复习库此刻打不开（换代中），或本机没有复习库文件、主库里却还留着没搬过的协议 1
  复习表（`srsLegacyMainDatabasePending`：数据在，只是本版本读不了）时设置照迁、默认组合不写 `srs_shared_uid`（= 待定标记），下次
  能打开时只补复习库归属并补进报告。只有一份 Profile 时不需要读复习库。
- 迁移后的读写路径：`applyProfile` 对组合格式按「默认组合之上的生效值」应用；`snapshotCurrentSettings`
  对组合格式只写回相对默认组合不同的叶子（`rebaseComboDocument`：原来拆了的保持拆分），默认组合 /
  存量快照照旧全量但保留 `combo` 元数据行；`createProfile` 新建普通组合（全部继承）；`copyProfile`
  复制默认 = 什么都不拆的普通组合，复制组合 = 同样的拆分，副本绝不带走 `role = default`；导出组合 =
  生效值全量（仍是 v1 分享格式，`combo` category 不出本机），导入 / 覆盖导入组合 = 相对默认组合的
  差异（覆盖时保留目标的复习库归属），覆盖默认组合保留身份行；删除默认组合 = 接班的那份（激活
  配置，否则最早建的另一份）提升成默认、其余组合改基到它（生效值不变），共享库指向被删那份时
  改指接班者。
- 激活配置不一定是默认组合：切到一个组合时活偏好 = 默认组合 + 它的拆分，ComboRepository 解析
  绑定层时仍以活偏好（激活配置的生效值）为底。

原设计：

1. 选默认组合：`profile_fallback_id` 有值取它，否则取 `active_profile_id`；都没有取 id 最小的
   Profile。先对激活 Profile 做一次 `snapshotCurrentSettings`，保证默认组合是最新活偏好。
2. 所有快照先过 `normalizeLegacySettingKey`（旧 `dictionary` / `reader` category → 今天
   `applyProfile` 落到的 pref 键）。
3. 其余每个 Profile：`diffAgainstDefaults(默认快照, 它的快照)` 得到被拆叶子，原地改写它的
   `profile_settings`（只留被拆叶子的行 + `combo/split:*`）。原快照整份先拷进迁移备份（备份目录
   随现有 schema 迁移备份机制走），失败整体回滚。
4. 复习库（`srs.library`）按 §4.2 决定每个 Profile 是 `shared` 还是 `own`。
5. 迁移报告（首次启动提示一次，可在配置页重看）：每个组合拆了哪些叶子；「语言与媒体类型绑定同
   一类内容且冲突」的条目（§2.2 的行为变化）；被忽略的越层拆分。

验证：迁移单测覆盖「单 Profile」「多 Profile 无绑定」「三层绑定全有」「旧 category 快照」「快照含
设备本地键」；往返断言 = 迁移前每个绑定场景下 `applyProfile` 的生效值 == 迁移后 `resolveCombos`
的生效值（越层与顺序变化的条目除外，单列断言）。

## 4. 复习库（`design-srs-shared-library` 方案 a，阶段 4～5）

### 4.1 模型

- 复习集合身份仍是 uid（不改 SRS schema 的归属列）。**共享库的集合 uid 记在默认组合的
  `combo/srs_shared_uid` 行**；新装与普通迁移下它就是默认组合自己的 uid，§4.2 的特例可指向别的
  Profile 的 uid，从而不必改写任何已发布集合的 uid（避开铁律 E 的改 uid 断链问题）。
- `srs.library` 叶子：`shared`（默认）→ 制卡 / 导入 / 复习落共享库；`own` → 用该组合自己的 uid
  当集合身份，沿用现有实体归属闸（BUG-5005 的行为在独立库之间保留）。
- 解析出的集合 uid 只由 `resolveCombos` 的 `srs.library` 叶子 + 来源组合 uid 决定：来源是默认
  或值为 `shared` → `srs_shared_uid`；值为 `own` → 来源组合 uid。
- .apkg 导入：目标是解析出的集合 + 目标牌组，不再出现「另一个 profile」；`other-apkg-dup-profile`
  在共享库下不再发生（独立库之间仍按现有归属闸记冲突）。
- 复习页：默认显示共享库；存在独立库时顶部多一个库切换（不新增导航入口）。

### 4.2 迁移规则（存量自动保持分开，不打扰）

- 只有一个 Profile，或多个 Profile 但只有一个有复习数据（判据：有用户笔记，与铁律 E「无用户
  笔记」同一判据）：直接并入共享库——`srs_shared_uid` 写成有数据那个 Profile 的 uid（它不是
  默认组合也一样），不移动、不改写任何复习行。
- 多个 Profile 各自都有复习数据：除默认组合外，每个都写 `srs.library = own`（拆出独立复习库），
  数据不合并、不丢。

### 4.3 手动「合并进共享库」（阶段 5，新功能面）

- 入口在组合编辑页的 `srs.library` 叶子：「合并进共享库」。
- 同 guid 笔记：按 FSRS 状态取较新的一份（最后复习时间 / HLC 较新），复习日志全部保留去重；
  笔记类型不同或字段内容冲突的列出来让用户逐条确认（默认保留共享库那份）。
- 合并在 Rust 存储核心里做（`native/fushi_srs` 胖核心，粗粒度命令 `merge_collection(from, into,
  resolutions)` + 进度事件），Dart 只呈现冲突表；合并结果作为 gen4 同步事件发布，对端按事件重放，
  不靠整库覆盖。
- 合并完成后该组合 `srs.library` 恢复继承（`shared`），旧集合打墓碑。

### 4.4 同步 / 备份 / 互联

- gen4 实体归属：归属仍按集合 uid，协议不改字段；共享库只是「更多组合解析到同一个 uid」。
- 备份合并：`profile_settings` 的 `combo` category 与其余行同规则跟随 `profiles`
  （`table_rules.part.dart` 里 `profile_settings` 的规则不变）；合并时两边同一组合（同 uid）的
  `split:*` 取并集、叶子值按现有 LWW。两边各自有默认组合时：本机默认保持默认，对端默认降级为
  普通组合并重新做一次 `diffAgainstDefaults`。
- 互联 `/api/interconnect/profile` 与分享 JSON（`profile_document.dart`）：`formatVersion` 升到 2，
  载荷带「生效值全量 + 拆分叶子列表」；导入为新组合时按本机默认组合重新 diff。v1 文件照旧导入
  （整份当快照，导入时 diff）。服务端 profile hub 用同一份引擎代码。

### 4.5 阶段 4 实现（已实现）

- 解析规则只写一次：引擎 `packages/fushi_engine/lib/profile/combo/combo_srs_library.dart`
  （`ComboSrsLibraries`，纯函数）；app 读口 `fushi/lib/src/profile/combo/srs_library_resolver.dart`
  （`loadComboSrsLibraries` / `resolveSrsLibraryUid`），消费方不再拿「激活配置的 uid」当集合身份。
- 「待定」（还没有默认组合，或默认组合没写 `srs_shared_uid`）时取激活配置自己的 uid（迁移前语义），
  不在没定的时候把卡写进可能被判成别人独立库的集合。
- 制卡：本机制卡（`_readSrsMiner`）按 作品会话绑定层 + 激活配置 解析；替对端 / 浏览器扩展制卡按
  所选配置解析（`_hostProfileMiningMiner`）；互联主机的「复习库」目录列共享库 + 独立库。
- 复习页 / .apkg 导入：`srsStoreProvider` 打开 `SrsLibraries.viewedUid`（默认 = 激活配置解析出的库）；
  导入落复习页正看的那份库，所以没拆 `srs.library` 的组合导入同一份 .apkg 落同一个集合，
  `otherProfileNoteType` 冲突只在独立库之间出现。存在独立库时牌组列表顶部出库切换
  （`srs_library_switcher.dart`，只在本次运行内记选择）；制卡落点选项与偏好 ID 归一只对激活配置的库做。
- 采用对端 uid（铁律 E，`adoptProfileUid`）时共享库指针同事务改指新 uid。
- **承载共享库的 Profile 不能删**（`ProfileHostsSharedSrsLibraryException`，配置页确认框写明原因）：
  共享库的集合挂在它的 `profiles` 行上，删了所有没拆独立库的组合的复习一起没了。阶段 3 的「删默认
  组合时共享库改指接班者」只剩共享库挂在别的配置上 / 待定的情形会走到。

### 4.6 阶段 5 实现（已实现）

与 §4.3 原设想的出入（以代码为准）：

- 胖核心是 `native/fushi_fsrs`（§4.3 写的 `native/fushi_srs` 不存在）。命令在
  `native/fushi_fsrs/src/store/gen4/cmd/collection_merge.rs`：`collection_merge_preview`（读快照，规模 + 冲突表）、
  `collection_merge`（一个写事务）、`collection_merges` / `collection_merge_done`（墓碑）。Dart 薄封装在
  `packages/fushi_engine/lib/srs/srs_collection_merge.dart`，app 编排在 `fushi/lib/src/srs/srs_library_merge.dart`。
- 「同 guid 取较新的 FSRS 状态」不再需要单独挑：笔记 ID 按 guid 内容寻址，卡的调度只由复习日志推出，
  合并走与「合并配置」同一条路（`Join` 操作 + 操作并集 + `absorb_foreign`），两边复习日志全部保留、按 HLC 重放，
  调度自然等于两边复习合起来的结果。真正要人选的只有 LWW 寄存器：字段、笔记类型、删除状态不同的列成冲突，
  默认保留共享库；选了独立库那份的，事务里以本机新写（`chg`）重新写回，随同步发布。「哪边改得更晚」只作提示。
- 没有进度事件：整个合并是一个写事务（失败全部回滚），UI 显示不定进度条。
- 墓碑：内核在同一事务里写 `srs_meta` 的 `collection_merged/<from>`；app 把该组合 `srs.library` 恢复继承后
  `collection_merge_done` 删掉。中途中断时，进配置管理页会补做（`SrsLibraryMerger.finishPending`）。
  独立库的媒体目录合并前拷进共享库（不覆盖同名），收尾后删掉原目录与 RWKV 快照。
- 入口暂放在配置管理页的配置行（「合并进共享复习库」按钮，只对拆了独立库的组合显示）；组合编辑页属阶段 6，
  届时挪到 `srs.library` 叶子。
- 未做：别的设备上还持有独立库集合时不会自动跟随合并（那边重放 `Join` 后数据已在共享库，但组合仍指向独立库，
  需在那台设备上也点一次合并，已无冲突）。

## 5. UI（阶段 6）

- 配置管理页：只有默认组合时不出现「组合」概念（设置页照常编辑默认值）。
- 组合编辑页：设置树逐节点标「继承」/「单独设置」，改继承值自动拆，「恢复继承」撤销；子组可整体
  拆 / 恢复。越层不可拆的节点灰掉并写原因。
- 作品「⋯」：直接拆节点、存成组合、「最终生效值」表（值 + 来源层 / 组合）。首页头像右边的配置
  胶囊（PR #4250）的作品内来源显示随这一期做。
- 动效：列表错峰 `FushiEntranceScope` + `fushiStaggeredItemBuilder`，按压 `FushiPressScale`；MD3 与
  Apple 两套。分段选择用 `adaptiveSegmentedButton`。i18n 一律 `i18n_sync.dart --add`。
- ctl 操作目录：新增组合读写路由要同时写 `op_descriptions_settings.dart`；AI 写操作（拆分 / 恢复 /
  合并）必须可撤销。

### 5.1 阶段 6 实现（已实现）

与 §4.4、§5 原设想的出入（以代码为准）：

- **组合编辑页** `fushi/lib/src/pages/implementations/combo_editor_page.dart`：配置管理页每行多一个「编辑组合」（只有一份
  配置时不出现）。按树分节，叶子行标「继承 / 单独设置」，点行展开看这组键的生效值；「单独设置」复制此刻的生效值，
  「恢复继承」撤销；子组有两个以上能拆的叶子时多一行「全部单独设置 / 全部恢复继承」。默认组合只读。
  - **改值本身仍在各设置页里做**，不在编辑页另做一套值编辑器：组合是激活配置时，改任何设置在写回时自动拆出它所属
    的项（`snapshotCurrentSettings` → `rebaseComboDocument`，阶段 3 已有）；编辑页对激活组合按活偏好改基显示拆分状态，
    非激活的给「切换到这个组合」。激活组合「恢复继承」后重新应用（活偏好换成继承来的值）。
  - 能不能拆按层判：普通组合按「所有叶子都能拆」的媒体类型层（绑在作品上时越层的拆分由解析器忽略，行上写明「绑在
    单部作品上时这一项不生效」）；作品匿名组合按作品层，不能拆的写原因。
  - 复习库归属有自己的动作：「拆成独立复习库」（确认框），已拆的「合并进共享复习库」（阶段 5 的合并流程，入口从配置行
    挪到这里）。普通的恢复继承不撤复习库拆分——独立库只能经合并回到共享，否则复习数据会落到看不见的集合里。
- **作品「作品配置」**（书架菜单，`reader_history/dialogs.part.dart` + `profile/combo/work_combo_panel.dart`）：绑定列表
  下面是「最终生效值」表——每个叶子的生效值与来源（默认 / 作品 / 媒体类型 / 语言 + 组合名），越层被忽略的拆分单列原因。
  作品层空着或挂的是匿名组合时可直接「单独设置 / 恢复继承」：第一次拆建一个 `role = work_local` 的匿名组合（名「作品：
  <标题>」）并绑上，复制这部作品此刻的生效值（含媒体类型 / 语言层）；全部恢复后撤绑定、删掉它；作品改绑别的组合或跟随
  默认时原匿名组合也删掉。「存成组合」= 改名并把角色改成 `named`，列进配置列表。匿名组合不出现在任何配置列表里
  （`listedComboProfiles`，引擎 `combo_profiles.dart`：配置管理、首页配置胶囊、悬浮球切换、浏览器扩展选配置共用）。
  作品挂的是普通组合时不在作品里直接改（别的作品可能共用），提示去配置管理编辑。
  书的媒体类型 / 内容语言判据抽成 `profile/book_profile_context.dart`，开书进作品会话与这里共用。
- **分享 JSON v2**（引擎 `profile_document.dart` + `combo/combo_share.dart`）：`formatVersion = 2`，`settings` 仍是生效值
  全量，新增 `splitNodes`（导出方单独设置的可比较叶子，复习库归属不出本机）。导入为新组合（及覆盖导入组合）时
  `comboDocumentFromShared` = 与本机默认不同的叶子 ∪ 对方声明的叶子（同值也保持单独设置）。v1 文件照旧（整份当快照
  diff）；v2 缺 `splitNodes` 视为空。服务端 profile hub 原样寄存 / 转出 `splitNodes`。**旧版本 app 收到 v2 文件会按
  「版本不兼容」拒收**（版本判据本来如此）。
- **备份合并**（`backup_merge_engine.dart` 的 `_mergeProfileSettings`，规则本体在引擎 `mergeComboProfileRows`）：Profile 仍按
  名字对应（§4.4 写的「同 uid」与现有按名合并不符，按名沿用）。本机默认组合原样保留；对端默认组合 / 整份快照按本机默认
  组合 diff 成普通组合，对端默认组合自己承载共享库（`srs_shared_uid` = 它自己的 uid）时拆成独立复习库；同名组合单独设置
  的叶子取并集，两边都拆了的叶子**整组以本机为准**（行没有时间戳，§4.4 写的 LWW 实际就是现有的「本机为准」；叶子是原子的，
  不逐键混拼）；对端的共享库指针与复习库归属不带进来。本机还没迁移时照旧键级补缺，但不带对端的 `role = default`。
  另外修了一处：备份复习数据新建的「（备份）」配置以前没有任何设置行，归一时会被当成「所有设置都未设置」整个拆开、复习数据
  也落在共享库外看不见；现在建成「设置全继承 + 复习库为它自己的独立库」的组合。
- 界面文件不 import 视图模型（连着 AppModel，会进最大 import 环）：编辑动作走窄接口 `ComboEditing`（`ProfileViewModel`
  实现），合并流程与配置名输入框由调用方注入。
- 未做（登记在拍板台留言）：首页配置胶囊的作品内来源显示；ctl 操作目录的组合读写路由（AI 可撤销写操作）；冲突多时的批量
  选择（阶段 5 遗留）。

## 6. 分期与登记

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 设置树登记 + 解析 / 编辑 / diff 核心 + 守卫测试，不接 UI、不改持久化 | 已实现（PR #4268） |
| 2 | `ComboRepository`（`combo` category 读写）+ 作品会话改由解析结果填充 + 媒体类型 / 语言层不再整包切换 | 已实现（§3.2） |
| 3 | 一次性迁移（§3.3）+ 迁移报告 + 往返测试 | 已实现（§3.3） |
| 4 | 复习库解析接入制卡 / .apkg 导入 / 复习页 + 迁移规则（§4.2） | 已实现（§4.5；迁移规则随阶段 3 落地） |
| 5 | 手动合并进共享库（Rust 核心命令 + 冲突确认 UI + 同步事件） | 已实现（§4.6） |
| 6 | 组合编辑 UI、作品生效值表、分享 JSON v2、备份合并规则 | 已实现（§5.1） |

阶段 2～6 的登记：拍板台 `design-combo-node-split` / `design-srs-shared-library` 的留言（PR 链接 +
剩余阶段）。每期开 PR 时引用本文件对应章节。
