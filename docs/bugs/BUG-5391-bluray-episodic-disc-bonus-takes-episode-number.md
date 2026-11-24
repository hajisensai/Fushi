## BUG-5391 · bluray-episodic-disc-bonus-takes-episode-number
- **报告**：2026-11-24（用户：ぼっち・ざ・ろっく！ 蓝光六卷合集「选集」16 项，标题与剧照每 3 项循环「転がるぼっち / また明日 / 馳せサンズ」，第 6/9/12 项实际是真人采访特典，很多集没有图）
- **真实性**：✅ 真 bug。只读核对用户库与真实盘（`D:\video\播放列表合集\ぼっち・ざ・ろっく！ [BDMV] (2022)\…vol.N\BD`）：每卷 `00001.mpls` 串着两集（1421 s × 2 + 8 s），被按 PlayItem 切成 `00001.p01/p02`；另有一条整播放列表的特典——vol.1 `00005` 32.8 分钟（1 段）、vol.2 `00003` 28.9 分钟（6 段）、vol.3 `00003` 94.5 分钟、vol.4 `00003` 35.9 分钟、vol.5 `00003` 9.2 分钟与 `00004` 23.6 分钟（1 段，与单集只差 5 秒）、vol.6 `00002` 95.4 分钟。三处根因：
  1. `packages/fushi_engine/lib/media/video/bluray/bluray_disc.dart` `selectBlurayTitles` 第 6 步相对下限（最长者 × 0.15）只挡几分钟的花絮，这些特典全过，第 7 步把它们与切出来的各集并列成标题（`<盘名> - 03`）→ 进盘合集；刮削协调器 `discOrdinalEpisodeOverrides`（`video_source_scrape_coordinator.dart`）按合集成员顺序编集号，第 3 集成了 vol.1 的采访、之后每集错位。修 BUG-5251 之前每卷各一个合集、各自从 1 编，于是每卷都是「1 2 3」，即用户看到的三项循环。
  2. 展示侧 `video_filename_parser.dart` `_acceptedSiblingNumbering` 对 `00001.p01.mpls` / `00001.p02.mpls` 做兄弟差分，按 PlayItem 序号定成第 1、2 集——特典降级后六卷会显示成「1 2 1 2 …」（合集详情页 `_episodeDisplayNumber`、选集面板都走 `parsedEpisodeNumbersOf`）。
  3. 存量：已被当成正片的特典行名字仍是 `… - 03`，身上挂着刮来的「第 3 集 馳せサンズ」集级刮削行与分集绑定；特典不进刮削计划，重刮永远不会再碰它们。
- **[x] ① 已修复** —
  - `bluray_disc.dart` `selectBlurayTitles` 新增 7b：盘上有被切成集的播放列表时，没被它串进去的其余整条标题降为特典（`selectBlurayExtras` 接住，名为 `<盘名> - <MPLS 号>`），不进盘合集、不占集号；没有切集的盘不受影响。真实六卷只读重跑：每卷标题只剩 `p01/p02`，特典 1～5 条。
  - `video_filename_parser.dart` `_acceptedSiblingNumbering`：原盘成员（`isDiscMemberPath`）不做兄弟差分，解析不出交给调用方回落顺位号，与刮削按合集顺序编的集号同一口径。
  - `disc_library_import.dart` `_syncAutoDiscTitleNames`：每轮把盘上标题 / 特典行的自动名（`_isAutoDiscTitle` 形状）对齐到本轮结论，`… 1 - 03` 改回 `… 1 - 00005`；用户改过的名字不动。
  - `video_source_metadata_indexer.dart` `_dropStaleDiscExtraEpisode`：索引器把原盘特典挂到正片作品下时，删掉它身上的刮削行、解开分集绑定（用户手动钉死的绑定除外）。
  - 存量库用用户库快照（只读拷贝）跑「导入 → 计划 → 索引」：发布组合集 12 集按卷序排，刮削计划集号 (1,1)…(1,12)，特典行改名、残留「馳せサンズ」刮削行清掉；用户真实库需重扫该来源后再重刮一次，集名 / 剧照才按新集号落到各集。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/video/bluray/bluray_episode_test.dart`「BUG-5391：切成集的盘上…长特典降为特典」「没有切集的盘：…照旧是标题」「BUG-5391：展示集号不从分集文件名差分」；`packages/fushi_engine/test/media/video/disc/disc_release_set_import_test.dart`「BUG-5391：长特典不进合集、不占集号；存量「- 03」行改回特典名，残留的集号刮削行清掉」（导入 + 刮削计划集号 + 索引清理一条链）。
- **备注**：用户库里另有一个自己改名的合集 `BOCCHI THE ROCK! Blu-ray`（id 138，31 个成员含特典）。导入器按合集名认回自己的合集，认不出改过名的这个，重扫会另建 `BOCCHI THE ROCK!`；刮削计划仍按特典划分把 138 的成员剔成 12 集、集号正确，但 138 的选集列表里特典仍在、顺位号会与集号错开。按成员身份认领改名合集涉及「导入器能不能改用户合集」的取舍，未在本 bug 内处理。
