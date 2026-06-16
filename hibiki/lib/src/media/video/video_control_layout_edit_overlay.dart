import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

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
  late VideoControlLayout _layout = widget.layout;

  @override
  void didUpdateWidget(VideoControlLayoutEditOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout && widget.layout != _layout) {
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
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _buildPalette(maxWidth: paletteWidth),
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
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 112),
            child: SizedBox(
              width: centerWidth,
              child: _buildSlotRegion(VideoControlSlot.hidden),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(BoxConstraints constraints) {
    final double availableWidth = math.max(0, constraints.maxWidth - 24);
    final double tileWidth =
        availableWidth >= 440 ? (availableWidth - 8) / 2 : availableWidth;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          _buildPalette(
            maxWidth: availableWidth,
            maxHeight: math.min(160, constraints.maxHeight * 0.42),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final VideoControlSlot slot
                      in VideoControlSlot.editableSlots)
                    SizedBox(
                      width: tileWidth,
                      child: _buildSlotRegion(slot),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPalette({double maxWidth = 420, double? maxHeight}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final VideoControlItem item
                    in VideoControlItem.customizableItems)
                  _buildDraggableControlChip(item, sourceSlot: null),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t.video_control_palette_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: maxHeight ?? double.infinity,
      ),
      child: maxHeight == null
          ? panel
          : SingleChildScrollView(
              child: panel,
            ),
    );
  }

  Widget _buildSlotRegion(VideoControlSlot slot) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in _layout.itemsIn(slot))
        if (item.isChipRenderable) item,
    ];
    return DragTarget<VideoControlDragData>(
      key: ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) {
        final VideoControlItem item = details.data.item;
        if (item.pinnedRequired && slot == VideoControlSlot.hidden) {
          return false;
        }
        return !items.contains(item);
      },
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        unawaited(_moveOrAddControlItem(details.data, slot));
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
          constraints: const BoxConstraints(minHeight: 84, maxHeight: 176),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: highlighted
                ? cs.primaryContainer.withValues(alpha: 0.9)
                : cs.surface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(8),
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
                        for (final VideoControlItem item in items)
                          _buildDraggableControlChip(
                            item,
                            sourceSlot: slot,
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
  }) {
    final Widget chip = _controlChipBody(item, dragging: false);
    return Draggable<VideoControlDragData>(
      data: VideoControlDragData(item: item, sourceSlot: sourceSlot),
      feedback: Material(
        color: Colors.transparent,
        child: _controlChipBody(item, dragging: true),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      child: chip,
    );
  }

  Widget _controlChipBody(VideoControlItem item, {required bool dragging}) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
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
              Icons.drag_indicator,
              size: 15,
              color: cs.onSecondaryContainer.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
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
      constraints: BoxConstraints(maxWidth: dragging ? 220 : 156),
      child: body,
    );
  }

  Future<void> _moveOrAddControlItem(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) async {
    final VideoControlItem item = payload.item;
    final VideoControlSlot? source = payload.sourceSlot;
    VideoControlLayout next = _layout;
    if (source != null && source != target) {
      next = next.removeItemFromSlot(item, source);
    }
    next = next.addItemToSlot(item, target);
    if (next == _layout) return;
    setState(() => _layout = next);
    await widget.onLayoutChanged(next);
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
        return slot.storageValue;
    }
  }

  String _controlItemLabel(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _controlButtonLabel(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return t.video_control_play_pause;
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
      case VideoControlItem.subtitleTrack:
        return t.video_control_subtitle_track;
      case VideoControlItem.audioTrack:
        return t.video_control_audio_track;
      case VideoControlItem.episodeList:
        return t.video_control_episode_list;
      case VideoControlItem.volume:
      case VideoControlItem.title:
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
      case VideoControlItem.subtitleTrack:
        return Icons.subtitles;
      case VideoControlItem.audioTrack:
        return Icons.audiotrack;
      case VideoControlItem.episodeList:
        return Icons.playlist_play;
      case VideoControlItem.volume:
      case VideoControlItem.title:
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
