# 复习卡片浏览器重设计（2026-11-04）

所有者 2026-11-04 定稿：方案 A「搜索积木 + 富卡片」为默认视图，C「出处」为顶栏切换的第二视图，B 的「健康条」与「表格模式」并入 A 的桌面版。三期一次做完。
设计稿：`fushi/build/srs_browse_design/refined.html`（本地，不入库；结构说明见下文，实现以本文为准）。

## 1. 页面结构

- 顶栏（`FushiFloatingTopBar`；Apple 走 `FushiPageScaffold` actions）：返回 · 标题「卡片」· 视图分段「列表 / 表格（仅宽屏）/ 出处」· 新卡 · 排序 · 撤销 · ⋯。多选时整条换成「已选 N 张 / 全选 / 取消」。
- 搜索积木条：查询字符串的结构化视图。积木种类：牌组（含 / 排除）、状态（is:）、标签、属性（prop:）、出处（src:）、自由文本。点积木弹底部面板编辑（包含 / 排除 + 勾选项 + 「将筛出 N 张」实时计数），× 删除；打字出补全（牌组 / 标签 / 笔记类型 / 状态 / 常用属性 / 「写成语法」）；用户粘贴语法自动拆成积木，拆不动的留成一块「语法」积木。最终仍拼成一条查询交给内核，语法是唯一真相。
- 快捷视图（带计数，一次 `browse_counts` 算完）：今天到期 `is:due`、最近挖的 `added:7`、难卡 `prop:lapses>=4`、问题卡 `is:emptyfield or (-has:audio note:"<Fushi 卡片类型名>")`（仅 Fushi 卡片类型参与缺音频判断，见 §2.3）、已暂停 `is:suspended`，后面跟用户保存的视图。
- 内容：
  - 列表：富卡片（正面大字 + 两个字段摘要 + 状态标签 + 保持率条 + 下次到期 + 出处小标 + 旗标）。手机左滑露出「暂停 / 旗标」，长按进多选；宽屏两列。
  - 表格（宽屏）：可选列（拖动排序；选了哪些列、什么顺序存 profile 偏好 `srs_browse_table_columns`，不进复习同步）、列头排序、双击单元格原地改字段（正面 / 两个字段摘要列 / 标签；编辑框是笔记里的原值；Enter 下一行同一格、Tab 下一格、Esc 取消、进撤销栈）、按牌组 / 出处 / 添加日期分组。
  - 出处：按出处分组（`browse_sources`），组头封面 + 标题 + 「今天到期 x / 共 y」+「只复习这一作」；组内磁贴（图片字段缩略图 + 正面 + 例句摘要 + 原声按钮）；没有出处的卡单独一组。
- 健康条（宽屏，有问题才显示）：问题卡、难卡、疑似重复（`is:dupe`）三张卡，点了把积木换成对应条件；问题卡「一键修复」= 对空字段的卡给出删除建议 / 对缺音频的 Fushi 卡跑现有补词音频流程，执行前确认、可撤销。
- 检查器（宽屏右栏；手机 = 全屏详情页，同三页）：
  - 预览：卡面（现有 `SrsBrowsePreview` 渲染）、原声片段播放、例句上下文（取笔记的例句字段，高亮被挖的词）、「回到出处」（现有 `CardSourceLink` 跳转）。
  - 编辑：字段原地编辑（复用笔记编辑器的字段控件，自动保存，进撤销栈）、标签编辑。
  - 历史：下次复习 / 当前保持率 / 间隔·难度 / 复习·遗忘四格，保持率预测曲线（FSRS 遗忘曲线，按复习记录分段），逐次评分记录（`SrsDbStore.history(cardId)`）。
- 保存的视图：名字 + 查询字符串，存 profile 偏好（随备份 / Profile 快照，不走复习同步）。
- Apple 设计系统：大标题、圆角分组列表、系统搜索框里放积木、分段控件切视图。
- 动效：列表 / 磁贴 `FushiEntranceScope` 错峰，按压 `FushiPressScale`、悬停 `FushiHoverLift`，视图切换与检查器页签切换淡入淡出，时长只取 `FushiMotion`。

## 2. 内核契约（Rust `native/fushi_fsrs/src/store/browse.rs` + `search.rs`，Dart `packages/fushi_engine/lib/srs/srs_browse.dart`；搜索解析器在 Dart `packages/fushi_srs/lib/src/search/search_parser.dart`）

都在现有浏览会话里，粗粒度、一次调用拿齐。**注意**：搜索语法由 Dart 解析器解析成语法树 JSON 再交给内核求值（不是 Rust 解析），新搜索词两边都要改。

### 2.1 `browse_rows` 每行新增

| Dart 字段（`SrsBrowseRow`） | 类型 | 含义 |
|---|---|---|
| `intervalDays` | `int?` | 主卡当前间隔天数；新卡 null（学习中为 0） |
| `difficulty` | `double?` | 主卡 FSRS 难度（内核口径 1..10；显示百分比用 `(d-1)/9`）；没有 null |
| `retention` | `double?` | 主卡此刻的可提取度（0..1）：卡所在牌组排程配置的 FSRS 记忆算法与参数（RWKV 牌组用 FSRS-7 影子参数）+ 稳定度 + 距上次复习的天数，与统计页同一个公式（fsrs crate `current_retrievability`）；新卡 / 无稳定度 / 无上次复习 null |
| `addedAt` / `modifiedAt` | `int` | 笔记添加 / 内容修改时刻（毫秒；修改 = 各寄存器生效记录的最大物理时刻，不早于添加，不含作答） |
| `lastReviewAt` | `int?` | 主卡上次复习时刻 |
| `fieldPreview` | `List<String>` | 排序字段（笔记类型第一个字段）之外、按字段顺序前两个非空字段的纯文本（去 HTML / `[sound:]`、trim，各截 120 字符）；不足两个就少给 |
| `fieldPreviewNames` | `List<String>` | `fieldPreview` 每一项来自的字段名（同长度同序）：表格原地改字段摘要列时按名字写回 |
| `imageRef` / `audioRef` | `String?` | 按字段顺序第一个 `<img src>` / `[sound:…]` 的媒体文件名 |
| `sourceKey` | `String?` | 出处分组键（见下）；无出处 null |
| `sourceKind` | `String?` | `SrsSourceKind` 值 |
| `sourceData` | `String?` | 出处原始 JSON（`SrsSourceRef.toJson()` 形状 `{kind, ...data}`）；`row.source` getter 已解析成 `SrsSourceRef?` |

**sourceKey 取法**（内核 `browse.rs` `source_key`；出处存在笔记的 `source` 寄存器里，值是 `SrsSourceRef.toJson()`）：`<kind>:<身份>`，身份按 kind 取：

| kind | 身份字段 |
|---|---|
| `book` | `bookKey` |
| `manga` | `mangaKey` |
| `video` / `audiobook` / `music` | `mediaKey` |
| `onlineNovel` | `sourceId` + `\u001f` + `novelUrl` |
| `onlineVideo` | `sourceId` + `\u001f` + `animeUrl` |
| `game` | `gameId` |
| `web` | `url` |
| 其它（`manual` / `anki` / 未知 kind）或上面字段缺失 / 不是非空字符串 | 退回 `title`（非空字符串时）；再没有就只有 `<kind>`（不带冒号） |

章节、页码、时间区间、字符偏移一律不进键。没有出处（`source` 寄存器空 / 不是带字符串 `kind` 的对象）= null。

编码（粗粒度，一页一条命令）：字符串类进现有 JSON 行（下标 8..14：`fieldPreview, imageRef, audioRef, sourceKey, sourceKind, sourceData, fieldPreviewNames`）；`rows.i64` 每行由 7 个扩到 11 个 i64（追加 `intervalDays, addedAt, modifiedAt, lastReviewAt`，null = `i64::MIN`）；新增 `rows.f64` 每行 2 个 f64（`difficulty, retention`，null = NaN）。字段原文、修改时刻、出处只对**这一页**的笔记从修改记录读一次（会话里按笔记缓存，写入后按笔记失效），不为取行装全库字段。

### 2.2 排序列

新增 `retention`（`SrsBrowseSortColumn.retention`，wire 名 `retention`）：卡片模式 = 该卡可提取度，笔记模式 = 该笔记各卡（有值的）平均；None 不论升降序都排最后。

新增 `source`（`SrsBrowseSortColumn.source`，wire 名 `source`）：按出处键（`sourceKey`）排，没有出处的不论升降序都排最后；表格「按出处分组」用它（组头显示作品名，同名的两部作品按键分开）。第一次用到时整列装出处寄存器（与 `src:` 同一份）。

### 2.3 新搜索词（确切语法）

| 语法 | 含义 |
|---|---|
| `prop:r<0.7`（`=` `!=` `<` `<=` `>` `>=`，值是小数） | 可提取度比较，口径同 `retention` 字段；没有可提取度的卡不命中任何比较 |
| `rated:N` | 最近 N 天内（含今天，按日界）作答过（N ≥ 1 的整数；0 当 1） |
| `rated:N:E` | 且那次作答评分为 E（1 重来 / 2 困难 / 3 良好 / 4 简单）；E 不是 1..4 报语法错误 |
| `is:emptyfield` | **调整**：笔记的排序字段（第一个字段）去 HTML、trim 后为空。原稿写「任一字段为空」——Fushi 卡片类型有一串可选字段（图片、备注、例句翻译…），按「任一」几乎每张卡都命中，「对空字段的卡给出删除建议」会建议删掉正常卡，所以改成主字段为空 |
| `has:audio` / `has:image` | 笔记任一字段原文含 `[sound:` / `<img`（不区分大小写） |
| `is:dupe` | 同笔记类型（未删除）下首字段查重规范形（`anki_dupes` 用的 `dupe_norm`：去 HTML、trim）相同且非空的笔记，≥ 2 条才算 |
| `src:none` | 没有出处 |
| `src:<kind>`（值里没有 `:`） | 出处种类为 kind（如 `src:book`、`src:onlineVideo`；大小写敏感，整值相等） |
| `src:"<sourceKey>"`（值里有 `:`） | 出处键整值相等；Dart 用 `srsSourceQuery(key)` 生成（key 为 null 给 `src:none`），里面的 `"` `\` `*` `_` 已转义 |

- 「问题卡」快捷视图里「仅 Fushi 卡片类型参与缺音频判断」由 UI 拼查询实现：`is:emptyfield or (-has:audio note:"<内置 Fushi 卡片类型的名字>")`（名字取 `builtinKey == kSrsBuiltinFushiCardKey` 的笔记类型，用 `srsFieldContainsQuery` 同样的转义）；内核不另设词。
- `rated:` / `src:` / `is:dupe` / `is:emptyfield` 只在浏览会话（`browse_query` / `browse_counts` / `anki_find`）里可用（内核先把它们换成 id 集合再求值）；AnkiConnect 的 findNotes / findCards 也因此支持这几个词。
- `has:` / `prop:r` 由语料求值；`has:` 与裸词一样要装全部字段原文（首次慢一点，之后常驻）。
- 全部要进搜索帮助表（`srs_browse_dialogs.dart` 的帮助）与 i18n。

### 2.4 新命令

- `browse_counts`：请求 `{nodes: [语法树 JSON | null | false…], mode, …同 browse_query 的上下文}` → `{counts: [int…]}`。`null` = 空查询（全部）；`false` = Dart 解析失败 / 不支持的那一条，回 -1；求值报语法错误（如正则不合法）的那一条也回 -1，不影响其它。与 `browse_query` 同口径（同一会话、同上下文；`mode = notes` 时数笔记）。不留查询结果。Dart：`SrsBrowseSession.counts(List<String> queries, {SrsBrowseMode mode = SrsBrowseMode.cards}) → Future<List<int>>`（解析在 Dart 侧做，所以 wire 上传的是语法树而不是原文）。
- `browse_sources`：`{gen}`（同 `browse_rows` 的结果句柄）→ `{groups: [{key, kind, data, count, due, preview: [rowIndex…≤8], latestAddedAt, decks: [牌组 id…]}]}`，按 `latestAddedAt` 降序（同值按键升序）；无出处的行合成 `key = null` 一组放最后。`data` 是组里最近添加那条笔记的出处原始 JSON；`due` = 组里有卡今天到期（`is:due` 口径）的行数；`preview` = 组内按结果顺序的前 8 个行号。Dart：`SrsBrowseResult.sources() → Future<List<SrsBrowseSourceGroup>>`。

```dart
class SrsBrowseSourceGroup {
  final String? key;        // null = 无出处组
  final String? kind;
  final String? data;       // 出处原始 JSON
  final int count;
  final int due;
  final List<int> preview;  // 结果行号
  final int latestAddedAt;
  SrsSourceRef? get source; // data 解析
}
```

- `decks`（Dart `SrsBrowseSourceGroup.deckIds`）= 组里各行的卡所在的牌组 id（去重、首次出现的顺序），「只复习这一作」据此定牌组范围（§2.6）。
- 两条新命令已加进 `SrsDbStore.kSrsBrowseOps` 与原生 `store/ffi.rs` 的浏览分派（只读，远程复习可转发）。
- 上下文新增（`srsBrowseContext` 自动带）：`models: [[记忆算法 wire, 参数]…]`、`deckModels: {牌组 id: 下标}`、`fallbackModel`——保持率用；不进语料结构。

### 2.6 只复习这一作（出处视图）

- 走现有自定义学习临时会话（store/study.rs `CustomStudy`，不建筛选牌组、不挪卡、会话无状态），`filter` 模式新增 `"source": <sourceKey>`：只出笔记缓存行 `source_key` 整值相等的卡，可与 `states` / `tags` 叠加。Dart：`SrsCustomStudy.source`（远程复习的 wire 同步带上）。
- `srs_notes_cache.source_key`（srs.db v25，部分索引 `(profile_uid, source_key) WHERE deleted_at IS NULL`）：出处寄存器的分组键，与 `browse.rs` `source_key` 同一个函数，写缓存行时算；空串 = 没有出处，NULL = 老行还没算，由 Dart 缓存修订号 10 的升级步 `backfill_source_keys` 只补这一列。不按制卡标签推（那只进统计页的 `source_kind`）。出卡时直接按索引查，不为出卡读修改记录。
- 浏览页：组头「只复习这一作」只给有出处、今天有到期的组；牌组范围 = `decks` 的最近公共祖先（全在一个牌组就是它），分在几个顶层牌组时让用户挑一个；会话条件 = 该出处 + 状态 `due` / `learning`（今天到期的复习卡与学习卡，不引入新卡），上限 `SrsCustomStudy.maxCards`。复习页回来后浏览页重读。

### 2.5 测试

Rust 单测覆盖新字段、新搜索词、两条新命令；Dart 引擎测试覆盖解码。原生库是硬依赖（找不到库测试失败不 skip）。

## 3. Flutter 侧文件划分

- `srs_browse_page.dart`：页面骨架、状态、键盘、批量 / 撤销（保留现有全部能力：多选、Shift 范围选、Ctrl+A、Delete、Ctrl+Z、全部批量操作）。
- 新 part / 文件：`srs_browse_query_bar.dart`（积木条 + 补全 + 编辑面板，积木 ↔ 语法解析纯函数可单测）、`srs_browse_card_tile.dart`（富卡片 / 磁贴）、`srs_browse_table.dart`、`srs_browse_sources_view.dart`、`srs_browse_inspector.dart`（三页，手机详情页复用）、`srs_browse_health.dart`、`srs_browse_saved_views.dart`。
- i18n 一律 `fushi/tool/i18n_sync.dart --add`，key 前缀 `srs_browse_`。
