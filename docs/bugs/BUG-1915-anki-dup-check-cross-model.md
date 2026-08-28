## BUG-1915 · 查词弹窗查重与制卡判重不同源：跨笔记类型的重复卡画成可制卡 +

- **报告**：2026-08-28（用户：视频页查词弹窗，点 + 弹「重复卡片，未导出」，但 + 号毫无变化）
- **真实性**：✅ 真 bug（本机真机 AnkiConnect 取证复现）

### 现象

视频页查词弹窗里 `たっぷり` 的制卡按钮显示可制卡 `+`。点下去弹 toast「重复卡片，未导出。」，
而按钮**一点变化都没有**，仍是 `+`。用户看到的是「提示说重复、按钮说可制卡」两个互相打架的说法。

### 根因

**两条判重根本不是同一件事**，而且实测给出相反答案。

- 画 `+` / `✓` 的查重：`AnkiConnectRepository.isDuplicate`
  → `AnkiConnectService.isDuplicate` → `findNotes 'deck:"…" "<第一字段名>:<词>"'`
  —— 按**字段名**匹配。
- 真正拒绝制卡的判重：`AnkiConnectService.addNote` 的 `duplicateScopeOptions`
  （`packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:864` `_addNoteDuplicateOptions`，
  含 `checkAllModels: true`）—— Anki 内建的**第一字段 checksum**，跨全部笔记类型，
  不管那个字段叫什么名字。

用户的目标卡组 `正在背::Kaishi 1.5k  zh-CH` 里混装两种笔记类型：1501 张 `Kaishi 1.5k zh-CH`
（第一字段名 `Word`）+ 12 张 `Lapis`（第一字段名 `Expression`，制卡目标）。`たっぷり` 已作为
一张 Kaishi 卡存在（`noteId=1758347126448`）。真机 AnkiConnect 实测：

| 查询 | 结果 |
|---|---|
| `deck:"正在背::Kaishi 1.5k  zh-CH" "Expression:たっぷり"`（Hibiki 查重发的那条） | **0 命中** → 画 `+` |
| 同卡组内「第一字段 == たっぷり」（Anki 自己的判据） | **1 命中** → `addNote` 拒绝 |

Kaishi 笔记类型压根没有 `Expression` 字段，按字段名永远查不到它。于是**凡是 Kaishi 里已有的词，
Lapis 卡都永远制不出来，而且事前 UI 一点提示都没有**——不止 `たっぷり` 一个词。

**回归点**：`08b899ecd4`（2026-07-29 `fix(anki): avoid GUI-thread duplicate preflight`）把**制卡侧**
的判重从「自己发 findNotes」改成「交给 Anki 内建 checksum」，并加 `checkAllModels: true` 想保持
跨模型范围，但**只改了制卡侧**，`isDuplicate()` 留在旧路径上没动。那行注释里的
"Preserve that cross-model scope" 是个误解——`Expression:value` 从来就不是跨模型的。
两条判据从那天起分家。

**次生根因（按钮连重画都没重画）**：`fushi/assets/popup/popup.js` 制卡后的重画被
`if (result.ankiConnect)` 门控，而 `MinePopupResult` 把 duplicate / 未配置 / 出错 / addNote 响应
丢失**四种结局压成同一个 `const MinePopupResult()`**（`ankiConnect: false`）。这个布尔表达不了
「发生了什么」，弹窗无从区分「Anki 明说卡在库里」与「这次 addNote 结果未知」，于是干脆全都不重画。

### [x] ① 已修复

不是「让两边的条件长得一样」（那还会再漂移一次），而是**删掉第二条判据**：

1. `AnkiConnectService.isDuplicate`（按字段名查）**删除**，换成 `isDuplicateForAdd` —— 直接调
   AnkiConnect 的 `canAddNotesWithErrorDetail`，它内部走的就是 `addNote` 用的同一个
   `isNoteDuplicateOrEmptyInScope`；options 复用同一个 `_addNoteDuplicateOptions`，不再手写一份。
   只传第一字段（Anki 判重只看它），不在查词渲染路径上构造整张卡。
   探测恒传 `allowDuplicate: false`（问的是「Anki 认不认为重复」，与用户的「允许重复」偏好无关）。
   `canAdd:false` 只有在 Anki **明说是重复**时才算重复——把「卡组过期」当成「已制卡」会让每个词
   都画上 ✓。老版 AnkiConnect 不认识该动作时退回旧判据，不让这些用户的 ✓ 集体消失。
2. `MinePopupResult` 增加语义精确的 `duplicate` 字段 + `MinePopupResult.failed(outcome)`
   工厂，8 个表面的「制卡后失败」分支统一带回真实结局。popup.js 三镜像据此在**重复**时也重画
   按钮。**只把 duplicate 加进重画门，不是所有失败**——TODO-448 刻意不让失败/结果未知的制卡
   触发延迟 duplicateCheck 把按钮翻成 ✓（addNote 送达但响应丢失的情形，会读成「先失败后成功」）。
   duplicate 不是未知：Anki 查过了，卡就在那儿。

提交：见本分支 `worktree-anki-dup-check-samesource`。

改动文件：
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart`（判据同源 + 共享重复文案常量）
- `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart`（改走同源判据 + 老版回退）
- `fushi/lib/src/pages/implementations/dictionary_popup_webview.dart`（`MinePopupResult.duplicate`）
- 8 个制卡表面的失败分支（mixin / reader / reader_pdf / texthooker / video / manga）
- `fushi/assets/popup/popup.js` + 浏览器扩展两镜像（重画门 + `parseMineResult`）

### [x] ② 已加自动化测试

- `packages/fushi_anki/test/duplicate_check_same_source_test.dart`（新增，8 条）——假 AnkiConnect
  **照上表实测行为建模**：按字段名查恒 0 命中、按 Anki 自己的第一字段判恒重复。两条判据在这台
  假机上给出相反答案，正是判别力所在。覆盖：跨笔记类型重复必须为 true / 探测与 addNote 发出的
  options 逐字段相同 / `checkAllModels` 必须开着 / `allowDupes=true` 时探测仍问 `allowDuplicate:false`
  / 只发第一字段 / `canAdd:false` 但非重复不画 ✓ / 老版回退 / 空词不问 Anki。
- `packages/fushi_anki/test/ankiconnect_service_test.dart`——旧 `isDuplicate` 组改写为
  `findNotesByField` 查询串 + `isDuplicateForAdd` 语义两组。
- `fushi/test/utils/misc/popup_asset_behavior_test.js`——新增
  `testDuplicateOutcomeStillRepaintsFromAnki`：制卡被判重复后按钮必须重画成 ✓。
- 三个旧 fake（commit_unknown / error_garble / note_id_and_update）里「制卡不得另跑一次查重」的
  计数器守卫改接新探测入口，避免守卫变空转。

**变异实测**（证明守卫有判别力，不是空转）：
- repo 退回旧 `findNotesByField` 判据 → 新测试 8 条中 7 条红（含核心那条）。
- `checkAllModels: true → false` → **精确**只红 `checkAllModels` 那一条。
- popup.js 重画门去掉 `|| result.duplicate` → **精确**只红新增的 JS 行为用例。
- 三次变异后均按 sha256 核对还原（`a63228e0…` / `3e310fce…` / `cdf047e6…`）。

### 备注

**已知边界（无法在查词阶段消除）**：探测传的第一字段值是词条本身，而制卡时那一格是
`fieldMappings` 渲染的结果。第一字段映射成 `{expression}`（Lapis 出厂默认，也是本用户的配置）
时两者逐字节相同；映射成依赖句子/媒体的模板时，查词阶段根本拿不到那些数据，任何实现都无法
预知制卡时的第一字段——此时探测退化为「按词查」，与旧行为一致，不比现状差。
AnkiDroid 后端同理（`anki_repository.dart` 的 `isDuplicate` 传 `expression`、制卡侧传第一字段
渲染值），且其 `checkForDuplicates` 本就限定同一笔记类型，不存在本 bug 的跨模型分叉。

**未做真机 E2E**：本轮只做到单测 + 变异实测；用户原始失败路径（视频页查 `たっぷり` → 按钮应显示 ✓）
未在真机复测。
