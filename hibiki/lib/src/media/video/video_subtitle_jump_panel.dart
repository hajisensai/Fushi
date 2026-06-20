import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
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

/// 字幕列表行内点击命中的字符：被点 grapheme 下标 + 该字符的全局屏幕矩形。
/// 供 [VideoSubtitleJumpPanel.onLookupCue] 精确查词（TODO-340）。
typedef SubtitleListCharHit = ({int graphemeIndex, Rect charRect});

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
    this.onLookupCue,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.loadingHint,
    this.isCueSelectedForCard,
    this.onToggleCueSelection,
    this.onClearCueSelection,
    this.initialAutoScroll = true,
    this.onAutoScrollChanged,
    this.locked = false,
    this.onToggleLock,
    this.fontSize = 14,
    this.width = 320,
  });

  final VideoPlayerController controller;
  final void Function(AudioCue cue) onTapCue;
  final void Function(AudioCue cue) onCopyCue;
  final Future<void> Function(AudioCue cue) onFavoriteCue;
  final bool Function(AudioCue cue) isCueFavorited;
  final VoidCallback onClose;

  /// 点列表项字幕文本 → 从点击命中的字符起查词（TODO-340）。[cue] 为被点行的字幕句，
  /// [graphemeIndex] 为点击位置命中的 grapheme 下标（与底部字幕逐字查词同语义，
  /// 调用方据此从该位置起取词最长匹配），[charRect] 为被点字符的全局屏幕矩形（查词
  /// 浮层定位用）。null 时文本不可查词、行点击仅 seek（向后兼容：部分调用方 / 测试不
  /// 接查词）。
  final void Function(AudioCue cue, int graphemeIndex, Rect charRect)?
      onLookupCue;
  final ColorScheme colorScheme;
  final String title;
  final String emptyHint;
  final String? loadingHint;
  final bool Function(AudioCue cue)? isCueSelectedForCard;
  final void Function(AudioCue cue)? onToggleCueSelection;
  final VoidCallback? onClearCueSelection;

  /// 自动滚动到当前播放句的初始开关（TODO-613）。面板内 [_autoScroll] 以此为初值，
  /// 用户切换时回调 [onAutoScrollChanged] 通知页面层落盘（默认 true，向后兼容）。
  final bool initialAutoScroll;

  /// 用户在面板头部切换「自动滚动」时回调（TODO-613）。null 时仍可切换（纯本地），
  /// 但不通知外部持久化（部分调用方 / 测试不接落盘）。
  final ValueChanged<bool>? onAutoScrollChanged;

  /// 列表锁定状态（TODO-611）。锁定时页面层的「点列表外关闭」barrier 被门控成 no-op，
  /// 列表不会被点外部关闭（仅 Esc / 控制条字幕按钮可关）。
  final bool locked;

  /// 用户在面板头部点锁定图标时回调（TODO-611）。null 时不渲染锁定按钮（部分调用方
  /// 不需要锁定能力，向后兼容）。
  final VoidCallback? onToggleLock;

  final double fontSize;
  final double width;

  @override
  State<VideoSubtitleJumpPanel> createState() => _VideoSubtitleJumpPanelState();
}

class _VideoSubtitleJumpPanelState extends State<VideoSubtitleJumpPanel> {
  late final ScrollController _scrollController;

  int _lastScrolledIndex = -1;
  int _lastControllerCueIndex = -1;
  bool _lastSubtitleCuesLoading = false;
  int? _scrollTargetRawIndex;
  int _hoveredIndex = -1;
  late bool _autoScroll = widget.initialAutoScroll;
  bool _scrollPostFrameScheduled = false;
  int _fontScaleIndex = 1;
  VideoSubtitleListFilter _filter = VideoSubtitleListFilter.all;

  /// 只给当前/待滚动目标行保留 [GlobalKey]，供自适应行高下精确
  /// [HibikiFocusScroll.ensureVisible]。普通可见行走 [ValueKey]，避免长列表滚动后
  /// [GlobalKey] map 按历史 visibleIndex 无限制增长。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};
  List<AudioCue>? _cachedCues;
  int _cachedCuesLength = -1;
  VideoSubtitleListFilter? _cachedFilter;
  List<int> _cachedVisibleIndexes = const <int>[];
  Map<int, int> _cachedVisibleIndexByRawIndex = const <int, int>{};
  List<AudioCue>? _cachedSelectedCues;
  int _cachedSelectedCuesLength = -1;
  int _cachedSelectedCount = 0;

  /// 单行估算高度（仅作目标行未挂载时的粗滚后备，TODO-340）。换行后实际行高可变，
  /// 故不再用作精确 itemExtent；当前 cue 行进入视口后由 ensureVisible 精确居中。
  double get _estimatedRowExtent => 56 * _fontScaleSteps;

  double get _fontScaleSteps => _kFontScaleSteps[_fontScaleIndex];

  double get _effectiveFontSize => widget.fontSize * _fontScaleSteps;

  /// 时间戳列宽度（TODO-567）。固定 52px 在放大字号 + 小时级时间戳（`1:23:45`，7
  /// 字符 tabular figures）下放不下，时间戳文本溢出 [SizedBox] 边界画到右侧字幕文本
  /// 区，看起来像「时间被下一条字幕挡住 / 溢出」。改为随字号缩放估宽：tabular figures
  /// 下每个 `h:mm:ss` 字位约 0.6em，7 字符 + 余量 → `字号 × 4.6`，并设下界 52 保证窄字
  /// 号下不变窄。配合时间戳 Text 单行不换行（`maxLines:1` / `softWrap:false`），列内
  /// 容永不溢出到文本列。
  double get _timestampColumnWidth {
    final double scaled = (_effectiveFontSize - 1) * 4.6;
    return scaled < 52 ? 52 : scaled;
  }

  double _estimatedRowExtentForCue(AudioCue cue, double rowWidth) {
    final double actionWidth = 3 * (_effectiveFontSize + 10);
    final double selectionWidth = _hasCueSelectionControls ? 44 : 0;
    final double textWidth = rowWidth -
        8 -
        4 -
        selectionWidth -
        _timestampColumnWidth -
        8 -
        actionWidth;
    final double safeTextWidth = textWidth < 48 ? 48 : textWidth;
    final int charsPerLine = (safeTextWidth / (_effectiveFontSize * 0.95))
        .floor()
        .clamp(1, 10000)
        .toInt();
    int lineCount = 0;
    for (final String line in cue.text.split('\n')) {
      final int length = line.isEmpty ? 1 : line.length;
      lineCount += (length / charsPerLine).ceil();
    }
    if (lineCount < 1) lineCount = 1;
    final double textHeight = lineCount * _effectiveFontSize * 1.25;
    final double estimated = 16 + textHeight + 2;
    return estimated < _estimatedRowExtent ? _estimatedRowExtent : estimated;
  }

  double _estimatedScrollOffsetForVisibleIndex(
    int visibleIndex,
    List<int> visibleIndexes,
    List<AudioCue> cues,
    double rowWidth,
  ) {
    double offset = 0;
    for (int i = 0; i < visibleIndex; i++) {
      offset += _estimatedRowExtentForCue(cues[visibleIndexes[i]], rowWidth);
    }
    return offset;
  }

  bool get _hasCueSelectionControls =>
      widget.isCueSelectedForCard != null &&
      widget.onToggleCueSelection != null;

  @override
  void initState() {
    super.initState();
    _lastControllerCueIndex = widget.controller.currentCueIndex;
    _lastSubtitleCuesLoading = widget.controller.isSubtitleCuesLoading;
    final int initialRawIndex = widget.controller.currentCueIndex;
    _scrollTargetRawIndex =
        _isCurrentCueVisible(initialRawIndex) ? initialRawIndex : null;
    _retainRowKeyFor(_scrollTargetRawIndex);
    _scrollController = ScrollController(
      initialScrollOffset: _initialScrollOffsetForCurrentCue(),
    );
    widget.controller.addListener(_onControllerChanged);
    _scheduleScrollToCurrentCue();
  }

  @override
  void didUpdateWidget(covariant VideoSubtitleJumpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastControllerCueIndex = widget.controller.currentCueIndex;
      _lastSubtitleCuesLoading = widget.controller.isSubtitleCuesLoading;
      _lastScrolledIndex = -1;
      _scrollTargetRawIndex =
          _isCurrentCueVisible(widget.controller.currentCueIndex)
              ? widget.controller.currentCueIndex
              : null;
      _rowKeys.clear();
      _retainRowKeyFor(_scrollTargetRawIndex);
      _scheduleScrollToCurrentCue();
    }
    _clearCueCaches();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final int currentIndex = widget.controller.currentCueIndex;
    final bool cuesLoading = widget.controller.isSubtitleCuesLoading;
    final bool cueChanged = currentIndex != _lastControllerCueIndex;
    final bool loadingChanged = cuesLoading != _lastSubtitleCuesLoading;
    if (!cueChanged && !loadingChanged) return;
    _lastControllerCueIndex = currentIndex;
    _lastSubtitleCuesLoading = cuesLoading;
    setState(() {
      _scrollTargetRawIndex = currentIndex >= 0 ? currentIndex : null;
      _retainRowKeyFor(_scrollTargetRawIndex);
    });
    if (cueChanged) _scheduleScrollToCurrentCue();
  }

  void _scheduleScrollToCurrentCue() {
    if (!_autoScroll) return;
    if (_scrollPostFrameScheduled) return;
    _scrollPostFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPostFrameScheduled = false;
      if (mounted) _scrollToCurrentCueIfNeeded();
    });
  }

  void _scrollToCurrentCueIfNeeded() {
    if (!_autoScroll) return;
    final int currentIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (currentIndex < 0 || currentIndex >= cues.length) return;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    final int visibleIndex =
        _visibleIndexForRawIndex(currentIndex, visibleIndexes);
    if (visibleIndex < 0 || visibleIndex == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    _lastScrolledIndex = visibleIndex;
    _scrollTargetRawIndex = currentIndex;
    _retainRowKeyFor(currentIndex);
    const Duration duration = Duration(milliseconds: 240);
    const Curve curve = Curves.easeOutCubic;
    // 可变行高下优先用 ensureVisible 把当前行精确居中（alignment 0.5）；目标行已挂载
    // 才有 RenderObject。未挂载（在远处视口外）时先按估算行高粗滚使其进入视口、下一帧
    // 再精确居中（TODO-340）。
    final BuildContext? rowContext = _rowKeys[currentIndex]?.currentContext;
    if (rowContext != null) {
      HibikiFocusScroll.ensureVisible(rowContext, duration: duration);
      return;
    }
    final double viewport = _scrollController.position.viewportDimension;
    final double rowWidth = widget.width;
    final double rowOffset = _estimatedScrollOffsetForVisibleIndex(
      visibleIndex,
      visibleIndexes,
      cues,
      rowWidth,
    );
    final double rowExtent = _estimatedRowExtentForCue(
      cues[currentIndex],
      rowWidth,
    );
    final double target = rowOffset - (viewport / 2) + (rowExtent / 2);
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    final double distance = (clamped - _scrollController.position.pixels).abs();
    final bool farAway = distance > viewport * 3;
    if (farAway) {
      _scrollController.jumpTo(clamped);
    } else {
      _scrollController.animateTo(clamped, duration: duration, curve: curve);
    }
    // 粗滚后下一帧目标行多半已挂载，再精确居中一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? settled = _rowKeys[currentIndex]?.currentContext;
      if (settled != null) {
        HibikiFocusScroll.ensureVisible(settled, duration: duration);
      }
    });
  }

  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      if (_autoScroll) _lastScrolledIndex = -1;
    });
    // TODO-613：通知页面层把新开关落 Drift preferences（null 时纯本地切换）。
    widget.onAutoScrollChanged?.call(_autoScroll);
    if (_autoScroll) {
      _scheduleScrollToCurrentCue();
    }
  }

  void _stepFont(int delta) {
    final int next =
        (_fontScaleIndex + delta).clamp(0, _kFontScaleSteps.length - 1);
    if (next == _fontScaleIndex) return;
    setState(() {
      _fontScaleIndex = next;
      _lastScrolledIndex = -1;
      // 字号变 → 行高变，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
    });
    _scheduleScrollToCurrentCue();
  }

  void _setFilter(Set<VideoSubtitleListFilter> next) {
    if (next.isEmpty) return;
    setState(() {
      _filter = next.single;
      _hoveredIndex = -1;
      _lastScrolledIndex = -1;
      // 过滤集变 → visibleIndex 重排，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
      _clearCueCaches();
    });
    _scheduleScrollToCurrentCue();
  }

  bool _isCueSelectedForCard(AudioCue cue) =>
      widget.isCueSelectedForCard?.call(cue) ?? false;

  int _selectedCueCount(List<AudioCue> cues) {
    if (!_hasCueSelectionControls) return 0;
    if (identical(_cachedSelectedCues, cues) &&
        _cachedSelectedCuesLength == cues.length) {
      return _cachedSelectedCount;
    }
    int count = 0;
    for (final AudioCue cue in cues) {
      if (_isCueSelectedForCard(cue)) count++;
    }
    _cachedSelectedCues = cues;
    _cachedSelectedCuesLength = cues.length;
    _cachedSelectedCount = count;
    return count;
  }

  List<int> _visibleCueIndexes(List<AudioCue> cues) {
    if (identical(_cachedCues, cues) &&
        _cachedCuesLength == cues.length &&
        _cachedFilter == _filter) {
      return _cachedVisibleIndexes;
    }
    late final List<int> indexes;
    switch (_filter) {
      case VideoSubtitleListFilter.all:
        indexes =
            List<int>.generate(cues.length, (int i) => i, growable: false);
        break;
      case VideoSubtitleListFilter.favorites:
        indexes = <int>[
          for (int i = 0; i < cues.length; i++)
            if (widget.isCueFavorited(cues[i])) i,
        ];
        break;
      case VideoSubtitleListFilter.selected:
        indexes = <int>[
          for (int i = 0; i < cues.length; i++)
            if (_isCueSelectedForCard(cues[i])) i,
        ];
        break;
    }
    _cachedCues = cues;
    _cachedCuesLength = cues.length;
    _cachedFilter = _filter;
    _cachedVisibleIndexes = indexes;
    _cachedVisibleIndexByRawIndex = <int, int>{
      for (int i = 0; i < indexes.length; i++) indexes[i]: i,
    };
    return indexes;
  }

  int _visibleIndexForRawIndex(int rawIndex, List<int> visibleIndexes) {
    if (_filter == VideoSubtitleListFilter.all) {
      return rawIndex >= 0 && rawIndex < visibleIndexes.length ? rawIndex : -1;
    }
    return _cachedVisibleIndexByRawIndex[rawIndex] ?? -1;
  }

  bool _isCurrentCueVisible(int rawIndex) {
    final List<AudioCue> cues = widget.controller.cues;
    if (rawIndex < 0 || rawIndex >= cues.length) return false;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    return _visibleIndexForRawIndex(rawIndex, visibleIndexes) >= 0;
  }

  double _initialScrollOffsetForCurrentCue() {
    final int currentIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (currentIndex < 0 || currentIndex >= cues.length) return 0;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    final int visibleIndex =
        _visibleIndexForRawIndex(currentIndex, visibleIndexes);
    if (visibleIndex < 0) return 0;
    final int contextIndex =
        (visibleIndex - 3).clamp(0, visibleIndexes.length - 1).toInt();
    return _estimatedScrollOffsetForVisibleIndex(
      contextIndex,
      visibleIndexes,
      cues,
      widget.width,
    );
  }

  void _clearCueCaches() {
    _cachedCues = null;
    _cachedCuesLength = -1;
    _cachedFilter = null;
    _cachedVisibleIndexes = const <int>[];
    _cachedVisibleIndexByRawIndex = const <int, int>{};
    _cachedSelectedCues = null;
    _cachedSelectedCuesLength = -1;
    _cachedSelectedCount = 0;
  }

  void _retainRowKeyFor(int? rawIndex) {
    _rowKeys.removeWhere((int key, _) => key != rawIndex);
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    final int currentIndex = widget.controller.currentCueIndex;
    _retainRowKeyFor(currentIndex >= 0 ? currentIndex : _scrollTargetRawIndex);
    final bool showLoading =
        cues.isEmpty && widget.controller.isSubtitleCuesLoading;
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
              child: showLoading
                  ? _buildLoading(cs)
                  : cues.isEmpty || visibleIndexes.isEmpty
                      ? _buildEmpty(cs)
                      // 无 itemExtent：行高自适应换行后的文本（TODO-340）。每行包一个
                      // GlobalKey（存 _rowKeys，按 rawIndex）供 ensureVisible 自动滚动。
                      : ListView.builder(
                          controller: _scrollController,
                          itemExtentBuilder:
                              (int i, SliverLayoutDimensions dimensions) {
                            if (i < 0 || i >= visibleIndexes.length) {
                              return null;
                            }
                            return _estimatedRowExtentForCue(
                              cues[visibleIndexes[i]],
                              dimensions.crossAxisExtent,
                            );
                          },
                          itemCount: visibleIndexes.length,
                          itemBuilder: (BuildContext _, int i) {
                            final int rawIndex = visibleIndexes[i];
                            final AudioCue cue = cues[rawIndex];
                            final bool selected = rawIndex == currentIndex;
                            final bool trackKey =
                                selected || rawIndex == _scrollTargetRawIndex;
                            final Key rowKey = trackKey
                                ? _rowKeys.putIfAbsent(rawIndex, GlobalKey.new)
                                : ValueKey<int>(rawIndex);
                            return KeyedSubtree(
                              key: rowKey,
                              child: _buildRow(
                                cs,
                                cue,
                                i,
                                selected,
                              ),
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
              // TODO-611：列表锁定开关。锁定后页面层的「点列表外关闭」barrier 被门控成
              // no-op（列表不会被点外部关闭，仅 Esc / 字幕按钮可关）。onToggleLock 为
              // null 时不渲染（部分调用方不需要锁定能力）。
              if (widget.onToggleLock != null)
                IconButton(
                  tooltip: widget.locked
                      ? t.video_subtitle_list_unlock
                      : t.video_subtitle_list_lock,
                  icon: Icon(
                    widget.locked ? Icons.lock : Icons.lock_open,
                    size: iconSize,
                  ),
                  color: widget.locked ? cs.primary : cs.onSurfaceVariant,
                  onPressed: widget.onToggleLock,
                  visualDensity: VisualDensity.compact,
                ),
              // BUG-254：去掉右上角 X 关闭按钮，改为点击面板外的空白区域关闭（由页面层
              // 全屏透明 barrier 承载）。关闭时的 onClearCueSelection 由页面层
              // [_hideVideoSidePanel] 统一清理（字幕列表关闭即清挖词选择），故移除按钮不丢
              // 该副作用。
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

  Widget _buildLoading(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              widget.loadingHint ?? widget.emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: _effectiveFontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, AudioCue cue, int index, bool selected) {
    final bool hovered = index == _hoveredIndex;
    final bool selectedForCard = _isCueSelectedForCard(cue);
    // 收藏（[favorited]）是持久属性，不抢「正在播 / 挖词选中 / hover」的背景色：用左侧
    // 竖色条 + 行内实心星标记，与三种瞬态背景正交叠加（BUG-264）。背景优先级仍为
    // current > selectedForCard > hover。
    final bool favorited = widget.isCueFavorited(cue);
    final Color bg = selected
        ? cs.primaryContainer
        : selectedForCard
            ? cs.secondaryContainer.withValues(alpha: 0.72)
            : favorited
                ? cs.tertiaryContainer.withValues(alpha: 0.32)
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
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) {
        if (_hoveredIndex == index) setState(() => _hoveredIndex = -1);
      },
      child: InkWell(
        // 行点击 = seek 到该句（与 asbplayer transcript 一致）。文本字符查词由文本区
        // 叠加的 translucent hit-test 层承载（[onLookupCue] 非 null 时），它赢手势竞技场、
        // 截断本 InkWell，故点字查词、点空白 / 时间戳 seek，两不冲突（BUG-263）。
        onTap: () => widget.onTapCue(cue),
        child: Container(
          // 左侧 3px 竖色条标记已收藏行（BUG-264）：未收藏时无边框、像素级不变。背景色
          // 统一走 [decoration]（不能同时传 color 与 decoration）。
          padding: const EdgeInsets.only(left: 8, right: 4, top: 8, bottom: 8),
          decoration: BoxDecoration(
            color: bg,
            border: favorited
                ? Border(left: BorderSide(color: cs.tertiary, width: 3))
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_hasCueSelectionControls) ...<Widget>[
                _buildSelectionCheckbox(cs, cue, selectedForCard),
                const SizedBox(width: 4),
              ],
              SizedBox(
                // TODO-567：列宽随字号缩放（[_timestampColumnWidth]），且时间戳单行
                // 不换行、超宽省略，绝不溢出到右侧字幕文本列（修「时间被下一条字幕
                // 挡住 / 溢出」）。
                width: _timestampColumnWidth,
                child: Text(
                  formatCueTimestamp(cue.startMs),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
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
                  child:
                      _buildRowText(cue, textColor, selected, selectedForCard)),
              // 操作按钮（跳转 / 复制 / 收藏）常驻，不再仅 hover / 选中可见（BUG-265）：
              // 长文本由上面单行省略让出空间，按钮不会挤坏布局。
              _buildRowActions(cs, cue, selected, favorited),
            ],
          ),
        ),
      ),
    );
  }

  /// 行的字幕文本。**允许换行显示完整字幕**（TODO-340：放开 BUG-266 的单行省略，固定
  /// [_itemExtent] 也随之放弃改自适应行高）。[VideoSubtitleJumpPanel.onLookupCue] 非 null
  /// 时仍只渲染单个 [RichText]，点击命中由同源 [TextPainter] 按 UTF-16 offset 反查
  /// grapheme，避免长字幕为每个字符创建独立 widget。
  Widget _buildRowText(
    AudioCue cue,
    Color textColor,
    bool selected,
    bool selectedForCard,
  ) {
    final TextStyle textStyle = TextStyle(
      color: textColor,
      fontSize: _effectiveFontSize,
      fontWeight: selected || selectedForCard ? FontWeight.w600 : null,
      height: 1.25,
    );
    final void Function(AudioCue, int, Rect)? onLookup = widget.onLookupCue;
    if (onLookup == null) {
      // 无查词能力：整段文本（换行），不叠 tap 层，外层 InkWell 行点击仍 seek。
      return Text(cue.text, style: textStyle);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextSpan textSpan = TextSpan(text: cue.text, style: textStyle);
        final TextDirection textDirection = Directionality.of(context);
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        final double maxWidth = constraints.maxWidth;

        List<int> graphemeStartOffsets() {
          final List<int> starts = <int>[];
          int offset = 0;
          for (final String grapheme in cue.text.characters) {
            starts.add(offset);
            offset += grapheme.length;
          }
          return starts;
        }

        List<int> graphemeEndOffsets(List<int> starts) {
          final List<int> ends = <int>[];
          int offset = 0;
          int i = 0;
          for (final String grapheme in cue.text.characters) {
            offset += grapheme.length;
            ends.add(offset);
            i++;
          }
          assert(i == starts.length);
          return ends;
        }

        int graphemeIndexForOffset(
          int offset,
          List<int> starts,
          List<int> ends,
        ) {
          if (starts.isEmpty) return -1;
          for (int i = 0; i < starts.length; i++) {
            if (offset <= starts[i]) return i == 0 ? 0 : i - 1;
            if (offset <= ends[i]) return i;
          }
          return starts.length - 1;
        }

        Rect unionBoxes(List<TextBox> boxes) {
          if (boxes.isEmpty) return Rect.zero;
          Rect rect = boxes.first.toRect();
          for (final TextBox box in boxes.skip(1)) {
            rect = rect.expandToInclude(box.toRect());
          }
          return rect;
        }

        SubtitleListCharHit? hitAt({
          required Offset localPosition,
          required Offset globalPosition,
        }) {
          final List<int> starts = graphemeStartOffsets();
          final List<int> ends = graphemeEndOffsets(starts);
          if (starts.isEmpty) return null;
          final TextPainter painter = TextPainter(
            text: textSpan,
            textAlign: TextAlign.start,
            textDirection: textDirection,
            textScaler: textScaler,
            maxLines: null,
            ellipsis: null,
          );
          try {
            painter.layout(maxWidth: maxWidth);
            final int offset =
                painter.getPositionForOffset(localPosition).offset;
            final int graphemeIndex =
                graphemeIndexForOffset(offset, starts, ends);
            if (graphemeIndex < 0) return null;
            final int start = starts[graphemeIndex];
            final int end = ends[graphemeIndex];
            Rect localRect = unionBoxes(
              painter.getBoxesForSelection(
                TextSelection(baseOffset: start, extentOffset: end),
              ),
            );
            if (localRect.isEmpty) {
              final Offset caretOffset = painter.getOffsetForCaret(
                TextPosition(offset: start),
                Rect.fromLTWH(0, 0, 1, painter.preferredLineHeight),
              );
              localRect = Rect.fromLTWH(
                caretOffset.dx,
                caretOffset.dy,
                1,
                painter.preferredLineHeight,
              );
            }
            if (!localRect.contains(localPosition)) {
              if (!localRect.inflate(1).contains(localPosition)) return null;
              localRect = localRect.expandToInclude(
                Rect.fromCenter(center: localPosition, width: 1, height: 1),
              );
            }
            if (localRect.isEmpty) return null;
            final Offset globalOrigin = globalPosition - localPosition;
            return (
              graphemeIndex: graphemeIndex,
              charRect: localRect.shift(globalOrigin),
            );
          } finally {
            painter.dispose();
          }
        }

        return GestureDetector(
          // translucent：tap 赢手势竞技场截断外层 InkWell（点文本 = 查词、非 seek），
          // 但空白处手动回落到行 seek，保留“点字查词、点空白 seek”的语义。
          behavior: HitTestBehavior.translucent,
          onTapUp: (TapUpDetails details) {
            final SubtitleListCharHit? hit = hitAt(
              localPosition: details.localPosition,
              globalPosition: details.globalPosition,
            );
            if (hit != null && hit.charRect.contains(details.globalPosition)) {
              onLookup(cue, hit.graphemeIndex, hit.charRect);
              return;
            }
            widget.onTapCue(cue);
          },
          child: RichText(
            text: textSpan,
            softWrap: true,
            overflow: TextOverflow.clip,
            maxLines: null,
            textAlign: TextAlign.start,
            textDirection: textDirection,
            textScaler: textScaler,
          ),
        );
      },
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

  Widget _buildRowActions(
    ColorScheme cs,
    AudioCue cue,
    bool selected,
    bool favorited,
  ) {
    final Color iconColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
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
