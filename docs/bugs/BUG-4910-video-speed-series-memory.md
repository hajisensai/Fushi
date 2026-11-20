## BUG-4910 · 倍速记忆本地每集一份、远端原地换集沿用，同一系列两边不一致
- **报告**：2026-11-20（来源：路线图 #3722 c45 的 video-s2-2，代码审读复核成立）
- **真实性**：✅ 真 bug。根因（基准 `origin/develop@7745effa2e`，`fushi/lib/src/pages/implementations/video_fushi_page.dart`）：
  - `:5510` 倍速键写死成 `video_speed_$_activeBookUid`。统一合集 Phase 3 之后合集里每集是独立 VideoBooks 行、本地换集是 pushReplacement 一个新单集页（`_activeBookUid` 换成下一集），`_initVideo` 的 `:4689` 按下一集自己的键读——多半没存过，回到 1.0。
  - 远端（互联 host 播放列表）原地换集 `_loadRemoteEpisode` 不重读倍速，沿用当前 `_playbackSpeed`；远端条目的 `_activeBookUid` 本身就是整部作品一个 uid。于是同一个「系列」本地换集倍速丢、远端换集倍速跟。
  - 音量记忆早已按同一根因改成系列键（`fushi/lib/src/media/video/video_volume_pref.dart`，cehHSgF04K），倍速漏了。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_speed_pref.dart`（照 `videoVolumeReadKeys` 的做法）：作为播放列表合集某一集打开时读写系列键 `video_speed_collection_<id>`，单视频 / 原盘 / 远端条目仍写本条目键；读时系列键缺省回退本集旧键 `video_speed_<bookUid>`（旧键冻结不改，迁移前已存的值继续生效）。`_speedPrefKey` / `_readPersistedSpeed` 改走它。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_speed_series_memory_test.dart`：键函数（合集写系列键、读顺序系列优先回退本集）+ 经真实开页路径（合集里的一集读到系列倍速、系列键缺省回退本集旧值、单视频不受系列键影响）。把读路径改回只读本集键的变异下「合集里的一集读系列倍速」红（实测）。
- **备注**：未做设备复测（本轮所有者定不做）：本地 / 远端合集换集后倍速沿用。
