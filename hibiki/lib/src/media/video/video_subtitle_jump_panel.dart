import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

String formatCueTimestamp(int startMs) {
  final int total = startMs < 0 ? 0 : startMs ~/ 1000;
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final int seconds = total % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final String mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

const List<double> _kFontScaleSteps = <double>[0.85, 1.0, 1.15, 1.3];

enum VideoSubtitleListFilter {
  all,
  favorites,
  selected,
}

class VideoSubtitleJumpPanel extends StatefulWidget {
  const VideoSubtitleJumpPanel({
    super.key,
    required this.controller,
    required this.onTapCue,
    required this.onCopyCue,
    required this.onFavoriteCue,
    required this.isCueFavorited,
    required this.onClose,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.isCueSelectedForCard,
    this.onToggleCueSelection,
    this.onClearCueSelection,
    this.fontSize = 14,
    this.width = 320,
  });

  final VideoPlayerController controller;
  final void Function(AudioCue cue) onTapCue;
  final void Function(AudioCue cue) onCopyCue;
  final Future<void> Function(AudioCue cue) onFavoriteCue;
  final bool Function(AudioCue cue) isCueFavorited;
  final VoidCallback onClose;
  final ColorScheme colorScheme;
  final String title;
  final String emptyHint;
  final bool Function(AudioCue cue)? isCueSelectedForCard;
  final void Function(AudioCue cue)? onToggleCueSelection;
  final VoidCallback? onClearCueSelection;
  final double fontSize;
  final double width;

  @override
  State<VideoSubtitleJumpPanel> createState() => _VideoSubtitleJumpPanelState();
}

class _VideoSubtitleJumpPanelState extends State<VideoSubtitleJumpPanel> {
  final ScrollController _scrollController = ScrollController();

  int _lastScrolledIndex = -1;
  int _hoveredIndex = -1;
  bool _autoScroll = true;
  int _fontScaleIndex = 1;
  VideoSubtitleListFilter _filter = VideoSubtitleListFilter.all;

  double get _itemExtent => 56 * _fontScaleSteps;

  double get _fontScaleSteps => _kFontScaleSteps[_fontScaleIndex];

  double get _effectiveFontSize => widget.fontSize * _fontScaleSteps;

  bool get _hasCueSelectionControls =>
      widget.isCueSelectedForCard != null &&
      widget.onToggleCueSelection != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(_scrollToCurrentCueIfNeeded);
  }

  void _scrollToCurrentCueIfNeeded() {
    if (!_autoScroll) return;
    final int currentIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (currentIndex < 0 || currentIndex >= cues.length) return;
    final List<AudioCue> visibleCues = _visibleCues(cues);
    final int visibleIndex = visibleCues.indexOf(cues[currentIndex]);
    if (visibleIndex < 0 || visibleIndex == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    _lastScrolledIndex = visibleIndex;
    final double viewport = _scrollController.position.viewportDimension;
    final double target =
        (visibleIndex * _itemExtent) - (viewport / 2) + _itemExtent;
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      if (_autoScroll) _lastScrolledIndex = -1;
    });
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_scrollToCurrentCueIfNeeded);
      });
    }
  }

  void _stepFont(int delta) {
    final int next =
        (_fontScaleIndex + delta).clamp(0, _kFontScaleSteps.length - 1);
    if (next == _fontScaleIndex) return;
    setState(() {
      _fontScaleIndex = next;
      _lastScrolledIndex = -1;
    });
  }

  void _setFilter(Set<VideoSubtitleListFilter> next) {
    if (next.isEmpty) return;
    setState(() {
      _filter = next.single;
      _hoveredIndex = -1;
      _lastScrolledIndex = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_scrollToCurrentCueIfNeeded);
    });
  }

  bool _isCueSelectedForCard(AudioCue cue) =>
      widget.isCueSelectedForCard?.call(cue) ?? false;

  int _selectedCueCount(List<AudioCue> cues) =>
      cues.where(_isCueSelectedForCard).length;

  List<AudioCue> _visibleCues(List<AudioCue> cues) {
    switch (_filter) {
      case VideoSubtitleListFilter.all:
        return cues;
      case VideoSubtitleListFilter.favorites:
        return cues.where(widget.isCueFavorited).toList(growable: false);
      case VideoSubtitleListFilter.selected:
        return cues.where(_isCueSelectedForCard).toList(growable: false);
    }
  }

  String _filterLabel(VideoSubtitleListFilter filter) {
    switch (filter) {
      case VideoSubtitleListFilter.all:
        return t.video_subtitle_filter_all;
      case VideoSubtitleListFilter.favorites:
        return t.video_subtitle_filter_favorites;
      case VideoSubtitleListFilter.selected:
        return t.video_subtitle_filter_selected;
    }
  }

  void _handleClose() {
    widget.onClearCueSelection?.call();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final List<AudioCue> visibleCues = _visibleCues(cues);
    final int currentIndex = widget.controller.currentCueIndex;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.width,
        color: cs.surface.withValues(alpha: 0.92),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs, cues),
            const Divider(height: 1),
            Expanded(
              child: cues.isEmpty || visibleCues.isEmpty
                  ? _buildEmpty(cs)
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: visibleCues.length,
                      itemExtent: _itemExtent,
                      itemBuilder: (BuildContext _, int i) {
                        final AudioCue cue = visibleCues[i];
                        return _buildRow(
                          cs,
                          cue,
                          i,
                          cues.indexOf(cue) == currentIndex,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs, List<AudioCue> cues) {
    final double iconSize = widget.fontSize + 4;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: widget.fontSize + 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: t.video_subtitle_list_font_smaller,
                icon: Icon(Icons.text_decrease, size: iconSize),
                color: _fontScaleIndex > 0 ? cs.onSurfaceVariant : cs.outline,
                onPressed: _fontScaleIndex > 0 ? () => _stepFont(-1) : null,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: t.video_subtitle_list_font_larger,
                icon: Icon(Icons.text_increase, size: iconSize),
                color: _fontScaleIndex < _kFontScaleSteps.length - 1
                    ? cs.onSurfaceVariant
                    : cs.outline,
                onPressed: _fontScaleIndex < _kFontScaleSteps.length - 1
                    ? () => _stepFont(1)
                    : null,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: t.video_subtitle_list_auto_scroll,
                icon: Icon(
                  _autoScroll
                      ? Icons.vertical_align_center
                      : Icons.pause_circle_outline,
                  size: iconSize,
                ),
                color: _autoScroll ? cs.primary : cs.onSurfaceVariant,
                onPressed: _toggleAutoScroll,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                icon: Icon(Icons.close, size: iconSize + 2),
                color: cs.onSurfaceVariant,
                onPressed: _handleClose,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<VideoSubtitleListFilter>(
                    showSelectedIcon: false,
                    segments: VideoSubtitleListFilter.values
                        .map(
                          (VideoSubtitleListFilter filter) =>
                              ButtonSegment<VideoSubtitleListFilter>(
                            value: filter,
                            label: Text(_filterLabel(filter)),
                          ),
                        )
                        .toList(growable: false),
                    selected: <VideoSubtitleListFilter>{_filter},
                    onSelectionChanged: _setFilter,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: TextStyle(fontSize: widget.fontSize - 1),
                    ),
                  ),
                ),
              ),
              if (_hasCueSelectionControls && _selectedCueCount(cues) > 0)
                Tooltip(
                  message: t.video_subtitle_list_clear_selection,
                  child: IconButton(
                    icon: Icon(Icons.clear_all, size: iconSize),
                    color: cs.onSurfaceVariant,
                    onPressed: widget.onClearCueSelection,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.emptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: _effectiveFontSize,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, AudioCue cue, int index, bool selected) {
    final bool hovered = index == _hoveredIndex;
    final bool selectedForCard = _isCueSelectedForCard(cue);
    final Color bg = selected
        ? cs.primaryContainer
        : selectedForCard
            ? cs.secondaryContainer.withValues(alpha: 0.72)
            : (hovered
                ? cs.onSurface.withValues(alpha: 0.06)
                : Colors.transparent);
    final Color tsColor = selected
        ? cs.onPrimaryContainer
        : selectedForCard
            ? cs.onSecondaryContainer
            : cs.onSurfaceVariant;
    final Color textColor = selected
        ? cs.onPrimaryContainer
        : selectedForCard
            ? cs.onSecondaryContainer
            : cs.onSurface;
    final bool showActions = hovered || selected || selectedForCard;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) {
        if (_hoveredIndex == index) setState(() => _hoveredIndex = -1);
      },
      child: InkWell(
        onTap: () => widget.onTapCue(cue),
        child: Container(
          color: bg,
          padding: const EdgeInsets.only(left: 8, right: 4, top: 8, bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_hasCueSelectionControls) ...<Widget>[
                _buildSelectionCheckbox(cs, cue, selectedForCard),
                const SizedBox(width: 4),
              ],
              SizedBox(
                width: 52,
                child: Text(
                  formatCueTimestamp(cue.startMs),
                  style: TextStyle(
                    color: tsColor,
                    fontSize: _effectiveFontSize - 1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cue.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: _effectiveFontSize,
                    fontWeight:
                        selected || selectedForCard ? FontWeight.w600 : null,
                    height: 1.25,
                  ),
                ),
              ),
              if (showActions) _buildRowActions(cs, cue, selected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionCheckbox(
    ColorScheme cs,
    AudioCue cue,
    bool selectedForCard,
  ) {
    return Tooltip(
      message: selectedForCard
          ? t.video_subtitle_list_remove_from_card
          : t.video_subtitle_list_select_for_card,
      child: Checkbox(
        value: selectedForCard,
        onChanged: (_) => widget.onToggleCueSelection?.call(cue),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        activeColor: cs.secondary,
        checkColor: cs.onSecondary,
      ),
    );
  }

  Widget _buildRowActions(ColorScheme cs, AudioCue cue, bool selected) {
    final Color iconColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final bool favorited = widget.isCueFavorited(cue);
    final double iconSize = _effectiveFontSize + 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RowActionButton(
          icon: Icons.play_arrow,
          tooltip: t.video_subtitle_list_jump,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onTapCue(cue),
        ),
        _RowActionButton(
          icon: Icons.content_copy_outlined,
          tooltip: t.copy,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onCopyCue(cue),
        ),
        _RowActionButton(
          icon: favorited ? Icons.star : Icons.star_border,
          tooltip: t.collection_sentence,
          color: favorited ? cs.primary : iconColor,
          size: iconSize,
          onPressed: () => widget.onFavoriteCue(cue),
        ),
      ],
    );
  }
}

class _RowActionButton extends StatelessWidget {
  const _RowActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: size,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
