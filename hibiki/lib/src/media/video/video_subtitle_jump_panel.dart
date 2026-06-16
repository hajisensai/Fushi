import 'package:flutter/material.dart';
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

  /// 每个可见行的 [GlobalKey]（按 visibleIndex），供自适应行高下用
  /// [HibikiFocusScroll.ensureVisible] 滚到当前 cue（TODO-340：放弃固定 itemExtent 换行后，
  /// 不能再按 `index * itemExtent` 算偏移）。每帧 build 重建。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  /// 单行估算高度（仅作目标行未挂载时的粗滚后备，TODO-340）。换行后实际行高可变，
  /// 故不再用作精确 itemExtent；当前 cue 行进入视口后由 ensureVisible 精确居中。
  double get _estimatedRowExtent => 56 * _fontScaleSteps;

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
    const Duration duration = Duration(milliseconds: 240);
    const Curve curve = Curves.easeOutCubic;
    // 可变行高下优先用 ensureVisible 把当前行精确居中（alignment 0.5）；目标行已挂载
    // 才有 RenderObject。未挂载（在远处视口外）时先按估算行高粗滚使其进入视口、下一帧
    // 再精确居中（TODO-340）。
    final BuildContext? rowContext = _rowKeys[visibleIndex]?.currentContext;
    if (rowContext != null) {
      HibikiFocusScroll.ensureVisible(rowContext, duration: duration);
      return;
    }
    final double viewport = _scrollController.position.viewportDimension;
    final double target = (visibleIndex * _estimatedRowExtent) -
        (viewport / 2) +
        _estimatedRowExtent;
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(clamped, duration: duration, curve: curve);
    // 粗滚后下一帧目标行多半已挂载，再精确居中一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? settled = _rowKeys[visibleIndex]?.currentContext;
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
      // 字号变 → 行高变，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
    });
  }

  void _setFilter(Set<VideoSubtitleListFilter> next) {
    if (next.isEmpty) return;
    setState(() {
      _filter = next.single;
      _hoveredIndex = -1;
      _lastScrolledIndex = -1;
      // 过滤集变 → visibleIndex 重排，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final List<AudioCue> visibleCues = _visibleCues(cues);
    final int currentIndex = widget.controller.currentCueIndex;
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
                  : cues.isEmpty || visibleCues.isEmpty
                      ? _buildEmpty(cs)
                      // 无 itemExtent：行高自适应换行后的文本（TODO-340）。每行包一个
                      // GlobalKey（存 _rowKeys，按 visibleIndex）供 ensureVisible 自动滚动。
                      : ListView.builder(
                          controller: _scrollController,
                          itemCount: visibleCues.length,
                          itemBuilder: (BuildContext _, int i) {
                            final AudioCue cue = visibleCues[i];
                            final GlobalKey rowKey =
                                _rowKeys.putIfAbsent(i, GlobalKey.new);
                            return KeyedSubtree(
                              key: rowKey,
                              child: _buildRow(
                                cs,
                                cue,
                                i,
                                cues.indexOf(cue) == currentIndex,
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
                  child: _buildRowText(
                      cs, cue, textColor, selected, selectedForCard)),
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
  /// [_itemExtent] 也随之放弃改自适应行高），并在 [VideoSubtitleJumpPanel.onLookupCue]
  /// 非 null 时把文本逐 grapheme 渲染成可命中的字符（[Wrap] 自然换行），整片 translucent
  /// 的 tap 层 → 点击位置精确反查命中的字符 grapheme 从该位置起查词（复用页面层 `_lookupAt`
  /// 链路：暂停 → 推查词浮层，与底部字幕逐字查词同范式，TODO-340）。[onLookupCue] 为 null
  /// （无查词能力 / 部分测试）时退化成整段 [Text]（仍换行），行点击仍 seek（向后兼容）。
  Widget _buildRowText(
    ColorScheme cs,
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
    // 逐 grapheme 渲染成独立 [Text] 并登记其 [BuildContext]（下标==grapheme 下标），
    // 供按全局坐标反查命中的字符（与底部 [VideoSubtitleOverlay] 同范式）。整片
    // translucent [GestureDetector] 的 onTapUp 反查命中 grapheme 再回调 onLookup。
    final List<String> chars = cue.text.characters.toList(growable: false);
    final List<BuildContext> charContexts = <BuildContext>[];
    SubtitleListCharHit? hitAt(Offset globalPos) {
      for (int i = 0; i < charContexts.length; i++) {
        final RenderObject? ro = charContexts[i].findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) continue;
        final Rect r = ro.localToGlobal(Offset.zero) & ro.size;
        if (r.contains(globalPos)) {
          return (graphemeIndex: i, charRect: r);
        }
      }
      return null;
    }

    return GestureDetector(
      // translucent：tap 赢手势竞技场截断外层 InkWell（点文本 = 查词、非 seek），
      // 但不独占 hover hit-test（与底部 overlay BUG-198 同范式）。
      behavior: HitTestBehavior.translucent,
      onTapUp: (TapUpDetails details) {
        final SubtitleListCharHit? hit = hitAt(details.globalPosition);
        if (hit != null) {
          onLookup(cue, hit.graphemeIndex, hit.charRect);
          return;
        }
        // 命中字符间空白 / 反查失败：保底从句首起查词（不丢交互），矩形退化成整行。
        onLookup(cue, 0, Rect.zero);
      },
      child: Wrap(
        children: <Widget>[
          for (int i = 0; i < chars.length; i++)
            Builder(
              builder: (BuildContext charContext) {
                charContexts.add(charContext);
                return Text(chars[i], style: textStyle);
              },
            ),
        ],
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
