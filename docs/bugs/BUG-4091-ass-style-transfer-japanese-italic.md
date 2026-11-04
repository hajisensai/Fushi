## BUG-4091 · 参考英语ASS生成的日语ASS整行变斜体
- **报告**：2026-11-04（用户：BanG Dream! 第二季第 8 集，参考英语 ASS 生成的日语 ASS「好斜」）
- **真实性**：✅ 真 bug — 根因 `packages/fushi_engine/lib/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart` 的样式迁移：`_inheritableTag` 白名单含 `\i[01]`（以及 `\b`），渲染时把参考行**行首**覆盖标签原样继承到整行日语。英语行 `{\i1}That{\i0} song.` 的 `\i1` 只强调一个词，迁移后变成 `{\i1}あの曲。` 整行斜体；另外参考 ASS 里 `Italic=-1` 的样式（心声 / 旁白）被日语行沿用，日文也整行斜。
- **[x] ① 已修复** — 白名单去掉 `\i`；新增 `lineLevelLeadingTags`：行首标签只有在行内没被重新定义、后面也没有 `\r` 时才算「整行级」（`{\an8\b1}` 整行粗体照常继承，`{\b1}词{\b0}` 这种局部强调不继承）；参考样式 `Italic=-1` 时日语行补 `{\i0}`（日文不用斜体表强调）。提交见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer_test.dart`「BUG-4091」三条：局部斜体不继承；行内重定义 / `\r` 的行首标签丢掉、整行 `\an8\b1` 保留；`Italic=-1` 样式补 `{\i0}`。白名单用例的期望同步去掉 `\i1`。
- **备注**：已生成过的日语 ASS 需重新生成一次才会更新。BanG Dream! S2E8 真文件未在本机复测。
