## BUG-4226 · yomitan-per-dict-frequency-unmappable
- **报告**：2026-11-07（用户：应用内反馈 ArXVzMKmM5，Windows 3.3.0+24434）
- **真实性**：✅ 真 bug。用户把 FreqSort 映射成 Yomitan 的 `{single-frequency-number-jiten}`（Yomitan 下拉框里就有），Fushi 制卡后字段为空。两层同时缺失：
  1. 渲染器不认识该标记：`packages/fushi_anki/lib/src/anki_models.dart:1192`（`_handlebarToValue` 的 `default: return ''`），逐词典只认 `{single-glossary-<名>}`。
  2. 制卡数据里根本没有逐词典频率：`fushi/assets/popup/popup.js:2769`/`:2840`（`buildMinePayload` 只产出调和平均 `freqHarmonicRank` 与全词典列表 `frequenciesHtml`），光补渲染器也无数据可渲染。
  另：Yomitan 的逐词典标记名是 `getKebabCase(词典名)`（上游 `ext/js/data/anki-template-util.js`），`jiten` ≠ 词典真名 `Jiten`，按真名查表也命不中。
- **[x] ① 已修复** — popup.js（三份镜像逐字节一致）抽出 `collectFrequencyNumbers` 作为每词典取数的唯一来源（Yomitan `getFrequencyNumbers` 同语义），调和平均改由它计算（行为逐值不变），并新增 `singleFrequencyNumbers` / `singleFrequenciesHtml` 两张「词典名 → 值」表进 payload；Dart `AnkiMiningPayload` 解析两张表（字符串 / 原生 Map 两条 wire），渲染器支持 `{single-frequency-number-<名>}`（该词典的频率数）与 `{single-frequency-<名>}`（只含该词典的 `{frequencies}` 列表），词典名依次按精确 / 去 `[n]` 后缀 / Yomitan kebab 名匹配（同一查找也服务 `{single-glossary-<名>}`）；两处 payload 重建点（`anki_note_composer.dart`、`ankimobile_repository.dart`）与互联制卡字段白名单透传；字段选择器为每本频率词典列出 `{single-frequency-number-<名>}`。FreqSort 默认映射 / 排序逻辑未动（待用户决策）。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/handlebar_single_frequency_test.dart`（渲染 / 解析 / kebab 对齐上游 / 真实落卡路径 `renderMediaPayload` / 字段候选）；`fushi/test/anki/single_frequency_mining_test.dart` + `.js`（node 真执行 popup.js 取数函数与 `buildMinePayload` 产出键）。红→绿：去掉渲染分支 6/12 失败；对 origin/develop 的 popup.js 跑 JS harness 退出码 1。
- **备注**：标记语义取自 Yomitan 上游 `default-anki-field-templates.handlebars` 的 `single-frequency-number` / `frequencies` partial。
