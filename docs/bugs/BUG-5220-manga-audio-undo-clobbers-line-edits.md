## BUG-5220 · 漫画有声「换音」类操作撤销时整句放回旧稿，抹掉之后独立改的停顿 / 说话人 / 念的文字
- **报告**：2026-11-22（第三方审查 HBK-AUDIT-208，[#4136](https://github.com/hajisensai/Fushi/pull/4136)）。
- **真实性**：✅ **真 bug（撤销越权覆盖用户后来的编辑）**。`fushi/lib/src/ops/ctl_tts_batch.dart:724`（`revertMangaLineBatch`）在按文件名 / 种子认出「清单这句还是这次改出来的」之后，`manifest.replaceLine(id, (_) => old)` 与 `:734` `script.replaceLine(id, (_) => oldScript)` 把清单行与演出稿行**整行**换回操作前的快照。换本地音频只改了演出稿的音源（`MangaScriptLine.audio`），按角色批量重生成只改了种子（与音源），可撤销时整行放回会把之后独立改的停顿（`beatMs`）、说话人、类型、手填文字、错字修正、单句声音一并抹回旧值。单句重生成的撤销（`fushi/lib/src/ops/ctl_tts_support.dart` `revertMangaRegen`）是同一写法、同一问题。根因：撤销没按「本操作拥有的字段」回滚，而是整行快照覆盖。
- **[x] ① 已修复** — 本 PR（分支 `claude/audit2-manga-audio-undo-lifecycle`）。`ctl_tts_support.dart` 新增 `mangaRenderedAudioRestored`（清单行只放回音频本身：文件 / 时长 / 占位 / 声音 / 种子 / 念的文字 / 整形版本，演出字段保留当前值）与 `mangaScriptAudioRestored`（演出稿行只放回音源，换种子类操作再放回种子）；批量撤销与单句重生成撤销都改用它们。`MangaScriptLine.copyWith` 加 `clearSeed`（旧种子为 null = 用作品默认种子时要能清回去）。
- **[x] ② 已加自动化测试** — `fushi/test/ops/ctl_tts_routes_test.dart` 三个撤销用例（单句重生成 / 按句换本地音频 / 按角色批量重生成）在操作之后、撤销之前独立改停顿为 900 ms 与说话人 / 手填文字，撤销后断言这些编辑保留、音频与种子放回；修复前整行放回会把 `beatMs` 抹回 0 而变红。
- **备注**：HBK-AUDIT-208。
