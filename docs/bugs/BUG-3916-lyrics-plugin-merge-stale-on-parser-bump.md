## BUG-3916 · lyrics-plugin-merge-stale-on-parser-bump
- **报告**：2026-10-31（用户：合并第三方 PR #2674 前的审查发现）
- **真实性**：✅ 真 bug。歌词插件来源（⑤）缓存命中时走 `_timelineOf`，版本对不上只重解析落库的「原文 + 译文合并后」
  派生 TTML（`fushi/lib/src/media/music/lyrics/music_lyrics_service.dart:578`，PR 版本）；而 ③'（同文件 `:413`）
  的注释已经写明合并规则随 `FushiLyrics.parserVersion` 变、只重解析派生 TTML 修不好旧合并结果。根因是落库存的是
  派生物而不是插件给的原始各轨，任何读者（含语料索引 `library_corpus_service.dart` 的 `_timelineOf`）都没法用新解析器重合并。
- **[x] ① 已修复** — 有译文时落库插件原始各轨（format `plugin-tracks`，`MusicPluginLyrics.toJson`）；新增
  `parseStoredMusicLyrics` 作为 `music_lyrics` 行 → 时间轴的唯一入口（服务 `_timelineOf` 与语料索引共用），版本对不上时
  用当前解析器从原始各轨就地重新合并，③' 与 ⑤ 共用同一条新鲜度路径、无需联网。早期落成合并 TTML 的 ③' 旧行仍按原逻辑
  回插件重取（取不到先用旧结果、不回写版本）。顺带修掉语料索引对手动指定 ASS 行按 TTML 解析的分叉。
  提交：`fix(music-lyrics): separate lyrics-plugin cache key and store raw plugin tracks`（feat/batch3-lyrics-plugins）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lyrics_service_plugins_test.dart`「歌词插件结果的缓存新鲜度（解析器版本）」组
  （落库原始各轨 / 版本落后时离线重新合并且不问插件 / 原始各轨损坏报解析错误）；`fushi/test/media/music/plugin/music_plugins_test.dart`
  「逐字 YRC + 译文合并」用例补版本落后重建断言。
- **备注**：选择「存原始各轨」而不是审查建议的「持久化候选 ref、版本变了回插件 lyricsFetch」：后者要加列（schema 迁移）、
  每次解析器升级都要联网且失败时只能顶旧结果；前者无迁移、离线可修、语料索引同路径。
