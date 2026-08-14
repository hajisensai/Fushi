// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch9).
part of '../video_fushi_page.dart';

/// Audio-track domain methods extracted via part-of (TODO-590 batch9); shared
/// private scope. Behaviour-preserving: bodies are verbatim except the lone
/// `setState(() => _currentAudioTrackId = track.id)` rebuild inside
/// [_selectAudioTrack] is routed through the main shell's `_rebuild(...)`
/// forwarder (the established part paradigm — an extension cannot call the
/// @protected `State.setState` directly). Everything else is moved
/// character-for-character.
///
/// Covers persisted audio-track restoration ([_restoreAudioTrack]), explicit
/// track selection ([_selectAudioTrack]), the settings-panel entry point
/// ([_showAudioTrackMenu], TODO-1351 now routes to the settings sheet's `audio`
/// category), the in-panel audio-track UI ([_buildAudioTrackSettingsSection]) and
/// the shared track-label helper ([_trackLabel], also consumed by the
/// subtitle/remote domains).
///
/// The instance field (`_currentAudioTrackId`), the `_VideoSidePanelKind` enum,
/// and every collaborator getter/method (`_videoChromeColorScheme`,
/// `_showVideoSidePanel`, `_showOsd`, the `widget.repo` audio-track persistence,
/// the controller's `audioTracks` / `selectAudioTrack`) stay in the main shell;
/// the extension reads/calls instance members through the shared private scope.
extension _VideoAudioTrack on _VideoFushiPageState {
  /// 若有持久化音轨偏好 [_currentAudioTrackId]，在 [controller] 的 audioTracks 里
  /// 按 id 匹配并切换，恢复用户上次选的音轨（退出重进 / 换集复用）。
  ///
  /// audioTracks 在 libmpv `open` 后才**逐步**填充，时机随设备/首帧不定。旧实现固定
  /// 等 300ms 后**单次**匹配，列表此刻常仍为空 → 匹配不到、且不重试 → 用户报「音频
  /// 切换退出重进又得重新弄」。改为**有界轮询**：每 200ms 重试，最多 ~4s，直到列表里
  /// 出现目标轨再切；期间换片/卸载（`_controller != controller`）即放弃。
  Future<void> _restoreAudioTrack(VideoPlayerController controller) async {
    final String? wantId = _currentAudioTrackId;
    if (wantId == null || wantId.isEmpty) return;
    for (int attempt = 0; attempt < 20; attempt++) {
      if (!mounted || _controller != controller) return;
      for (final AudioTrack track in controller.audioTracks) {
        if (track.id == wantId) {
          await controller.selectAudioTrack(track);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 选中某音轨：切轨 + 持久化 id（换集复用）+ SnackBar。
  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    AudioTrack track,
  ) async {
    await controller.selectAudioTrack(track);
    // 同系列音轨记忆（schema v52）：合集内选音轨写系列级，全系列共享（换集/从书架
    // 重进任一集都读到）；单文件视频（无合集）仍走 per-book，行为与旧版一致。
    //
    // 互联远端音轨持久化 bug：远端播放在 client 无 VideoBooks 行，旧路径
    // `updateAudioTrackId(远端uid)` 是静默 0 行 UPDATE（选轨退出即丢）。改按稳定
    // 远端 uid（合集连播 = 当前成员 id，与断点键 [_remotePositionKeyForIndex]
    // 同构）落 prefs，重进 [_initRemote] / [_loadRemoteEpisode] 优先重放。
    if (_isRemote) {
      final (String uid, _) = _remotePositionKeyForIndex(_currentEpisode);
      await appModel.setRemoteAudioTrackId(uid, track.id);
    } else {
      final int? collectionId = widget.playlistCollectionId;
      if (collectionId != null) {
        await widget.repo.updateCollectionAudioTrackId(collectionId, track.id);
      } else {
        await widget.repo.updateAudioTrackId(widget.bookUid, track.id);
      }
    }
    if (!mounted) return;
    _rebuild(() => _currentAudioTrackId = track.id);
    _showOsd(
      t.video_audio_track_switched(
        label: _trackLabel(track.title, track.language, track.id),
      ),
    );
  }

  /// 弹音轨切换（顶栏 ♪ 按钮 / 右键菜单共用）。TODO-1351：音轨切换收进设置面板的
  /// 「音频」分类（取代原来外面浮的音轨侧栏），此入口直接把设置面板开在 `audio` tab。
  void _showAudioTrackMenu(
    VideoPlayerController _, {
    VideoControlSlot? sourceSlot,
  }) {
    _showPlayerSettings(sourceSlot: sourceSlot, initialCategory: 'audio');
  }

  /// TODO-1351：设置面板「音频」分类里的音轨切换区（取代外面浮的音轨侧栏）。用
  /// [Builder] 让配色随设置面板自身主题（浅色 MD3）解析，而非视频 chrome 深色。轨列表
  /// 读 controller 的 audioTracks、选中态 [_currentAudioTrackId]，点某轨走既有
  /// [_selectAudioTrack]（切轨 + 持久化 + OSD）。空列表显示占位。
  Widget _buildAudioTrackSettingsSection(VideoPlayerController controller) {
    return Builder(
      builder: (BuildContext context) {
        final ColorScheme cs = Theme.of(context).colorScheme;
        final List<AudioTrack> tracks = controller.audioTracks;
        if (tracks.isEmpty) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.audiotrack),
            title: Text(t.video_audio_track_empty),
            enabled: false,
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final AudioTrack track in tracks)
              ListTile(
                dense: true,
                leading: const Icon(Icons.audiotrack),
                title: Text(_trackLabel(track.title, track.language, track.id)),
                selected: _currentAudioTrackId == track.id,
                selectedColor: cs.primary,
                trailing: _currentAudioTrackId == track.id
                    ? Icon(Icons.check, color: cs.primary)
                    : null,
                onTap: () => unawaited(_selectAudioTrack(controller, track)),
              ),
          ],
        );
      },
    );
  }

  String _trackLabel(String? title, String? language, String id) {
    if ((title ?? '').isNotEmpty) return title!;
    if ((language ?? '').isNotEmpty) return language!;
    return id;
  }
}
