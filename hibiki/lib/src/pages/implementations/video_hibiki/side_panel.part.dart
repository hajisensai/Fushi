// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch10).
part of '../video_hibiki_page.dart';

/// Side-panel domain methods extracted via part-of (TODO-590 batch10); shared
/// private scope. Behaviour-preserving: every body is moved
/// character-for-character. None of these methods call `State.setState` — the
/// open/close lifecycle is driven entirely through the `_videoSidePanel`
/// [ValueNotifier], so there is no `setState→_rebuild` normalisation here (and
/// none of the moved members is `static`, so no `_VideoHibikiPageState.`
/// qualification is needed either).
///
/// Covers the slot-aware alignment helper ([_sidePanelAlignmentForSlot]), the
/// generic open/close entry points ([_showVideoSidePanel] / [_hideVideoSidePanel]),
/// per-kind title/width tables ([_videoSidePanelTitle] / [_videoSidePanelWidth]),
/// the kind→child dispatcher ([_buildVideoSidePanelChild]), the tap-outside
/// barrier overlay ([_buildVideoSidePanelOverlay]) and the content/position
/// builder ([_buildVideoSidePanelContent]).
///
/// The `_videoSidePanel` notifier, the `_VideoSidePanelState`/`_VideoSidePanelKind`
/// types, the per-kind child builders (`_buildSpeedSidePanel`,
/// `_buildVideoQuickSettingsSheet`, `_buildSubtitleSourcesSidePanel`,
/// `_buildAudioTracksSidePanel`, `_buildChapterSidePanel`), the controls/rail
/// collaborators (`_clearRailHover`, `_hideVideoControlEditOverlay`,
/// `_hideControlPopover`, `_markControlsVisible`, `_pokeControlsVisible`,
/// `_refocusVideo`, `_clearSelectedMiningCues`), the `_subtitleListVisible` /
/// `_episodeListVisible` notifiers and `_videoUiScale` all stay in the main
/// shell; the extension reads/calls them through the shared private scope.
extension _VideoSidePanel on _VideoHibikiPageState {
  Alignment _sidePanelAlignmentForSlot(VideoControlSlot? sourceSlot) {
    switch (sourceSlot) {
      case VideoControlSlot.topLeft:
      case VideoControlSlot.bottomLeft:
      case VideoControlSlot.screenLeft:
        return Alignment.centerLeft;
      case VideoControlSlot.topRight:
      case VideoControlSlot.bottomRight:
      case VideoControlSlot.screenRight:
      case VideoControlSlot.bottomCenter:
      case VideoControlSlot.topCenter:
      case VideoControlSlot.hidden:
      case null:
        return Alignment.centerRight;
    }
  }

  void _showVideoSidePanel(
    _VideoSidePanelKind kind, {
    VideoControlSlot? sourceSlot,
  }) {
    _clearRailHover();
    _hideVideoControlEditOverlay(revealControls: false);
    _hideControlPopover();
    _videoSidePanel.value = _VideoSidePanelState(
      kind: kind,
      alignment: _sidePanelAlignmentForSlot(sourceSlot),
    );
    // 与 push-aside 字幕列表互斥（TODO-314）：开任何浮层都先关字幕列表。
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    // TODO-638：开任何浮层都关掉 push-aside 剧集列表（与字幕列表同处右栏，互斥）。
    if (_episodeListVisible.value) {
      _episodeListVisible.value = false;
    }
    // BUG-253：开面板时不再唤起背景控制条（旧 [_pokeControlsVisible]），而是立刻把
    // 已经在显示的 media_kit 控制条 / 右侧 rail 镜像收起，避免它们冒在面板后面。
    // 面板开着期间 [_markControlsVisible] / [_pokeControlsVisible] 都被门控成不可见。
    _markControlsVisible(false);
    _refocusVideo();
  }

  void _hideVideoSidePanel() {
    _videoSidePanel.value = null;
    // BUG-253：面板关闭后唤回一次控制条（poke 在 [_videoSidePanel] 复位为 null 之后才
    // 放行），给用户「面板已关、控制条回来了」的即时反馈，与解锁沉浸态的范式一致。
    _pokeControlsVisible();
    _refocusVideo();
  }

  String _videoSidePanelTitle(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return t.video_setting_speed;
      case _VideoSidePanelKind.settings:
        return t.video_settings_title;
      case _VideoSidePanelKind.subtitleSources:
        return t.video_menu_subtitle_track;
      case _VideoSidePanelKind.secondarySubtitleSources:
        return t.video_secondary_subtitle_sources;
      case _VideoSidePanelKind.audioTracks:
        return t.video_audio_track;
      case _VideoSidePanelKind.chapters:
        return t.video_chapters;
    }
  }

  double _videoSidePanelWidth(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.settings:
        return 560;
      case _VideoSidePanelKind.chapters:
        return 420;
      case _VideoSidePanelKind.subtitleSources:
      case _VideoSidePanelKind.secondarySubtitleSources:
      case _VideoSidePanelKind.audioTracks:
      case _VideoSidePanelKind.speed:
        return 320;
    }
  }

  Widget _buildVideoSidePanelChild(
    _VideoSidePanelKind kind,
    VideoPlayerController controller,
  ) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return _buildSpeedSidePanel();
      case _VideoSidePanelKind.settings:
        return _buildVideoQuickSettingsSheet();
      case _VideoSidePanelKind.subtitleSources:
        return _buildSubtitleSourcesSidePanel(controller);
      case _VideoSidePanelKind.secondarySubtitleSources:
        return _buildSecondarySubtitleSourcesSidePanel(controller);
      case _VideoSidePanelKind.audioTracks:
        return _buildAudioTracksSidePanel(controller);
      case _VideoSidePanelKind.chapters:
        return _buildChapterSidePanel(controller);
    }
  }

  Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {
    return Positioned.fill(
      child: ValueListenableBuilder<_VideoSidePanelState?>(
        valueListenable: _videoSidePanel,
        builder: (
          BuildContext context,
          _VideoSidePanelState? panelState,
          __,
        ) {
          if (panelState == null) return const SizedBox.shrink();
          final Widget panelContent = _buildVideoSidePanelContent(
            panelState,
            controller,
          );
          // BUG-254：面板打开时在面板「后面 / 左侧空白」铺一层全屏不可见 barrier，
          // 点面板之外任意位置 → [_hideVideoSidePanel] 关闭面板。barrier 用
          // [HitTestBehavior.opaque] 吃掉点击，**不**冒泡到下方控制条 [Listener]，
          // 因此点空白只关面板、不会触发暂停 / 全屏（与 [_handleVideoPointerUp] 的
          // 侧栏早返回门控一致）。面板本体是不透明 Material、在 Stack 上层，点面板内
          // 部命中面板自身、到不了 barrier，故只有点外部才关闭。
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hideVideoSidePanel,
              ),
              panelContent,
            ],
          );
        },
      ),
    );
  }

  /// 单纯构造侧栏面板的「内容 + 定位」部分（不含 BUG-254 的点外关闭 barrier）。
  /// 字幕跳转列表已改 push-aside（TODO-314），不再经此 overlay 路径。
  Widget _buildVideoSidePanelContent(
    _VideoSidePanelState panelState,
    VideoPlayerController controller,
  ) {
    final _VideoSidePanelKind kind = panelState.kind;
    final Widget panel = VideoTranslucentSidePanel(
      title: _videoSidePanelTitle(kind),
      width: _videoSidePanelWidth(kind),
      alignment: panelState.alignment,
      onClose: _hideVideoSidePanel,
      child: _buildVideoSidePanelChild(kind, controller),
    );
    if (kind != _VideoSidePanelKind.settings) return panel;
    return HibikiAppUiScale(
      scale: _videoUiScale,
      child: panel,
    );
  }
}
