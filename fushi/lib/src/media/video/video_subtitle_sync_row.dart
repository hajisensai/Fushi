import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/subtitle_delay_input_debounce.dart';
import 'package:fushi/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/utils.dart';

/// TODO-413：「自动对轴」按钮的功能开关。音频能量互相关自动对轴（TODO-701 阶段1）算法
/// 管线已完整落地（抽包络 + 互相关 + 置信门控 + 写穿 delayMs），TODO-742 曾因「真机未验、
/// 暂缓发布」临时关掉入口（非确定性缺陷）；TODO-413 翻开此开关上线，配套前 N 分钟截断
/// （大文件性能）与音轨越界回退（外挂音轨边界）。降级链已闭环：无 ffmpeg / 超时 / 空包络 /
/// 低相关一律不改 delayMs 仅提示，翻开关最坏只是「低置信」提示（降级非破坏）。
const bool kSubtitleAutoAlignButtonEnabled = true;

/// 字幕调轴行（A/V 延迟）：滑条 / ±50ms·±1000ms 步进 / 数值输入框 / 自动对轴按钮 /
/// 波形对轴面板五处共享同一权威延迟值。从旧 `VideoQuickSettingsSheet._buildDelayRow`
/// 原样抽出为独立控件（阶段 B：面板改 schema 投影，本行以 `SettingsCustomItem` 入
/// schema、仅播放中可见），逻辑逐字保留。
class VideoSubtitleSyncRow extends StatefulWidget {
  const VideoSubtitleSyncRow({required this.host, super.key});

  final VideoQuickSettingsHost host;

  @override
  State<VideoSubtitleSyncRow> createState() => _VideoSubtitleSyncRowState();
}

class _VideoSubtitleSyncRowState extends State<VideoSubtitleSyncRow> {
  /// 字幕调轴滑条范围（±10 秒，覆盖绝大多数外挂字幕偏移；更大偏移仍可经输入框键入到
  /// ±600000，与 VideoPlayerController 的 clamp 一致）。
  static const int _subtitleSyncSliderRangeMs = 10000;
  static const int _subtitleSyncClampMs = 600000;

  // 本地权威镜像（与旧面板同语义）：打开时取页面当前延迟，之后由本行内五个入口经
  // [_commitDelay] 统一提交（页面侧对同值早退，不重复 OSD）。
  late int _delayMs = widget.host.delayMs();

  /// 字幕调轴数值输入框控制器（与滑条/± 按钮共享同一权威 [_delayMs]）。
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
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoQuickSettingsHost host = widget.host;
    // 拖动中显示预览值，否则显示已落盘的权威值。
    final int shownMs = _delayDragMs ?? _delayMs;
    final String label = '${shownMs >= 0 ? '+' : ''}$shownMs ms';

    // 滑条只在 ±[_subtitleSyncSliderRangeMs] 内拖（细调常见偏移）；超出范围的当前值
    // 仍能通过输入框设置，滑条把手 clamp 到端点显示。
    final double sliderValue = shownMs
        .clamp(-_subtitleSyncSliderRangeMs, _subtitleSyncSliderRangeMs)
        .toDouble();

    final Widget buttons = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        FushiIconButton(
          icon: Icons.keyboard_double_arrow_left,
          tooltip: '-1000ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs - 1000),
        ),
        FushiIconButton(
          icon: Icons.chevron_left,
          tooltip: '-50ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs - 50),
        ),
        FushiFocusable(
          onTap: shownMs == 0 ? null : () => _commitDelay(0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 84, maxWidth: 140),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: shownMs == 0
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        FushiIconButton(
          icon: Icons.chevron_right,
          tooltip: '+50ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs + 50),
        ),
        FushiIconButton(
          icon: Icons.keyboard_double_arrow_right,
          tooltip: '+1000ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs + 1000),
        ),
        // TODO-413：「自动对轴」按钮（音频能量互相关自动对轴，TODO-701 阶段1）。门控用
        // 编译期常量 [kSubtitleAutoAlignButtonEnabled]=true 上线；执行期切 spinner 并禁用
        // （_runAutoAlign/_autoAligning 防重入）。手动对轴（±50/±1000ms 步进、滑条、数值
        // 输入框）与本按钮独立，互不影响、照常可用。
        if (kSubtitleAutoAlignButtonEnabled && host.onAutoAlign != null)
          _autoAligning
              ? Padding(
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                )
              : FushiIconButton(
                  icon: Icons.auto_fix_high,
                  tooltip: t.video_subtitle_auto_align,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: _runAutoAlign,
                ),
      ],
    );

    return AdaptiveSettingsRow(
      title: t.video_setting_av_delay,
      subtitle: t.video_setting_av_delay_hint,
      icon: Icons.sync_outlined,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 可拉滑条（细调 ±10s）：拖动只本地预览，松手才落盘+实时生效（避免每 tick 写 DB）。
          // TODO-742：必须走 [adaptiveSlider] 而非裸 [Slider]——本面板可能处在全局
          // [FushiAppUiScale] 的 Transform.scale 子树里，裸 Slider 的值指示器水平钳制在两
          // 空间差 s² 下会把气泡甩到拇指反方向（根因与守卫见 adaptive_widgets.dart /
          // slider_value_indicator_scale_test.dart）。
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
          SizedBox(height: tokens.spacing.gap / 2),
          buttons,
          SizedBox(height: tokens.spacing.gap / 2),
          // 数值输入框：可直接键入正负毫秒值（支持超出滑条范围的大偏移）。
          AdaptiveSettingsTextField(
            controller: _delayController,
            labelText: t.video_setting_subtitle_sync_input,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            textInputAction: TextInputAction.done,
            // 边键入边去抖生效（BUG-918）：不再要求按回车，退格 / 键入实时反映到延迟；
            // 回车立即提交，非法输入回退当前权威值（共享 [SubtitleDelayInputDebounce]）。
            onChanged: _delayInput.onChanged,
            onSubmitted: _delayInput.onSubmitted,
          ),
          // TODO-1051 阶段B / TODO-1207：音频波形对轴入口（有字幕 cue + 可抽波形时才挂）。
          // 调轴经 onCommitDelay 写回权威 [_delayMs]（同源、零第二套状态）；拿不到波形
          // （移动端 ffmpeg 无逐帧行）时入口收起，不崩不空白、不显示按钮。
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

  /// 副字幕独立调轴段（TODO-2837）：标题 + 滑条 + ±50/±1000 微调 + 数值输入 +
  /// 「跟随主字幕」重置。未单独设置（null=跟随）时滑条/数值回显主轨生效值、数值
  /// 染次要色；显式设置后染主色并出现重置按钮。副字幕轨未激活时整段收起。
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
        : '${shownMs >= 0 ? '+' : ''}$shownMs ms';
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
                style: theme.textTheme.titleSmall,
              ),
            ),
            // 显式设置过才给「跟随主字幕」重置入口（跟随态本身无可重置）。
            if (_secondaryDelayMs != null)
              TextButton(
                onPressed: () => _commitSecondaryDelay(null),
                child: Text(t.video_setting_secondary_delay_follow),
              ),
          ],
        ),
        Text(
          t.video_setting_secondary_av_delay_hint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: tokens.spacing.gap / 2,
          runSpacing: tokens.spacing.gap / 2,
          children: <Widget>[
            FushiIconButton(
              icon: Icons.keyboard_double_arrow_left,
              tooltip: '-1000ms',
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              // 跟随态微调以主轨生效值为基准起步（首次微调 = 主轨值 ± 步进）。
              onTap: () =>
                  _commitSecondaryDelay((_secondaryDelayMs ?? _delayMs) - 1000),
            ),
            FushiIconButton(
              icon: Icons.chevron_left,
              tooltip: '-50ms',
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () =>
                  _commitSecondaryDelay((_secondaryDelayMs ?? _delayMs) - 50),
            ),
            FushiFocusable(
              onTap: shownMs == 0 && !following
                  ? null
                  : () => _commitSecondaryDelay(0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 84, maxWidth: 160),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: following
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            FushiIconButton(
              icon: Icons.chevron_right,
              tooltip: '+50ms',
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () =>
                  _commitSecondaryDelay((_secondaryDelayMs ?? _delayMs) + 50),
            ),
            FushiIconButton(
              icon: Icons.keyboard_double_arrow_right,
              tooltip: '+1000ms',
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () =>
                  _commitSecondaryDelay((_secondaryDelayMs ?? _delayMs) + 1000),
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        AdaptiveSettingsTextField(
          controller: _secondaryDelayController,
          labelText: t.video_setting_subtitle_sync_input,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          textInputAction: TextInputAction.done,
          onChanged: _secondaryDelayInput.onChanged,
          onSubmitted: _secondaryDelayInput.onSubmitted,
        ),
      ],
    );
  }
}
