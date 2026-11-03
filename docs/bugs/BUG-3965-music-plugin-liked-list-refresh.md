## BUG-3965 · music-plugin-liked-list-refresh
- **报告**：2026-11-02（用户：应用内反馈 pkBiUfDPl4）——音乐插件「我喜欢」歌单页，喜欢 / 取消喜欢后列表不刷新。
- **真实性**：✅ 真 bug。`MusicPluginFavorites.toggle`（`fushi/lib/src/media/music/plugin/music_plugin_favorites.dart` 原 205-227）只改内存喜欢集合并 notify，没有「喜欢歌单内容已变」的信号；歌单详情页 `_MusicPluginCollectionPageState`（`fushi/lib/src/pages/implementations/music/music_plugin_detail_pages.dart` 原 259 `late Future _data = _load()`）只在 initState 拉一次曲目，不订阅收藏状态。
- **[x] ① 已修复** — 收藏状态暴露 `likedPlaylistOf` / `isLikedPlaylist`（按 id 认出喜欢歌单，不管从哪个入口打开）与每插件单调递增的 `likedRevisionOf`（toggle 成功、重拉到不同内容、退出登录才 +1）；歌单详情页在歌单模式订阅收藏状态，认出是喜欢歌单且修订号变了就重拉曲目（FutureBuilder 保留旧数据，不闪加载态），dispose 移除监听。（未提交）
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_plugin_favorites_test.dart`（喜欢歌单识别 + 修订号语义：toggle / 相同内容重拉不变 / 外部变化 / 失败不变 / 退出登录）。
- **备注**：详情页订阅接线没有 widget 测试（页面依赖 `musicPluginManager.source()` 的真插件宿主，替身成本高），由修订号单测 + 代码审查覆盖；如需更强层应补假 `MusicPluginSource` 的 widget 测试。
