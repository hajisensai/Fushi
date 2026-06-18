import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

class VideoControlLayoutEditOverlay extends StatefulWidget {
  const VideoControlLayoutEditOverlay({
    required this.layout,
    required this.onLayoutChanged,
    required this.onClose,
    super.key,
  });

  final VideoControlLayout layout;
  final Future<void> Function(VideoControlLayout layout) onLayoutChanged;
  final VoidCallback onClose;

  @override
  State<VideoControlLayoutEditOverlay> createState() =>
      _VideoControlLayoutEditOverlayState();
}

class _VideoControlLayoutEditOverlayState
    extends State<VideoControlLayoutEditOverlay> {
  /// Buttons users can directly rearrange on the video surface.
  static List<VideoControlItem> get _onVideoDraggableItems =>
      VideoControlItem.customizableItems;

  static const List<VideoControlSlot> _editorSlots = <VideoControlSlot>[
    VideoControlSlot.topLeft,
    VideoControlSlot.topCenter,
    VideoControlSlot.topRight,
    VideoControlSlot.bottomLeft,
    VideoControlSlot.bottomCenter,
    VideoControlSlot.bottomRight,
    VideoControlSlot.screenLeft,
    VideoControlSlot.screenRight,
    VideoControlSlot.hidden,
  ];

  late VideoControlLayout _layout = widget.layout;
  bool _dirty = false;

  @override
  void didUpdateWidget(VideoControlLayoutEditOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty && oldWidget.layout != widget.layout) {
      _layout = widget.layout;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.34),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact =
                constraints.maxWidth < 760 || constraints.maxHeight < 460;
            if (compact) return _buildCompactLayout(constraints);
            return _buildSpatialLayout(constraints);
          },
        ),
      ),
    );
  }

  Widget _buildSpatialLayout(BoxConstraints constraints) {
    final double sideWidth = math.min(
      216,
      math.max(148, constraints.maxWidth * 0.22),
    );
    final double centerWidth = math.min(
      320,
      math.max(236, constraints.maxWidth * 0.3),
    );
    final double paletteWidth = math.min(
      420,
      math.max(260, constraints.maxWidth - sideWidth * 2 - 72),
    );
    final double centerLeft = (constraints.maxWidth - centerWidth) / 2;
    final double paletteLeft = (constraints.maxWidth - paletteWidth) / 2;
    final double paletteHeight = math.min(
      160,
      math.max(96, constraints.maxHeight - 340),
    );

    return Stack(
      children: <Widget>[
        Positioned(
          top: 12,
          left: 12,
          width: sideWidth,
          child: _buildSlotRegion(VideoControlSlot.topLeft),
        ),
        Positioned(
          top: 12,
          right: 12,
          width: sideWidth,
          child: _buildSlotRegion(VideoControlSlot.topRight),
        ),
        Positioned(
          top: 12,
          left: centerLeft,
          width: centerWidth,
          child: _buildSlotRegion(VideoControlSlot.topCenter),
        ),
        Positioned(
          top: 108,
          left: paletteLeft,
          width: paletteWidth,
          child: _buildPalette(
            maxWidth: paletteWidth,
            maxHeight: paletteHeight,
          ),
        ),
        Positioned(
          left: paletteLeft,
          right: paletteLeft,
          bottom: 108,
          child: _buildSlotRegion(
            VideoControlSlot.hidden,
            tray: true,
          ),
        ),
        Positioned(
          left: 12,
          top: 0,
          bottom: 0,
          width: sideWidth,
          child: Center(
            child: _buildSlotRegion(VideoControlSlot.screenLeft),
          ),
        ),
        Positioned(
          right: 12,
          top: 0,
          bottom: 0,
          width: sideWidth,
          child: Center(
            child: _buildSlotRegion(VideoControlSlot.screenRight),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          width: sideWidth,
          child: _buildSlotRegion(VideoControlSlot.bottomLeft),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: centerWidth,
              child: _buildSlotRegion(VideoControlSlot.bottomCenter),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          width: sideWidth,
          child: _buildSlotRegion(VideoControlSlot.bottomRight),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(BoxConstraints constraints) {
    final double availableWidth = math.max(0, constraints.maxWidth - 24);
    final double tileWidth =
        availableWidth >= 440 ? (availableWidth - 8) / 2 : availableWidth;
    final double paletteMaxHeight = math.min(
      200,
      math.max(0, constraints.maxHeight - 40),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          _buildCompactPalette(
            maxWidth: availableWidth,
            maxHeight: paletteMaxHeight,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final VideoControlSlot slot in _editorSlots)
                    SizedBox(
                      width: tileWidth,
                      child: _buildSlotRegion(
                        slot,
                        tray: slot == VideoControlSlot.hidden,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactPalette({
    required double maxWidth,
    required double maxHeight,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget chipList = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final VideoControlItem item in _onVideoDraggableItems)
          _buildDraggableControlChip(
            item,
            sourceSlot: null,
            sourceIndex: null,
          ),
      ],
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: SizedBox(
        height: maxHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.92),
            borderRadius: tokens.radii.chipRadius,
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 48,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.dashboard_customize_outlined,
                          size: 18,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: _cancelDraft,
                          child: Text(t.dialog_cancel),
                        ),
                        const SizedBox(width: 2),
                        FilledButton(
                          onPressed: _saveDraft,
                          child: Text(t.dialog_save),
                        ),
                        IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .closeButtonTooltip,
                          icon: const Icon(Icons.close),
                          onPressed: _cancelDraft,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          t.video_control_palette_title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(child: chipList),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPalette({double maxWidth = 420, double? maxHeight}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool tightHeight = maxHeight != null && maxHeight < 220;
    final Widget chipList = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final VideoControlItem item in _onVideoDraggableItems)
          _buildDraggableControlChip(
            item,
            sourceSlot: null,
            sourceIndex: null,
          ),
      ],
    );
    final Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.92),
        borderRadius: tokens.radii.chipRadius,
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: maxHeight == null ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 18,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.video_control_palette_title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: _cancelDraft,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (maxHeight == null)
              chipList
            else
              Expanded(child: SingleChildScrollView(child: chipList)),
            const SizedBox(height: 6),
            if (!tightHeight) ...<Widget>[
              Text(
                t.video_control_palette_hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  TextButton(
                    onPressed: _cancelDraft,
                    child: Text(t.dialog_cancel),
                  ),
                  FilledButton(
                    onPressed: _saveDraft,
                    child: Text(t.dialog_save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final Widget boundedPanel =
        maxHeight == null ? panel : SizedBox(height: maxHeight, child: panel);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: maxHeight ?? double.infinity,
      ),
      child: boundedPanel,
    );
  }

  Widget _buildSlotRegion(VideoControlSlot slot, {bool tray = false}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in _layout.itemsIn(slot))
        if (_isOnVideoDraggableItem(item)) item,
    ];
    return DragTarget<VideoControlDragData>(
      key: ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) {
        final VideoControlItem item = details.data.item;
        if (!_isOnVideoDraggableItem(item)) return false;
        return _canAcceptPayload(details.data, slot);
      },
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveOrAddControlItem(details.data, slot, targetIndex: items.length);
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        final bool rejecting = rejected.isNotEmpty;
        final Color borderColor = rejecting
            ? cs.error
            : highlighted
                ? cs.primary
                : cs.outlineVariant;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: BoxConstraints(
            minHeight: tray ? 64 : 84,
            maxHeight: tray ? 120 : 176,
          ),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: highlighted
                ? cs.primaryContainer.withValues(alpha: 0.9)
                : cs.surface.withValues(alpha: 0.86),
            borderRadius: tokens.radii.chipRadius,
            border: Border.all(
              color: borderColor,
              width: highlighted || rejecting ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _controlSlotLabel(slot),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color:
                      highlighted ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              if (items.isEmpty)
                Text(
                  t.video_control_slot_drop_hint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: highlighted
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (int index = 0; index < items.length; index++)
                          _buildPlacedControlChip(
                            items[index],
                            sourceSlot: slot,
                            sourceIndex: index,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDraggableControlChip(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    double maxWidth = 156,
  }) {
    final Widget chip = _controlChipBody(
      item,
      dragging: false,
      maxWidth: maxWidth,
    );
    return Draggable<VideoControlDragData>(
      data: VideoControlDragData(
        item: item,
        sourceSlot: sourceSlot,
        sourceIndex: sourceIndex,
      ),
      feedback: Material(
        color: Colors.transparent,
        child: _controlChipBody(item, dragging: true, maxWidth: 220),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }

  Widget _buildPlacedControlChip(
    VideoControlItem item, {
    required VideoControlSlot sourceSlot,
    required int sourceIndex,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return DragTarget<VideoControlDragData>(
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _canAcceptPayload(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveOrAddControlItem(
          details.data,
          sourceSlot,
          targetIndex: sourceIndex,
        );
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(maxWidth: 204),
          padding: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: highlighted
                ? cs.primaryContainer.withValues(alpha: 0.82)
                : cs.secondaryContainer,
            borderRadius: tokens.radii.controlRadius,
            border: Border.all(
              color: highlighted ? cs.primary : Colors.transparent,
              width: highlighted ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildDraggableControlChip(
                item,
                sourceSlot: sourceSlot,
                sourceIndex: sourceIndex,
                maxWidth: 112,
              ),
              Theme(
                data: theme.copyWith(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: IconButton(
                  tooltip: t.video_control_remove_from_slot,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: Icon(
                    Icons.close,
                    size: 14,
                    color: cs.onSecondaryContainer,
                  ),
                  onPressed: () => _removeControlItem(item, sourceSlot),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _isOnVideoDraggableItem(VideoControlItem item) => item.isChipRenderable;

  Widget _controlChipBody(
    VideoControlItem item, {
    required bool dragging,
    required double maxWidth,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: tokens.radii.controlRadius,
        boxShadow: dragging
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _controlItemIcon(item),
              size: 15,
              color: cs.onSecondaryContainer,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                _controlItemLabel(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: body,
    );
  }

  bool _canAcceptPayload(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final VideoControlItem item = payload.item;
    if (!_isOnVideoDraggableItem(item)) return false;
    if (!item.canMoveToSlot(target)) return false;
    final List<VideoControlItem> targetItems = _layout.itemsIn(target);
    if (payload.sourceSlot == target) return true;
    return !targetItems.contains(item);
  }

  void _moveOrAddControlItem(
    VideoControlDragData payload,
    VideoControlSlot target, {
    int? targetIndex,
  }) {
    final VideoControlLayout next = _layout.moveDraggedItem(
      payload,
      target,
      targetIndex: targetIndex,
    );
    if (next == _layout) return;
    setState(() {
      _layout = next;
      _dirty = true;
    });
  }

  void _removeControlItem(VideoControlItem item, VideoControlSlot slot) {
    final VideoControlLayout next = _layout.removeItemFromSlot(item, slot);
    if (next == _layout) return;
    setState(() {
      _layout = next;
      _dirty = true;
    });
  }

  Future<void> _saveDraft() async {
    await widget.onLayoutChanged(_layout);
    if (!mounted) return;
    widget.onClose();
  }

  void _cancelDraft() {
    widget.onClose();
  }

  String _controlSlotLabel(VideoControlSlot slot) {
    switch (slot) {
      case VideoControlSlot.topLeft:
        return t.video_control_slot_top_left;
      case VideoControlSlot.topRight:
        return t.video_control_slot_top_right;
      case VideoControlSlot.bottomLeft:
        return t.video_control_slot_bottom_left;
      case VideoControlSlot.bottomCenter:
        return t.video_control_slot_bottom_center;
      case VideoControlSlot.bottomRight:
        return t.video_control_slot_bottom_right;
      case VideoControlSlot.screenLeft:
        return t.video_control_slot_screen_left;
      case VideoControlSlot.screenRight:
        return t.video_control_slot_screen_right;
      case VideoControlSlot.hidden:
        return t.video_control_slot_hidden;
      case VideoControlSlot.topCenter:
        return t.video_control_slot_top_center;
    }
  }

  String _controlItemLabel(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _controlButtonLabel(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return t.video_control_play_pause;
      case VideoControlItem.back:
        return MaterialLocalizations.of(context).backButtonTooltip;
      case VideoControlItem.immersiveLock:
        return t.video_menu_lock;
      case VideoControlItem.seekBackward:
        return t.video_control_seek_backward;
      case VideoControlItem.seekForward:
        return t.video_control_seek_forward;
      case VideoControlItem.previousCue:
        return t.video_control_previous_cue;
      case VideoControlItem.nextCue:
        return t.video_control_next_cue;
      case VideoControlItem.fullscreen:
        return t.video_control_fullscreen;
      case VideoControlItem.screenshot:
        return t.video_control_screenshot;
      case VideoControlItem.clipExport:
        return t.video_clip_export;
      case VideoControlItem.subtitleTrack:
        return t.video_control_subtitle_track;
      case VideoControlItem.audioTrack:
        return t.video_control_audio_track;
      case VideoControlItem.previousEpisode:
        return t.video_prev_episode;
      case VideoControlItem.nextEpisode:
        return t.video_next_episode;
      case VideoControlItem.episodeList:
        return t.video_control_episode_list;
      case VideoControlItem.previousChapter:
        return t.shortcut_action_video_previous_chapter;
      case VideoControlItem.nextChapter:
        return t.shortcut_action_video_next_chapter;
      case VideoControlItem.chapterList:
        return t.video_chapters;
      case VideoControlItem.volume:
        return t.video_control_volume;
      case VideoControlItem.title:
        return t.video_control_title;
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return item.storageValue;
    }
  }

  IconData _controlItemIcon(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _controlButtonIcon(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return Icons.play_arrow_rounded;
      case VideoControlItem.back:
        return Icons.arrow_back;
      case VideoControlItem.immersiveLock:
        return Icons.lock_outline;
      case VideoControlItem.seekBackward:
        return Icons.fast_rewind;
      case VideoControlItem.seekForward:
        return Icons.fast_forward;
      case VideoControlItem.previousCue:
        return Icons.skip_previous;
      case VideoControlItem.nextCue:
        return Icons.skip_next;
      case VideoControlItem.fullscreen:
        return Icons.fullscreen;
      case VideoControlItem.screenshot:
        return Icons.photo_camera_outlined;
      case VideoControlItem.clipExport:
        return Icons.movie_creation_outlined;
      case VideoControlItem.subtitleTrack:
        return Icons.subtitles;
      case VideoControlItem.audioTrack:
        return Icons.audiotrack;
      case VideoControlItem.previousEpisode:
        return Icons.skip_previous_outlined;
      case VideoControlItem.nextEpisode:
        return Icons.skip_next_outlined;
      case VideoControlItem.episodeList:
        return Icons.playlist_play;
      case VideoControlItem.previousChapter:
        return Icons.first_page;
      case VideoControlItem.nextChapter:
        return Icons.last_page;
      case VideoControlItem.chapterList:
        return Icons.format_list_numbered;
      case VideoControlItem.volume:
        return Icons.volume_up_outlined;
      case VideoControlItem.title:
        return Icons.title;
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return Icons.tune;
    }
  }

  String _controlButtonLabel(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return t.video_control_speed;
      case VideoControlButton.subtitleList:
        return t.video_control_subtitle_list;
      case VideoControlButton.favoriteSentence:
        return t.video_control_favorite_sentence;
      case VideoControlButton.favoriteSentences:
        return t.video_control_favorite_sentences;
      case VideoControlButton.settings:
        return t.video_control_settings;
    }
  }

  IconData _controlButtonIcon(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return Icons.speed_outlined;
      case VideoControlButton.subtitleList:
        return Icons.format_list_bulleted;
      case VideoControlButton.favoriteSentence:
        return Icons.star_border_rounded;
      case VideoControlButton.favoriteSentences:
        return Icons.collections_bookmark_outlined;
      case VideoControlButton.settings:
        return Icons.tune;
    }
  }
}
