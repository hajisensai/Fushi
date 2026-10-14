// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch10).
part of '../video_fushi_page.dart';

/// Side-panel domain methods extracted via part-of (TODO-590 batch10); shared
/// private scope. Behaviour-preserving: every body is moved
/// character-for-character. None of these methods call `State.setState` — the
/// open/close lifecycle is driven entirely through the `_videoSidePanel`
/// [ValueNotifier], so there is no `setState→_rebuild` normalisation here (and
/// none of the moved members is `static`, so no `_VideoFushiPageState.`
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
/// `_buildVideoQuickSettingsSheet`, `_buildChapterSidePanel`), the controls/rail
/// collaborators (`_clearRailHover`, `_hideVideoControlEditOverlay`,
/// `_hideControlPopover`, `_markControlsVisible`, `_pokeControlsVisible`,
/// `_focusOwnership`), the `_subtitleListVisible` /
/// `_episodeListVisible` notifiers and `_videoUiScale` all stay in the main
/// shell; the extension reads/calls them through the shared private scope.
extension _VideoSidePanel on _VideoFushiPageState {
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
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  void _hideVideoSidePanel() {
    _videoSidePanel.value = null;
    // BUG-253：面板关闭后唤回一次控制条（poke 在 [_videoSidePanel] 复位为 null 之后才
    // 放行），给用户「面板已关、控制条回来了」的即时反馈，与解锁沉浸态的范式一致。
    _pokeControlsVisible();
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  String _videoSidePanelTitle(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return t.video_setting_speed;
      case _VideoSidePanelKind.settings:
        return t.video_settings_title;
      case _VideoSidePanelKind.subtitle:
        return t.video_settings_cat_subtitle;
      case _VideoSidePanelKind.audio:
        return t.video_settings_cat_audio;
      case _VideoSidePanelKind.chapters:
        return t.video_chapters;
      case _VideoSidePanelKind.quality:
        return t.video_quality;
      case _VideoSidePanelKind.danmakuMatch:
        return t.video_danmaku_manual_match_title;
    }
  }

  /// 侧栏页头图标（M3E 下画成标题前的饼干形徽标；Apple / 墨水屏不画）。
  IconData _videoSidePanelIcon(_VideoSidePanelKind kind) {
    switch (kind) {
      case _VideoSidePanelKind.speed:
        return FushiIcons.speed;
      case _VideoSidePanelKind.settings:
        return FushiIcons.settings;
      case _VideoSidePanelKind.subtitle:
        return FushiIcons.subtitles;
      case _VideoSidePanelKind.audio:
        return FushiIcons.music;
      case _VideoSidePanelKind.chapters:
        return FushiIcons.numberedList;
      case _VideoSidePanelKind.quality:
        return FushiIcons.highQuality;
      case _VideoSidePanelKind.danmakuMatch:
        return FushiIcons.forum;
    }
  }

  double _videoSidePanelWidth(_VideoSidePanelKind kind) {
    switch (kind) {
      // 切换条成员（字幕 / 音频 / 章节 / 画质 / 设置）同宽：原地互换时面板不跳宽。
      case _VideoSidePanelKind.settings:
      case _VideoSidePanelKind.subtitle:
      case _VideoSidePanelKind.audio:
      case _VideoSidePanelKind.chapters:
      case _VideoSidePanelKind.quality:
        final Size window = MediaQuery.sizeOf(context);
        // 手机横屏（最短边 < 600）：与阅读器设置侧板同宽档（400 上限），不再占掉
        // 大半个画面；手机竖屏走贴底面板，宽度由外壳决定。
        if (videoQuickSettingsCompact(window)) {
          return readerSideSheetWidth(window.width);
        }
        // BUG-1546：桌面设置侧栏不固定 560——大窗口下随窗口宽度自适应放宽
        // （560..900）；上限与快捷设置弹窗同源。
        return fushiQuickSettingsPanelWidth(window.width);
      case _VideoSidePanelKind.danmakuMatch:
        return 480;
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
      case _VideoSidePanelKind.subtitle:
        return _buildVideoQuickSettingsSheet(
          groups: const <settings_dest.VideoGroup>[
            settings_dest.VideoGroup.subtitle,
          ],
        );
      case _VideoSidePanelKind.audio:
        return _buildVideoQuickSettingsSheet(
          groups: const <settings_dest.VideoGroup>[
            settings_dest.VideoGroup.audio,
          ],
        );
      case _VideoSidePanelKind.chapters:
        return _buildChapterSidePanel(controller);
      case _VideoSidePanelKind.quality:
        return _buildQualitySidePanel(controller);
      case _VideoSidePanelKind.danmakuMatch:
        return _buildDanmakuMatchSidePanel();
    }
  }

  Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {
    return Positioned.fill(
      child: ValueListenableBuilder<_VideoSidePanelState?>(
        valueListenable: _videoSidePanel,
        builder: (BuildContext context, _VideoSidePanelState? panelState, __) {
          if (panelState == null) return const SizedBox.shrink();
          // 手柄重设计 P3：侧栏随打开挂载，挂载即领焦点进面板、卸载还给页面
          // 焦点——D-pad 才能在速度/设置/章节/画质行间移动。
          final Widget panelContent = PanelFocusScope(
            visible: true,
            restoreFocus: () =>
                _focusOwnership.reclaim(FocusReclaimCause.overlayClosed),
            child: _buildVideoSidePanelContent(panelState, controller),
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

  /// 面板切换条成员：字幕 / 音频 / 章节（有章节时）/ 画质（有可选档时）/ 设置。
  /// 倍速与弹幕手动匹配是一次性的小弹层，不进切换条。
  List<_VideoSidePanelKind> _videoPanelSwitcherKinds() {
    return <_VideoSidePanelKind>[
      _VideoSidePanelKind.subtitle,
      _VideoSidePanelKind.audio,
      if (_hasChapters) _VideoSidePanelKind.chapters,
      if (_qualityCurrentLabel != null || _isYoutubeStream)
        _VideoSidePanelKind.quality,
      _VideoSidePanelKind.settings,
    ];
  }

  /// 切换条上点了某个面板：原地换内容（停靠位不变），各面板打开时的副作用
  /// （画质懒解析）与按钮入口一致；字幕面板挂载时自己触发字幕源加载。
  void _switchVideoSidePanel(_VideoSidePanelKind kind) {
    final _VideoSidePanelState? current = _videoSidePanel.value;
    if (current == null || current.kind == kind) return;
    if (kind == _VideoSidePanelKind.quality &&
        _isYoutubeStream &&
        !_youtubeVariantsResolved &&
        !_youtubeVariantsLoading) {
      unawaited(_ensureYoutubeVariantsLoaded());
    }
    _videoSidePanel.value = _VideoSidePanelState(
      kind: kind,
      alignment: current.alignment,
    );
  }

  ReaderPanelSwitcher? _videoPanelSwitcher(_VideoSidePanelKind kind) {
    final List<_VideoSidePanelKind> kinds = _videoPanelSwitcherKinds();
    if (!kinds.contains(kind)) return null;
    return ReaderPanelSwitcher(
      items: <({String id, IconData icon, String label})>[
        for (final _VideoSidePanelKind k in kinds)
          (
            id: k.name,
            icon: _videoSidePanelIcon(k),
            label: _videoSidePanelTitle(k),
          ),
      ],
      // 整块面板随 [_videoSidePanel] 重建，当前项是固定值即可。
      current: AlwaysStoppedAnimation<String>(kind.name),
      onSelect: (String id) {
        for (final _VideoSidePanelKind k in kinds) {
          if (k.name == id) _switchVideoSidePanel(k);
        }
      },
    );
  }

  /// 单纯构造侧栏面板的「内容 + 定位」部分（不含 BUG-254 的点外关闭 barrier）。
  /// 字幕跳转列表已改 push-aside（TODO-314），不再经此 overlay 路径。
  ///
  /// 切换条成员共用同一个外壳实例：互换时外壳不重新进场，只有内容交叉淡入
  /// （与阅读器侧板原地换内容同款）。
  Widget _buildVideoSidePanelContent(
    _VideoSidePanelState panelState,
    VideoPlayerController controller,
  ) {
    final _VideoSidePanelKind kind = panelState.kind;
    final ReaderPanelSwitcher? switcher = _videoPanelSwitcher(kind);
    final bool member = switcher != null;
    // 设置面板顶上就是分类页签，不画大标题页头（反馈 nGxUGtYot9）；字幕 / 音频
    // 只有一个分组，同样不画——切换条本身已经标明当前面板。
    final bool headerless =
        kind == _VideoSidePanelKind.settings ||
        kind == _VideoSidePanelKind.subtitle ||
        kind == _VideoSidePanelKind.audio;
    final Widget child = _buildVideoSidePanelChild(kind, controller);
    final Widget panel = VideoTranslucentSidePanel(
      key: member ? const ValueKey<String>('video-switchable-panel') : null,
      title: headerless ? null : _videoSidePanelTitle(kind),
      icon: _videoSidePanelIcon(kind),
      width: _videoSidePanelWidth(kind),
      alignment: panelState.alignment,
      // 切换条成员手机竖屏都改贴底面板（与阅读器设置面板同一判据）。
      bottomSheetWhenCompact: member,
      // 成片文字与控件背后不能透出字幕。
      opaque: member,
      switcher: switcher,
      onClose: _hideVideoSidePanel,
      child: member
          ? AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.topCenter,
                children: <Widget>[...previous, if (current != null) current],
              ),
              child: KeyedSubtree(
                key: ValueKey<String>('video-panel-${kind.name}'),
                child: child,
              ),
            )
          : child,
    );
    if (!member) return panel;
    return FushiAppUiScale(scale: _videoUiScale, child: panel);
  }
}
