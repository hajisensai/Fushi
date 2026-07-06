import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 字幕对轴的「音频波形」入口面板（TODO-1051 阶段B；TODO-1207 改为按钮触发的放大可交互视图）。
///
/// 挂在视频快速设置面板的「字幕调轴」区。TODO-1207 之前是一块**常驻的小波形**（纯
/// [CustomPaint]，只能看不能操作，普通用户嫌它占地方又看不清）。现在收敛成一个
/// **紧凑的可点击入口**（一行标签 + 迷你波形缩略图 + 放大图标）：点击弹出
/// [SubtitleWaveformZoomView]——放大的可交互视图，可横向拖动查看整条时间轴、用底部
/// 调轴控件把字幕 cue 线对齐到波形语音峰值。
///
/// **调轴同源、零第二套状态**：放大视图里的所有调轴都经 [onCommitDelay] 写回上方快速
/// 设置的权威 `_delayMs`，与顶部滑条 / 步进 / 自动对轴完全同一个延迟值。本面板自身不落
/// 任何新持久化字段。
///
/// **cue 线随延迟平移**：要平移的延迟经 [initialDelayMs] 从上方权威传入，面板在
/// [didUpdateWidget] 里同步（[_renderDelayMs]）——上方任意手动调轴 / 自动对轴改延迟后，
/// 缩略图与（若打开的）放大视图初值随之平移。
///
/// **优雅降级**：波形数据来自 [loadWaveform]（页面经 ffmpeg 抽音频能量包络）。移动端拿
/// 不到逐帧行返回空包络；此时入口收起（[SizedBox.shrink]），不崩不空白、不显示按钮。
///
/// 不在 paint 里跑 ffmpeg：[loadWaveform] 在 initState 只调一次，缓存原始逐帧包络；
/// 降采样（[downsampleEnergyEnvelope]，纯函数）随目标宽度算，painter 只读 0..1 桶。
class SubtitleWaveformAlignPanel extends StatefulWidget {
  const SubtitleWaveformAlignPanel({
    required this.initialDelayMs,
    required this.cues,
    required this.durationMs,
    required this.loadWaveform,
    this.onCommitDelay,
    this.positionListenable,
    this.currentPositionMs,
    this.height = 96.0,
    super.key,
  });

  /// 当前字幕延迟（毫秒，正=字幕延后）。由上方快速设置面板的权威 `_delayMs` 传入；
  /// 变化时经 [didUpdateWidget] 同步，缩略图 cue 线整体平移。
  final int initialDelayMs;

  /// 当前字幕 cue 列表（取 start/end 画边界线）。不可变，面板只读，绝不改 cue 本体。
  final List<AudioCue> cues;

  /// 视频总时长（毫秒）。<=0 时波形时间窗退化到探测上界（降级）。
  final int durationMs;

  /// 抽音频能量包络（原始逐帧 dB 序列）。由页面提供（经 extractAudioEnergyEnvelope）；
  /// 返回空列表 = 拿不到波形（移动端降级）。面板在 initState 只调一次。
  final Future<List<double>> Function() loadWaveform;

  /// 把放大视图里调出的延迟写回上方权威 `_delayMs`（-> `onSetDelay` 落盘 + 实时生效）。
  /// null = 放大视图只读（不显示调轴控件），但仍可查看波形。由 [VideoQuickSettingsSheet]
  /// 传 `(ms) => _commitDelay(ms)` 保证与顶部调轴同源、零第二套状态。
  final Future<void> Function(int delayMs)? onCommitDelay;

  /// 可选：播放位置变化的通知源（如 VideoPlayerController），用于重绘播放头。
  final Listenable? positionListenable;

  /// 可选：读当前播放位置（毫秒）。null 时不画播放头。
  final int Function()? currentPositionMs;

  /// 入口按钮高度（逻辑像素）。缩略波形按此高度收进入口行。
  final double height;

  @override
  State<SubtitleWaveformAlignPanel> createState() =>
      _SubtitleWaveformAlignPanelState();
}

class _SubtitleWaveformAlignPanelState
    extends State<SubtitleWaveformAlignPanel> {
  /// 缩略图 / 放大视图初值使用的延迟（毫秒）。跟随 initialDelayMs（上方权威 `_delayMs`），
  /// 经 [didUpdateWidget] 同步。
  late int _renderDelayMs = widget.initialDelayMs;

  /// 原始逐帧音频能量包络（[loadWaveform] 一次性抽出）。null = 加载中；空 = 拿不到（降级）。
  List<double>? _rawEnvelope;

  /// 波形是否已加载完成（含空结果的降级态）。
  bool _loaded = false;

  /// 缩略图每根波形柱的目标像素宽（含间隙），据宽度算降采样桶数。
  static const double _barSlotPx = 3.0;

  /// 缩略波形缩略图目标宽度（逻辑像素）；入口行右侧的预览条。
  static const double _thumbnailWidth = 96.0;

  @override
  void initState() {
    super.initState();
    _loadWaveformOnce();
  }

  @override
  void didUpdateWidget(SubtitleWaveformAlignPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上方面板（手动调轴 / 自动对轴）改延迟后 setState 用新 initialDelayMs 重建本面板；
    // 同步 [_renderDelayMs] 让缩略图 cue 线立即随之整体平移。
    if (oldWidget.initialDelayMs != widget.initialDelayMs &&
        _renderDelayMs != widget.initialDelayMs) {
      setState(() => _renderDelayMs = widget.initialDelayMs);
    }
  }

  Future<void> _loadWaveformOnce() async {
    try {
      final List<double> raw = await widget.loadWaveform();
      if (!mounted) return;
      setState(() {
        _rawEnvelope = raw;
        _loaded = true;
      });
    } catch (_) {
      // 抽取失败一律降级（收起入口），不崩不空白。
      if (!mounted) return;
      setState(() {
        _rawEnvelope = const <double>[];
        _loaded = true;
      });
    }
  }

  /// cue 边界（start/end 混合，未加延迟）。painter 内部叠加延迟。
  List<int> get _cueBoundariesMs {
    final List<int> out = <int>[];
    for (final AudioCue cue in widget.cues) {
      out.add(cue.startMs);
      out.add(cue.endMs);
    }
    return out;
  }

  /// 波形时间窗上界（毫秒）：与 extractAudioEnergyEnvelope 的探测上界同源
  /// （前 N 分钟截断），取 min(durationMs, probeLimit)；durationMs 未知时用探测上界。
  int get _windowEndMs {
    const int limit = kSubtitleAutoAlignProbeLimitMs;
    if (widget.durationMs <= 0) return limit;
    return widget.durationMs < limit ? widget.durationMs : limit;
  }

  Future<void> _openZoomView() async {
    final List<double>? env = _rawEnvelope;
    if (env == null || env.isEmpty) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext _) => SubtitleWaveformZoomView(
        rawEnvelope: env,
        cueBoundariesMs: _cueBoundariesMs,
        windowEndMs: _windowEndMs,
        initialDelayMs: widget.initialDelayMs,
        onCommitDelay: widget.onCommitDelay,
        positionListenable: widget.positionListenable,
        currentPositionMs: widget.currentPositionMs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    // 有波形数据才显示入口；加载中出 spinner，空包络（移动端降级）收起。
    final bool hasWaveform = _loaded && (_rawEnvelope?.isNotEmpty ?? false);

    if (!_loaded) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.primary,
            ),
          ),
        ),
      );
    }
    if (!hasWaveform) return const SizedBox.shrink();
    return _buildEntryButton(theme, cs);
  }

  /// 紧凑入口：一行「标签 + 提示 + 迷你波形缩略图 + 放大图标」，整行可点开放大视图。
  Widget _buildEntryButton(ThemeData theme, ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return Material(
      key: const ValueKey<String>('subtitle-waveform-open-button'),
      color: tokens.surfaces.overlay.withValues(alpha: 0.5),
      borderRadius: tokens.radii.cardRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openZoomView,
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: Row(
            children: <Widget>[
              Icon(Icons.graphic_eq, color: cs.primary, size: 22),
              SizedBox(width: gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.video_subtitle_waveform_open,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      t.video_subtitle_waveform_open_hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap),
              _buildThumbnail(cs),
              SizedBox(width: gap / 2),
              Icon(Icons.zoom_in, color: cs.onSurfaceVariant, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  /// 迷你波形缩略图（入口右侧预览，只读、无播放头，随延迟平移 cue 线）。
  Widget _buildThumbnail(ColorScheme cs) {
    const double h = 36.0;
    final int buckets = (_thumbnailWidth / _barSlotPx).floor().clamp(1, 100000);
    final List<double> down = downsampleEnergyEnvelope(
      _rawEnvelope ?? const <double>[],
      buckets,
    );
    return SizedBox(
      width: _thumbnailWidth,
      height: h,
      child: CustomPaint(
        size: const Size(_thumbnailWidth, h),
        painter: SubtitleWaveformPainter(
          buckets: down,
          windowStartMs: 0,
          windowEndMs: _windowEndMs,
          cueBoundariesMs: _cueBoundariesMs,
          previewDelayMs: _renderDelayMs,
          currentPositionMs: -1,
          waveColor: cs.primary.withValues(alpha: 0.55),
          cueLineColor: cs.secondary,
          playheadColor: cs.tertiary,
          centerLineColor: cs.outlineVariant,
          verticalPadding: 2.0,
        ),
      ),
    );
  }
}

/// 放大的可交互波形对轴视图（TODO-1207）。经 [SubtitleWaveformAlignPanel] 的入口按钮
/// 弹出（showDialog）。
///
/// **交互模型（平移查看 vs 调轴，物理分离、永不冲突）**：
/// - **横向拖动波形 = 平移查看**：波形按固定像素密度铺开在一条可横向滚动的时间轴上，
///   拖动 / 滚轮平移查看不同时间段（默认只抽了前 N 分钟）。可用缩放按钮改密度看细节。
/// - **调轴 = 底部专用控件条**：滑条（细调）/ 步进 / 归零 / 数值输入，改动经 [onCommitDelay]
///   写回上方权威 `_delayMs`（同源、零第二套状态）。波形上的 cue 线随之**实时平移**——
///   用户滚到有语音的段落，拖底部滑条让 cue 线对齐波形峰值即完成对轴。
///
/// 两类操作作用在不同 widget（波形区 = 滚动手势；控件条 = 独立控件），故横向拖查看永不
/// 误触调轴，反之亦然。
///
/// **图例**：顶部一行标出「响度包络 / 字幕边界 / 播放头」三层颜色，解决「看不懂」。
class SubtitleWaveformZoomView extends StatefulWidget {
  const SubtitleWaveformZoomView({
    required this.rawEnvelope,
    required this.cueBoundariesMs,
    required this.windowEndMs,
    required this.initialDelayMs,
    this.onCommitDelay,
    this.positionListenable,
    this.currentPositionMs,
    super.key,
  });

  /// 原始逐帧音频能量包络（未降采样）。按放大后的时间轴宽度降采样成波形桶。
  final List<double> rawEnvelope;

  /// 字幕 cue 的时间边界（毫秒，未加延迟）。painter 内部叠加当前延迟。
  final List<int> cueBoundariesMs;

  /// 波形时间窗上界（毫秒）：与抽取探测上界同源。
  final int windowEndMs;

  /// 打开时的当前延迟（毫秒），本地权威初值。
  final int initialDelayMs;

  /// 调轴写回上方权威 `_delayMs`。null = 只读（不显示调轴控件）。
  final Future<void> Function(int delayMs)? onCommitDelay;

  /// 可选：播放位置变化通知源，驱动播放头重绘。
  final Listenable? positionListenable;

  /// 可选：读当前播放位置（毫秒），画播放头。
  final int Function()? currentPositionMs;

  @override
  State<SubtitleWaveformZoomView> createState() =>
      _SubtitleWaveformZoomViewState();
}

class _SubtitleWaveformZoomViewState extends State<SubtitleWaveformZoomView> {
  /// 本地权威延迟（毫秒，乐观更新）。改动经 [_commit] 写回上方 `_delayMs`。
  late int _delayMs = widget.initialDelayMs;

  /// 拖动滑条时的临时预览值（松手才 [_commit] 落盘）。null = 未拖动。
  int? _dragMs;

  /// 时间轴缩放（每毫秒像素 = _basePxPerMs * _zoom）。放大看细节、缩小看全局。
  double _zoom = 1.0;

  /// 数值输入框控制器（与滑条 / 步进共享同一权威 [_delayMs]，经 [_commit] 同步）。
  late final TextEditingController _delayController =
      TextEditingController(text: '${widget.initialDelayMs}');

  final ScrollController _scrollController = ScrollController();

  /// 每根波形柱的目标像素宽（含间隙）。
  static const double _barSlotPx = 3.0;

  /// 基础时间密度：每毫秒 0.12 逻辑像素（=120px/秒）@ zoom 1。
  static const double _basePxPerMs = 0.12;
  static const double _minZoom = 0.25;
  static const double _maxZoom = 8.0;

  /// 放大波形区高度（逻辑像素）。
  static const double _waveHeight = 200.0;

  /// 调轴细调滑条范围（正负 10 秒）与 clamp 上界（正负 600 秒），与
  /// [VideoQuickSettingsSheet] / VideoPlayerController 一致。
  static const int _sliderRangeMs = 10000;
  static const int _clampMs = 600000;

  @override
  void dispose() {
    _delayController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 调轴权威提交：clamp -> 本地 setState -> 可选回写输入框 -> 回调写回上方 `_delayMs`。
  Future<void> _commit(int next, {bool syncField = true}) async {
    final int clamped = next.clamp(-_clampMs, _clampMs);
    if (mounted) setState(() => _delayMs = clamped);
    if (syncField && _delayController.text != '$clamped') {
      _delayController.text = '$clamped';
    }
    await widget.onCommitDelay?.call(clamped);
  }

  void _zoomBy(double factor) {
    setState(() {
      _zoom = (_zoom * factor).clamp(_minZoom, _maxZoom);
    });
  }

  /// 把滚动位置移到播放头附近（居中显示）。播放头未知时 no-op。交互回调里读，
  /// 内容宽 / 视口宽从 ScrollPosition 取真值（不在 build 里碰 context.size）。
  void _jumpToPlayhead() {
    final int Function()? read = widget.currentPositionMs;
    if (read == null || !_scrollController.hasClients) return;
    final int posMs = read();
    if (posMs < 0) return;
    final ScrollPosition pos = _scrollController.position;
    final double viewWidth = pos.viewportDimension;
    final double contentWidth = viewWidth + pos.maxScrollExtent;
    final double x = timeToX(
      timeMs: posMs,
      windowStartMs: 0,
      windowEndMs: widget.windowEndMs,
      width: contentWidth,
    );
    if (x.isNaN) return;
    final double target = (x - viewWidth / 2).clamp(0.0, pos.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;

    return HibikiDialogFrame(
      maxWidth: 720,
      padding: EdgeInsets.all(tokens.spacing.page),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(theme, cs),
          SizedBox(height: gap),
          _buildLegend(theme, cs),
          SizedBox(height: gap / 2),
          Text(
            t.video_subtitle_waveform_scroll_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          SizedBox(height: gap),
          _buildScrollableWaveform(cs),
          SizedBox(height: gap / 2),
          _buildViewControls(cs),
          if (widget.onCommitDelay != null) ...<Widget>[
            Divider(height: gap * 2, color: cs.outlineVariant),
            _buildDelayControls(theme, cs, tokens),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme cs) {
    final String label = '${_delayMs >= 0 ? '+' : ''}$_delayMs ms';
    return Row(
      children: <Widget>[
        Icon(Icons.graphic_eq, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t.video_subtitle_waveform_open,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: _delayMs == 0 ? cs.onSurfaceVariant : cs.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  /// 图例：三层颜色对应「响度包络 / 字幕边界 / 播放头」。
  Widget _buildLegend(ThemeData theme, ColorScheme cs) {
    Widget item(Color color, String text, {bool line = false}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: line ? 3 : 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(line ? 1 : 2),
            ),
          ),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      );
    }

    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: <Widget>[
        item(cs.primary.withValues(alpha: 0.55),
            t.video_subtitle_waveform_legend_energy),
        item(cs.secondary, t.video_subtitle_waveform_legend_cue, line: true),
        item(cs.tertiary, t.video_subtitle_waveform_legend_playhead,
            line: true),
      ],
    );
  }

  /// 可横向滚动的放大波形（横向拖动 = 平移查看时间轴；不改延迟）。
  Widget _buildScrollableWaveform(ColorScheme cs) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double viewWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
        final double naturalWidth = widget.windowEndMs * _basePxPerMs * _zoom;
        // 内容至少铺满视图宽（短片不留大片空白），否则按时间密度展开可滚动。
        final double contentWidth =
            naturalWidth < viewWidth ? viewWidth : naturalWidth;
        final int targetBuckets =
            (contentWidth / _barSlotPx).floor().clamp(1, 400000);
        final List<double> buckets =
            downsampleEnergyEnvelope(widget.rawEnvelope, targetBuckets);

        SubtitleWaveformPainter buildPainter(int positionMs) {
          return SubtitleWaveformPainter(
            buckets: buckets,
            windowStartMs: 0,
            windowEndMs: widget.windowEndMs,
            cueBoundariesMs: widget.cueBoundariesMs,
            previewDelayMs: _dragMs ?? _delayMs,
            currentPositionMs: positionMs,
            waveColor: cs.primary.withValues(alpha: 0.55),
            cueLineColor: cs.secondary,
            playheadColor: cs.tertiary,
            centerLineColor: cs.outlineVariant,
          );
        }

        final Widget painted = (widget.positionListenable != null &&
                widget.currentPositionMs != null)
            ? AnimatedBuilder(
                animation: widget.positionListenable!,
                builder: (BuildContext _, __) => CustomPaint(
                  size: Size(contentWidth, _waveHeight),
                  painter: buildPainter(widget.currentPositionMs!.call()),
                ),
              )
            : CustomPaint(
                size: Size(contentWidth, _waveHeight),
                painter: buildPainter(widget.currentPositionMs?.call() ?? -1),
              );

        return Container(
          height: _waveHeight,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: _waveHeight,
                child: painted,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 视图控件行（缩放 + 跳到播放头）：只改查看，不改延迟。
  Widget _buildViewControls(ColorScheme cs) {
    final bool canJump =
        widget.currentPositionMs != null && (widget.currentPositionMs!() >= 0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        if (canJump)
          TextButton.icon(
            onPressed: _jumpToPlayhead,
            icon: const Icon(Icons.my_location, size: 18),
            label: Text(t.video_subtitle_waveform_jump_playhead),
          ),
        IconButton(
          icon: const Icon(Icons.zoom_out),
          tooltip: t.video_subtitle_waveform_zoom_out,
          onPressed: _zoom <= _minZoom ? null : () => _zoomBy(1 / 1.5),
        ),
        IconButton(
          icon: const Icon(Icons.zoom_in),
          tooltip: t.video_subtitle_waveform_zoom_in,
          onPressed: _zoom >= _maxZoom ? null : () => _zoomBy(1.5),
        ),
      ],
    );
  }

  /// 底部调轴控件条（滑条 / 步进 / 归零 / 数值输入）：写回上方权威 `_delayMs`。
  Widget _buildDelayControls(
      ThemeData theme, ColorScheme cs, HibikiDesignTokens tokens) {
    final int shownMs = _dragMs ?? _delayMs;
    final String label = '${shownMs >= 0 ? '+' : ''}$shownMs ms';
    final double sliderValue =
        shownMs.clamp(-_sliderRangeMs, _sliderRangeMs).toDouble();
    final double gap = tokens.spacing.gap;

    final Widget buttons = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: gap / 2,
      runSpacing: gap / 2,
      children: <Widget>[
        HibikiIconButton(
          icon: Icons.keyboard_double_arrow_left,
          tooltip: '-1000ms',
          padding: EdgeInsets.all(gap / 2),
          onTap: () => _commit(_delayMs - 1000),
        ),
        HibikiIconButton(
          icon: Icons.chevron_left,
          tooltip: '-50ms',
          padding: EdgeInsets.all(gap / 2),
          onTap: () => _commit(_delayMs - 50),
        ),
        HibikiFocusable(
          onTap: shownMs == 0 ? null : () => _commit(0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 84, maxWidth: 140),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: shownMs == 0 ? cs.onSurfaceVariant : cs.primary,
              ),
            ),
          ),
        ),
        HibikiIconButton(
          icon: Icons.chevron_right,
          tooltip: '+50ms',
          padding: EdgeInsets.all(gap / 2),
          onTap: () => _commit(_delayMs + 50),
        ),
        HibikiIconButton(
          icon: Icons.keyboard_double_arrow_right,
          tooltip: '+1000ms',
          padding: EdgeInsets.all(gap / 2),
          onTap: () => _commit(_delayMs + 1000),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 细调滑条（正负 10s）：拖动只本地预览，松手才落盘+实时生效。走 adaptiveSlider
        // 修全局 UI-scale 下裸 Slider 值指示器水平钳制错位（TODO-742 同款）。
        adaptiveSlider(
          context: context,
          value: sliderValue,
          min: -_sliderRangeMs.toDouble(),
          max: _sliderRangeMs.toDouble(),
          divisions: _sliderRangeMs ~/ 50,
          label: label,
          onChanged: (double v) => setState(() => _dragMs = v.round()),
          onChangeEnd: (double v) {
            setState(() => _dragMs = null);
            _commit(v.round());
          },
        ),
        SizedBox(height: gap / 2),
        buttons,
        SizedBox(height: gap / 2),
        AdaptiveSettingsTextField(
          controller: _delayController,
          labelText: t.video_setting_subtitle_sync_input,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          textInputAction: TextInputAction.done,
          onSubmitted: (String raw) {
            final int? parsed = int.tryParse(raw.trim());
            if (parsed == null) {
              _delayController.text = '$_delayMs';
              return;
            }
            _commit(parsed);
          },
        ),
      ],
    );
  }
}
