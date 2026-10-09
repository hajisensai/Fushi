/// 图形字幕整轨转文字的进度卡：阶段（准备引擎 / 读取字幕轨 / 逐条识别）、百分比、
/// 实际使用的识别引擎与 AI 重读来源、取消按钮。
///
/// 以前只有每 10% 一条的 OSD，抽轨阶段（大文件要读几分钟）整段没有任何反馈，也看不出
/// 用的是哪个引擎、AI 开没开。卡片常驻到任务结束，不挡画面中央（挂在视频右上角）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart'
    show videoM3eFloatingColor;
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

/// 整轨转文字的阶段。
enum GraphicSubtitleOcrJobPhase {
  /// 解析识别引擎（本机探测 / Lens 上传同意）。
  preparing,

  /// 抽字幕轨（要读完整个容器，进度 = 已读到的媒体时间 / 片长）。
  extracting,

  /// 逐条识别。
  recognizing,
}

/// 进度卡的显示状态（不可变，页面每次进度变化换一个新值）。
@immutable
class GraphicSubtitleOcrJobState {
  const GraphicSubtitleOcrJobState({
    required this.phase,
    this.processed = Duration.zero,
    this.duration,
    this.done = 0,
    this.total = 0,
    this.engineLabel,
    this.aiLabel,
  });

  final GraphicSubtitleOcrJobPhase phase;

  /// 抽轨阶段已读到的媒体时间。
  final Duration processed;

  /// 片长；未知（直播流 / 还没解析出来）时为 null，进度条转不定态。
  final Duration? duration;

  /// 识别阶段：已完成 / 总条数。
  final int done;
  final int total;

  /// 实际识别引擎（引擎解析前为 null）。
  final String? engineLabel;

  /// AI 重读来源；null = 没开。只在 [engineLabel] 非空后有意义。
  final String? aiLabel;

  /// 0..1；不定态返回 null。
  double? get fraction => switch (phase) {
    GraphicSubtitleOcrJobPhase.preparing => null,
    GraphicSubtitleOcrJobPhase.extracting =>
      duration == null || duration! <= Duration.zero
          ? null
          : (processed.inMicroseconds / duration!.inMicroseconds).clamp(
              0.0,
              1.0,
            ),
    GraphicSubtitleOcrJobPhase.recognizing =>
      total <= 0 ? null : (done / total).clamp(0.0, 1.0),
  };

  GraphicSubtitleOcrJobState copyWith({
    GraphicSubtitleOcrJobPhase? phase,
    Duration? processed,
    Duration? duration,
    int? done,
    int? total,
    String? engineLabel,
    String? aiLabel,
  }) => GraphicSubtitleOcrJobState(
    phase: phase ?? this.phase,
    processed: processed ?? this.processed,
    duration: duration ?? this.duration,
    done: done ?? this.done,
    total: total ?? this.total,
    engineLabel: engineLabel ?? this.engineLabel,
    aiLabel: aiLabel ?? this.aiLabel,
  );

  /// 当前阶段的一行说明（含百分比）。
  String statusText() {
    final double? f = fraction;
    final int percent = f == null ? 0 : (f * 100).floor();
    return switch (phase) {
      GraphicSubtitleOcrJobPhase.preparing =>
        t.video_subtitle_graphic_ocr_job_preparing,
      GraphicSubtitleOcrJobPhase.extracting =>
        f == null
            ? t.video_subtitle_graphic_ocr_extracting
            : t.video_subtitle_graphic_ocr_job_extracting(percent: percent),
      GraphicSubtitleOcrJobPhase.recognizing =>
        t.video_subtitle_graphic_ocr_job_recognizing(
          done: done,
          total: total,
          percent: percent,
        ),
    };
  }
}

/// 识别引擎的显示名（与漫画 OCR 设置里的引擎名同一套文案）。本机 ONNX 带上模型名。
String graphicSubtitleOcrEngineLabel(
  MangaOcrEngineId engine, {
  required String localModelKey,
}) => switch (engine) {
  MangaOcrEngineId.localOnnx => t.manga_ocr_engine_local_model(
    model: localModelLabel(MangaOcrLocalModel.fromKey(localModelKey)),
  ),
  MangaOcrEngineId.systemOcr => t.manga_ocr_engine_system,
  MangaOcrEngineId.googleLens => t.manga_ocr_engine_google_lens,
  MangaOcrEngineId.externalMokuro => t.manga_ocr_engine_external,
  MangaOcrEngineId.pairedHost => t.manga_remote_ocr_engine,
};

/// 引擎偏好的显示名（开始前的确认框用；`auto` 还没解析出具体引擎）。
String graphicSubtitleOcrPreferenceLabel(
  MangaOcrEnginePreference preference, {
  required String localModelKey,
}) => switch (preference.explicitEngine) {
  null => t.manga_ocr_engine_auto,
  final MangaOcrEngineId engine => graphicSubtitleOcrEngineLabel(
    engine,
    localModelKey: localModelKey,
  ),
};

/// 进度卡。
class VideoGraphicSubtitleOcrProgressCard extends StatelessWidget {
  const VideoGraphicSubtitleOcrProgressCard({
    required this.state,
    required this.onCancel,
    super.key,
  });

  final GraphicSubtitleOcrJobState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double? fraction = state.fraction;
    final String? engine = state.engineLabel;
    final TextStyle? meta = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Material(
        key: const ValueKey<String>('graphic_subtitle_ocr_progress_card'),
        // 与播放器其它浮层（设置 / 章节面板）同一中性深色表面令牌。
        color: videoM3eFloatingColor(scheme),
        elevation: 3,
        shape: const RoundedRectangleBorder(
          borderRadius: FushiM3eShape.cardRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 14),
          child: FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      FushiIcons.ocr,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.video_subtitle_graphic_ocr_track,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FushiIconButton(
                      icon: FushiIcons.close,
                      tooltip: t.dialog_cancel,
                      size: 20,
                      onTap: onCancel,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AnimatedSwitcher(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        child: Text(
                          state.statusText(),
                          key: ValueKey<String>(
                            'graphic_ocr_status_${state.phase.name}',
                          ),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FushiWavyLinearProgress(
                        value: fraction,
                        color: scheme.primary,
                        trackColor: scheme.secondaryContainer,
                        semanticsLabel: state.statusText(),
                      ),
                      if (engine != null) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          t.video_subtitle_graphic_ocr_job_engine(
                            engine: engine,
                          ),
                          style: meta,
                        ),
                        Text(
                          state.aiLabel == null
                              ? t.video_subtitle_graphic_ocr_job_ai_off
                              : t.video_subtitle_graphic_ocr_job_ai_on(
                                  provider: state.aiLabel!,
                                ),
                          style: meta,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 暂停自动 OCR 的状态（[VideoGraphicSubtitleOcrStatusPill]）。
enum GraphicSubtitlePauseOcrStatus {
  /// 没在识别、也没有结果（播放中 / 非图形轨）。
  idle,

  /// 正在截帧识别。
  recognizing,

  /// 识别出了可点的字。
  ready,

  /// 识别完了但这一帧没有字。
  empty,
}

/// 暂停自动 OCR 的轻量状态标记：识别中显示小转圈，识别完给一个「已识别 · 点字查词」
/// 的小药丸，几秒后淡出，不挡字幕、不抢焦点、不响应点击。
class VideoGraphicSubtitleOcrStatusPill extends StatelessWidget {
  const VideoGraphicSubtitleOcrStatusPill({required this.status, super.key});

  final GraphicSubtitlePauseOcrStatus status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Widget? content = switch (status) {
      GraphicSubtitlePauseOcrStatus.idle => null,
      GraphicSubtitlePauseOcrStatus.recognizing => _pill(
        context,
        leading: SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: scheme.onInverseSurface,
          ),
        ),
        text: t.video_subtitle_graphic_ocr_status_recognizing,
      ),
      GraphicSubtitlePauseOcrStatus.ready => _pill(
        context,
        leading: Icon(
          FushiIcons.success,
          size: 14,
          color: scheme.inversePrimary,
        ),
        text: t.video_subtitle_graphic_ocr_status_ready,
      ),
      GraphicSubtitlePauseOcrStatus.empty => _pill(
        context,
        leading: Icon(
          FushiIcons.subtitlesOff,
          size: 14,
          color: scheme.onInverseSurface,
        ),
        text: t.video_subtitle_graphic_ocr_status_empty,
      ),
    };
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        transitionBuilder: (Widget child, Animation<double> animation) =>
            FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1).animate(animation),
                child: child,
              ),
            ),
        child: content == null
            ? const SizedBox.shrink(key: ValueKey<String>('graphic_ocr_idle'))
            : KeyedSubtree(
                key: ValueKey<GraphicSubtitlePauseOcrStatus>(status),
                child: content,
              ),
      ),
    );
  }

  Widget _pill(
    BuildContext context, {
    required Widget leading,
    required String text,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      label: text,
      child: DecoratedBox(
        key: const ValueKey<String>('graphic_subtitle_ocr_status_pill'),
        decoration: ShapeDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.72),
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              leading,
              const SizedBox(width: 6),
              Text(
                text,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onInverseSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
