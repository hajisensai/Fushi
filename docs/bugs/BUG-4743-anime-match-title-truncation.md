## BUG-4743 · anime-match-title-truncation
- **报告**：2026-11-16（用户：维护者，应用内反馈 rB3cuyTXBr「番剧匹配，名字显示不全」，Windows 3.3.0+1368）
- **真实性**：✅ 真 bug。合集字幕面板「番剧匹配」区把 AniList 候选画成 chip，`fushi/lib/src/pages/implementations/subtitle_collection_panel.dart:1567-1583`（修前）每个 chip 套 `ConstrainedBox(maxWidth: 260)`、标题 `maxLines: 1` + 省略号；而且 chip 本身也不是长标题的容器——MD3 `RawChip` 把 label 包进 `DefaultTextStyle(maxLines: 1, softWrap: false)`，高度按未扣图标宽度时的 dry layout 定（选中出对勾后换行行数会变多却不长高），Apple `_glassChip` 同样强制单行省略。同系列各季的 romaji 前缀相同（`… 2nd Season` 只差在末尾），截断后多个候选显示成同一串，用户无从选系列。
- **[x] ① 已修复** — 候选改成与同面板「字幕版本」同构的单选列表行（`FushiStaggeredEntrance` + `FushiGroupedListItem` + `FushiListItem`，行首 `_selectionMark`），标题 `titleMaxLines: null` 不限行，按面板宽度换行；tooltip 不再需要。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_collection_panel_test.dart`「MD3 / Apple：番剧匹配候选标题完整显示，同前缀的季能区分」：480 宽面板里两条同前缀长 romaji 候选，断言各自 `RenderParagraph.didExceedMaxLines == false` 且不越出面板右缘。
- **备注**：没做真机复测；截图未见，定位依据是 i18n `video_jimaku_anime_match`「番剧匹配」的唯一使用点。
