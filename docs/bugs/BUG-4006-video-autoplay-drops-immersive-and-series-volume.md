## BUG-4006 · 自动连播（本地换集）退出沉浸锁定，音量不跟随系列
- **报告**：2026-11-03（开发者反馈 #cehHSgF04K：「视频自动连播会取消沉浸模式。音量设置没有跟随系列」，Windows，3.3.0-debug.23079）
- **真实性**：✅ 真 bug，两个症状同一结构根因：统一合集 Phase 3 之后本地换集（手动上下集 / 列表选集 / 自动连播倒计时归零，都走 `_switchEpisode`）= pushReplacement 一个新的单集页，每集是独立 VideoBooks 行。
  - 沉浸锁定是页面局部状态 `fushi/lib/src/pages/implementations/video_fushi_page.dart:2277`（`ValueNotifier<bool>(false)`），换集构造新页 `fushi/lib/src/pages/implementations/video_fushi/episode.part.dart:233` 只交接了字幕列表与原生全屏，没交接锁定态 → 新页恒从未锁定开始。远端 / 网页换集原地换流、页面不换，不受影响。
  - 音量键 `fushi/lib/src/pages/implementations/video_fushi_page.dart:5046` `'video_volume_$_activeBookUid'`：注释与守卫（`video_volume_persist_static_test.dart`「playlist episodes must share one volume value」）写的都是「播放列表共享」，但 Phase 3 后 `_activeBookUid` 恒为当前集，实际成了每集一个音量，连播到下一集读到的是那集自己的值（多为默认 100）。守卫只钉了键的字面形状，把这个回归锁成了契约。
- **[x] ① 已修复** —
  - `VideoFushiPage` 新增 `initialImmersiveLocked`（默认构造与 `neutralized` 入口透传，`.remote` 恒 false）；`_switchEpisode` 交 `_immersiveLocked.value`，`initState` 在订阅 `_immersiveLocked` 之前播种，首帧控制条可见性就按锁定态派生。
  - 新增 `fushi/lib/src/media/video/video_volume_pref.dart`：合集内（`playlistCollectionId` 非空）读写系列键 `video_volume_collection_<id>`，单视频仍是冻结旧键 `video_volume_<bookUid>`；读取时系列键缺省回退本集旧键，修复前已存的值继续生效。页面 `_volumePrefKey` / `_readPersistedVolume` 改走它。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_autoplay_series_state_test.dart`（音量键纯函数、`neutralized` 真实构造透传 `initialImmersiveLocked`、换集交接与 initState 播种顺序、页面读写走系列键）；`fushi/test/media/video/video_volume_persist_static_test.dart` 改掉钉死旧键形状的断言。
- **备注**：倍速记忆 `video_speed_<bookUid>`（`_speedPrefKey`）有同样的「每集一个」问题，本反馈只报了音量，未改，待定是否一并改成系列级。新页以锁定态开局时没有像 `_toggleImmersiveLock` 那样立刻藏光标（光标按常规闲置隐藏），未在真机 / 桌面实测连播全流程。
