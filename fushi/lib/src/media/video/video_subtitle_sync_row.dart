import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/media/video/subtitle_delay_input_debounce.dart';
import 'package:fushi/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// TODO-413：「自动对轴」按钮的功能开关。音频能量互相关自动对轴（TODO-701 阶段1）算法
/// 管线已完整落地（抽包络 + 互相关 + 置信门控 + 写穿 delayMs），TODO-742 曾因「真机未验、
/// 暂缓发布」临时关掉入口（非确定性缺陷）；TODO-413 翻开此开关上线，配套前 N 分钟截断
/// （大文件性能）与音轨越界回退（外挂音轨边界）。降级链已闭环：无 ffmpeg / 超时 / 空包络 /
/// 低相关一律不改 delayMs 仅提示，翻开关最坏只是「低置信」提示（降级非破坏）。
const bool kSubtitleAutoAlignButtonEnabled = true;

/// 字幕调轴行（A/V 延迟）：滑条 / ±50ms·±1000ms 步进 / 可点按输入的读数胶囊 /
/// 自动对轴按钮 / 上下句对齐 / 波形对轴面板共享同一权威延迟值。本行以
/// `SettingsCustomItem` 入 schema、仅播放中可见。
///
/// [floatBar] = true 时是「浮条调轴」形态（视频页画面顶部的紧凑浮条，见
/// [VideoQuickSettingsHost.onEnterSubtitleDelayBar]）：只留步进 + 读数 + 一键对齐 +
/// 「完成」（[onDone]），把字幕区域让出来看实时效果。
class VideoSubtitleSyncRow extends StatefulWidget {
  const VideoSubtitleSyncRow({
    required this.host,
    this.floatBar = false,
    this.onDone,
    super.key,
  });

  final VideoQuickSettingsHost host;

  /// 浮条形态（见类注释）。
  final bool floatBar;

  /// 浮条形态的「完成」：退出浮条模式。
  final VoidCallback? onDone;

  @override
  State<VideoSubtitleSyncRow> createState() => _VideoSubtitleSyncRowState();
}

class _VideoSubtitleSyncRowState extends State<VideoSubtitleSyncRow> {
  /// 字幕调轴滑条范围（±10 秒，覆盖绝大多数外挂字幕偏移；更大偏移仍可经输入框键入到
  /// ±600000，与 VideoPlayerController 的 clamp 一致）。
  static const int _subtitleSyncSliderRangeMs = 10000;
  static const int _subtitleSyncClampMs = 600000;

  // 本地权威镜像（与旧面板同语义）：打开时取页面当前延迟，之后由本行内五个入口经
  // [_commitDelay] 统一提交（页面侧对同值早退，不重复 OSD）。本行**之外**的入口
  // （z/x 微调、Ctrl+Shift+←/→ 对齐快捷键）改了页面延迟时，由 [_syncDelayFromHost]
  // 拉回页面权威值（BUG-3231：浮条开着按快捷键，读数不跟、再点 ± 以旧值为基数覆盖）。
  late int _delayMs = widget.host.delayMs();

  /// 字幕调轴数值输入（读数胶囊的编辑态）控制器（与滑条/± 按钮共享同一权威 [_delayMs]）。
  late final TextEditingController _delayController =
      TextEditingController(text: '$_delayMs');

  /// 拖动字幕调轴滑条时的临时预览值（仅本地回显，松手才 [_commitDelay] 落盘+实时生效），
  /// 避免每个拖动 tick 都写 DB。null = 未在拖动。
  int? _delayDragMs;

  /// 数值输入框「边键入边生效」的去抖（BUG-918）：键入即去抖提交（350ms 停手后
  /// [_commitDelay]，与滑条 / ± 按钮同源、实时生效），不要求按回车。与波形对轴放大
  /// 视图共享 [SubtitleDelayInputDebounce]（原两处逐行拷贝已抽出）。
  late final SubtitleDelayInputDebounce _delayInput =
      SubtitleDelayInputDebounce(
    controller: _delayController,
    isMounted: () => mounted,
    currentDelayMs: () => _delayMs,
    commit: _commitDelay,
  );

  /// 一键自动对轴进行中（TODO-701）：按钮显示 spinner 并禁用，防重入。
  bool _autoAligning = false;

  // ── 副字幕独立调轴（TODO-2837）────────────────────────────────────────────
  // 本地权威镜像：null = 跟随主字幕（[_delayMs]）；非 null = 副轨独立偏移。
  // 仅副字幕轨激活（host.hasSecondarySubtitle）时渲染本段，避免死 UI。
  late int? _secondaryDelayMs = widget.host.secondaryDelayMs?.call();

  /// 拖动副轨滑条时的临时预览值（仅本地回显，松手才提交）；null = 未在拖动。
  int? _secondaryDragMs;

  /// 副轨数值输入框控制器（未单独设置时回显主轨生效值）。
  late final TextEditingController _secondaryDelayController =
      TextEditingController(text: '${_secondaryDelayMs ?? _delayMs}');

  /// 副轨数值输入框「边键入边生效」去抖（与主轨同款，BUG-918 范式）。
  late final SubtitleDelayInputDebounce _secondaryDelayInput =
      SubtitleDelayInputDebounce(
    controller: _secondaryDelayController,
    isMounted: () => mounted,
    currentDelayMs: () => _secondaryDelayMs ?? _delayMs,
    commit: (int delayMs, {bool syncField = true}) =>
        _commitSecondaryDelay(delayMs, syncField: syncField),
  );

  @override
  void initState() {
    super.initState();
    widget.host.subtitlePositionListenable?.addListener(_syncDelayFromHost);
  }

  @override
  void didUpdateWidget(VideoSubtitleSyncRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Listenable? previous = oldWidget.host.subtitlePositionListenable;
    final Listenable? current = widget.host.subtitlePositionListenable;
    if (!identical(previous, current)) {
      previous?.removeListener(_syncDelayFromHost);
      current?.addListener(_syncDelayFromHost);
    }
    _syncDelayFromHost(rebuild: false);
  }

  /// 页面延迟被本行以外的入口改掉（快捷键微调 / 对齐）时，把镜像、读数与输入框拉回
  /// 页面权威值 [VideoQuickSettingsHost.delayMs]。页面 `_setDelayMs` 只发 OSD、不重建
  /// 本行，所以除了 [didUpdateWidget] 还挂在 controller 的通知上（调延迟会立即
  /// notify，见 `VideoPlayerController.setDelayMs`）；值没变时零开销早退。
  ///
  /// [rebuild] = false 供 [didUpdateWidget] 用（框架随后必然 build，不能再 setState）。
  void _syncDelayFromHost({bool rebuild = true}) {
    if (!mounted) return;
    final int hostMs = widget.host.delayMs();
    if (hostMs == _delayMs) return;
    _delayInput.cancelPending();
    if (_delayController.text != '$hostMs') _delayController.text = '$hostMs';
    if (rebuild) {
      setState(() => _delayMs = hostMs);
    } else {
      _delayMs = hostMs;
    }
  }

  /// ± 步进：以页面权威值为基数（不是可能过期的镜像），快捷键刚改过的延迟不会被覆盖。
  Future<void> _stepDelay(int deltaMs) =>
      _commitDelay(widget.host.delayMs() + deltaMs);

  @override
  void dispose() {
    widget.host.subtitlePositionListenable?.removeListener(_syncDelayFromHost);
    _delayInput.dispose();
    _delayController.dispose();
    _secondaryDelayInput.dispose();
    _secondaryDelayController.dispose();
    super.dispose();
  }

  /// 字幕调轴权威提交：滑条 / ± 按钮 / 数值输入框三处共享。clamp 到 ±[_subtitleSyncClampMs]
  /// （与 VideoPlayerController.setDelayMs 一致），更新本地 [_delayMs]、可选回写输入框文本、
  /// 即时回调 [VideoQuickSettingsHost.onSetDelay] 落盘+实时生效。
  Future<void> _commitDelay(int next, {bool syncField = true}) async {
    final int clamped = next.clamp(-_subtitleSyncClampMs, _subtitleSyncClampMs);
    // 权威提交路径取消任何待触发的键入去抖，免得一个陈旧的键入值在按钮点击后姗姗迟到
    // 覆盖掉刚设的值（BUG-918）。
    if (syncField) _delayInput.cancelPending();
    setState(() => _delayMs = clamped);
    if (syncField && _delayController.text != '$clamped') {
      _delayController.text = '$clamped';
    }
    await widget.host.onSetDelay(clamped);
  }

  /// 副轨调轴权威提交（TODO-2837）：滑条 / ± 按钮 / 数值输入 / 「跟随主字幕」重置
  /// 四处共享。[next] 为 null = 重置为跟随主字幕；非 null clamp 后经
  /// [VideoQuickSettingsHost.onSetSecondaryDelay] 落盘 + 实时生效。
  Future<void> _commitSecondaryDelay(int? next, {bool syncField = true}) async {
    final Future<void> Function(int? delayMs)? onSet =
        widget.host.onSetSecondaryDelay;
    if (onSet == null) return;
    final int? clamped =
        next?.clamp(-_subtitleSyncClampMs, _subtitleSyncClampMs);
    if (syncField) _secondaryDelayInput.cancelPending();
    setState(() => _secondaryDelayMs = clamped);
    final String fieldText = '${clamped ?? _delayMs}';
    if (syncField && _secondaryDelayController.text != fieldText) {
      _secondaryDelayController.text = fieldText;
    }
    await onSet(clamped);
  }

  /// TODO-701 阶段1：触发一键自动对轴。回调内部抽音频能量包络、与字幕 cue 互相关求整体
  /// 平移，再经 onSetDelay 写穿延迟并弹 OSD/低置信提示；本行只在其执行期间把按钮切成
  /// spinner 并禁用（防重入）。TODO-1206：回调返回本次实际平移 offset（毫秒），非 null 就
  /// 走 [_commitDelay] 同步权威值 + 输入框 + 波形预览；null（低置信 / noData）不动当前值。
  Future<void> _runAutoAlign() async {
    final Future<int?> Function()? cb = widget.host.onAutoAlign;
    if (cb == null || _autoAligning) return;
    setState(() => _autoAligning = true);
    try {
      final int? alignedOffsetMs = await cb();
      if (mounted && alignedOffsetMs != null) {
        await _commitDelay(alignedOffsetMs);
      }
    } finally {
      if (mounted) setState(() => _autoAligning = false);
    }
  }

  /// 「上一句 / 下一句字幕对齐到当前播放时间」按钮（asbplayer 式绝对偏移，与键盘
  /// Ctrl+Shift+←/→ 同一执行体）。决策与写穿都在页面侧回调里，本行只负责把回传的
  /// 新延迟同步进本地权威镜像 / 滑条 / 数值输入框——与 [_runAutoAlign] 同款契约，
  /// 否则点完按钮延迟已经变了、面板控件却停在旧值。
  ///
  /// 回调返回 null（已是首末句无相邻 cue / 播放位置未就绪）时不动当前值。不做防重入
  /// spinner：这条路径是纯同步计算 + 一次写穿，没有 [_runAutoAlign] 的 ffmpeg 探测开销。
  Future<void> _snapDelayToCue({required bool next}) async {
    final int? Function({required bool next})? cb =
        widget.host.onSnapDelayToCue;
    if (cb == null) return;
    final int? newDelayMs = cb(next: next);
    if (newDelayMs == null || !mounted) return;
    await _commitDelay(newDelayMs);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.floatBar) return _buildFloatBar(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoQuickSettingsHost host = widget.host;
    final bool compact = SettingsCompactRowsScope.of(context);
    // 拖动中显示预览值，否则显示已落盘的权威值。
    final int shownMs = _delayDragMs ?? _delayMs;
    final String label = _delayLabel(shownMs);

    // 滑条只在 ±[_subtitleSyncSliderRangeMs] 内拖（细调常见偏移）；超出范围的当前值
    // 仍能点读数直接输入，滑条把手 clamp 到端点显示。
    final double sliderValue = shownMs
        .clamp(-_subtitleSyncSliderRangeMs, _subtitleSyncSliderRangeMs)
        .toDouble();

    // M3E：±50 / ±1000ms 是一组 tonal 圆钮，中间夹一枚等宽数字读数胶囊（非零时
    // 换 secondaryContainer 色块）。读数胶囊本身就是输入框：点按原地变成数字输入
    // （反馈 nGxUGtYot9：「当前延迟」与「手动输入偏移」合成一行）。「一键求绝对
    // 偏移」类动作另成一组，窄面板换行时两组各自整体换行、不把步进钮拆散。
    final Widget buttons = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        _stepperRow(context, label: label, shownMs: shownMs),
        _actionRow(context, host, shownMs: shownMs, includeFloatBar: true),
      ],
    );

    return AdaptiveSettingsRow(
      title: t.video_setting_av_delay,
      // 说明收成一句（正负号含义）；完整用法在读数胶囊的提示里。
      subtitle: t.video_setting_av_delay_hint_short,
      icon: FushiIcons.sync,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 可拉滑条（细调 ±10s）：拖动只本地预览，松手才落盘+实时生效（避免每 tick 写 DB）。
          // TODO-742：必须走 [adaptiveSlider] 而非裸 [Slider]——本面板可能处在全局
          // [FushiAppUiScale] 的 Transform.scale 子树里，裸 Slider 的值指示器水平钳制在两
          // 空间差 s² 下会把气泡甩到拇指反方向（根因与守卫见 adaptive_widgets.dart /
          // slider_value_indicator_scale_test.dart）。
          // 手机紧凑档（[SettingsCompactRowsScope]）不放滑条：±步进 + 可输入读数已覆盖
          // 它的用途，省下的一截留给首屏更多设置项。
          if (!compact) ...<Widget>[
            adaptiveSlider(
              context: context,
              value: sliderValue,
              min: -_subtitleSyncSliderRangeMs.toDouble(),
              max: _subtitleSyncSliderRangeMs.toDouble(),
              divisions: _subtitleSyncSliderRangeMs ~/ 50, // 50ms 一档
              label: label,
              onChanged: (double v) => setState(() => _delayDragMs = v.round()),
              onChangeEnd: (double v) {
                setState(() => _delayDragMs = null);
                _commitDelay(v.round());
              },
            ),
          ],
          SizedBox(height: tokens.spacing.gap / 2),
          buttons,
          // TODO-1051 阶段B / TODO-1207：音频波形对轴入口（有字幕 cue + 可抽波形时才挂）。
          // 调轴经 onCommitDelay 写回权威 [_delayMs]（同源、零第二套状态）；五端同一条
          // 抽取路径（逐帧 RMS 走 ffmpeg 写文件），抽不出波形时入口内联提示、不隐藏。
          if (host.loadSubtitleWaveform != null &&
              host.subtitleWaveformCues.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            SubtitleWaveformAlignPanel(
              key: ValueKey<int>(host.subtitleWaveformCues.length),
              initialDelayMs: _delayMs,
              cues: host.subtitleWaveformCues,
              durationMs: host.videoDurationMs,
              loadWaveform: host.loadSubtitleWaveform!,
              onCommitDelay: _commitDelay,
              // TODO-1316：放大波形对轴视图内的「自动对轴」按钮复用与顶部同一 onAutoAlign
              // 逻辑，成功后经上面的 onCommitDelay 同步权威延迟。
              onAutoAlign: host.onAutoAlign,
              onSnapDelayToCue: host.onSnapDelayToCue,
              onPlayCue: host.onPlaySubtitleCue,
              isPlaying: host.subtitleIsPlaying,
              onTogglePlayPause: host.onToggleSubtitlePlayPause,
              keyboardShortcuts: host.subtitleAlignShortcuts,
              onSeek: host.onSeekSubtitleWaveform,
              positionListenable: host.subtitlePositionListenable,
              currentPositionMs: host.currentSubtitlePositionMs,
            ),
          ],
          // TODO-2837：副字幕独立调轴段。仅副字幕轨激活时渲染（无副字幕不加死 UI）；
          // 激活态是活值（面板内切换副字幕轨即变），经 controller（
          // subtitlePositionListenable）的通知即时显隐。
          if (host.onSetSecondaryDelay != null &&
              host.secondaryDelayMs != null) ...<Widget>[
            if (host.subtitlePositionListenable != null)
              ListenableBuilder(
                listenable: host.subtitlePositionListenable!,
                builder: (BuildContext ctx, Widget? _) =>
                    _buildSecondarySection(ctx),
              )
            else
              _buildSecondarySection(context),
          ],
        ],
      ),
    );
  }

  String _delayLabel(int ms) => '${ms >= 0 ? '+' : ''}$ms ms';

  /// ±1000 / ±50 步进钮夹一枚可点按输入的读数胶囊。极窄面板（< 270）整组等比
  /// 缩小而不是溢出。
  Widget _stepperRow(
    BuildContext context, {
    required String label,
    required int shownMs,
  }) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _stepButton(
            icon: FushiIcons.fastRewind,
            tooltip: '-1000ms',
            onPressed: () => _stepDelay(-1000),
          ),
          _stepButton(
            icon: FushiIcons.chevronLeft,
            tooltip: '-50ms',
            onPressed: () => _stepDelay(-50),
          ),
          _DelayReadoutField(
            key: const ValueKey<String>('video-subtitle-delay-readout'),
            fieldKey: const ValueKey<String>('video-subtitle-delay-input'),
            label: label,
            active: shownMs != 0,
            maxWidth: 140,
            semanticsLabel: t.video_setting_subtitle_sync_input,
            tooltip: '${t.video_setting_av_delay_tap_to_type}\n'
                '${t.video_setting_av_delay_hint}',
            controller: _delayController,
            onChanged: _delayInput.onChanged,
            onSubmitted: _delayInput.onSubmitted,
          ),
          _stepButton(
            icon: FushiIcons.chevronRight,
            tooltip: '+50ms',
            onPressed: () => _stepDelay(50),
          ),
          _stepButton(
            icon: FushiIcons.fastForward,
            tooltip: '+1000ms',
            onPressed: () => _stepDelay(1000),
          ),
        ],
      ),
    );
  }

  /// 「一键」动作组：归零（非零时）/ 自动对轴 / 上一句、下一句对齐到此刻 / 浮条调轴。
  Widget _actionRow(
    BuildContext context,
    VideoQuickSettingsHost host, {
    required int shownMs,
    required bool includeFloatBar,
  }) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 归零：此前藏在「点读数」里（读数现在是输入框），改成显式小钮，只在非零时出现。
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          child: shownMs == 0
              ? const SizedBox.shrink()
              : FushiIconButtonControl(
                  key: const ValueKey<String>('video-subtitle-delay-reset'),
                  size: FushiIconButtonSize.s,
                  tooltip: t.video_setting_av_delay_reset,
                  icon: const FushiIcon(FushiIcons.undo),
                  onPressed: () => _commitDelay(0),
                ),
        ),
        // TODO-413：「自动对轴」按钮（音频能量互相关自动对轴，TODO-701 阶段1）。门控用
        // 编译期常量 [kSubtitleAutoAlignButtonEnabled]=true 上线；执行期切 spinner 并禁用
        // （_runAutoAlign/_autoAligning 防重入）。手动对轴（±50/±1000ms 步进、滑条、读数
        // 输入）与本按钮独立，互不影响、照常可用。
        if (kSubtitleAutoAlignButtonEnabled && host.onAutoAlign != null)
          _autoAligning
              ? SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: FushiCircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                )
              : FushiIconButtonControl(
                  size: FushiIconButtonSize.s,
                  tooltip: t.video_subtitle_auto_align,
                  icon: const FushiIcon(FushiIcons.ai),
                  onPressed: _runAutoAlign,
                ),
        // 「上/下一句对齐到当前时间」（asbplayer 式）：暂停在某句真正开口的那一刻点一下，
        // 一步求出绝对偏移，不用 ± 来回试。与自动对轴并列——都是「一键求绝对偏移」，
        // 区别是这里由用户用播放头指定对齐目标（不依赖音频探测，无 ffmpeg 也能用）。
        if (host.onSnapDelayToCue != null) ...<Widget>[
          FushiIconButtonControl(
            key: const ValueKey<String>('video-subtitle-delay-snap-prev'),
            size: FushiIconButtonSize.s,
            tooltip: t.video_subtitle_prev_cue_align,
            icon: const FushiIcon(FushiIcons.skipPrevious),
            onPressed: () => _snapDelayToCue(next: false),
          ),
          FushiIconButtonControl(
            key: const ValueKey<String>('video-subtitle-delay-snap-next'),
            size: FushiIconButtonSize.s,
            tooltip: t.video_subtitle_next_cue_align,
            icon: const FushiIcon(FushiIcons.skipNext),
            onPressed: () => _snapDelayToCue(next: true),
          ),
        ],
        // 浮条调轴：收起设置面板、只在画面顶上留一条调轴浮条，字幕区域整片让出来
        // （反馈 JsICLVdq0i：调延迟时字幕被面板挡住，看不到实时效果）。
        if (includeFloatBar && host.onEnterSubtitleDelayBar != null)
          FushiIconButtonControl.filledTonal(
            key: const ValueKey<String>('video-subtitle-delay-float'),
            size: FushiIconButtonSize.s,
            tooltip: t.video_setting_av_delay_float,
            icon: const FushiIcon(FushiIcons.pictureInPicture),
            onPressed: host.onEnterSubtitleDelayBar,
          ),
      ],
    );
  }

  /// 浮条形态（[VideoSubtitleSyncRow.floatBar]）：只留步进 + 可输入读数 + 一键对齐 +
  /// 完成，放不下时两组各自整体换行。滑条 / 波形 / 副字幕这些需要面积的控件留在面板里。
  Widget _buildFloatBar(BuildContext context) {
    final int shownMs = _delayDragMs ?? _delayMs;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        _stepperRow(context, label: _delayLabel(shownMs), shownMs: shownMs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _actionRow(
              context,
              widget.host,
              shownMs: shownMs,
              includeFloatBar: false,
            ),
            const SizedBox(width: 4),
            FushiFilledButton(
              key: const ValueKey<String>('video-subtitle-delay-bar-done'),
              onPressed: widget.onDone,
              child: Text(t.dialog_done),
            ),
          ],
        ),
      ],
    );
  }

  /// 副字幕独立调轴段（TODO-2837）：标题 + 滑条 + ±50/±1000 微调（中间读数可点按
  /// 输入）+ 「跟随主字幕」重置。未单独设置（null=跟随）时滑条/数值回显主轨生效值、
  /// 数值染次要色；显式设置后染主色并出现重置按钮。副字幕轨未激活时整段收起。
  Widget _buildSecondarySection(BuildContext context) {
    if (!(widget.host.hasSecondarySubtitle?.call() ?? false)) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool following =
        _secondaryDelayMs == null && _secondaryDragMs == null;
    final int shownMs = _secondaryDragMs ?? _secondaryDelayMs ?? _delayMs;
    final String label = following
        ? t.video_setting_secondary_delay_follow
        : _delayLabel(shownMs);
    final double sliderValue = shownMs
        .clamp(-_subtitleSyncSliderRangeMs, _subtitleSyncSliderRangeMs)
        .toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: tokens.spacing.gap),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.video_setting_secondary_av_delay,
                style: context.fushiType.titleSmallEmphasized,
              ),
            ),
            // 显式设置过才给「跟随主字幕」重置入口（跟随态本身无可重置）。
            if (_secondaryDelayMs != null)
              FushiTextButton(
                onPressed: () => _commitSecondaryDelay(null),
                child: Text(t.video_setting_secondary_delay_follow),
              ),
          ],
        ),
        Text(
          t.video_setting_secondary_av_delay_hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        adaptiveSlider(
          context: context,
          value: sliderValue,
          min: -_subtitleSyncSliderRangeMs.toDouble(),
          max: _subtitleSyncSliderRangeMs.toDouble(),
          divisions: _subtitleSyncSliderRangeMs ~/ 50, // 50ms 一档
          label: label,
          onChanged: (double v) => setState(() => _secondaryDragMs = v.round()),
          onChangeEnd: (double v) {
            setState(() => _secondaryDragMs = null);
            _commitSecondaryDelay(v.round());
          },
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _stepButton(
                  icon: FushiIcons.fastRewind,
                  tooltip: '-1000ms',
                  // 跟随态微调以主轨生效值为基准起步（首次微调 = 主轨值 ± 步进）。
                  onPressed: () => _commitSecondaryDelay(
                    (_secondaryDelayMs ?? _delayMs) - 1000,
                  ),
                ),
                _stepButton(
                  icon: FushiIcons.chevronLeft,
                  tooltip: '-50ms',
                  onPressed: () => _commitSecondaryDelay(
                    (_secondaryDelayMs ?? _delayMs) - 50,
                  ),
                ),
                _DelayReadoutField(
                  key: const ValueKey<String>(
                    'video-subtitle-secondary-delay-readout',
                  ),
                  fieldKey: const ValueKey<String>(
                    'video-subtitle-secondary-delay-input',
                  ),
                  label: label,
                  active: !following,
                  maxWidth: 160,
                  semanticsLabel: t.video_setting_subtitle_sync_input,
                  tooltip: t.video_setting_av_delay_tap_to_type,
                  controller: _secondaryDelayController,
                  onChanged: _secondaryDelayInput.onChanged,
                  onSubmitted: _secondaryDelayInput.onSubmitted,
                ),
                _stepButton(
                  icon: FushiIcons.chevronRight,
                  tooltip: '+50ms',
                  onPressed: () => _commitSecondaryDelay(
                    (_secondaryDelayMs ?? _delayMs) + 50,
                  ),
                ),
                _stepButton(
                  icon: FushiIcons.fastForward,
                  tooltip: '+1000ms',
                  onPressed: () => _commitSecondaryDelay(
                    (_secondaryDelayMs ?? _delayMs) + 1000,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// ± 步进钮：M3E tonal 圆钮（S 档 40dp），手柄 / 方向键可逐个聚焦。
  Widget _stepButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FushiIconButtonControl.filledTonal(
        size: FushiIconButtonSize.s,
        tooltip: tooltip,
        icon: FushiIcon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

/// 延迟读数胶囊 + 原地数字输入（反馈 nGxUGtYot9：「当前延迟」与「手动输入偏移」
/// 合成一行）。
///
/// 平时是等宽数字的读数胶囊（逐帧拖动不抖宽；[active] = 非零 / 已单独设置时换
/// secondaryContainer 色块，颜色过渡走 effects 弹簧）；点按 / Enter 原地变成同尺寸
/// 的数字输入框（全选当前值，键入即去抖生效，回车或失焦提交并变回读数）。输入
/// 走宿主同一个 [controller] 与去抖（[SubtitleDelayInputDebounce]），与滑条 / 步进钮
/// 共享同一权威值。
class _DelayReadoutField extends StatefulWidget {
  const _DelayReadoutField({
    required this.fieldKey,
    required this.label,
    required this.active,
    required this.maxWidth,
    required this.tooltip,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.semanticsLabel,
    super.key,
  });

  /// 编辑态输入框的 key（测试按它输入）。
  final Key fieldKey;

  /// 读数 / 输入框的无障碍名（「偏移 (ms)」），读屏念得出这是可输入的偏移值。
  final String semanticsLabel;
  final String label;
  final bool active;
  final double maxWidth;
  final String tooltip;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_DelayReadoutField> createState() => _DelayReadoutFieldState();
}

class _DelayReadoutFieldState extends State<_DelayReadoutField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'subtitle-delay-input');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() => _editing = true);
    widget.controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.controller.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _focusNode.requestFocus();
    });
  }

  /// 失焦（点别处 / Tab 走开）即提交并变回读数；回车走 [_submit]。
  void _onFocusChanged() {
    if (!_focusNode.hasFocus && _editing) _submit(widget.controller.text);
  }

  void _submit(String raw) {
    if (!_editing) return;
    widget.onSubmitted(raw);
    if (mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiSpringSpec spring = context.fushiMotion.effectsFast;
    final TextStyle digits = context.fushiType.titleMediumEmphasized.tabular;
    final Color fill =
        _editing || widget.active ? cs.secondaryContainer : cs.surfaceContainer;
    final Color foreground = _editing || widget.active
        ? cs.onSecondaryContainer
        : cs.onSurfaceVariant;
    final Widget content = _editing
        ? FushiTextFieldControl(
            key: widget.fieldKey,
            controller: widget.controller,
            focusNode: _focusNode,
            autofocus: true,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            textInputAction: TextInputAction.done,
            style: digits.copyWith(color: foreground),
            cursorColor: foreground,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              suffixText: 'ms',
            ),
            onChanged: widget.onChanged,
            onSubmitted: _submit,
          )
        : Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: digits.copyWith(color: foreground),
          );
    final Widget pill = AnimatedContainer(
      duration: spring.duration,
      curve: spring.curve,
      constraints: BoxConstraints(
        minWidth: 96,
        maxWidth: widget.maxWidth,
        minHeight: 40,
      ),
      width: _editing ? widget.maxWidth : null,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: FushiM3eShape.cardRadius,
        border: _editing ? Border.all(color: cs.primary, width: 2) : null,
      ),
      child: content,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        label: widget.semanticsLabel,
        textField: true,
        child: _editing
            ? pill
            : FushiTooltip(
                message: widget.tooltip,
                child: FushiFocusable(onTap: _startEditing, child: pill),
              ),
      ),
    );
  }
}
