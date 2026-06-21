// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch6).
part of '../video_hibiki_page.dart';

/// controls-popover (音量 / 倍速轻浮层：锚定几何 + show/hide + 内容卡片) domain
/// methods extracted via part-of (TODO-590 batch6); shared private scope.
/// Behaviour-preserving: bodies are verbatim copies of the main-shell originals.
/// 唯一归一化：本域引用主壳 `static const _videoControlPopoverGapBase`，搬出后改为
/// 全限定 `_VideoHibikiPageState._videoControlPopoverGapBase`（批3 已确立的 static
/// 全限定范式）。本域无 `setState(`（直接驱动 `_videoControlPopover` 等 notifier /
/// 字段），故无 `_rebuild(` 转发。顶层类型 `_VideoControlPopoverKind` /
/// `_VideoControlPopoverPlacement` 与顶层函数 `videoControlPopoverDirectionForSlot` /
/// `resolveVideoControlPopoverPlacement` 不是 host-class static，保持裸引用。浮层状态
/// 字段（`_videoControlPopover` / `_activeControlPopover*` / `_controlPopover*` 命名空间
/// 的 link / key / timer / hovered / pinned）留在主壳，经共享私有作用域被本域读写。
extension _VideoControlsPopover on _VideoHibikiPageState {
  Widget _controlPopoverAnchor({
    required _VideoControlPopoverKind kind,
    required LayerLink link,
    required bool desktop,
    required Widget child,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    final GlobalKey? targetKey = sourceSlot == null || sourceItem == null
        ? null
        : _controlPopoverTargetKeyFor(sourceSlot, sourceItem);
    Widget anchored = CompositedTransformTarget(
      key: targetKey,
      link: link,
      child: child,
    );
    if (!desktop) return anchored;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _controlPopoverAnchorHovered = true;
        _showControlPopover(
          kind,
          popoverLink: link,
          sourceSlot: sourceSlot,
          sourceItem: sourceItem,
        );
      },
      onHover: (_) {
        _controlPopoverAnchorHovered = true;
        _pokeControlsVisible();
      },
      onExit: (_) {
        _controlPopoverAnchorHovered = false;
        _scheduleControlPopoverHide();
      },
      child: anchored,
    );
  }

  /// 底栏音量入口（TODO-438）：底栏只保留图标锚点，hover/click/tap 打开上方轻浮层。
  ///
  /// 滑条值仍经 [_volumeDisplay] 驱动；所有改音量入口（浮层滑条 / 滚轮 / 键盘音量键 /
  /// 静音切换 / media_kit 移动竖滑）统一经 [_syncVolumeDisplay] 写它，保持显示与 controller
  /// 单一真相同步。按钮自身不含 [Slider]，故 hover 不会改变底栏几何。
  Widget _buildVolumeButton(
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final LayerLink popoverLink =
        _controlPopoverLinkFor(slot, VideoControlItem.volume);
    final Widget volumeButton = ValueListenableBuilder<double>(
      valueListenable: _volumeDisplay,
      builder: (BuildContext context, double value, Widget? child) {
        return Tooltip(
          message: t.shortcut_action_video_toggle_mute,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon:
                      Icon(_volumeIconFor(value), size: _videoControlIconSize),
                  onPressed: () => _toggleControlPopover(
                    _VideoControlPopoverKind.volume,
                    popoverLink: popoverLink,
                    sourceSlot: slot,
                    sourceItem: VideoControlItem.volume,
                  ),
                )
              : MaterialCustomButton(
                  icon:
                      Icon(_volumeIconFor(value), size: _videoControlIconSize),
                  onPressed: () => _toggleControlPopover(
                    _VideoControlPopoverKind.volume,
                    popoverLink: popoverLink,
                    sourceSlot: slot,
                    sourceItem: VideoControlItem.volume,
                  ),
                ),
        );
      },
    );
    final Widget anchored = _controlPopoverAnchor(
      kind: _VideoControlPopoverKind.volume,
      link: popoverLink,
      desktop: desktop,
      sourceSlot: slot,
      sourceItem: VideoControlItem.volume,
      child: volumeButton,
    );
    if (!desktop) return anchored;
    return Listener(
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) {
          _onVolumeWheel(controller, event.scrollDelta.dy);
        }
      },
      child: anchored,
    );
  }

  LayerLink _controlPopoverLinkFor(
    VideoControlSlot slot,
    VideoControlItem item,
  ) {
    final String key = _controlPopoverKeyFor(slot, item);
    return _controlPopoverItemLinks.putIfAbsent(key, LayerLink.new);
  }

  GlobalKey _controlPopoverTargetKeyFor(
    VideoControlSlot slot,
    VideoControlItem item,
  ) {
    final String key = _controlPopoverKeyFor(slot, item);
    return _controlPopoverTargetKeys.putIfAbsent(
      key,
      () => GlobalKey(debugLabel: 'video-control-popover-target-$key'),
    );
  }

  String _controlPopoverKeyFor(VideoControlSlot slot, VideoControlItem item) =>
      '${slot.storageValue}:${item.storageValue}';

  /// 计算音量 / 倍速轻浮层相对触发按钮的锚定（TODO-560）。
  ///
  /// 弹出**方向**由按钮所在槽位决定（[videoControlPopoverDirectionForSlot]），音量与
  /// 倍速共用同一套方向逻辑：底栏向上、顶栏向下、左 / 右侧栏向右 / 左。旧实现对倍速恒
  /// 返回「向上居中」，导致按钮被放进顶栏 / 侧栏后浮层仍往上弹、与按钮脱节。
  ///
  /// 方向决定 [CompositedTransformFollower] 的 target/follower [Alignment]（让浮层贴在
  /// 按钮的内侧边）与 [gapDirection]（offset 的让位方向）。横向 / 纵向对齐沿弹出轴取按钮
  /// 同侧（左槽左对齐、右槽右对齐），跨轴取按钮中心，再由
  /// [resolveVideoControlPopoverPlacement] 做越界 clamp。
  _VideoControlPopoverPlacement _controlPopoverPlacementFor(
    _VideoControlPopoverKind kind,
    VideoControlSlot? sourceSlot,
  ) {
    final VideoControlPopoverDirection direction =
        videoControlPopoverDirectionForSlot(sourceSlot);
    switch (direction) {
      case VideoControlPopoverDirection.up:
        // 浮层底边贴按钮顶边；横向取按钮同侧（左/右/中）对齐。
        final (Alignment target, Alignment follower) = switch (sourceSlot) {
          VideoControlSlot.bottomLeft => (
              Alignment.topLeft,
              Alignment.bottomLeft,
            ),
          VideoControlSlot.bottomRight => (
              Alignment.topRight,
              Alignment.bottomRight,
            ),
          _ => (Alignment.topCenter, Alignment.bottomCenter),
        };
        return _VideoControlPopoverPlacement(
          targetAnchor: target,
          followerAnchor: follower,
          gapDirection: const Offset(0, -1),
        );
      case VideoControlPopoverDirection.down:
        // 浮层顶边贴按钮底边；横向取按钮同侧对齐。
        final (Alignment target, Alignment follower) = switch (sourceSlot) {
          VideoControlSlot.topLeft => (
              Alignment.bottomLeft,
              Alignment.topLeft,
            ),
          VideoControlSlot.topRight => (
              Alignment.bottomRight,
              Alignment.topRight,
            ),
          _ => (Alignment.bottomCenter, Alignment.topCenter),
        };
        return _VideoControlPopoverPlacement(
          targetAnchor: target,
          followerAnchor: follower,
          gapDirection: const Offset(0, 1),
        );
      case VideoControlPopoverDirection.right:
        // 左侧栏：浮层左边贴按钮右边，竖向居中。
        return const _VideoControlPopoverPlacement(
          targetAnchor: Alignment.centerRight,
          followerAnchor: Alignment.centerLeft,
          gapDirection: Offset(1, 0),
        );
      case VideoControlPopoverDirection.left:
        // 右侧栏：浮层右边贴按钮左边，竖向居中。
        return const _VideoControlPopoverPlacement(
          targetAnchor: Alignment.centerLeft,
          followerAnchor: Alignment.centerRight,
          gapDirection: Offset(-1, 0),
        );
    }
  }

  double _controlPopoverPreferredWidthFor(_VideoControlPopoverKind kind) {
    return switch (kind) {
      _VideoControlPopoverKind.volume => 220 * _videoUiScale,
      _VideoControlPopoverKind.speed => 220 * _videoUiScale,
    };
  }

  double _controlPopoverWidthFor(
    _VideoControlPopoverKind kind,
    double maxWidth,
  ) {
    final double boundedMax = math.max(0, maxWidth);
    if (boundedMax == 0) return 0;
    final double preferred = _controlPopoverPreferredWidthFor(kind);
    final double minimum = math.min(160 * _videoUiScale, boundedMax);
    return preferred.clamp(minimum, boundedMax).toDouble();
  }

  Rect? _activeControlPopoverTargetRect(BuildContext overlayContext) {
    final VideoControlSlot? slot = _activeControlPopoverSourceSlot;
    final VideoControlItem? item = _activeControlPopoverSourceItem;
    if (slot == null || item == null) return null;

    final BuildContext? targetContext =
        _controlPopoverTargetKeys[_controlPopoverKeyFor(slot, item)]
            ?.currentContext;
    final RenderObject? targetObject = targetContext?.findRenderObject();
    final RenderObject? overlayObject = overlayContext.findRenderObject();
    if (targetObject is! RenderBox || overlayObject is! RenderBox) {
      return null;
    }
    if (!targetObject.attached ||
        !overlayObject.attached ||
        !targetObject.hasSize) {
      return null;
    }

    final Offset topLeft = overlayObject.globalToLocal(
      targetObject.localToGlobal(Offset.zero),
    );
    return topLeft & targetObject.size;
  }

  double _controlPopoverAnchoredLeft({
    required Rect targetRect,
    required double width,
    required _VideoControlPopoverPlacement placement,
  }) {
    final double targetFraction = (placement.targetAnchor.x + 1) / 2;
    final double followerFraction = (placement.followerAnchor.x + 1) / 2;
    final double targetX = targetRect.left + targetRect.width * targetFraction;
    return targetX - width * followerFraction;
  }

  void _toggleControlPopover(
    _VideoControlPopoverKind kind, {
    required LayerLink popoverLink,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    if (_videoControlPopover.value == kind && _controlPopoverPinned) {
      _hideControlPopover();
      return;
    }
    _showControlPopover(
      kind,
      popoverLink: popoverLink,
      pinned: true,
      sourceSlot: sourceSlot,
      sourceItem: sourceItem,
    );
  }

  void _showControlPopover(
    _VideoControlPopoverKind kind, {
    required LayerLink popoverLink,
    bool pinned = false,
    VideoControlSlot? sourceSlot,
    VideoControlItem? sourceItem,
  }) {
    if (!mounted) return;
    _controlPopoverHideTimer?.cancel();
    _activeControlPopoverLink = popoverLink;
    _activeControlPopoverPlacement =
        _controlPopoverPlacementFor(kind, sourceSlot);
    _activeControlPopoverSourceSlot = sourceSlot;
    _activeControlPopoverSourceItem = sourceItem;
    if (_videoControlPopover.value != kind) {
      _controlPopoverPinned = pinned;
    } else if (pinned) {
      _controlPopoverPinned = true;
    }
    _hideVideoControlEditOverlay(revealControls: false);
    if (_subtitleListVisible.value) {
      _clearSelectedMiningCues();
      _subtitleListVisible.value = false;
    }
    // TODO-638：开任何浮层都关掉 push-aside 剧集列表（与字幕列表同处右栏，互斥）。
    if (_episodeListVisible.value) {
      _episodeListVisible.value = false;
    }
    if (_videoSidePanel.value != null) {
      _videoSidePanel.value = null;
    }
    _videoControlPopover.value = kind;
    _pokeControlsVisible();
    _refocusVideo();
  }

  void _hideControlPopover() {
    _controlPopoverHideTimer?.cancel();
    _controlPopoverPinned = false;
    _activeControlPopoverLink = null;
    _activeControlPopoverPlacement = null;
    _activeControlPopoverSourceSlot = null;
    _activeControlPopoverSourceItem = null;
    if (_videoControlPopover.value != null) {
      _videoControlPopover.value = null;
    }
  }

  void _scheduleControlPopoverHide() {
    _controlPopoverHideTimer?.cancel();
    if (_controlPopoverPinned) return;
    _controlPopoverHideTimer = Timer(const Duration(milliseconds: 180), () {
      if (_controlPopoverAnchorHovered || _controlPopoverPanelHovered) return;
      _hideControlPopover();
    });
  }

  Widget _controlPopoverHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _controlPopoverPanelHovered = true;
        _pokeControlsVisible();
      },
      onHover: (_) {
        _controlPopoverPanelHovered = true;
        _pokeControlsVisible();
      },
      onExit: (_) {
        _controlPopoverPanelHovered = false;
        _scheduleControlPopoverHide();
      },
      child: child,
    );
  }

  Widget _buildVideoControlPopoverOverlay(VideoPlayerController controller) {
    return Positioned.fill(
      child: ValueListenableBuilder<_VideoControlPopoverKind?>(
        valueListenable: _videoControlPopover,
        builder: (BuildContext context, _VideoControlPopoverKind? kind, _) {
          if (kind == null) return const SizedBox.shrink();
          final LayerLink? link = _activeControlPopoverLink;
          if (link == null) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final _VideoControlPopoverPlacement placement =
                  _activeControlPopoverPlacement ??
                      _controlPopoverPlacementFor(kind, null);
              final double gap =
                  _VideoHibikiPageState._videoControlPopoverGapBase *
                      _videoUiScale;
              final Rect? targetRect = _activeControlPopoverTargetRect(context);
              final VideoControlSlot? sourceSlot =
                  _activeControlPopoverSourceSlot;
              // 横向越界 clamp 对音量与倍速同样适用（TODO-560）：倍速浮层此前完全不走
              // resolve，放进顶/侧栏后既不换方向也不修横向。
              final VideoControlPopoverPlacement? resolved =
                  sourceSlot != null && targetRect != null
                      ? resolveVideoControlPopoverPlacement(
                          playerBounds: Offset.zero &
                              Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                          targetRect: targetRect,
                          preferredWidth:
                              _controlPopoverPreferredWidthFor(kind),
                          sourceSlot: sourceSlot,
                          gap: gap,
                          minWidth: 160 * _videoUiScale,
                        )
                      : null;
              final double width = resolved?.width ??
                  _controlPopoverWidthFor(kind, constraints.maxWidth);
              // 仅竖向弹（顶/底栏）需要横向修正把宽浮层拉回画面内；侧栏弹时横向由
              // gapDirection 的 gap 提供，不叠加 dx（否则与 gap 双重位移）。
              final bool verticalPopover = placement.gapDirection.dx == 0;
              final double dx =
                  !verticalPopover || resolved == null || targetRect == null
                      ? 0
                      : resolved.left -
                          _controlPopoverAnchoredLeft(
                            targetRect: targetRect,
                            width: width,
                            placement: placement,
                          );
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _hideControlPopover,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CompositedTransformFollower(
                    link: link,
                    showWhenUnlinked: false,
                    targetAnchor: placement.targetAnchor,
                    followerAnchor: placement.followerAnchor,
                    // 让位方向随槽位变（TODO-560）：底栏 (0,-gap) 向上、顶栏 (0,gap) 向下、
                    // 侧栏 (±gap,0) 向左/右；竖向弹时再叠加 dx 横向修正。
                    offset: placement.gapDirection * gap + Offset(dx, 0),
                    child: _controlPopoverHoverKeepAlive(
                      child: _buildVideoControlPopoverContent(
                        kind,
                        controller,
                        width: width,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildVideoControlPopoverContent(
    _VideoControlPopoverKind kind,
    VideoPlayerController controller, {
    required double width,
  }) {
    switch (kind) {
      case _VideoControlPopoverKind.volume:
        return _buildVolumePopover(width: width);
      case _VideoControlPopoverKind.speed:
        return _buildSpeedPopover(width: width);
    }
  }

  Widget _buildControlPopoverFrame({
    required double width,
    required Widget child,
  }) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(width: width),
          child: Padding(
            padding: EdgeInsets.all(10 * _videoUiScale),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildVolumePopover({required double width}) {
    return ValueListenableBuilder<double>(
      valueListenable: _volumeDisplay,
      builder: (BuildContext context, double value, Widget? child) {
        final double clamped = value.clamp(0.0, 100.0).toDouble();
        final ColorScheme cs = _videoChromeColorScheme(context);
        return VideoVolumePopoverCard(
          width: width,
          value: clamped,
          uiScale: _videoUiScale,
          colorScheme: cs,
          icon: _volumeIconFor(clamped),
          tooltip: t.shortcut_action_video_toggle_mute,
          onToggleMute: () => unawaited(_toggleMute()),
          onChanged: _setVolumeFromSlider,
        );
      },
    );
  }

  double _nearestSpeedPreset(double value, List<double> presets) {
    double nearest = presets.first;
    double nearestDistance = (value - nearest).abs();
    for (final double preset in presets.skip(1)) {
      final double distance = (value - preset).abs();
      if (distance < nearestDistance) {
        nearest = preset;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  Widget _buildSpeedPopover({required double width}) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<double> speedPresets = _speedMenuPresets();
    final double sliderValue = _playbackSpeed.clamp(0.5, 2.0).toDouble();
    return _buildControlPopoverFrame(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.speed, color: cs.primary, size: 20 * _videoUiScale),
              SizedBox(width: 8 * _videoUiScale),
              Expanded(
                child: Text(
                  '${_playbackSpeed.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14 * _videoUiScale,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_setSpeed(1.0)),
                child: const Text('1.0x'),
              ),
            ],
          ),
          Slider(
            value: sliderValue,
            min: 0.5,
            max: 2.0,
            divisions: speedPresets.length > 1 ? speedPresets.length - 1 : null,
            label: '${_playbackSpeed.toStringAsFixed(1)}x',
            onChanged: (double value) {
              final double next = _nearestSpeedPreset(value, speedPresets);
              unawaited(_setSpeed(next));
            },
          ),
        ],
      ),
    );
  }
}
