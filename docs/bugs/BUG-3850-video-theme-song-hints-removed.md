## BUG-3850 · 已删的「跳过片头」按钮换了个实现又回来了，外加 OP 期间「♪ 曲名 · 在音乐库打开」角标，按用户决定两个提示都删
- **报告**：2026-10-27（用户：反馈 _Jw9woR5Vg / 工单 #65，Windows，截图为视频页左上角曲名角标 + 右下角「跳过片头」按钮）
- **真实性**：✅ 真 bug（沿真实代码路径确认）。BUG-3218 已按用户决定删掉章节名版「跳过片头 / 片尾」按钮；作品图谱 L2（`docs/specs/2026-10-24-cross-media-links.md` §2，声纹识别音乐库里的 OP / ED）又新做了一份：
  - `fushi/lib/src/media/video/theme_song/video_theme_song_overlay.dart`（已删）`VideoThemeSongOverlay`：位置落在识别出的 OP / ED 内就在右下角画「跳过片头 / 片尾」，任何段内都在左上角画「♪ 曲名 · 在音乐库打开」（点了压 `MusicTrackDetailPage`）；
  - 挂载点 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` 的 `_buildThemeSongOverlay()`，装配在 `video_fushi/theme_song.part.dart`。
  - 跳过按钮没有关闭入口（设置里只有「自动跳过」与「显示主题曲曲名」两项）——与 BUG-3218 的原始投诉一模一样。
  - BUG-3218 的守卫按旧符号名（`VideoSkipChapterButton` 等）钉，换了名字的新实现完全拦不住。
- **[x] ① 已修复** — 删 `VideoThemeSongOverlay` 整个渲染层（跳过按钮 + 曲名角标）、页面挂载与 `_skipThemeSong` / `_openThemeSongTrack`、设置项「显示主题曲曲名」及偏好键 `video_theme_song_now_playing`、5 个 i18n key（`i18n_sync --remove`）。状态机改名 `video_theme_song_tracker.dart`，只剩**默认关**的「自动跳过」（设置里显式打开才生效）与进度条上的段首 / 段尾刻度。PR 分支 `claude/skip-button-music-library-issues-ddb25a`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_skip_chapter_removed_guard_test.dart` 新增 BUG-3850 组：播放页不得再挂主题曲覆盖层 / 引用曲目页，覆盖层文件不得存在，并**按用户看得见的文案**钉一层——英文 i18n 里不得有任何以「Skip intro / opening / ending / credits / OP / ED」开头的文案、不得有 `video_*now_playing` key（换什么名字重做都过不了）；同时钉住自动跳过与刻度仍接线。`fushi/test/media/video/video_theme_song_tracker_test.dart` 覆盖自动跳过状态机（开关关着不跳、3 s 窗口只跳一次、插入曲不跳、换源解绑）。
- **备注**：旧库里 `video_theme_song_now_playing` 的残留行无人读，不迁移。群里提到的「音乐库联动」并非自动导出：用户自己让内置 AI 把特典 CD 挪进了音乐库；AI 做不到「关联作品」是另一个 bug，见 BUG-3802。
