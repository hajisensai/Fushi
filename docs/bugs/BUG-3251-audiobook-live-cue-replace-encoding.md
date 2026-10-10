## BUG-3251 · 播放中换字幕后周期写入仍按旧 cue 编码，被杀则断点错位
- **报告**：2026-10-10（PR #2032 / BUG-3197 审查遗留疑点；BUG-3197 备注里自记的「已知剩余窗口」与「#2023 合入后应同样换算」两项）
- **真实性**：✅ 真 bug（代码路径确认 + 测试复现）。两处：
  1. 活会话：`fushi/lib/src/media/audiobook/audiobook_session.dart` 只在 `_stopInternal` 里按库里 cue 给 stop 位置换编码（BUG-3197）。书架重新导入 / 重新匹配字幕时这本书正在后台播放，控制器仍持旧 cue，`AudiobookPlayerController` 的周期位置写入一直按旧 cue 推出的文件时长编码，覆盖掉仓库层刚换算好的新编码；不经 stop 直接被杀，库里留下旧编码，下次开书按新 cue 一拆，多文件有声书的断点落到别的文件 / 偏移。
  2. 互联「只更新字幕」：`packages/fushi_engine/lib/sync/sync_asset_package_service.dart` `importAudioSubtitlePackage` 直接 `_db.replaceCuesForBook`，完全没有换算本机断点（BUG-3197 的换算只在 `AudiobookRepository.saveCues` / `SrtBookRepository.saveCues`）。
- **[x] ① 已修复** — 会话起播后监听 `audio_cues` 表的提交（`tableUpdates`），正在播的这本书的 cue 被整组替换且推出的文件时长变了，就把库里的新 cue 交给活控制器（`AudiobookPlayerController.adoptReplacedBookCues`），之后的周期写入立即按新编码；`saveCues`（两个仓库）把「换 cue + 换算库里进度」包进同一事务，保证提交通知晚于换算、不会把会话按新编码写下的值再换一遍；「只更新字幕」两条分支改走 `_replaceCuesKeepingPosition`（同一事务内换 cue + 换算）。提交见 `fix(audiobook): re-encode live and refreshed positions when cues are replaced`。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/audiobook_session_test.dart`「BUG-3251 replacing the cues while playing switches periodic writes to the new encoding at once」（去掉监听即红：仍是 13000）；`fushi/test/sync/interconnect_audiobook_refetch_test.dart`「只更新字幕：多文件断点按新 cue 换编码，真实位置不变」。
- **备注**：仍剩「换 cue 事务提交 → 会话读到新 cue」之间约一次读库的窗口，期间若恰有一次旧编码周期写入、随后进程被杀，会留旧编码；下一次周期写入即自愈。
