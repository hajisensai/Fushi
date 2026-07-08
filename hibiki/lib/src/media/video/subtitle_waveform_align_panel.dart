import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 字幕对轴的「音频波形」入口面板（TODO-1051 阶段B；TODO-1207 改为按钮触发的放大可交互视图）。
///
/// 挂在视频快速设置面板的「字幕调轴」区。TODO-1207 之前是一块**常驻的小波形**（纯
/// [CustomPaint]，只能看不能操作，普通用户嫌它占地方又看不清）。现在收敛成一个
/// **紧凑的可点击入口**（一行图标 + 标签 + 提示 + 放大图标）：点击弹出
/// [SubtitleWaveformZoomView]——放大的可交互视图，可横向拖动查看整条时间轴、用底部
/// 调轴控件把字幕 cue 线对齐到波形语音峰值。
///
/// **入口常驻可见（TODO-1315，勿再回退）**：入口按钮挂载即显、绝不因波形探测结果收起。
/// 它只是一个「点击进入波形对轴」的按钮，不承载任何波形数据，故不依赖探测成功与否——只
/// 要上层 [VideoQuickSettingsSheet] 判定有字幕 cue + 可抽波形（本地视频路径）就挂上本面板，
/// 入口就一直在、一直可点。历史上（TODO-1315 之前）本面板在挂载时预探测、探测返回空包络
/// 即 [SizedBox.shrink] **把整个入口收起**，弱设备 / 移动端因此「入口没了、进不去」（用户
/// 报「字幕调轴入口也没了」）；该「探测为空即隐藏入口」行为已废弃，**勿再引入**。
///
/// **懒探测（TODO-1315）**：波形数据来自 [loadWaveform]（页面经 ffmpeg 抽逐帧音频能量，对
/// 长视频要数十秒）。**只在用户点击入口时**才调 [loadWaveform]，不在挂载时预跑——进字幕
/// 设置分类不再被 ffmpeg 抽轨拖卡。放大视图关闭后本地不保留包络引用即释放（页面级
/// `WaveformEnvelopeCache` 仍留一份供秒开）。点击时探测返回空包络（移动端拿不到逐帧行 /
/// ffmpeg 不可用）就不弹窗、改在入口副标题内联提示「本设备无法生成波形」，入口仍在、可重试。
///
/// **调轴同源、零第二套状态**：放大视图里的所有调轴都经 [onCommitDelay] 写回上方快速
/// 设置的权威 `_delayMs`，与顶部滑条 / 步进 / 自动对轴完全同一个延迟值。本面板自身不落
/// 任何新持久化字段。
///
/// **cue 线随延迟平移**：要平移的延迟经 [initialDelayMs] 从上方权威传入，放大视图打开时
/// 以它为初值——上方任意手动调轴 / 自动对轴改延迟后，（若打开的）放大视图 cue 线随之平移。
///
/// 不在 paint 里跑 ffmpeg：[loadWaveform] 只在点击时调一次（页面侧带缓存），降采样
/// （[downsampleEnergyEnvelope]，纯函数）随目标宽度算，painter 只读 0..1 桶。
class SubtitleWaveformAlignPanel extends StatefulWidget {
  const SubtitleWaveformAlignPanel({
    required this.initialDelayMs,
    required this.cues,
    required this.durationMs,
    required this.loadWaveform,
    this.onCommitDelay,
    this.onAutoAlign,
    this.onPlayCue,
    this.positionListenable,
    this.currentPositionMs,
    super.key,
  });

  /// 当前字幕延迟（毫秒，正=字幕延后）。由上方快速设置面板的权威 `_delayMs` 传入；
  /// 作为（点击后打开的）放大对轴视图 cue 线的初值，随权威延迟一起整体平移。
  final int initialDelayMs;

  /// 当前字幕 cue 列表（取 start/end 画边界线）。不可变，面板只读，绝不改 cue 本体。
  final List<AudioCue> cues;

  /// 视频总时长（毫秒）。<=0 时波形时间窗退化到探测上界（降级）。
  final int durationMs;

  /// 抽音频能量包络（原始逐帧 dB 序列）。由页面提供（经 extractAudioEnergyEnvelope）；
  /// 返回空列表 = 拿不到波形（移动端降级，入口内联提示不可用、不隐藏）。TODO-1315 起
  /// **只在用户点击入口时**才调一次（懒探测），不在挂载时预跑。
  final Future<List<double>> Function() loadWaveform;

  /// 把放大视图里调出的延迟写回上方权威 `_delayMs`（-> `onSetDelay` 落盘 + 实时生效）。
  /// null = 放大视图只读（不显示调轴控件），但仍可查看波形。由 [VideoQuickSettingsSheet]
  /// 传 `(ms) => _commitDelay(ms)` 保证与顶部调轴同源、零第二套状态。
  final Future<void> Function(int delayMs)? onCommitDelay;

  /// TODO-1316：一键自动对轴回调（= 页面 `_autoAlignSubtitle`：抽音频能量与字幕 cue 互
  /// 相关求整体平移并写穿延迟，返回本次实际平移 offset；低置信 / 无数据返回 null）。传入
  /// 时放大对轴视图显示「自动对轴」按钮，与顶部快速设置的自动对轴按钮同一逻辑、零第二套
  /// 状态。null = 不显示该按钮（无字幕 / 无视频路径）。
  final Future<int?> Function()? onAutoAlign;

  /// TODO-1244：逐句试听回调。放大对轴视图的每句字幕旁挂一个播放按钮，点击把播放器
  /// seek 到该句（叠加当前预览延迟后的）时间并播放，方便用户核对「这段波形是哪句话」。
  /// null = 不显示逐句播放按钮（无播放器 / 只读）。由页面传 `(ms) => seek+play`，复用现有
  /// 播放器，不新建音频栈。
  final Future<void> Function(int startMs)? onPlayCue;

  /// 可选：播放位置变化的通知源（如 VideoPlayerController），用于重绘播放头。
  final Listenable? positionListenable;

  /// 可选：读当前播放位置（毫秒）。null 时不画播放头。
  final int Function()? currentPositionMs;

  @override
  State<SubtitleWaveformAlignPanel> createState() =>
      _SubtitleWaveformAlignPanelState();
}

class _SubtitleWaveformAlignPanelState
    extends State<SubtitleWaveformAlignPanel> {
  /// TODO-1315 懒加载：波形探测（ffmpeg 抽逐帧能量包络，对 2h REMUX 要数十秒）只在用户
  /// **点开放大对轴视图**时触发，不在面板挂载（进字幕设置分类）时预跑——弱设备开设置
  /// 不再被 ffmpeg 抽轨拖卡。true = 点开后正 await [SubtitleWaveformAlignPanel.loadWaveform]，
  /// 入口显示 spinner 并防重入。
  bool _probing = false;

  /// 上次点开探测返回空包络（移动端拿不到逐帧行 / ffmpeg 不可用 / 超时的降级态）。true 时
  /// 入口副标题改显「本设备无法生成波形」，不弹放大视图（不崩不空白）；再次点击重试时清零。
  bool _probeUnavailable = false;

  /// 波形时间窗上界（毫秒）：与 extractAudioEnergyEnvelope 的探测上界同源
  /// （前 N 分钟截断），取 min(durationMs, probeLimit)；durationMs 未知时用探测上界。
  int get _windowEndMs {
    const int limit = kSubtitleAutoAlignProbeLimitMs;
    if (widget.durationMs <= 0) return limit;
    return widget.durationMs < limit ? widget.durationMs : limit;
  }

  /// TODO-1315 懒加载入口：点击才抽波形（[SubtitleWaveformAlignPanel.loadWaveform]，页面侧
  /// 带缓存，二次点开命中缓存秒开），非空才弹放大视图；空包络（降级）改显不可用提示、不弹
  /// 窗。放大视图关闭后本地不保留包络引用（`env` 仅在本作用域存活），退出即释放——弱设备
  /// 内存/绘制零常驻。
  Future<void> _openZoomView() async {
    if (_probing) return;
    setState(() {
      _probing = true;
      _probeUnavailable = false;
    });
    List<double> env;
    try {
      env = await widget.loadWaveform();
    } catch (_) {
      // 抽取失败一律降级：不弹窗、显示不可用提示（不崩不空白）。
      env = const <double>[];
    }
    if (!mounted) return;
    setState(() => _probing = false);
    if (env.isEmpty) {
      setState(() => _probeUnavailable = true);
      return;
    }
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext _) => SubtitleWaveformZoomView(
        rawEnvelope: env,
        cues: widget.cues,
        windowEndMs: _windowEndMs,
        initialDelayMs: widget.initialDelayMs,
        onCommitDelay: widget.onCommitDelay,
        onAutoAlign: widget.onAutoAlign,
        onPlayCue: widget.onPlayCue,
        positionListenable: widget.positionListenable,
        currentPositionMs: widget.currentPositionMs,
      ),
    );
    // 退出释放：env 随本作用域结束回收，面板不常驻波形（页面级缓存仍留一份供秒开）。
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    // TODO-1315：入口常驻可见（挂载即显、不预探测波形），点击才懒抽 + 弹放大视图。
    return _buildEntryButton(theme, cs);
  }

  /// 紧凑入口：一行「图标 + 标签 + 提示 + 放大/加载图标」，整行可点。TODO-1315 起入口
  /// **常驻可见**（挂载即显、不预探测），点击才懒抽波形并弹放大视图；探测中显示 spinner，
  /// 空包络（降级）副标题改显不可用提示。
  Widget _buildEntryButton(ThemeData theme, ColorScheme cs) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    final String hint = _probeUnavailable
        ? t.video_subtitle_waveform_unavailable
        : t.video_subtitle_waveform_open_hint;
    return Material(
      key: const ValueKey<String>('subtitle-waveform-open-button'),
      color: tokens.surfaces.overlay.withValues(alpha: 0.5),
      borderRadius: tokens.radii.cardRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _probing ? null : _openZoomView,
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
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            _probeUnavailable ? cs.error : cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap),
              _probing
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primary,
                      ),
                    )
                  : Icon(Icons.zoom_in, color: cs.onSurfaceVariant, size: 22),
            ],
          ),
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
    required this.cues,
    required this.windowEndMs,
    required this.initialDelayMs,
    this.onCommitDelay,
    this.onAutoAlign,
    this.onPlayCue,
    this.positionListenable,
    this.currentPositionMs,
    super.key,
  });

  /// 原始逐帧音频能量包络（未降采样）。按放大后的时间轴宽度降采样成波形桶。
  final List<double> rawEnvelope;

  /// 字幕 cue 列表（TODO-1244）。取 start/end 画边界竖线（painter 内部叠加当前延迟），
  /// 并在波形下方的文本条里按各句时间位置显示句文本 + 逐句播放按钮。只读，绝不改 cue 本体。
  final List<AudioCue> cues;

  /// 波形时间窗上界（毫秒）：与抽取探测上界同源。
  final int windowEndMs;

  /// 打开时的当前延迟（毫秒），本地权威初值。
  final int initialDelayMs;

  /// 调轴写回上方权威 `_delayMs`。null = 只读（不显示调轴控件）。
  final Future<void> Function(int delayMs)? onCommitDelay;

  /// TODO-1316：一键自动对轴回调（同 [SubtitleWaveformAlignPanel.onAutoAlign]）。传入时
  /// 放大对轴视图显示「自动对轴」按钮，点击调此回调求整体平移并经 [onCommitDelay] 同步；
  /// null = 不显示按钮。
  final Future<int?> Function()? onAutoAlign;

  /// TODO-1244：逐句试听回调。文本条每句的播放按钮点击时把播放器 seek 到该句（叠加当前
  /// 预览延迟后的）时间并播放。null = 不显示播放按钮。
  final Future<void> Function(int startMs)? onPlayCue;

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

  /// TODO-1316：波形对轴视图内自动对轴进行中；true 时按钮切 spinner 并禁用（防重入）。
  bool _autoAligning = false;

  /// TODO-1316：上次自动对轴置信度低 / 无数据（[SubtitleWaveformZoomView.onAutoAlign] 返回
  /// null），未改延迟。true 时按钮下方显示「未能可信对轴」提示（放大视图内自带反馈，不依赖
  /// 被弹窗遮蔽的页面 OSD）；任一 [_commit]（手动或成功自动对轴）前清零。
  bool _autoAlignLowConfidence = false;

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

  /// TODO-1244：波形下方 cue 文本条高度（逻辑像素）。
  static const double _stripHeight = 56.0;

  /// 文本条里每个 cue 片段的最小宽度（逻辑像素）：短句在时间轴上占位很窄，给个下限
  /// 保证文字/播放按钮可点、可读。
  static const double _minChipWidth = 48.0;

  /// 视口外裁剪余量（逻辑像素）：只为落在「可见范围 ± 该余量」内的 cue 建文本片段，
  /// 把上墙 widget 数从「窗内全部 cue」压到「可见的几十个」——密集字幕滚动/拖延迟不卡。
  static const double _cullMarginPx = 400.0;

  /// 降采样波形桶缓存：桶数只随缩放/视口宽变化，不随滚动/延迟变化。按目标桶数 memo，
  /// 避免每次滚动 setState 都对整条包络重算降采样（[downsampleEnergyEnvelope] 是 O(n)）。
  int _cachedBucketCount = -1;
  List<double> _cachedBuckets = const <double>[];

  @override
  void initState() {
    super.initState();
    // 横向滚动时重建：文本条按新视口裁剪出可见 cue 片段（[_cullMarginPx] 余量）。
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  /// cue 边界（start/end 混合，未加延迟）。painter 内部叠加延迟画竖线。
  List<int> get _cueBoundariesMs {
    final List<int> out = <int>[];
    for (final AudioCue cue in widget.cues) {
      out.add(cue.startMs);
      out.add(cue.endMs);
    }
    return out;
  }

  /// 按目标桶数 memo 的降采样波形桶（见 [_cachedBucketCount]）。
  List<double> _bucketsFor(int targetBuckets) {
    if (targetBuckets == _cachedBucketCount) return _cachedBuckets;
    _cachedBucketCount = targetBuckets;
    _cachedBuckets =
        downsampleEnergyEnvelope(widget.rawEnvelope, targetBuckets);
    return _cachedBuckets;
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _delayController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 调轴权威提交：clamp -> 本地 setState -> 可选回写输入框 -> 回调写回上方 `_delayMs`。
  Future<void> _commit(int next, {bool syncField = true}) async {
    final int clamped = next.clamp(-_clampMs, _clampMs);
    if (mounted) {
      setState(() {
        _delayMs = clamped;
        _autoAlignLowConfidence = false;
      });
    }
    if (syncField && _delayController.text != '$clamped') {
      _delayController.text = '$clamped';
    }
    await widget.onCommitDelay?.call(clamped);
  }

  /// TODO-1316：波形对轴视图内的一键自动对轴。调上方权威的
  /// [SubtitleWaveformZoomView.onAutoAlign]（= 页面 `_autoAlignSubtitle`：抽音频能量与字幕 cue
  /// 互相关求整体平移并写穿延迟，返回本次实际 offset；低置信 / 无数据返回 null）。拿到非 null
  /// offset 就 [_commit] 同步本地 [_delayMs] + 输入框 + 波形 cue 线（与手动调轴 / 顶部自动对轴
  /// 同源、零第二套状态）；返回 null 时置 [_autoAlignLowConfidence] 在按钮下方给不可信提示。
  /// 执行期 [_autoAligning] 切 spinner 防重入。
  Future<void> _runAutoAlign() async {
    final Future<int?> Function()? cb = widget.onAutoAlign;
    if (cb == null || _autoAligning) return;
    setState(() {
      _autoAligning = true;
      _autoAlignLowConfidence = false;
    });
    try {
      final int? alignedOffsetMs = await cb();
      if (!mounted) return;
      if (alignedOffsetMs != null) {
        await _commit(alignedOffsetMs);
      } else {
        setState(() => _autoAlignLowConfidence = true);
      }
    } finally {
      if (mounted) setState(() => _autoAligning = false);
    }
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

  /// 可横向滚动的放大波形 + 下方 cue 文本条（横向拖动 = 平移查看时间轴；不改延迟）。
  ///
  /// TODO-1244：波形下方挂一条与波形同一个横向滚动的 cue 文本条——每句字幕按其时间位置
  /// 铺在时间轴上显示句文本 + 逐句播放按钮，点句试听核对「这段波形是哪句话」。文本条与
  /// 波形放在同一 [SingleChildScrollView] 里，一次横向滚动带动两者对齐。
  Widget _buildScrollableWaveform(ColorScheme cs) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final ThemeData theme = Theme.of(context);
        final double viewWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
        final double naturalWidth = widget.windowEndMs * _basePxPerMs * _zoom;
        // 内容至少铺满视图宽（短片不留大片空白），否则按时间密度展开可滚动。
        final double contentWidth =
            naturalWidth < viewWidth ? viewWidth : naturalWidth;
        final int targetBuckets =
            (contentWidth / _barSlotPx).floor().clamp(1, 400000);
        final List<double> buckets = _bucketsFor(targetBuckets);
        final List<int> boundaries = _cueBoundariesMs;

        SubtitleWaveformPainter buildPainter(int positionMs) {
          return SubtitleWaveformPainter(
            buckets: buckets,
            windowStartMs: 0,
            windowEndMs: widget.windowEndMs,
            cueBoundariesMs: boundaries,
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

        final Widget strip = _buildCueStrip(
          theme: theme,
          cs: cs,
          delayMs: _dragMs ?? _delayMs,
          contentWidth: contentWidth,
          viewportWidth: viewWidth,
        );

        return Container(
          height: _waveHeight + _stripHeight,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: contentWidth,
                      height: _waveHeight,
                      child: painted,
                    ),
                    strip,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// TODO-1244：波形下方的 cue 文本条。每句按时间位置（[AudioCue.startMs]/[endMs] 叠加
  /// [delayMs]）铺在时间轴上，宽度 = 该句时长像素（下限 [_minChipWidth]）。视口外裁剪
  /// （[_cullMarginPx] 余量）把上墙片段压到可见的几十个，密集字幕滚动/拖延迟不卡。
  Widget _buildCueStrip({
    required ThemeData theme,
    required ColorScheme cs,
    required int delayMs,
    required double contentWidth,
    required double viewportWidth,
  }) {
    final double viewLeft =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    final double viewRight = viewLeft + viewportWidth;
    final List<Widget> chips = <Widget>[];
    for (final AudioCue cue in widget.cues) {
      final String text = cue.text.trim();
      if (text.isEmpty) continue;
      final double startX = timeToX(
        timeMs: cue.startMs + delayMs,
        windowStartMs: 0,
        windowEndMs: widget.windowEndMs,
        width: contentWidth,
      );
      final double endX = timeToX(
        timeMs: cue.endMs + delayMs,
        windowStartMs: 0,
        windowEndMs: widget.windowEndMs,
        width: contentWidth,
      );
      if (startX.isNaN || endX.isNaN) continue;
      final double left = startX < 0 ? 0.0 : startX;
      if (left >= contentWidth) continue;
      final double avail = contentWidth - left;
      if (avail < 8) continue;
      double width = endX - startX;
      if (width < _minChipWidth) width = _minChipWidth;
      if (width > avail) width = avail;
      final double right = left + width;
      // 视口裁剪：只为可见范围 ± 余量内的 cue 建片段（密集字幕不上墙全部）。
      if (right < viewLeft - _cullMarginPx ||
          left > viewRight + _cullMarginPx) {
        continue;
      }
      chips.add(Positioned(
        left: left,
        top: 0,
        bottom: 0,
        width: width,
        child: _buildCueChip(theme, cs, cue, text, delayMs),
      ));
    }
    return SizedBox(
      width: contentWidth,
      height: _stripHeight,
      child: Stack(clipBehavior: Clip.hardEdge, children: chips),
    );
  }

  /// 单个 cue 文本片段：显示句文本 + 逐句播放按钮。整片可点 →
  /// [SubtitleWaveformZoomView.onPlayCue] 把播放器 seek 到该句（叠加当前预览延迟后的）
  /// 时间并播放，方便核对波形段=哪句话。
  Widget _buildCueChip(
    ThemeData theme,
    ColorScheme cs,
    AudioCue cue,
    String text,
    int delayMs,
  ) {
    final bool canPlay = widget.onPlayCue != null;
    final int rawSeekMs = cue.startMs + delayMs;
    final int seekMs = rawSeekMs < 0 ? 0 : rawSeekMs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.0, vertical: 3.0),
      child: Material(
        color: cs.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: canPlay ? () => widget.onPlayCue!.call(seekMs) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (canPlay)
                  Padding(
                    padding: const EdgeInsets.only(right: 2.0, top: 1.0),
                    child: Icon(
                      Icons.play_circle_outline,
                      size: 16,
                      color: cs.primary,
                    ),
                  ),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSecondaryContainer,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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

  /// 底部调轴控件条（自动对轴 / 滑条 / 步进 / 归零 / 数值输入）：写回上方权威 `_delayMs`。
  Widget _buildDelayControls(
      ThemeData theme, ColorScheme cs, HibikiDesignTokens tokens) {
    final int shownMs = _dragMs ?? _delayMs;
    final String label = '${shownMs >= 0 ? '+' : ''}$shownMs ms';
    final double sliderValue =
        shownMs.clamp(-_sliderRangeMs, _sliderRangeMs).toDouble();
    final double gap = tokens.spacing.gap;

    // TODO-1316：波形对轴视图内的「自动对轴」按钮（复用上方权威 onAutoAlign 逻辑，不重写
    // 算法）。成功后 cue 线随 [_commit] 平移、顶部标签更新即在弹窗内可见反馈；低置信在按钮
    // 下方给文字提示。null = 无自动对轴回调（无字幕 / 无视频路径）时不显示。
    final Widget? autoAlignButton = widget.onAutoAlign == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _autoAligning ? null : _runAutoAlign,
                icon: _autoAligning
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onSecondaryContainer,
                        ),
                      )
                    : const Icon(Icons.auto_fix_high, size: 18),
                label: Text(t.video_subtitle_auto_align),
              ),
              if (_autoAlignLowConfidence)
                Padding(
                  padding: EdgeInsets.only(top: gap / 2),
                  child: Text(
                    t.video_subtitle_auto_align_low_confidence,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              SizedBox(height: gap),
            ],
          );

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
        if (autoAlignButton != null) autoAlignButton,
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
