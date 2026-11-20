## BUG-4937 · music-grid-layout-still-blocks
- **报告**：2026-11-17（用户：应用内反馈 Tj28bZywxp，Windows 3.3.0-debug.28450）「外观选择封面网格后音乐板块没有变化」，截图是网易云歌单详情，曲目仍是带大字水印的封面色块。
- **真实性**：✅ 真 bug。设置里这一档是「封面网格（原来的）」，色块排布本身不接这一档（`fushi/lib/src/utils/components/fushi_cover_block_layout.dart:21`：「[ShellContentLayout.grid] 不走这里——调用点保留原封面网格」）。音乐模块的「色块 / 列表」分流只看样式、不看库页布局，封面网格下仍把 `shellContentLayoutOf(context)`（= grid）喂给 `FushiCoverBlocks` / `SliverFushiCoverBlocks`：
  - 共用层 `fushi/lib/src/pages/implementations/music/music_collection_view.dart` `MusicStyledCollection._body`（原 418-447）：没有原有网格卡（`gridCardBuilder == null`）时封面网格下照排色块（原注释明写「null = 网格布局下也排色块」）——曲库艺人 / 本地歌单、插件搜索结果、曲目列表都走这里；
  - 各页自写的判据只看 `style == MusicViewStyle.blocks`（外加「重设计外壳」）：`music_track_list.dart:688`、`music_album_page.dart:792`、`music_plugin_detail_pages.dart:621`（反馈截图这一页）/ `1157`、`music_server_pages.dart:1156` / `2276`、`music_apple_music_pages.dart:321` / `927` / `1040`、`music_local_playlist_page.dart:277`、`music_plugin_pages.dart:2137`。
  - 推荐页（`musicRecommendPosterMode`）与有原有网格卡的专辑 / 来源歌单本来就按封面网格分流，所以只有曲目、艺人、本地歌单这几类还是色块。
- **[x] ① 已修复** — `music_collection_view.dart` 新增唯一判据 `musicCoverBlocksActive(context, style)`（色块样式 && 重设计外壳 && 库页布局不是封面网格）；`MusicStyledCollection` 封面网格下有原有网格卡排网格卡、没有就排单列行（曲目 / 艺人 / 本地歌单改版前都是单列行）；上面各页的色块分支一律改走这个判据，封面网格下回到各页原有的行 / 可拖动排序列表。拼贴下行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_grid_layout_original_view_test.dart`：判据三种组合；`MusicStyledCollection` 封面网格无卡 → 行、有卡 → 网格卡、拼贴 → 色块；真 `MusicTrackList`（色块样式）封面网格下是 `MusicTrackRowSurface` 行、没有 `MusicTrackBlock`，拼贴下仍是 `MusicTrackBlock`。
- **备注**：封面网格下曲目 / 艺人 / 本地歌单页头仍有「色块 / 列表」切换键，两种都排行（切换键的去留属 UI 取舍，未动）。分诊说「整个 music 目录只有 music_apple_music_pages.dart:307 读了 grid」与代码不符：`MusicStyledCollection._useGridCards`、`musicRecommendPosterMode` 等也读，缺口只在没有原有网格卡的视图。
