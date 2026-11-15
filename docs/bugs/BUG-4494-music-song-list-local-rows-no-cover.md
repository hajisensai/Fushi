## BUG-4494 · 音乐「歌曲」分区本地曲目行全是音符图标，不显示封面
- **报告**：2026-11-11（用户：应用内反馈 EMjx7gJftH / GitHub issue #3352；Windows）
- **真实性**：✅ 真 bug。专辑网格与「继续收听」都能显示（内嵌 / 目录）封面，同一列表里的远程曲目行也画封面（`music_track_list.dart` `_remoteRow` 用 `MusicCover`），唯独本地曲目行不画。根因：`fushi/lib/src/pages/implementations/music/music_track_list.dart:474` `_localRow` 的 leading 在不显示轨号时写死 `const FushiListLeadingIcon(FushiIcons.music)`，根本没接专辑的 `coverPath` / `coverTrackUid` 或曲目的 `hasEmbeddedCover`。影响歌曲分区、艺人页、本地歌单；专辑页显示轨号不受影响。
- **[x] ① 已修复** — 本地行改画 `musicMaterialCover(MusicCover(...), size: 40, compact: true)`（与远程行同尺寸同材质）。来源由新纯函数 `musicLocalTrackCoverOf` 决定，与专辑网格 / 继续收听同一口径：专辑目录封面优先；其次专辑选定的内嵌封面曲目（`coverTrackUid`，同一张专辑各行共用一次读取、走 `MusicEmbeddedCoverCache`）；那首不在本列表时退回本曲自己的内嵌封面；都没有画占位。列表内 uid → 路径表 `musicLocalTrackPathsOf` 随列表换新时重算。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_track_list_cover_bug4494_test.dart`：纯函数 3 条（目录封面 + 共用内嵌、选定曲目不在列表时回退本曲、无封面占位）+ 真 `MusicTrackList` widget 测试 2 条（歌曲分区每行是 `MusicCover` 且参数正确；专辑页轨号模式不画封面）。
- **备注**：未在真机肉眼复测；判据由 widget 测试咬住传给 `MusicCover` 的来源参数，`MusicCover` 的取图逻辑本身未改（专辑网格已在用）。
