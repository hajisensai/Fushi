## BUG-2152 · 英语制卡音标重复两遍 —— 同一 PitchEntry 的 transcriptions 数组内没有去重
- **报告**：2026-09-05（用户：截图一张英语卡，`PitchPosition` 里是 `[/spəʊk/][/spəʊk/]`）
- **真实性**：⚠️ 代码路径成立，**本机未复现**。两件事都要说清：
  - **成立的部分**：`native/fushidicts/fushidicts_src/query.cpp:504-583` 的 `enrich_pitch()`
    对**每本 pitch 词典只产出一个 `PitchEntry`**（`:576-580`），循环里把该词典下所有匹配 meta
    记录的 transcription 平铺累加进同一个 `transcriptions` vector（`:517` 声明、`:569-570`
    `emplace_back`），**全程没有任何去重**；`parse_ipa`（`json/yomitan_parser.cpp:224-235`）
    原样复制。于是一本词典把 `spoke` 拆成名词条 + speak 过去式条、两条各带一个 `/spəʊk/`
    时，得到的就是 `transcriptions: ["/spəʊk/","/spəʊk/"]`。
  - 下游三道去重**全部是记录级（PitchEntry 级），够不着记录内部的数组**：
    `packages/fushi_dictionary/lib/src/language/language.dart:673-675` 的 `pKey`
    （`dictName:positions,patterns|transcriptions`，整个数组进 key，所以只算一次就留下）、
    原生镜像 `popup_json.cpp:128-161`、以及 popup.js 的 `mergeIdenticalPitchGroups`
    （`fushi/assets/popup/popup.js:2752-2775`，key 里同样带整个 transcriptions 数组）。
    `window.deduplicatePitchAccents`（`popup.js:2871-2874`）只过滤 `pitchPositions`。
  - 因此**弹窗展示侧和制卡侧一样会重复**，不是只有制卡坏。渲染点分别是
    `createTranscriptionsHtml`（`popup.js:2730-2739`）与 `constructPitchPositionHtml`
    （`popup.js:1573-1575`）。
  - **未复现的部分**：本机 `D:\APP\HIBIKI_date` 这套 24 本词典里**一条 ipa meta 记录都没有**
    （按 `\x01<u16 len>spoke` 和 mode 串 `\x03ipa` 扫全部 blobs.bin 均 0 命中；meta 记录在
    blobs.bin 里是明文，`importer.cpp:405-413`），唯一的英语词典 OALDPE 登记为 `term`。
    所以本机 `entry.pitches` 对 `spoke` 应为空数组，`constructPitchPositionHtml` 应返回 `''`。
    另外经 AnkiConnect 查证，本机 Anki（单 profile「账户 1」，13656 条，全日语牌组）
    **没有这张英语卡**（`Amane`/`Mahiru`/`OALD`/`spəʊk` 全 0 命中）。
- **[ ] ① 未修复** — 卡在「不知道它是哪来的」这一步，不做猜测式修复。待确认：那张卡是哪台设备 /
  哪个 collection 制的、当时装的是哪本英语词典（带 ipa meta 的）。拿到之后按下列判断落刀：
  - 若确为 transcriptions 重复：真根因在 `enrich_pitch()` 的累加处去重（保序），
    Dart/原生两份 popup_json 的记录级去重不动；
  - 若其实来自 `patterns`（`popup.js:1570-1572` 同一函数、同一 `[...]` 形状，肉眼分不出）：
    同理在 `enrich_pitch` 的 pattern 累加处修。
- **[ ] ② 未加自动化测试** — 跟着 ① 一起做。
- **备注**：与 BUG-2151（同一张卡上黑框错版）是两个独立缺陷。BUG-2151 已修并验证；
  顺带实证：本机真 Fushi 制的 Lapis 卡（noteId 1788450543147）`PitchPosition` 字段确实是
  `<ol><li><span style="display:inline;">…`，即 BUG-2151 描述的存量形态。
