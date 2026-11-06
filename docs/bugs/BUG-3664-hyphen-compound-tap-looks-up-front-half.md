## BUG-3664 · hyphen-compound-tap-looks-up-front-half
- **报告**：2026-10-21（用户反馈 IuqbSI7Hox，标题「只能查到前面」，截图：阅读器英文正文 `time-blackened`，查词卡只查出 time）
- **真实性**：✅ 真 bug。点词时把起点「回退到词首」的循环只停在 `isScanBoundary`（空白 / 标点）上，连字符不在 `scanDelimiters` 里（`fushi/lib/src/reader/reader_selection_scripts.dart` `selectFromPosition` 与悬停去重分支；`fushi/assets/popup/selection.js` `selectFromPosition` 同款）。点 blackened 会一路退回 time 的 t，喂给引擎「time-blackened oak…」，词典没有这个复合词，最长匹配只剩 time。Dart 侧取词（`fushi/lib/src/lookup/latin_word_lookup.dart`）与长按选词（`spaceDelimitedWordBounds`）本来就只回退字母，不跨连字符——三处口径不一致。
- **[x] ① 已修复** — 新增 `isTokenStartBoundary` = `isScanBoundary` + 词内连字符（`-` 与 U+2010–2015 / U+2212 / U+FE63 / U+FF0D；软连字符 U+00AD 不算），阅读器注入脚本与 selection.js 三镜像的词首回退都改用它。前向扫描不变：点 time 仍把整个复合词交给引擎，`well-known` 这类有词条的复合词照样能查到。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/hyphen_word_start_and_anchor_bug3664_test.{dart,js}`：node 真执行两份实现，点 blackened → `blackened oak`、点 well → `well-known fact`、三种连字符截回退、软连字符不截、撇号仍截。顺带更新 BUG-1773 / BUG-2056 两条源码守卫的回退锚点。
- **备注**：真机未复测。
