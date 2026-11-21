## BUG-5044 · 视频播放页收藏星标在页外改收藏后不刷新
- **报告**：2026-11-20（来源：路线图 #3722 c51 遗留，PR #3821 审查）
- **真实性**：✅ 真 bug。播放页的收藏镜像 `_favoritedVideoSentences`（`fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart` 的 `_refreshFavoritedCueCache`）只在换集 / 打开面板 / 本页增删 / 手机遥控回调时重填；`FavoriteSentenceRepository`（`packages/fushi_audio/lib/src/audiobook/favorite_sentence_repository.dart`）是无状态仓库，没有变更通知，收藏夹页、同步合并（`aggregate_sync_service.dart`）、备份恢复直接写同一个偏好键 `favorite_sentences` 后，播放页的查词浮层星标与字幕条星标一直是旧状态。
- **[x] ① 已修复** — `FushiDatabase.watchPrefChanged(key)`（`tableUpdates(preferences)` 后重读该键，值变了才发）；`FavoriteSentenceRepository.watchChanges()` 暴露它；播放页在镜像第一次填充时订阅，任何来源改了收藏都重填镜像，退页取消。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/favorite_sentence_change_stream_test.dart`（仓库增删 / 绕过仓库直写都发，别的偏好与同值重写不发）；`fushi/test/pages/video_lookup_favorite_mirror_test.dart` 的「页外收藏 / 取消收藏：镜像自动跟上」（真实页面 State）。
- **备注**：变更流只看得到本进程经同一个 `FushiDatabase` 的写入；弹窗词典等其它进程写收藏不在覆盖内（与现有偏好跨进程同步口径一致）。
