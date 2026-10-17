## BUG-2965 · 剧场版合集包Movie 01…25被误判带集号，只入库一部其余进Extras
- **报告**：2026-10-06（给用户补齐哆啦A梦剧场版时，最好的 1980–2004 片源是一个 25 部合集种子 `[Fabre-RAW] Doraemon Movies 01-25 (1980-2004) [WEB-DL 1080p]`，文件名形如 `[Fabre-RAW] Doraemon Movie 01 (1980) [1080p].mkv`；投进下载管线前沿代码核对整理路径时发现）
- **真实性**：✅ 真 bug（沿代码路径定位，未在真机下 157 GiB 复现）。movie 形态种子整理时，最大文件当主片，其余文件要过 `_isStandaloneMovieCandidate`（`packages/fushi_engine/lib/media/video/download/video_download_organizer.dart`）才算并列正片，判据末条是「文件名解析不出集号」。`Doraemon Movie 01` 去掉方括号 / 圆括号后，`Movie` 只置 `isMovieHint`，尾部 `01` 被当成第 1 集——于是 24 部全进 `<Title>/Extras/`，持久化成 `kind: extra`，导入只取 `video` 行：库里只有一部、其余 24 部躺在磁盘上不入库不刮削。同文件的 `looksLikeEpisodicPack` 早已按同一判据跳过带电影提示的文件（BUG-2760），两处对同一问题口径不一。
- **[x] ① 已修复** — `_isStandaloneMovieCandidate`：带电影提示的文件，序号是「第几部」不是集号，直接算并列正片（与 `looksLikeEpisodicPack` 同口径）；不带提示的 `Bonus - 01` 仍进 Extras。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`「a numbered movie pack (Movie 01…NN) keeps every film as a standalone movie…（BUG-2965）」（变异实测：去掉该判据即红，三部里两部掉进 Extras）。
- **备注**：主片（最大文件）仍沿用 job 标题（BUG-2007 契约：字幕搜索与身份都挂在主片上）；合集包投递时应以最大那部的片名作 job 标题。
