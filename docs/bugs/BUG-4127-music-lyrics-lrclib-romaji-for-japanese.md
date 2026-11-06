## BUG-4127 · 音乐歌词：日文歌拿到 LRCLIB 罗马音版（不检查歌词书写系统）
- **报告**：2026-10-28（用户：开发者本人，应用内反馈 zl9Nmfldfr，「文字位置不对，而且文本是英文的，应该默认对应的语言才对」；截图是 Windows 歌词页播放 うさぎとかめ / 平沢唯(CV:豊崎愛生)，整页罗马音纯文本）
- **真实性**：✅ 真 bug（语言部分）。日志里同曲 sidecar / 内嵌都没有（`resolve` 的 ②③ 早返回没触发），罗马音来自 LRCLIB。根因：
  - `fushi/lib/src/media/music/lyrics/music_lyrics_service.dart` `_resolveLrclib`（修前 574-608）：`/api/get` 命中的 `bestLyrics` 不看正文书写系统直接落库、返回，罗马音 / 翻译版与原文版一视同仁；缓存命中同样直接返回。
  - `fushi/lib/src/media/music/lyrics/lyrics_candidate_scoring.dart` `pickBestLyricsCandidate`（修前 145-185）只按标题 / 艺人 / 时长评分，分不出同名的原文版与罗马音版。
  - `resolve`（修前 531-553）LRCLIB 固定第一，罗马音命中直接 return，带原文的歌词插件没机会。
  - 位置部分：截图是旧版 `music_lyrics_page.dart` 固定 `width: 380` 左栏布局，88712fbf45（2026-10-29）已重写为 split / stage / disc 三种布局，非本条代码修复范围。
- **[x] ① 已修复** — 新增纯函数 `lyricsScriptProfile` / `expectedLyricsScript` / `lyricsScriptFit` / `lyricsScriptMismatches`（按元数据推断期望书写系统：有假名→日文、谚文→韩文、汉字→汉字系，全拉丁字母不推断）；`_resolveLrclib` 对不上时按 `lyricsQueries` 走 `/api/search`（LRCLIB 客户端新增 `q` 参数）挑同名、同录音时长（±2 s）且书写系统对得上的记录；挑不到就留着但排到歌词插件之后；缓存的对不上行每 `kLrclibNegativeCacheTtl` 重挑一次（改版前落库的旧行首次解析即重挑），保留用户偏移。`pickBestLyricsCandidate` 对带正文的候选加书写系统权重并可要求必须对得上；在线搜索结果原文版排前，选来源 / 在线搜索列表副标题标出书写系统。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_script_selection_test.dart`（离线 LrclibTransport fixture：罗马音 get + 原文 search → 选原文；拉丁字母曲目不额外搜索；同名原文按时长裁决；搜不到原文时插件胜出；无插件仍用罗马音且 TTL 内不重挑；搜索失败不落库；旧缓存罗马音行重挑保留偏移；在线搜索排序与书写系统标注）。把 `_resolveLrclib` 的期望书写系统变异成 null 时其中 5 条变红。
- **备注**：没有沿用「学习语言=日文」作先验：元数据全是拉丁字母时英文歌与罗马字标题日文歌分不开，按学习语言判会让所有英文歌都被降到插件之后、多一次搜索。原始那条 LRCLIB 罗马音记录现已查不到（`/api/get` 今天 404），fixture 按截图文字构造。位置部分（split / stage 布局在 plain 歌词下的视觉位置）未做 Windows 2560x1440@1.5x 实机截图复核，待补。
