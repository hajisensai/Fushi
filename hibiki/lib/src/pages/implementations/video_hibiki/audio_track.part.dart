// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch9).
part of '../video_hibiki_page.dart';

/// Audio-track domain methods extracted via part-of (TODO-590 batch9); shared
/// private scope. Behaviour-preserving: bodies are verbatim except the lone
/// `setState(() => _currentAudioTrackId = track.id)` rebuild inside
/// [_selectAudioTrack] is routed through the main shell's `_rebuild(...)`
/// forwarder (the established part paradigm — an extension cannot call the
/// @protected `State.setState` directly). Everything else is moved
/// character-for-character.
///
/// Covers persisted audio-track restoration ([_restoreAudioTrack]), explicit
/// track selection ([_selectAudioTrack]), the side-panel entry point
/// ([_showAudioTrackMenu]), the audio-track side panel UI
/// ([_buildAudioTracksSidePanel]) and the shared track-label helper
/// ([_trackLabel], also consumed by the subtitle/remote domains).
///
/// The instance field (`_currentAudioTrackId`), the `_VideoSidePanelKind` enum,
/// and every collaborator getter/method (`_videoChromeColorScheme`,
/// `_showVideoSidePanel`, `_showOsd`, the `widget.repo` audio-track persistence,
/// the controller's `audioTracks` / `selectAudioTrack`) stay in the main shell;
/// the extension reads/calls instance members through the shared private scope.
extension _VideoAudioTrack on _VideoHibikiPageState {
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
    await widget.repo.updateAudioTrackId(widget.bookUid, track.id);
    if (!mounted) return;
    _rebuild(() => _currentAudioTrackId = track.id);
    _showOsd(
      t.video_audio_track_switched(
        label: _trackLabel(track.title, track.language, track.id),
      ),
    );
  }

  /// 弹音轨菜单（顶栏 ♪ 按钮共用）。
  void _showAudioTrackMenu(
    VideoPlayerController _, {
    VideoControlSlot? sourceSlot,
  }) {
    _showVideoSidePanel(
      _VideoSidePanelKind.audioTracks,
      sourceSlot: sourceSlot,
    );
  }

  Widget _buildAudioTracksSidePanel(VideoPlayerController controller) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<AudioTrack> tracks = controller.audioTracks;
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.video_audio_track,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (BuildContext _, int i) {
        final AudioTrack track = tracks[i];
        final String label = _trackLabel(
          track.title,
          track.language,
          track.id,
        );
        final bool selected = _currentAudioTrackId == track.id;
        return ListTile(
          dense: true,
          leading: const Icon(Icons.audiotrack),
          title: Text(label),
          selected: selected,
          selectedColor: cs.primary,
          trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
          onTap: () => unawaited(_selectAudioTrack(controller, track)),
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
