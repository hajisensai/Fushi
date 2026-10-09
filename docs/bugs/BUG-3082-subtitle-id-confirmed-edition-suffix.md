## BUG-3082 · OpenSubtitles 候选 id 已确认、发布名带 Extended Cut 等版本修饰时被判别作
- **报告**：2026-10-09（#2007 合入后的审查）
- **真实性**：✅ 真 bug。`checkSubtitleWork`（`fushi/lib/src/media/video/subtitle/subtitle_work_identity.dart:157-168`，修前行号）遇到带标题、且与目标任一标题都不相等的发布名时，只要 `_isVariantOf`（同文件 `:235`）为真就拒，而 `_isVariantOf` 两个方向的包含都算。OpenSubtitles 候选的 tmdb/imdb id 已与目标相等（`_IdVerdict.confirmed`），发布名 `Your.Name.Extended.Cut…` / `Title.Directors.Cut…` 归一后包含目标标题，结果被判成「release title names a different work」。标题这类弱证据推翻了 id 这类强证据。
- **[x] ① 已修复**（`f59868a07a`）— 按确认强度区分：
  - id 已确认（`idConfirmed`，`subtitle_work_identity.dart:161`）时只拒一个方向：目标标题把发布名整个包含且更长（`_targetExtends`，`:258`）。例如目标是「のび太の恐竜2006」、发布名是「のび太の恐竜」，说明发布名指的是标题更短的原作。发布名在目标标题后面多出的词当作版本修饰，照收。
  - 只有来源条目名与目标相等（没有 id）属于弱确认，仍按 `_isVariantOf` 两个方向都拒，因为重制版 / 续作常把原标题整个包含在内。
  - library doc 里的证据次序同步改写。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/subtitle_work_identity_test.dart` 的 `BUG-3082` 组，共 5 条：
  - TMDB 确认 + Extended Cut 发布名，收；
  - TMDB 确认 + Directors Cut 发布名，收；
  - IMDb 确认 + 版本修饰，收；
  - id 已确认但目标标题更长，仍拒；
  - 只有条目名相等时，版本修饰仍拒。

  既有用例 ④（AniList 确认 + 目标「恐竜2006」）仍然拒。变异实测：回退到修前实现后，三条「收」用例全红。
- **备注**：
