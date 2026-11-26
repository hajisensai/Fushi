## BUG-5528 · 原盘下载字幕版本对不上时只能整份换 ASR 稿：缺 TV 版 / BD 版逐句合并
- **报告**：2026-11-26（用户：「bd 很多其实只是原版改了改，所以其实中间很多字幕都是和原版一样的，感觉可以从那边上手增加制作效果」）
- **真实性**：✅ 真缺口（功能分期，不是回归）。整库补字幕给原盘下载 TV 版字幕后，用本机 ASR 稿当参考逐句重定时（`packages/fushi_engine/lib/media/video/subtitle/library_subtitle_fill.dart` 的原盘分支 → `retimeVideoSubtitleToFile` → 上游 `retimeSubtitles`）。重定时只挪时间、不改文本：命中率 ≥40% 时整份留下载稿，**BD 新增的台词没有字幕、BD 删掉的台词留着孤句**；<40% 时整份丢下载稿改用 ASR 稿，**TV 版里能对上的那大半句子也一起丢了**。
- **[ ] ① 未修复** — 要在上游 `hajisensai/fushi-subtitles` 的重定时里加「版本合并」：对上的句子用下载稿文本 + ASR 时间；只有 ASR 有的段落（BD 新增）补 ASR 稿；下载稿里在 ASR 中找不到落点的连续段（BD 删掉）丢掉；输出每段来源统计。本仓只改装配（`library_subtitle_fill.dart` 原盘分支改成一律走合并、不再按 40% 二选一）。
- **[ ] ② 未加自动化测试** — 上游：合成 TV / BD 两份 cue 序列（中间插入一段、删掉一段）断言合并结果；本仓：`library_subtitle_fill_test.dart` 的原盘重定时用例改断言「合并」而非「二选一」。
- **备注**：设计见 `docs/specs/2026-11-26-library-subtitle-fill.md`「上游待办」。ASR 算法按仓库规则只能去上游改。
