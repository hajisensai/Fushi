## BUG-5289 · 音乐歌词「已计句子」并集不跨设备同步
- **报告**：2026-11-23（来源：拍板台 qQTh1Q3G9U 方案 a 的「换设备同步后也不会重复计」一句，实现首期时登记的缺口）
- **真实性**：✅ 真缺口。音乐歌词字数的「每首每句只计一次」并集存在本机库偏好 `music_lyric_coverage_<trackUid>`（`fushi/lib/src/media/music/music_study_tracker.dart` 的 `musicLyricCoveragePrefKey` / `_saveCoverage`），偏好表不进聚合同步（`packages/fushi_engine/lib/sync/aggregate_merge_service.dart` 只同步收藏句等指定偏好），所以两台设备各听一遍同一句会各计一次。视频的 `video_watch_coverage_<uid>` 也是同样的形态和同样的缺口。
- **[ ] ① 未修复** — 方向：把「每曲已计句子并集」（以及视频片内覆盖并集）作为可同步的偏好块，按 `IntervalCoverage` 并集合并（与收藏句偏好块同一条聚合同步路径），对端落地时取并集、不覆盖；Profile 隔离与清空统计时连带清的语义要一起定。
- **[ ] ② 未加自动化测试** — 修复时在聚合合并层加「两端各自的并集 → 合并后取并集、不丢任何一边」的单测。
- **备注**：单设备的口径（跨会话只计一次）已经由 `music_study_tracker_test.dart` 覆盖；这里只缺跨设备那一半。
