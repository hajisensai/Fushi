import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

String formatCueTimestamp(int startMs) =>
    HibikiTimeFormat.clock(Duration(milliseconds: startMs < 0 ? 0 : startMs));

/// 字幕列表行**时间戳列宽度**（TODO-567 / TODO-1200）。纯函数，页面与测试同源。
///
/// 时间戳用 tabular figures 单行不换行渲染，列宽须容下最宽的时间戳字符串，否则文本溢出到
/// 右侧字幕文本列（TODO-567）。但旧实现恒按**小时级**最坏宽度（`(字号-1) × 4.6`、下界 52）
/// 预留，即便整段视频不足 1 小时（时间戳只有 `m:ss`，约 5 字符 ≈ 40px）也占 ~60px——短时间戳
/// 左对齐在过宽的列里，时间戳与字幕文本之间凭空多出一段空白（TODO-1200 用户报的「奇怪空隙」），
/// 且白白吃掉本就紧张的文本列宽度（窄面板上字幕被挤成 3-4 字硬折行）。
///
/// 修正：按列表**是否真的出现小时级时间戳**（[hasHours]）取宽——不足 1 小时只按 `mm:ss`
/// （约 5 字符）算窄列，达到 1 小时才按 `h:mm:ss`（约 7 字符）算宽列。既不溢出（仍容下实际
/// 最宽时间戳），又消除短视频的空隙、把宽度还给文本列。tabular figures 下每字位约 0.62em，
/// 加一点余量并随字号缩放，设下界防极窄字号下列太窄。[effectiveFontSize] 传行内时间戳同源
/// 的有效字号（渲染时时间戳用 `effectiveFontSize - 1`，故此处一致用 `-1` 折算字位宽）。
double subtitleTimestampColumnWidth(double effectiveFontSize, bool hasHours) {
  const double emPerChar = 0.62;
  final double chars = hasHours ? 7.2 : 5.0;
  final double scaled = (effectiveFontSize - 1) * emPerChar * chars;
  final double floor = hasHours ? 52.0 : 36.0;
  return scaled < floor ? floor : scaled;
}

const List<double> _kFontScaleSteps = <double>[0.85, 1.0, 1.15, 1.3];

/// 字幕列表行内点击命中的字符：被点 grapheme 下标 + 该字符的全局屏幕矩形。
/// 供 [VideoSubtitleJumpPanel.onLookupCue] 精确查词（TODO-340）。
typedef SubtitleListCharHit = ({int graphemeIndex, Rect charRect});

/// 命中字幕列表某行某字符：整条 [cue] + grapheme 下标 + 该字符的全局屏幕矩形。
/// 比 [SubtitleListCharHit] 多带所属 [cue]，供查词浮层 dismiss barrier 直接切换查词
/// （BUG-872）。
typedef SubtitleListHit = ({AudioCue cue, int graphemeIndex, Rect charRect});

/// 给上层（查词浮层的 dismiss barrier）按全局坐标反查「点到的是字幕列表哪行哪个字符」
/// 用的句柄。[VideoSubtitleJumpPanel] 每帧 build 把命中实现绑进来；上层持有同一对象、
/// 调 [hitTest]（BUG-872）。
///
/// 与画面底部内嵌字幕的 `VideoSubtitleHitTester`（`video_subtitle_overlay.dart`）同范式：
/// 查词浮层打开时，根 Overlay 的全屏 dismiss barrier 盖在**推挤式字幕列表侧栏**之上、抢走
/// 点击 → 点列表里下一个词只会关浮层、查不了下一个词。让 barrier 先用本句柄反查是否点到了
/// 列表字符，是则切换查词（保持暂停 + `replaceStack`），否则才 dismiss。
class VideoSubtitleListHitTester {
  SubtitleListHit? Function(Offset globalPos)? _impl;

  /// [VideoSubtitleJumpPanel] build 时绑定当前可见行的命中实现。
  void bindHitTest(SubtitleListHit? Function(Offset globalPos) impl) =>
      _impl = impl;

  /// 面板卸载（侧栏隐藏）时解绑，避免 barrier 调到已失效的实现。
  void unbind() => _impl = null;

  /// 无绑定（无查词能力 / 面板已卸载）时返回 null，barrier 落回原 dismiss。
  SubtitleListHit? hitTest(Offset globalPos) => _impl?.call(globalPos);
}

/// 字幕文本每个 grapheme 的 UTF-16 起始偏移（按 [String.characters] 顺序）。列表行内 tap 的
/// `hitAt` 与 [subtitleListCharHitFromParagraph] 共用（消除重复，BUG-872）。
@visibleForTesting
List<int> subtitleGraphemeStartOffsets(String text) {
  final List<int> starts = <int>[];
  int offset = 0;
  for (final String grapheme in text.characters) {
    starts.add(offset);
    offset += grapheme.length;
  }
  return starts;
}

/// 字幕文本每个 grapheme 的 UTF-16 结束偏移（与 [subtitleGraphemeStartOffsets] 一一对应）。
@visibleForTesting
List<int> subtitleGraphemeEndOffsets(String text) {
  final List<int> ends = <int>[];
  int offset = 0;
  for (final String grapheme in text.characters) {
    offset += grapheme.length;
    ends.add(offset);
  }
  return ends;
}

/// 把 UTF-16 [offset] 映射到 grapheme 下标：落在某 grapheme 区间内即命中该 grapheme，
/// 落在起点前归第一个、越界归最后一个。[starts]/[ends] 为同源 grapheme 偏移表。
@visibleForTesting
int subtitleGraphemeIndexForOffset(
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

Rect _subtitleUnionBoxes(List<TextBox> boxes) {
  if (boxes.isEmpty) return Rect.zero;
  Rect rect = boxes.first.toRect();
  for (final TextBox box in boxes.skip(1)) {
    rect = rect.expandToInclude(box.toRect());
  }
  return rect;
}

/// 在一个已布局的行文本 [RenderParagraph] 上，按行内 [localPosition] 反查命中的字符
/// （BUG-872，供 [VideoSubtitleListHitTester] 用）。逻辑与 [VideoSubtitleJumpPanel] 行内 tap
/// 的 `hitAt` 同构（同一 grapheme 映射 + 选区盒并集 + 1px 容差），只是取位置 / 选区盒改用
/// 实时 [RenderParagraph]（免重建 TextPainter），并去掉 caret 兜底（miss 落回 dismiss，安全）。
///
/// 返回被点 grapheme 下标 + 该字符的**全局**屏幕矩形（`globalPosition - localPosition` 平移，
/// 与 `hitAt` 同式，保证与底部字幕查词定位一致）。空文本 / 越界 / 容差外返回 null。
SubtitleListCharHit? subtitleListCharHitFromParagraph(
  RenderParagraph paragraph,
  String text, {
  required Offset localPosition,
  required Offset globalPosition,
}) {
  final List<int> starts = subtitleGraphemeStartOffsets(text);
  if (starts.isEmpty) return null;
  final List<int> ends = subtitleGraphemeEndOffsets(text);
  final int offset = paragraph.getPositionForOffset(localPosition).offset;
  final int graphemeIndex =
      subtitleGraphemeIndexForOffset(offset, starts, ends);
  if (graphemeIndex < 0) return null;
  final int start = starts[graphemeIndex];
  final int end = ends[graphemeIndex];
  Rect localRect = _subtitleUnionBoxes(
    paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    ),
  );
  if (localRect.isEmpty) return null;
  if (!localRect.contains(localPosition)) {
    if (!localRect.inflate(1).contains(localPosition)) return null;
    localRect = localRect.expandToInclude(
      Rect.fromCenter(center: localPosition, width: 1, height: 1),
    );
  }
  final Offset globalOrigin = globalPosition - localPosition;
  return (
    graphemeIndex: graphemeIndex,
    charRect: localRect.shift(globalOrigin),
  );
}

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
    this.hitTester,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.loadingHint,
    this.isCueSelectedForCard,
    this.onToggleCueSelection,
    this.onClearCueSelection,
    this.initialAutoScroll = true,
    this.onAutoScrollChanged,
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

  /// 可选：按全局坐标反查列表字符命中的句柄（BUG-872）。非 null 时面板每帧把当前可见行的
  /// 命中实现绑进去，供查词浮层 dismiss barrier「点列表下一个词切换查词、保持浮层」。null
  /// （测试 / 无查词能力）时不绑，行为与历史一致。
  final VideoSubtitleListHitTester? hitTester;
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

  /// BUG-872：当前已构建（可见）行的文本 [RenderParagraph] 命中登记表，键为 ListView.builder
  /// 的 **builder 下标 i**（同一时刻每 i 唯一，稳定不撞 GlobalKey）。逐行在 [_buildRow] 里把
  /// 行文本 [RichText] 的 [GlobalKey]（[_rowTextKeys]）与所属 cue（[_rowHitCues]）登记进来；
  /// [_hitTestRows] 遍历本表、用各行 RenderParagraph 反查全局坐标命中的字符。行滚出屏后
  /// element 卸载、`currentContext` 为 null，自动跳过（不残留误命中）；[_rowHitCues] 每帧 build
  /// 前清空、仅当帧真正构建的行回填，保证不会读到旧 cue。
  final Map<int, GlobalKey> _rowTextKeys = <int, GlobalKey>{};
  final Map<int, AudioCue> _rowHitCues = <int, AudioCue>{};
  List<AudioCue>? _cachedCues;
  int _cachedCuesLength = -1;
  VideoSubtitleListFilter? _cachedFilter;
  List<int> _cachedVisibleIndexes = const <int>[];
  Map<int, int> _cachedVisibleIndexByRawIndex = const <int, int>{};

  /// BUG-841：特效叠加 / 多层 ASS 用多条 Dialogue 事件渲染**同一句可见文本**（不同
  /// layer / style / 位置做描边、辉光、逐字变色等特效），画面 overlay 有意全渲染各层
  /// （TODO-1312），但字幕列表按 `(startMs, 文本)` 折叠这些重复，只保留首条**代表行**，
  /// 一句话不再在列表里出现多行。双语（同时间、文本不同）文本不同不折叠，日/中各占一行。
  /// [_cachedDedupIndexes] 是代表行的 raw 下标（升序，`setCues` 已排序）；
  /// [_cachedRepresentativeByRaw] 把**每个** raw 下标（含被折叠的重复）映射到其代表行的
  /// raw 下标，供当前播放句落在重复项时把高亮 / 自动滚动定位到那唯一渲染的代表行。
  List<AudioCue>? _cachedDedupCues;
  int _cachedDedupCuesLength = -1;
  List<int> _cachedDedupIndexes = const <int>[];
  Map<int, int> _cachedRepresentativeByRaw = const <int, int>{};
  List<AudioCue>? _cachedSelectedCues;
  int _cachedSelectedCuesLength = -1;
  int _cachedSelectedCount = 0;

  /// 单行估算高度（仅作目标行未挂载时的粗滚后备，TODO-340）。换行后实际行高可变，
  /// 故不再用作精确 itemExtent；当前 cue 行进入视口后由 ensureVisible 精确居中。
  double get _estimatedRowExtent => 56 * _fontScaleSteps;

  double get _fontScaleSteps => _kFontScaleSteps[_fontScaleIndex];

  double get _effectiveFontSize => widget.fontSize * _fontScaleSteps;

  /// 列表里是否出现**小时级**时间戳（TODO-1200）：cue 升序（`setCues` 保证），故最后一条
  /// cue 的起始时间即最大值，>= 1 小时才需要 `h:mm:ss` 宽列；空列表按无小时（窄列）。用它
  /// 让 [_timestampColumnWidth] 只在真有小时级时间戳时才取宽列，短视频用窄列消除空隙。
  bool get _hasHourTimestamps {
    final List<AudioCue> cues = widget.controller.cues;
    if (cues.isEmpty) return false;
    return cues.last.startMs >= 3600 * 1000;
  }

  /// 时间戳列宽度（TODO-567 / TODO-1200）：内容自适应，见 [subtitleTimestampColumnWidth]。
  /// 短视频（无小时级时间戳）取窄列消除时间戳与文本间的「奇怪空隙」并把宽度还给文本列，
  /// 达到 1 小时才取宽列容下 `h:mm:ss`。配合时间戳 Text 单行不换行（`maxLines:1` /
  /// `softWrap:false`），列内容永不溢出到文本列。
  double get _timestampColumnWidth =>
      subtitleTimestampColumnWidth(_effectiveFontSize, _hasHourTimestamps);

  double _estimatedRowExtentForCue(AudioCue cue, double rowWidth) {
    // 3 个操作图标：每个 icon 宽 [_effectiveFontSize]+2，[_RowActionButton] 内缩 all(2)
    // → 每个约 +6，故动作列宽 ≈ 3×(字号+6)（TODO-1200 压缩内缩后，与 [_buildRowActions]
    // 的实际几何一致，供行高文本宽度估算）。
    final double actionWidth = 3 * (_effectiveFontSize + 6);
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
    // BUG-841：当前句可能落在被折叠的重复项上——追踪其**代表行** raw（列表渲染的唯一行），
    // 否则高亮 / 滚动定位不到（rowKey 按代表行 raw 挂）。
    final int initialRawIndex =
        _representativeRaw(widget.controller.currentCueIndex);
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
      final int currentRep =
          _representativeRaw(widget.controller.currentCueIndex);
      _scrollTargetRawIndex =
          _isCurrentCueVisible(currentRep) ? currentRep : null;
      _rowKeys.clear();
      _retainRowKeyFor(_scrollTargetRawIndex);
      _scheduleScrollToCurrentCue();
    }
    _clearCueCaches();
  }

  @override
  void dispose() {
    // BUG-872：面板卸载（侧栏隐藏）时解绑命中句柄，避免 barrier 调到已失效的实现。
    widget.hitTester?.unbind();
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// BUG-872：按全局坐标反查当前可见行里命中的字符，返回 `(cue, grapheme, charRect)`。
  /// 供 [VideoSubtitleListHitTester] 绑定给查词浮层 dismiss barrier。无查词能力 / 无命中
  /// 返回 null（barrier 落回原 dismiss）。遍历 [_rowTextKeys]：滚出屏的行 `currentContext`
  /// 为 null 自动跳过；先粗判点落在哪行的段落框内，再逐字符精查。
  SubtitleListHit? _hitTestRows(Offset globalPos) {
    if (widget.onLookupCue == null || _rowHitCues.isEmpty) return null;
    for (final MapEntry<int, GlobalKey> entry in _rowTextKeys.entries) {
      final AudioCue? cue = _rowHitCues[entry.key];
      if (cue == null) continue;
      final RenderObject? ro = entry.value.currentContext?.findRenderObject();
      if (ro is! RenderParagraph || !ro.attached) continue;
      final Offset local = ro.globalToLocal(globalPos);
      if (!(Offset.zero & ro.size).contains(local)) continue;
      final SubtitleListCharHit? hit = subtitleListCharHitFromParagraph(
        ro,
        cue.text,
        localPosition: local,
        globalPosition: globalPos,
      );
      if (hit == null) continue;
      return (
        cue: cue,
        graphemeIndex: hit.graphemeIndex,
        charRect: hit.charRect,
      );
    }
    return null;
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
      // BUG-841：追踪代表行 raw（当前句可能是被折叠的重复项）。
      _scrollTargetRawIndex =
          currentIndex >= 0 ? _representativeRaw(currentIndex) : null;
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
    final int rawIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (rawIndex < 0 || rawIndex >= cues.length) return;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    // BUG-841：当前句若是被折叠的重复项，定位到其代表行（列表渲染的唯一行、rowKey 所在）。
    final int currentIndex = _representativeRaw(rawIndex);
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
    // BUG-841：只数去重后的代表行，与 selected 档实际渲染的行一一对应。
    int count = 0;
    for (final int i in _dedupedRawIndexes(cues)) {
      if (_isCueSelectedForCard(cues[i])) count++;
    }
    _cachedSelectedCues = cues;
    _cachedSelectedCuesLength = cues.length;
    _cachedSelectedCount = count;
    return count;
  }

  /// 收藏档可见条目数（TODO-631）。与 [VideoSubtitleListFilter.favorites] 档实际渲染的
  /// 条目集合（[_visibleCueIndexes] 的 favorites 分支）一一对应——同一个 `isCueFavorited`
  /// 谓词，故数量与列表完全一致。这是已删的「本集收藏」面板顶部计数 header 的归宿：收藏
  /// 统计并入字幕列表收藏档。
  int _favoriteCueCount(List<AudioCue> cues) {
    // BUG-841：只数去重后的代表行，与 favorites 档实际渲染的行一一对应。
    int count = 0;
    for (final int i in _dedupedRawIndexes(cues)) {
      if (widget.isCueFavorited(cues[i])) count++;
    }
    return count;
  }

  /// BUG-841：按 `(startMs, 文本)` 折叠重复 cue，返回代表行 raw 下标（升序）并同步
  /// 刷新 [_cachedRepresentativeByRaw]（每个 raw → 其代表行 raw）。按 cues 身份 + 长度
  /// 记忆化（`setCues` 换列表即失效；[_clearCueCaches] 亦清）。特效叠加 / 多层同句拷贝
  /// 同 start 同文本 → 折叠成一行；双语文本不同 → 各自保留。
  List<int> _dedupedRawIndexes(List<AudioCue> cues) {
    if (identical(_cachedDedupCues, cues) &&
        _cachedDedupCuesLength == cues.length) {
      return _cachedDedupIndexes;
    }
    final List<int> reps = <int>[];
    final Map<String, int> firstByKey = <String, int>{};
    final Map<int, int> repByRaw = <int, int>{};
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final String key = '${cue.startMs} ${cue.text}';
      final int? rep = firstByKey[key];
      if (rep == null) {
        firstByKey[key] = i;
        repByRaw[i] = i;
        reps.add(i);
      } else {
        repByRaw[i] = rep;
      }
    }
    _cachedDedupCues = cues;
    _cachedDedupCuesLength = cues.length;
    _cachedDedupIndexes = reps;
    _cachedRepresentativeByRaw = repByRaw;
    return reps;
  }

  /// 把任意 raw 下标（可能是被折叠的重复项）映射到其代表行 raw 下标（BUG-841）。当前
  /// 播放句落在重复拷贝上时，用它把高亮 / 自动滚动定位到唯一渲染的代表行。
  int _representativeRaw(int rawIndex) {
    if (rawIndex < 0) return rawIndex;
    _dedupedRawIndexes(widget.controller.cues);
    return _cachedRepresentativeByRaw[rawIndex] ?? rawIndex;
  }

  List<int> _visibleCueIndexes(List<AudioCue> cues) {
    // 收藏档（[VideoSubtitleListFilter.favorites]）的成员集由 *实时* [isCueFavorited]
    // 谓词决定，而该谓词可在 panel widget 身份不变（如页面层用稳定的 `_isCueFavorited`
    // 方法 tear-off）的情况下变化——收藏 toggle 不触发 [didUpdateWidget] 的兜底
    // `_clearCueCaches()`。若把收藏档也按 `(cues 身份, 长度, filter)` 缓存，收藏状态变
    // 后这三者都没变 → 命中陈旧成员集 → 列表延迟（计数 chip 走未缓存的
    // [_favoriteCueCount] 即时更新，列表却落后，TODO-632/BUG-359）。故收藏档**不缓存**：
    // 每次重算（收藏档条目通常不多，成本可接受）。`all` / `selected` 仍按结构键缓存
    // （`all` 纯结构；`selected` 经 onToggleCueSelection→页面 setState 触发 didUpdateWidget
    // 清缓存，保留其缓存性能）。
    final bool cacheable = _filter != VideoSubtitleListFilter.favorites;
    if (cacheable &&
        identical(_cachedCues, cues) &&
        _cachedCuesLength == cues.length &&
        _cachedFilter == _filter) {
      return _cachedVisibleIndexes;
    }
    // BUG-841：三档都以**去重后**的代表行为基（特效叠加同句拷贝只出一行）；收藏 / 已选
    // 再在代表行上过滤，计数 chip 走同一去重集合（[_favoriteCueCount] / [_selectedCueCount]）
    // 故数量与列表一致。
    final List<int> base = _dedupedRawIndexes(cues);
    late final List<int> indexes;
    switch (_filter) {
      case VideoSubtitleListFilter.all:
        indexes = base;
        break;
      case VideoSubtitleListFilter.favorites:
        indexes = <int>[
          for (final int i in base)
            if (widget.isCueFavorited(cues[i])) i,
        ];
        break;
      case VideoSubtitleListFilter.selected:
        indexes = <int>[
          for (final int i in base)
            if (_isCueSelectedForCard(cues[i])) i,
        ];
        break;
    }
    // [_visibleIndexForRawIndex] 非 all 档读 [_cachedVisibleIndexByRawIndex]，故收藏档
    // 即便不走 visibleIndexes 缓存，也必须每次同步刷新该 raw→visible 映射（用本次重算
    // 的 indexes）；否则收藏档自动滚动定位会按陈旧映射。`_cachedCues` / `_cachedFilter`
    // 仍记为收藏档，使任何后续非收藏档命中前都因 filter 不等而重算。
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
    // BUG-841：去重后 `all` 档不再是恒等映射（重复项被折叠、raw 下标有跳空），三档统一走
    // raw→代表行→可见位置映射；当前句落在被折叠的重复项时，定位到其代表行。
    final int rep = _cachedRepresentativeByRaw[rawIndex] ?? rawIndex;
    return _cachedVisibleIndexByRawIndex[rep] ?? -1;
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
    _cachedDedupCues = null;
    _cachedDedupCuesLength = -1;
    _cachedDedupIndexes = const <int>[];
    _cachedRepresentativeByRaw = const <int, int>{};
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
    // BUG-872：把当前可见行的命中实现绑给查词浮层 dismiss barrier；每帧重置行 cue 登记表，
    // 仅本帧真正构建（itemBuilder 调用）的行回填，避免读到上一帧的旧 cue。
    widget.hitTester?.bindHitTest(_hitTestRows);
    _rowHitCues.clear();
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    // BUG-841：当前句可能是被折叠的重复项——映射到其代表行 raw（列表渲染的唯一行）供高亮
    // 与 rowKey 保留，否则当前句落在重复拷贝时整行都不高亮。
    final int currentIndex =
        _representativeRaw(widget.controller.currentCueIndex);
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
                      ? _buildEmpty(cs, cuesLoaded: cues.isNotEmpty)
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
              // TODO-637：字幕列表是「带 × 的非阻塞侧栏」——头部带回右上角 × 关闭
              // 按钮（BUG-254 当初移除 ×、改点画面 barrier 关闭，但该 barrier 罩在画面
              // 字幕查词手势上致画面查不了词，TODO-636）。× 调 onClose（页面层清挖词
              // 选择 + 隐藏列表），与 Esc / 控制条字幕按钮三路关闭等价。锁定按钮（原
              // TODO-611，唯一作用是门控已删的 barrier）随 barrier 一并移除（TODO-634）。
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: Icon(Icons.close, size: iconSize),
                color: cs.onSurfaceVariant,
                onPressed: widget.onClose,
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
              // TODO-631：收藏档收藏数。删了独立「本集收藏」面板后，其顶部「收藏 N」计数
              // 并入字幕列表收藏档——只在 favorites 档显示，让用户切到收藏档时一眼看到本
              // 视频已收藏多少句（与列表条目数一致，复用同一 isCueFavorited 谓词）。
              if (_filter == VideoSubtitleListFilter.favorites)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Text(
                    t.video_favorite_count(count: _favoriteCueCount(cues)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: widget.fontSize - 1,
                      fontWeight: FontWeight.w600,
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

  /// 空态文案（TODO-631 / BUG-795）。必须区分两种「无行可显示」：
  ///   1. `cuesLoaded == false`：字幕本体一条都没有（真未加载）→ [widget.emptyHint]
  ///      （"未加载字幕"）。
  ///   2. `cuesLoaded == true` 但当前过滤档（收藏 / 已选）筛出 0 条：字幕已加载，只是
  ///      本档为空 → 给**过滤档专属**文案，别再误报"未加载字幕"（用户报的核心症状：
  ///      收藏 0 句时切到收藏档，明明有字幕却显示未加载）。「全部」档筛出 0 条只可能因
  ///      cues 本身为空（[VideoSubtitleListFilter.all] 全量映射），故落回 [widget.emptyHint]。
  Widget _buildEmpty(ColorScheme cs, {required bool cuesLoaded}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _emptyHintForFilter(cuesLoaded: cuesLoaded),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: _effectiveFontSize,
          ),
        ),
      ),
    );
  }

  String _emptyHintForFilter({required bool cuesLoaded}) {
    if (!cuesLoaded) return widget.emptyHint;
    switch (_filter) {
      case VideoSubtitleListFilter.favorites:
        return t.video_subtitle_filter_favorites_empty;
      case VideoSubtitleListFilter.selected:
        return t.video_subtitle_filter_selected_empty;
      case VideoSubtitleListFilter.all:
        return widget.emptyHint;
    }
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
    // BUG-872：可查词时给本行文本一个稳定 [GlobalKey]（按 builder 下标）并登记所属 cue，供
    // [_hitTestRows] 反查。不可查词（onLookupCue==null）时不登记，行为与历史一致。
    final GlobalKey? textKey = widget.onLookupCue == null
        ? null
        : _rowTextKeys.putIfAbsent(index, GlobalKey.new);
    if (textKey != null) _rowHitCues[index] = cue;
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
                  child: _buildRowText(
                      cue, textColor, selected, selectedForCard, textKey)),
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
    GlobalKey? textKey,
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

        SubtitleListCharHit? hitAt({
          required Offset localPosition,
          required Offset globalPosition,
        }) {
          // BUG-872：grapheme 映射 / 选区盒并集用顶层纯 helper（与 barrier 反查
          // [subtitleListCharHitFromParagraph] 同源），此处仅 caret 兜底沿用 TextPainter。
          final List<int> starts = subtitleGraphemeStartOffsets(cue.text);
          final List<int> ends = subtitleGraphemeEndOffsets(cue.text);
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
                subtitleGraphemeIndexForOffset(offset, starts, ends);
            if (graphemeIndex < 0) return null;
            final int start = starts[graphemeIndex];
            final int end = ends[graphemeIndex];
            Rect localRect = _subtitleUnionBoxes(
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
            // BUG-872：稳定 key 让 [_hitTestRows] 能按 builder 下标取到本行 RenderParagraph
            // 反查字符命中（供查词浮层 dismiss barrier 切换查词）。
            key: textKey,
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
        // TODO-1200：内缩从 4 压到 2，收窄常驻 3 个操作图标的动作列，把行宽还给中间的
        // 字幕文本列（窄面板上文本不再被挤成 3-4 字硬折行）。图标仍常驻可见（不改 BUG-265
        // 的常显语义），只是更紧凑。
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
