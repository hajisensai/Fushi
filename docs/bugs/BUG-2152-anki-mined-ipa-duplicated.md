## BUG-2152 · 英语制卡音标重复两遍 —— 同一 PitchEntry 的 transcriptions 数组内没有去重
- **报告**：2026-09-05（用户转述用户反馈：英语卡 `PitchPosition` 里是 `[/spəʊk/][/spəʊk/]`）
- **真实性**：✅ 真 bug。卡不是本机产的（本机 Anki 单 profile、13656 条、全日语牌组，查 `Amane`/`Mahiru`/`OALD`/`spəʊk` 全 0 命中；
  本机 24 本词典一条 ipa meta 记录都没有——同一扫描方法在 NHK 命中 73100 条 `pitch`、BCCWJ 命中 100 万+ 条 `freq` 作阳性对照，
  两种工具两条独立路径同一结论），所以本机复现不出来；但**用户后续换维基音标词典的截图直接坐实了**：
  `first` 的标签框里 `[/fɜːst/]` 等条目肉眼可见地重复出现。
- **根因（两条独立路径，同一个可见症状）**：
  1. **词典内重复**（主路径）——`native/fushidicts/fushidicts_src/query.cpp` 的 `enrich_pitch()`：
     每本 pitch 词典**只产出一个 `PitchEntry`**，循环里把该词典下所有匹配 meta 记录的 transcription
     平铺 `emplace_back` 进同一个 vector，全程无去重；`pitches`（声调/pattern）那支同理。
     一个词典把 `spoke` 拆成名词条 + speak 过去式条、两条各带一个 `/spəʊk/`，就得到
     `transcriptions: ["/spəʊk/","/spəʊk/"]`。
     下游三道去重**全是记录级（PitchEntry 级）**，整个数组进 key，结构上够不着数组内部：
     `packages/fushi_dictionary/lib/src/language/language.dart:673-675` 的 `pKey`、
     原生镜像 `popup_json.cpp:128-161`、popup.js 的 `mergeIdenticalPitchGroups`。
  2. **跨词典重复**——展示侧 `createPitchSection` 先跑 `mergeIdenticalPitchGroups` 再渲染，
     制卡侧 `buildMinePayload` 却直接吃原始 `entry.pitches`。两本词典给出同一份发音时，
     弹窗里合成一行、卡片上却重复两遍。**制卡与展示分叉**。
- **[x] ① 已修复**：
  - 路径 1 在 `enrich_pitch()` 的**累加处**去重（保序、首次出现胜出），transcriptions 与 pitch accents 两支都覆盖
    ——因为两者渲染成同样的 `[...]` 形状，截图里分不出是哪支。
  - 路径 2 让 `buildMinePayload` 复用展示侧同一份 `mergeIdenticalPitchGroups`，制卡与展示不再分叉。
    popup.js 三镜像同步。
- **[x] ② 已加自动化测试**：`native/fushidicts/tests/pitch_duplicate_notation_test.cpp`（已登记进
  `tests/CMakeLists.txt` 的 ctest 清单），fixture 覆盖「跨记录重复 + 单记录内重复 + 不同记法必须全留下且保序」。
  **变异实测**：摘掉两处去重后 `ipa transcription count: got 5 want 2` / `pitch accent count: got 4 want 2` 双双变红；
  修复后 **29/29 原生测试全绿**（含 `ipa_import_query_test` 等相邻用例，说明去重没伤到既有行为）。
  制卡侧那半由 `fushi/test/anki/lapis_pitch_tag_list_markup_test.dart` 的
  「制卡侧复用展示侧的 pitch 归一化」用例锁。
- **顺带查出的路由缺口（同一条链上，尚未单独立号，因为手头没有能触发它的词典）**：
  带 term_bank 的混合词典（term + ipa meta）在 `importer.cpp:104-107` 必然判 `term`
  （term_bank 探测先于 meta 探测），而 `app_model.dart:317-346 bucketDictPaths` 对 `term`
  只有 `hasKanji` 一条双桶例外（`:340-343`，TODO-622），**没有 hasPitch 对应物**；
  `enrich_pitch` 又只遍历 `pitch_dicts_`（`query.cpp:509`、注册见 `:205-213`/`:171-173`）。
  于是这类词典的 ipa meta 彻底不可达。与 TODO-622 同型。
- **备注**：与 BUG-2151（`<ol>` 标记契约错版）、BUG-2155（标签框撑爆卡头）是同一张卡上的三个独立缺陷。
  顺带实证：本机真 Fushi 制的 Lapis 卡（noteId 1788450543147）`PitchPosition` 字段确实是
  `<ol><li><span style="display:inline;">…`，即 BUG-2151 描述的存量形态。
