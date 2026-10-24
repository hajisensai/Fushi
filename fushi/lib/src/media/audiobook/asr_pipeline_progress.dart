/// 设备端转录「下载模型 → 加载模型 → 转录 → 匹配正文 → 入库」的进度展示件：
/// 阶段轨、带百分比的平滑进度条、正文覆盖情况。转录弹层与下载页的后台任务行
/// 共用，两处的阶段判定都是本文件里的纯函数。
///
/// 进度数值一律原样取引擎（下载字节 / 已转录时长 / 远端回报），不重新加权；
/// 匹配器在 isolate 里一次跑完、中途不报进度，所以「匹配正文 / 入库」只给阶段
/// 与细分步骤，进度条走不定态，不估算百分比。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show AudiobookAlignmentStep;
import 'package:fushi_engine/media/audiobook/audiobook_text_coverage.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 流水线的五个阶段（按先后）。
enum AsrPipelineStage {
  downloadModel,
  loadModel,
  transcribe,
  matchText,
  import,
}

/// 阶段轨上一格的状态。
enum AsrStageState {
  /// 还没到。
  pending,

  /// 正在进行（当前高亮）。
  active,

  /// 已完成。
  done,

  /// 本轮不需要（模型本来就在）。
  skipped,

  /// 在这一步失败。
  failed,
}

/// 纯函数：由「当前在哪一步」推出五格状态。
///
/// - [current] 之前的阶段为 done（在 [skipped] 里的为 skipped），之后为 pending；
/// - [current] 本身为 active，[failed] 为真时为 failed；
/// - [current] 为 null：[allDone] 为真时全部 done（[skipped] 里的仍 skipped），
///   否则只有 [completed] 里的为 done、其余 pending。
List<AsrStageState> asrPipelineStates({
  AsrPipelineStage? current,
  Set<AsrPipelineStage> skipped = const <AsrPipelineStage>{},
  Set<AsrPipelineStage> completed = const <AsrPipelineStage>{},
  bool allDone = false,
  bool failed = false,
}) {
  return <AsrStageState>[
    for (final AsrPipelineStage stage in AsrPipelineStage.values)
      if (current != null && stage == current)
        failed ? AsrStageState.failed : AsrStageState.active
      else if (skipped.contains(stage) &&
          (allDone ||
              completed.contains(stage) ||
              (current != null && stage.index < current.index)))
        AsrStageState.skipped
      else if (allDone ||
          completed.contains(stage) ||
          (current != null && stage.index < current.index))
        AsrStageState.done
      else
        AsrStageState.pending,
  ];
}

/// 后台任务的阶段 → 阶段轨的当前格。准备中（还不知道要不要下模型）算在第一格。
AsrPipelineStage asrPipelineStageForJobPhase(
  AudiobookTranscribeJobPhase? phase,
) => switch (phase) {
  null ||
  AudiobookTranscribeJobPhase.preparing ||
  AudiobookTranscribeJobPhase.downloadingModel =>
    AsrPipelineStage.downloadModel,
  AudiobookTranscribeJobPhase.loadingModel => AsrPipelineStage.loadModel,
  AudiobookTranscribeJobPhase.transcribing => AsrPipelineStage.transcribe,
  AudiobookTranscribeJobPhase.matching => AsrPipelineStage.matchText,
  AudiobookTranscribeJobPhase.importing => AsrPipelineStage.import,
};

/// 纯函数：后台任务的五格状态。没有正文的任务（独立字幕书）「匹配正文」为
/// skipped；本轮没下模型的「下载模型」为 skipped。失败 / 取消时不知道停在哪一步
/// （阶段已清掉），返回 null，任务行不画阶段轨；排队中全部 pending。
List<AsrStageState>? asrPipelineStatesForJob(AudiobookTranscribeJob job) {
  final bool hasText = job.contentPath != null || job.targetBookKey != null;
  final Set<AsrPipelineStage> skipped = <AsrPipelineStage>{
    if (!hasText) AsrPipelineStage.matchText,
    if (job.modelDownloadSkipped) AsrPipelineStage.downloadModel,
  };
  switch (job.status) {
    case AudiobookTranscribeJobStatus.queued:
      return asrPipelineStates();
    case AudiobookTranscribeJobStatus.running:
      return asrPipelineStates(
        current: asrPipelineStageForJobPhase(job.phase),
        skipped: skipped,
      );
    case AudiobookTranscribeJobStatus.done:
      return asrPipelineStates(allDone: true, skipped: skipped);
    case AudiobookTranscribeJobStatus.failed:
    case AudiobookTranscribeJobStatus.cancelled:
      return null;
  }
}

/// 阶段名（阶段轨下的小字）。
String asrPipelineStageLabel(AsrPipelineStage stage) => switch (stage) {
  AsrPipelineStage.downloadModel => t.audiobook_transcribe_stage_download_model,
  AsrPipelineStage.loadModel => t.audiobook_transcribe_stage_load_model,
  AsrPipelineStage.transcribe => t.audiobook_transcribe_stage_transcribe,
  AsrPipelineStage.matchText => t.audiobook_transcribe_stage_match_text,
  AsrPipelineStage.import => t.audiobook_transcribe_stage_import,
};

String _stateLabel(AsrStageState state) => switch (state) {
  AsrStageState.pending => t.audiobook_transcribe_stage_state_pending,
  AsrStageState.active => t.audiobook_transcribe_stage_state_active,
  AsrStageState.done => t.audiobook_transcribe_stage_state_done,
  AsrStageState.skipped => t.audiobook_transcribe_stage_state_skipped,
  AsrStageState.failed => t.audiobook_transcribe_stage_state_failed,
};

/// 对齐服务的细分步骤 → 一句给用户看的话（复用导入对话框的步骤文案）。
String asrAlignmentStepLabel(AudiobookAlignmentStep step) => switch (step) {
  AudiobookAlignmentStep.readingText => t.import_step_reading_idb,
  AudiobookAlignmentStep.parsingSubtitle => t.import_step_parsing,
  AudiobookAlignmentStep.matching => t.import_step_matching,
  AudiobookAlignmentStep.finishing => t.audiobook_transcribe_step_finishing,
  AudiobookAlignmentStep.persisting => t.import_step_persisting,
  AudiobookAlignmentStep.saving => t.import_step_saving,
  AudiobookAlignmentStep.done => t.import_step_done,
};

/// 0..1 → 整数百分比文字。四舍五入，但没到 1 时最多 99%：99.6% 不显示成
/// 100%（还没完）。
String formatAsrPercent(double value) {
  final double v = value.clamp(0.0, 1.0);
  final int pct = v >= 1 ? 100 : (v * 100).round().clamp(0, 99);
  return '$pct%';
}

/// 阶段轨用到的几种颜色（按设计系统取）。
({Color accent, Color muted, Color error, Color strong, Color soft})
_railColors(BuildContext context, Color? foreground) {
  if (isGlassDesign(context)) {
    final FushiAppleColors apple = appleColorsOf(context);
    return (
      accent: apple.accent,
      muted: apple.tertiaryLabel,
      error: apple.destructive,
      strong: foreground ?? apple.label,
      soft: foreground?.withValues(alpha: 0.7) ?? apple.secondaryLabel,
    );
  }
  final ColorScheme cs = Theme.of(context).colorScheme;
  return (
    accent: cs.primary,
    muted: cs.outline,
    error: cs.error,
    strong: foreground ?? cs.onSurface,
    soft: foreground?.withValues(alpha: 0.7) ?? cs.onSurfaceVariant,
  );
}

/// 五段阶段轨：已完成打勾、当前高亮（实心圆点）、未到空心、跳过为一道横线、
/// 失败为错误色。格与格之间的连线走到哪一格就上色到哪一格。状态切换按
/// [FushiMotion.short] 交叉淡化（减弱动态效果时归零）。
class AsrPipelineStageRail extends StatelessWidget {
  const AsrPipelineStageRail({
    required this.states,
    this.foreground,
    this.compact = false,
    super.key,
  }) : assert(states.length == 5, 'one state per AsrPipelineStage');

  /// 与 [AsrPipelineStage.values] 一一对应。
  final List<AsrStageState> states;

  /// 放在 tonal 色块上时的配对前景（文字用）；null = 页面前景。
  final Color? foreground;

  /// 任务行里的小号版本。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ({Color accent, Color muted, Color error, Color strong, Color soft})
    colors = _railColors(context, foreground);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final double marker = compact ? 14 : 18;
    final TextStyle labelStyle = compact
        ? context.fushiType.labelSmall
        : context.fushiType.labelMedium;
    bool reached(AsrStageState s) =>
        s == AsrStageState.done ||
        s == AsrStageState.skipped ||
        s == AsrStageState.active ||
        s == AsrStageState.failed;
    return Row(
      key: const ValueKey<String>('asr-pipeline-rail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < states.length; i++)
          Expanded(
            child: Semantics(
              label:
                  '${asrPipelineStageLabel(AsrPipelineStage.values[i])}, '
                  '${_stateLabel(states[i])}',
              excludeSemantics: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: i == 0
                            ? const SizedBox.shrink()
                            : _Connector(
                                color: reached(states[i])
                                    ? colors.accent
                                    : colors.muted.withValues(alpha: 0.4),
                                duration: duration,
                              ),
                      ),
                      _StageMarker(
                        key: ValueKey<String>(
                          'asr-pipeline-stage-$i-${states[i].name}',
                        ),
                        state: states[i],
                        size: marker,
                        accent: colors.accent,
                        muted: colors.muted,
                        error: colors.error,
                        duration: duration,
                      ),
                      Expanded(
                        child: i == states.length - 1
                            ? const SizedBox.shrink()
                            : _Connector(
                                color:
                                    states[i] == AsrStageState.done ||
                                        states[i] == AsrStageState.skipped
                                    ? colors.accent
                                    : colors.muted.withValues(alpha: 0.4),
                                duration: duration,
                              ),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  AnimatedDefaultTextStyle(
                    duration: duration,
                    style: labelStyle.copyWith(
                      color: switch (states[i]) {
                        AsrStageState.active => colors.strong,
                        AsrStageState.failed => colors.error,
                        AsrStageState.done => colors.soft,
                        AsrStageState.skipped ||
                        AsrStageState.pending => colors.muted,
                      },
                      fontWeight: states[i] == AsrStageState.active
                          ? FontWeight.w600
                          : null,
                    ),
                    child: Text(
                      asrPipelineStageLabel(AsrPipelineStage.values[i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector({required this.color, required this.duration});

  final Color color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: duration,
      curve: FushiMotion.standard,
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      // 2dp 细线两端全圆角 = M3 的 full 形状（胶囊），不写像素圆角。
      decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
    );
  }
}

class _StageMarker extends StatelessWidget {
  const _StageMarker({
    required this.state,
    required this.size,
    required this.accent,
    required this.muted,
    required this.error,
    required this.duration,
    super.key,
  });

  final AsrStageState state;
  final double size;
  final Color accent;
  final Color muted;
  final Color error;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (state) {
      AsrStageState.done => FushiIcon(
        FushiIcons.success,
        size: size,
        color: accent,
      ),
      AsrStageState.skipped => FushiTooltip(
        message: t.audiobook_transcribe_stage_state_skipped,
        child: FushiIcon(FushiIcons.removeCircle, size: size, color: muted),
      ),
      AsrStageState.failed => FushiIcon(
        FushiIcons.error,
        size: size,
        color: error,
      ),
      AsrStageState.pending => FushiIcon(
        FushiIcons.radioUnchecked,
        size: size,
        color: muted,
      ),
      // 当前：实心圆点外加一圈淡色光环，比相邻两格大一号。
      AsrStageState.active => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent.withValues(alpha: 0.22),
        ),
        child: Container(
          width: size * 0.55,
          height: size * 0.55,
          decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
        ),
      ),
    };
    return SizedBox.square(
      dimension: size,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        transitionBuilder: (Widget c, Animation<double> a) => FadeTransition(
          opacity: fushiUnitClamped(a),
          child: ScaleTransition(scale: a, child: c),
        ),
        child: KeyedSubtree(key: ValueKey<AsrStageState>(state), child: child),
      ),
    );
  }
}

/// 进度条 + 右侧百分比。确定值按 [FushiMotion.medium] 补间（引擎事件是一跳一跳
/// 的，补间让条平滑走过去；减弱动态效果时归零即直跳）；[value] 为 null 时是不定
/// 态，不显示百分比。
class AsrSmoothedProgressBar extends StatelessWidget {
  const AsrSmoothedProgressBar({
    required this.value,
    this.foreground,
    super.key,
  });

  final double? value;

  /// 百分比文字色（tonal 色块上的配对前景）；null = 页面前景。
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final double? target = value?.clamp(0.0, 1.0);
    if (target == null) {
      return const FushiLinearProgressIndicator(value: null);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double v, Widget? _) {
        final double shown = v.clamp(0.0, 1.0);
        return Row(
          children: <Widget>[
            Expanded(child: FushiLinearProgressIndicator(value: shown)),
            const SizedBox(width: 12),
            Text(
              formatAsrPercent(shown),
              key: const ValueKey<String>('asr-progress-percent'),
              style: context.fushiType.labelLarge.tabular.copyWith(
                color: foreground,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 覆盖情况的着色档 → 标签色调。
FushiTagTone asrCoverageTone(AudiobookCoverageTier tier) => switch (tier) {
  AudiobookCoverageTier.excellent => FushiTagTone.success,
  AudiobookCoverageTier.acceptable => FushiTagTone.warning,
  AudiobookCoverageTier.poor => FushiTagTone.error,
};

/// 「正文覆盖 97.3%」的百分比文字（一位小数，向下取整同 [formatAsrPercent]）。
String formatAsrCoveragePercent(double rate) =>
    ((rate.clamp(0.0, 1.0) * 1000).floor() / 10).toStringAsFixed(1);

/// 一行文字版（任务行、无障碍）：「正文覆盖 97.3% · 命中 1234/1260 句」；没有
/// 字符覆盖率时只有后半。
String asrCoverageSentence(AudiobookTextCoverage coverage) {
  final String cues = t.audiobook_transcribe_coverage_cues(
    matched: coverage.matchedCues,
    total: coverage.totalCues,
  );
  final double? rate = coverage.charRate;
  if (rate == null) return cues;
  return '${t.audiobook_transcribe_coverage_text(pct: formatAsrCoveragePercent(rate))}'
      ' · $cues';
}

/// 覆盖情况：着色的覆盖率标签（≥98% 绿 / 96%~98% 橙 / <96% 红，按设计系统取色）
/// + 命中 cue 数。[caption] 非 null 时放在最前（如「上次匹配正文」）。
class AsrCoverageSummary extends StatelessWidget {
  const AsrCoverageSummary({
    required this.coverage,
    this.caption,
    this.foreground,
    super.key,
  });

  final AudiobookTextCoverage coverage;
  final String? caption;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final double? rate = coverage.charRate;
    final String cues = t.audiobook_transcribe_coverage_cues(
      matched: coverage.matchedCues,
      total: coverage.totalCues,
    );
    final TextStyle style = context.fushiType.bodySmall.tabular.copyWith(
      color: foreground,
    );
    return Semantics(
      label: asrCoverageSentence(coverage),
      excludeSemantics: true,
      child: Wrap(
        key: const ValueKey<String>('asr-coverage-summary'),
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (caption != null) Text(caption!, style: style),
          FushiTag(
            key: ValueKey<String>('asr-coverage-tag-${coverage.tier.name}'),
            text: rate == null
                ? cues
                : t.audiobook_transcribe_coverage_text(
                    pct: formatAsrCoveragePercent(rate),
                  ),
            tone: asrCoverageTone(coverage.tier),
            dense: true,
          ),
          if (rate != null) Text(cues, style: style),
        ],
      ),
    );
  }
}
