## BUG-1636 · 互联远端视频音轨选择不持久化
- **报告**：2026-08-14（互联完整支持批次巡查发现，与 [BUG-1620] 同族）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi/audio_track.part.dart` `_selectAudioTrack`：远端播放（`VideoFushiPage.remote` 恒 `playlistCollectionId == null`）落进 `repo.updateAudioTrackId(远端uid)` —— client 没有该 uid 的 VideoBooks 行，**静默 0 行 UPDATE**；且起播 `_initRemote` 恒 `_currentAudioTrackId = null`，host 端的音轨偏好（`VideoBooks.audioTrackId` / 系列级 `MediaCollections.audioTrackId`）也从不下发。多音轨视频远端播放每次都要重选音轨。
- **[x] ① 已修复** —（本分支提交）
  - client：`_selectAudioTrack` 远端分支按稳定远端 uid（合集连播 = 当前成员 id）落 `video_remote_audio_track` prefs（JSON map，`PreferencesRepository.remoteAudioTrackId`，与远端字幕选择 `video_remote_subtitle` 同范式）；起播三处（`_initRemote` 单视频/合集起播 + `_loadRemoteEpisode` 换成员）恢复 `本机 prefs ?? host 下发值`，由既有 `_restoreAudioTrack` 应用。
  - host：清单新增 additive 字段 `RemoteVideoInfo.audioTrackId` = `effectiveSeriesAudioTrackId(系列级, row)`（host→client 半边：client 没选过时跟随 host 的选择；同一文件的轨 id 跨设备同义）。
  - ~~有意不做 client→host 上报~~ → **已实现**（用户拍板「全部修复、根本性修复」）：播放偏好同步泛化批把调轴/音轨/副字幕源/副字幕调轴统一成带戳字段模型（`VideoPlaybackSyncState`，逐字段严格较新者胜），`/delay` 端点泛化为 `/playback`，音轨选择两端双向收敛（`video_remote_audio_track_` 键对 + 清单带 `audioTrackUpdatedAtMs` + sweep）。
- **[x] ② 已加自动化测试** — `fushi/test/models/preferences_repository_test.dart`（remoteAudioTrackId set/read/清除/跨实例 reload）；`fushi/test/sync/fushi_library_host_service_video_test.dart`（清单下发系列级 ?? row 音轨）；`fushi/test/sync/video_delay_sync_test.dart`（DTO json 往返 + copyWith 不丢 + 旧 host 缺键向后兼容）。
- **备注**：同族修复（同一批次落地）：远端主字幕 `embedded:<n>` 选择此前不重放（重进落回 host 默认）→ 现按持久化编码向 host 重新抽取；远端副字幕从「完全不支持」到完整支持（TODO-2837，来源/调轴均本地持久化）。
