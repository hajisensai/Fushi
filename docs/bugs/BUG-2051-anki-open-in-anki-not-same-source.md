## BUG-2051 · 点已制卡 ↗ 在 Anki 中打开：反查判据与查重判据不同源，跨笔记类型的卡查不到

- **报告**：2026-09-02（用户：「已经制过的卡 yomitan 好像是通过 Expression 查的，我们是根据 id 查的」，指的是词条右侧的 ↗ 跳转按钮）
- **真实性**：✅ 真 bug（本机真机 AnkiConnect 取证复现，见下表）

### 现象

词条显示 **已制卡 ✓**，点旁边的 ↗「在 Anki 中打开卡片」，弹「**没有找到已制的卡片**」。
同一个词，两句互相打架的说法。

### 根因

BUG-1915 把**查重**（画 ✓/+）换成了 Anki 内建的第一字段 checksum，却把 **↗ 的反查**留在
按字段名查的老路上，于是同一个「这个词有没有卡」问了两遍、得到相反答案：

- 画 ✓：`AnkiConnectRepository.isDuplicate`
  → `canAddNotesWithErrorDetail`（`ankiconnect_service.dart:488` `isDuplicateForAdd`）
  —— Anki 内建**第一字段 checksum**，跨全部笔记类型，不看字段叫什么名字。
- 点 ↗：`openMinedCardInAnki` → `AnkiConnectRepository.findMatchingNotes`
  （`ankiconnect_repository.dart:1114`）→ `findNotes 'deck:"…" "<第一字段名>:<词>"'`
  —— 按**字段名**匹配，只能命中「恰好也有同名字段」的笔记类型。

用户卡组 `正在背::Kaishi 1.5k  zh-CH` 混装两种笔记类型：`Kaishi 1.5k zh-CH`（第一字段名
`Word`）+ `Lapis`（第一字段名 `Expression`，制卡目标）。`たっぷり` 已作为一张 Kaishi 卡
存在（note `1758347126448`）。真机实测（2026-09-02，AnkiConnect 25.x）：

| 查询 | 结果 |
|---|---|
| `canAddNotesWithErrorDetail`（画 ✓ 的判据） | `canAdd:false, error:"…is a duplicate"` → 画 ✓ |
| `deck:"正在背::Kaishi 1.5k  zh-CH" "Expression:たっぷり"`（↗ 的反查） | `[]` → 「没有找到已制的卡片」 |
| `deck:"…" "Word:たっぷり"`（那张卡真实所在） | `[1758347126448]` |
| `deck:"…" ("dupe:1758278161949,たっぷり" OR …)` | `[1758347126448]` |

**对照 Yomitan**（上游源码实测，非记忆：`ext/js/comm/anki-connect.js` `_fieldsToQuery` /
`_getNoteQuery`，`ext/js/display/display-anki.js` `_updateSaveButtons`）：它的「已添加」
指示与 ↗ 查看按钮用的是**同一份 noteIds**，来自 `findNoteIds()` → `findNotes
'"deck:X" "<第一字段名小写>:<值>"'`；`canAddNotes` 只用来禁用/启用「+」。也就是说
Yomitan 只有一条判据，两个 UI 天然一致；我们有两条，所以会打架。

### [x] ① 已修复

不是「让两条查询长得一样」（那还会再漂移一次），而是**让 ↗ 不再有自己的判据**：

1. `AnkiConnectService.guiBrowseQuery(query)`（新）：把 Anki 浏览器过滤到任意查询串。
   ↗ 只喂它 `nid:a,b,c`（见下），**不把它的返回值当第二次匹配判定**。
2. `ankiDuplicateSearchQuery(...)`（新，`ankiconnect_service.dart`）：把 checksum 判据用
   搜索语法表达一遍 —— `(did:… OR did:…) ("dupe:<mid1>,<词>" OR "dupe:<mid2>,<词>" …)`，
   mid 取**全部**笔记类型（`modelNamesAndIds`，也是新增）。`canAddNotes` 只回布尔、给不出
   note id，`dupe:` 是唯一既同源又能拿到卡的路子。
2b. **不按名字查**（第二轮，用户提出）：卡组范围先用 `deckNamesAndIds` 把名字**精确**
   解析成 id（`ankiDuplicateDeckIds`：`名 == 目标` 或 `名.startsWith('目标::')`，字符串
   比较在 Dart 里做），查询串里用 `did:`；命中的 note id 再用 `ankiNoteIdBrowseQuery`
   变成 `nid:a,b,c` 交给浏览器。于是**查询串里唯一还留着的名字是 `dupe:` 里那个词，
   而它恰好是 Anki 唯一做精确比较的地方**。理由是实测出来的，见「按名字查的实测」。
   代价是多一次 `findNotes` 往返——它不是第二条判据：`nid:` 按上一步的**结果 id**
   定位，不重新匹配任何东西。
3. `BaseAnkiRepository.openWordInAnki(expression, reading) -> AnkiOpenWordOutcome`（新契约，
   三态 `opened / noMatch / failed`）。AnkiConnect 覆写成上面那条；**基类默认实现**走
   `findMatchingNotes` + `openNoteInAnki` 打开最近一张，给没有「按词打开」能力的后端
   （AnkiDroid 只有按 note id 的 deep link）。AnkiDroid 的查重与反查本来就都传
   `models:[当前笔记类型]`，两者同源，不存在本 bug，故不动。
4. ↗ 的两条 UI 车道合并成一条：popup.js 不再按 `__fushiMinedCardActionNative` 分流，
   app 内外都调 `openInAnki` 桥（overlay 侧新增该 handler，Windows 原生 `global_lookup_window.cpp`
   把它列入 DEFERRED）。宿主回三态名，popup.js 就地 `showInlineHint`——app 外没有 Flutter
   toast，提示只能画在按钮旁边。
5. 删掉随之失去存在理由的代码：`openMinedCardInAnki` / `showAnkiOpenNotePicker` /
   `_OpenNotePicker`（Flutter 多卡选择框）、popup.js 的 `runInPageOpenInAnki` 与面板的
   `openOnly` 形态。多张卡由 Anki 浏览器自己列——那本来就是它的工作。
   点 ✓ 的操作面板（覆写/新增重复卡/查看某一张）**不变**，仍按 note id 打开单张。

提交：见本分支 `worktree-anki-open-word-samesource`。

改动文件：
- `packages/fushi_anki/lib/src/anki_models.dart`（`AnkiOpenWordOutcome` 三态）
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart`（查询串 + `guiBrowseQuery` + `modelNamesAndIds`）
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart`（`openWordInAnki` 覆写）
- `packages/fushi_anki/lib/src/base_anki_repository.dart`（契约 + 默认实现）
- `fushi/lib/src/anki/anki_mined_card_action_sheet.dart`（删旧编排与选择框）
- `fushi/lib/src/pages/{base_source_page,implementations/dictionary_page_mixin,implementations/dictionary_popup_webview,implementations/dictionary_popup_layer}.dart`
- `fushi/lib/src/lookup/overlay_bridge_handlers.dart`（新桥）
- `fushi/windows/runner/global_lookup_window.cpp`（DEFERRED 名单）
- `fushi/assets/popup/popup.js` + 扩展两镜像（唯一车道 + 三态提示）

### [x] ② 已加自动化测试

- `packages/fushi_anki/test/open_word_in_anki_test.dart`（新增，第一轮 14 条 → 第二轮 20 条）——假 AnkiConnect
  **照上表实测行为建模**：按字段名查恒 0 命中、`dupe:` 命中那张 Kaishi 卡。覆盖：✓ 判重
  与 ↗ 必须给同一答案 / ↗ 不得再发 findNotes / 查询串形状（卡组过滤 + 全量 mid + 括号分组
  + 不含 `Expression:`）/ collection scope 不带卡组 / 空选中 → noMatch / 传输失败 → failed
  / 空词零请求 / 引号转义 / 空 mid 或空词 → 空串 / deckRoot 取根 / 基类默认三条。
- `fushi/test/utils/misc/popup_asset_behavior_test.js`——↗ 的四条用例改写：走宿主桥、
  noMatch 与 failed 各说各的话、未接线宿主（回 null）仍提示不静默、app 内同一条车道。
- `fushi/test/pages/open_in_anki_wiring_static_test.dart` /
  `anki_mined_card_action_wiring_static_test.dart`——接线守卫改钉新不变式（含
  「`findNotesByField` 不得在 ↗ 方法体里复活」「C++ DEFERRED 名单含 openInAnki」）。
- `fushi/test/pages/anki_mined_card_action_sheet_widget_test.dart`——删掉三条只测已删 UI
  的用例，留指针指向新守卫文件。

**变异实测**（证明守卫有判别力，不是空转；每次按 sha256 核对还原）：
- 查询串退回按第一字段名查（BUG-1915 之前的形状）→ 14 条中 **4 条红**（含核心那条
  「✓ 判为已制卡的词 ↗ 必须能打开」）。
- `modelIds` 只取当前笔记类型 → **2 条红**（跨笔记类型那张卡看不见）。
- 去掉 `dupe:` 组的括号 → **5 条红**（查询串形状 + 各 scope）。
- `noMatch` 改成 `failed`（三态塌回两态）→ **精确 1 条红**。
- popup.js 把 `'opened'` 读错 → **精确 1 条 JS 用例红**（`a successful open says nothing`）。
- 三次 Dart 变异 + 一次 JS 变异后 sha256 逐一核对还原（`4ba94b56…` / `07599a41…` / `b680ce74…`）。

### 审查追加（同一 bug 的第二个成因 + 守卫覆盖面）

**① 旧版 AnkiConnect 的 `guiBrowse` 不回命中列表 —— 同一句错话换个成因又出现。**
第一版把「应答不是列表」一律当空命中，三态直接回 `noMatch`。可 `guiBrowse` 的语义是
「**打开浏览器并搜索**」，返回值只是附加信息：旧版 AnkiConnect 只回 `null`，那种机器上
浏览器**已经打开**并过滤到了这条查询，我们却弹「没有找到已制的卡片」——正是本 bug 要
修掉的那句话。首轮真机取证是在 AnkiConnect 25.x 上做的，覆盖不到旧版。

修法（不做版本判断：那要多一次 `version` 往返 + 硬编码一张「哪个版本起回列表」的表，
任何代理 / fork 都能让它失效）：`guiBrowseQuery` 改回 `List<int>?`，
`null` = 拿不到计数（未知），`[]` = 明确答「一张都没有」。只有后者才是 `noMatch`。
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:875`（`return null`）
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1277`
  （`cardIds != null && cardIds.isEmpty ? noMatch : opened`）

**② 守卫只钉了方法体内部，拦不住「再加一处入口自己拼一条链」。**
原守卫只断言 `openWordInAnki` **方法体内**不得复活 `findNotesByField`。新增第四处入口
自己 `findMatchingNotes` + `openNoteInAnki` 拼一条按词打开，没有任何守卫会红——那正是
本 bug 的成因（同一个问题两条判据）换个位置重来。

`fushi/test/pages/open_in_anki_wiring_static_test.dart` 新增三条**目录枚举型**守卫
（`listSync(recursive: true)` 扫全树，新文件自动落进扫描面；判据前先剥注释，否则文档
注释里的 `[BaseAnkiRepository.openWordInAnki]` 会把每个提到它的文件算成调用点）：
- `.openWordInAnki(` 的调用点 == 登记的三条车道（`dictionary_page_mixin` /
  `base_source_page` / `overlay_bridge_handlers`）。
- 没有第二处同时 `.findMatchingNotes(` + `.openNoteInAnki(` 的文件（白名单两处都是
  **按 note id** 的既有车道，不是按词打开）。
- `guiBrowseQuery(` 只在 AnkiConnect service / repository 内部被调用。

**追加的自动化测试**（`packages/fushi_anki/test/open_word_in_anki_test.dart`，16 条）：
假机加 `guiBrowseReturnsNull` 开关，覆盖「旧版应答 `result:null` → opened 不是 noMatch」
与「service 层把 null 与 `[]` 分成两个值」。

**变异实测**（每条按唯一锚点还原 + sha256 核对，不用 `git checkout`）：

| 改坏哪一行 | 红没红 | 报错文案 | 还原 sha256 |
|---|---|---|---|
| `ankiconnect_service.dart` `return null` → `return const <int>[]`（回退本次修复） | ✅ 2 条红，其余 14 条绿 | `Expected: opened / Actual: noMatch`；`Expected: null / Actual: []` | `a1f0e4a2…5109b`（= 修复后基线） |
| 新建 `fushi/lib/src/anki/_mutation_probe_open_lane.dart` 冒充第四处入口 | ✅ 2 条守卫红，PR 原有 8 条守卫全绿 | `Which: larger than expected` | 删除探针（不碰既有文件，守卫 sha `d0870bbd…7ac6` 不变） |
| 新建 `packages/fushi_anki/lib/src/_mutation_probe_browse.dart` 调 `guiBrowseQuery` | ✅ 第三条守卫红 | `Which: larger than expected` | 同上 |

后两行的「PR 原有 8 条守卫全绿」就是 control：旧护栏结构上抓不到新入口，是新守卫在承重。
**第二轮（改按 id 查）新增用例**：浏览器那句只能是 `nid:`（不含词/`deck:`/`dupe:`）、
判命中那句按 `did:` 过滤、`ankiDeckIdFilter` 与 `ankiNoteIdBrowseQuery` 的形状、以及
「卡组范围按 id 解析」5 条（子组按 `::` 精确展开 / 带 `_` 的卡组名只解析出它自己、兄弟
卡组不得被通配进来 / deckRoot 取根 / collection·空名·卡组已删 → 不加过滤 / `Lapis2` 不算
`Lapis` 的子组）。假 AnkiConnect 改成：`findNotes` 才是判命中的那一步，**`guiBrowse`
故意没有判别力**（只回传 `nid:` 里点到的），否则又是两条判据。共 20 条。

**第二轮变异实测**（每条按 sha256 核对还原）：
- 子卡组用裸前缀（丢掉 `::`）→ **精确 1 条红**（`Lapis2` 那条）。
- `nid:` 只列第一张而不是全部同名 → **精确 1 条红**。
- 把带词的 `dupe:` 串直接丢给 `guiBrowse`（退回第一轮的形状）→ 单测 1 条红 + 静态守卫 1 条红。
- `deck` scope 失效（不再限定卡组）→ **4 条红**。
- 查不到也照样去开浏览器 → **精确 1 条红**。

守卫自查：静态守卫取函数体时 `indexOf('\n}')` 会先命中**命名参数表**的 `})`（同样在列 0），
把函数体截成一个参数表、后续 `contains` 断言全部恒假。已改成跳过后面紧跟 `)` 的那些
（`topLevelBodyEnd`），并加了「取到的片段必须含 `dupe:`」的非空转自检。

### 按名字查的实测（第二轮的依据）

用户指出「anki 按名字查会非常灾难」。在本机真 Anki 上量了一遍，属实，而且第一轮的修复
**只同源了一半**：`dupe:` 那半对了，卡组那半我用的 `deck:"<名字>"` 走的是 Anki 搜索的
**通配匹配**，而画 ✓ 那侧（`duplicateScopeOptions.deckName`）是**精确名**。

| 卡组条件 | ↗ 侧 `findNotes` | ✓ 侧 `canAddNotesWithErrorDetail` |
|---|---|---|
| 真名 `eggrolls-JLPT10k-v3` / `正在背::Kaishi 1.5k  zh-CH` | 10164 条 | 判重复 |
| 把一个字换成 `_` | **同样 10164 条**（`_` = 单字通配） | **判不重复**（名字不存在） |
| `e*` / `正在背::*` | **整棵树 10164 条** | **判不重复** |
| 不存在的名字 | 0 条 | 判不重复（静默，不报错） |

也就是说：只要卡组名里有 `_` 或 `*`（本机就有 `galgame_card_test` / `galgame_track_test`），
两侧对「哪些卡在范围内」的答案就不一样——判据的下一个漂移入口。id 没有这个问题。

另外两条实测事实：`did:` **只匹配该卡组自己、不含子卡组**（父卡组 `did:` n=1 而
`deck:` n=10164），所以子卡组要在 Dart 侧按 `::` 前缀精确展开，对齐查重侧的
`checkChildren: true`；卡组名里的连续空格不会被 Anki 吞（`deck:"…1.5k  zh-CH"` n=1501，
改成单空格 n=0）。

### 备注

**真机验证**：本机真 Anki 上跑完整新链路。单卡词 `たっぷり`：
`(did:1771332842760) ("dupe:…,たっぷり" OR …)` → `[1758347126448]` →
`guiBrowse('nid:1758347126448')` → `cardsInfo` 确认正是笔记类型 `Kaishi 1.5k zh-CH`、
第一字段 `たっぷり` 的那张卡；同一时刻旧的按字段名查询返回 `[]`。
**多卡词** `与える`（本 bug 的原型形状：同一个词同时是一张 Kaishi 笔记、第一字段名
`Word`，和一张 Lapis 笔记、第一字段名 `Expression`）：同源查询返回
`[1788020832613, 1758347125581]`，与逐条枚举第一字段的结果完全一致，
`guiBrowse('nid:1758347125581,1788020832613')` 在浏览器里一次列出两张。该库 `正在背`
树下 2894 条笔记里，**44 个词跨 ≥2 种笔记类型**——旧实现对这些词只能看见一半。
原始失败路径（app 内点 ↗）**未**在真机 app 里复测：本轮做到「同一条链路在真 Anki 上给出
正确结果」这一层。

**`dupe:` 语法的实测边界**（同机取证）：按**第一个逗号**切（`"dupe:mid,x,たっぷり"` 不
命中，排除了「按最后一个逗号切」，故词里含逗号不会截断文本）；未知 mid 只是不命中、不
报错（全量 OR 安全）；值里的引号/反斜杠/空格/冒号/括号/星号整体加引号后都能解析，且
`*` 不当通配符（精确文本比较）。**未直接实测**：第一字段里含逗号或 HTML 的卡能否被
`dupe:` 命中——本机收藏集里没有这种卡，没有为测试往用户库里写卡；结论是从「按第一个
逗号切」+ Anki 的 dupe 搜索本就用 checksum + 去 HTML 文本比较推出来的。

**次生问题（未修，另开）**：点 ✓ 的操作面板也走 `findMatchingNotes`，跨笔记类型时它拿到
空集 → popup.js 落回「当新卡制」→ 又被 Anki 以重复拒绝。这是 BUG-1915 残余症状之二，
与本 bug 同根不同入口，本轮刻意不混进来。
