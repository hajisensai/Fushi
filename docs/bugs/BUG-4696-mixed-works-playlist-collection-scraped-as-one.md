## BUG-4696 · 装着不同作品的清单合集被当成一部作品去识别
- **报告**：2026-11-15（用户：待确认列表里「哆啦A梦剧场版合集 播放列表」有 44 个候选，「AI 判断的层级不对」）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart` 的 `plan`：只要成员文件名带集号、又在一个多成员合集里，就整个合集当一个剧集单元。用户库的合集 84 来自 `哆啦A梦剧场版合集 播放列表.m3u8`，成员是 `哆啦A梦：大雄与天空的理想乡 - S00E01.mkv`、`哆啦A梦：大雄的地球交响乐 - S00E01.mkv`（旧整理器把剧场版命名成特典集号）——两部不同的电影。运行记录（run 3791）里 AI 的理由就是「这是多部剧场版的合集，不对应任何单一候选」，置信度 0：AI 没错，是交给它的单元错了。拆开之后还有第二层：单文件按文件名 `S00E01` 猜成剧集，离线标题索引报 `matches only entries of another media type`（标题只对得上电影条目）。
- **[x] ① 已修复** — 计划器：合集里 ≥ 2 个成员、文件名解出的作品名两两不同时，各成员各自成一个作品单元（合集本身不动，仍是用户的播放清单）；只要有两个成员同名就不拆，部分混装仍走文件哈希按作品拆。协调器：形态只是按文件名猜的单文件，离线标题索引按该形态查不到、换一种形态唯一精确命中时以命中为准。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_source_work_planner_test.dart`（「成员分属不同作品的清单合集按文件各自识别」，含同作品两集的对照）；`fushi/test/media/video/metadata/offline_identity_coordinator_test.dart`（「single file guessed as TV adopts the unique movie hit of the title」）。
- **备注**：这两部电影用户后来按新命名又下了一份（`映画ドラえもん のび太と空の理想郷 (2023)` 等），旧的 `Season 00/… - S00E01.mkv` 是历史遗留文件，本条只让它们能自动识别，不动磁盘上的命名。
