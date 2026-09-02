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

1. `AnkiConnectService.guiBrowseQuery(query)`（新）：把 Anki 浏览器过滤到任意查询串，
   并回传**被选中的 card id**——`guiBrowse` 的应答本来就是命中列表，所以「打开」与
   「到底有没有卡」是同一次往返的两个产物，不必再另发一条 `findNotes` 去问同一个问题。
2. `ankiDuplicateSearchQuery(...)`（新，`ankiconnect_service.dart`）：把 checksum 判据用
   搜索语法表达一遍 —— `deckFilter ("dupe:<mid1>,<词>" OR "dupe:<mid2>,<词>" …)`，mid 取
   **全部**笔记类型（`modelNamesAndIds`，也是新增），卡组过滤器复用查重那一个
   `ankiDuplicateDeckFilter`。`canAddNotes` 只回布尔、给不出 note id，`dupe:` 是唯一
   既同源又能拿到卡的路子。
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

- `packages/fushi_anki/test/open_word_in_anki_test.dart`（新增，14 条）——假 AnkiConnect
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

### 备注

**真机验证**：本机真 Anki 上直接发新实现构造的那条查询串，`guiBrowse` 返回
`[1758347126448]`，`cardsInfo` 确认打开的正是笔记类型 `Kaishi 1.5k zh-CH`、第一字段
`たっぷり` 的那张卡；同一时刻旧查询串返回 `[]`。原始失败路径（app 内点 ↗）**未**在真机
app 里复测——本轮做到「同一条查询串在真 Anki 上给出正确结果」这一层。

**`dupe:` 语法的实测边界**（同机取证）：按**第一个逗号**切（`"dupe:mid,x,たっぷり"` 不
命中，排除了「按最后一个逗号切」，故词里含逗号不会截断文本）；未知 mid 只是不命中、不
报错（全量 OR 安全）；值里的引号/反斜杠/空格/冒号/括号/星号整体加引号后都能解析，且
`*` 不当通配符（精确文本比较）。**未直接实测**：第一字段里含逗号或 HTML 的卡能否被
`dupe:` 命中——本机收藏集里没有这种卡，没有为测试往用户库里写卡；结论是从「按第一个
逗号切」+ Anki 的 dupe 搜索本就用 checksum + 去 HTML 文本比较推出来的。

**次生问题（未修，另开）**：点 ✓ 的操作面板也走 `findMatchingNotes`，跨笔记类型时它拿到
空集 → popup.js 落回「当新卡制」→ 又被 Anki 以重复拒绝。这是 BUG-1915 残余症状之二，
与本 bug 同根不同入口，本轮刻意不混进来。
