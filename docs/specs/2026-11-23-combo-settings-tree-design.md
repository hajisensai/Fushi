# 组合（Combo）设置树与共享复习库：设计与分期

日期：2026-11-23
拍板来源：拍板台 `design-combo-node-split`（做）、`design-srs-shared-library`（方案 a）
状态：阶段 1 已实现（本 PR）；阶段 2～6 待做，见文末「分期与登记」

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
  词典行保持当前值）。迁移比较也只看快照与默认组合都有的行，否则每个在新词典导入前建的 Profile 都会
  被误判成「单独设置了词典」。
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
  - key `role` value `default` | `work_local`：默认组合 / 作品上直接拆出的匿名组合（UI 不列入组合
    列表）。默认组合不写 `split:*`（所有叶子都有值）。
- 非默认组合的 `profile_settings` 只保留被拆叶子的行 + 上述 `combo` 行。

### 3.2 读写路径（阶段 2）

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

### 3.3 迁移（阶段 3，schema 升级时一次性跑）

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

## 6. 分期与登记

| 阶段 | 内容 | 状态 |
|---|---|---|
| 1 | 设置树登记 + 解析 / 编辑 / diff 核心 + 守卫测试，不接 UI、不改持久化 | **本 PR** |
| 2 | `ComboRepository`（`combo` category 读写）+ 作品会话改由解析结果填充 + 媒体类型 / 语言层不再整包切换 | 待做 |
| 3 | 一次性迁移（§3.3）+ 迁移报告 + 往返测试 | 待做，依赖 2 |
| 4 | 复习库解析接入制卡 / .apkg 导入 / 复习页 + 迁移规则（§4.2） | 待做，依赖 3 |
| 5 | 手动合并进共享库（Rust 核心命令 + 冲突确认 UI + 同步事件） | 待做，依赖 4 |
| 6 | 组合编辑 UI、作品生效值表、分享 JSON v2、备份合并规则 | 待做，依赖 2～3 |

阶段 2～6 的登记：拍板台 `design-combo-node-split` / `design-srs-shared-library` 的留言（PR 链接 +
剩余阶段）。每期开 PR 时引用本文件对应章节。
