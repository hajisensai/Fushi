/// 图形字幕整轨转文字的进度卡：阶段（准备引擎 / 读取字幕轨 / 逐条识别）、百分比、
/// 实际使用的识别引擎与 AI 重读来源、取消按钮。
///
/// 以前只有每 10% 一条的 OSD，抽轨阶段（大文件要读几分钟）整段没有任何反馈，也看不出
/// 用的是哪个引擎、AI 开没开。卡片常驻到任务结束，不挡画面中央（挂在视频右上角）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiAppleLinearProgress, FushiCircularProgressIndicator, FushiTooltip;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/video/video_side_panel.dart'
    show VideoFloatingPanelSurface;
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl, FushiTextButton;
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
    this.aiDone = 0,
    this.aiTotal = 0,
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

  /// 大模型重读：已回 / 已排队条数（本地识别与重读并行，重读在后台批量进行）。
  final int aiDone;
  final int aiTotal;

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
    int? aiDone,
    int? aiTotal,
  }) => GraphicSubtitleOcrJobState(
    phase: phase ?? this.phase,
    processed: processed ?? this.processed,
    duration: duration ?? this.duration,
    done: done ?? this.done,
    total: total ?? this.total,
    engineLabel: engineLabel ?? this.engineLabel,
    aiLabel: aiLabel ?? this.aiLabel,
    aiDone: aiDone ?? this.aiDone,
    aiTotal: aiTotal ?? this.aiTotal,
  );

  /// 当前阶段的一行说明（含百分比）。
  String statusText() {
    final double? f = fraction;
    final int percent = f == null ? 0 : (f * 100).floor();
    return switch (phase) {
      GraphicSubtitleOcrJobPhase.preparing =>
        t.video_subtitle_graphic_ocr_job_preparing,
      // 边读边识别：已经有字补进播放器时把条数一起报出来。
      GraphicSubtitleOcrJobPhase.extracting when done > 0 =>
        t.video_subtitle_graphic_ocr_job_extracting_live(
          percent: percent,
          done: done,
        ),
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

/// 进度卡。右上角「收起」把整张卡缩成一枚小药丸（图标 + 进度环 + 百分比），不再挡画面；
/// 点药丸再展开。收起状态跟着这张卡的 State 走，同一个任务的进度刷新不会把它弹开。
class VideoGraphicSubtitleOcrProgressCard extends StatefulWidget {
  const VideoGraphicSubtitleOcrProgressCard({
    required this.state,
    required this.onCancel,
    super.key,
  });

  final GraphicSubtitleOcrJobState state;
  final VoidCallback onCancel;

  @override
  State<VideoGraphicSubtitleOcrProgressCard> createState() =>
      _VideoGraphicSubtitleOcrProgressCardState();
}

class _VideoGraphicSubtitleOcrProgressCardState
    extends State<VideoGraphicSubtitleOcrProgressCard> {
  bool _collapsed = false;

  void _setCollapsed(bool value) {
    if (_collapsed == value) return;
    setState(() => _collapsed = value);
  }

  @override
  Widget build(BuildContext context) {
    // 表面交给播放器浮层的统一表面：Apple 液态玻璃 / M3E 中性深色（面板中性主题
    // 重走主题工厂，浅色主题下前景也是亮色，BUG-3273）/ 墨水屏实色描边。卡片自己
    // 不再挑底色与前景，否则 Apple 下是一块 M3 深色卡、墨水屏下半透明。
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.topLeft,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              alignment: Alignment.topLeft,
              scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
              child: child,
            ),
          ),
      child: _collapsed ? _buildPill() : _buildCard(),
    );
  }

  /// 药丸高度，也是它的命中区高度（整颗药丸都是 InkWell）。
  static const double _pillHeight = 40;

  Widget _buildPill() {
    final GraphicSubtitleOcrJobState state = widget.state;
    final double? fraction = state.fraction;
    final String status = state.statusText();
    return VideoFloatingPanelSurface(
      key: const ValueKey<String>('graphic_subtitle_ocr_progress_pill'),
      borderRadius: BorderRadius.circular(_pillHeight / 2),
      glassRadius: _pillHeight / 2,
      child: Builder(
        builder: (BuildContext context) {
          final ThemeData theme = Theme.of(context);
          final ColorScheme scheme = theme.colorScheme;
          return FushiTooltip(
            message: status,
            child: InkWell(
              onTap: () => _setCollapsed(false),
              child: Semantics(
                button: true,
                label: '${t.video_subtitle_graphic_ocr_track} · $status',
                excludeSemantics: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: _pillHeight,
                    minWidth: _pillHeight,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox.square(
                          dimension: 20,
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              FushiCircularProgressIndicator(
                                value: fraction,
                                strokeWidth: 2,
                                color: scheme.primary,
                              ),
                              Icon(
                                FushiIcons.ocr,
                                size: 11,
                                color: scheme.onSurface,
                              ),
                            ],
                          ),
                        ),
                        if (fraction != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Text(
                            '${(fraction * 100).floor()}%',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurface,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 2),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard() {
    return ConstrainedBox(
      key: const ValueKey<String>('graphic_subtitle_ocr_progress_card_box'),
      constraints: const BoxConstraints(maxWidth: 340),
      child: VideoFloatingPanelSurface(
        surfaceKey: const ValueKey<String>(
          'graphic_subtitle_ocr_progress_card',
        ),
        borderRadius: FushiM3eShape.cardRadius,
        child: Builder(builder: _buildCardBody),
      ),
    );
  }

  Widget _buildCardBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final GraphicSubtitleOcrJobState state = widget.state;
    final double? fraction = state.fraction;
    final String? engine = state.engineLabel;
    final TextStyle? meta = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
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
                Icon(FushiIcons.ocr, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.video_subtitle_graphic_ocr_track,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                FushiIconButton(
                  key: const ValueKey<String>(
                    'graphic_subtitle_ocr_progress_collapse',
                  ),
                  icon: FushiIcons.expandLess,
                  tooltip: t.video_subtitle_adjust_collapse,
                  size: 20,
                  onTap: () => _setCollapsed(true),
                ),
                FushiIconButton(
                  icon: FushiIcons.close,
                  tooltip: t.dialog_cancel,
                  size: 20,
                  onTap: widget.onCancel,
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
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    child: Text(
                      state.statusText(),
                      key: ValueKey<String>(
                        'graphic_ocr_status_${state.phase.name}',
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (isGlassDesign(context))
                    FushiAppleLinearProgress(
                      value: fraction,
                      semanticsLabel: state.statusText(),
                    )
                  else
                    FushiWavyLinearProgress(
                      value: fraction,
                      color: scheme.primary,
                      trackColor: scheme.secondaryContainer,
                      semanticsLabel: state.statusText(),
                    ),
                  if (engine != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      t.video_subtitle_graphic_ocr_job_engine(engine: engine),
                      style: meta,
                    ),
                    Text(
                      state.aiLabel == null
                          ? t.video_subtitle_graphic_ocr_job_ai_off
                          : state.aiTotal > 0
                          ? t.video_subtitle_graphic_ocr_job_ai_progress(
                              provider: state.aiLabel!,
                              done: state.aiDone,
                              total: state.aiTotal,
                            )
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
  const VideoGraphicSubtitleOcrStatusPill({
    required this.status,
    this.graphicSubtitle = true,
    super.key,
  });

  final GraphicSubtitlePauseOcrStatus status;

  /// 这一帧是不是图片字幕帧。「所有视频」档下普通画面也会识别，那时说「识别画面
  /// 文字」，不说「识别字幕」（BUG-3342：画面上根本没有字幕时文案对不上）。
  final bool graphicSubtitle;

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
          child: FushiCircularProgressIndicator(
            strokeWidth: 1.6,
            color: scheme.onInverseSurface,
          ),
        ),
        text: graphicSubtitle
            ? t.video_subtitle_graphic_ocr_status_recognizing
            : t.video_subtitle_frame_ocr_status_recognizing,
      ),
      GraphicSubtitlePauseOcrStatus.ready => _pill(
        context,
        leading: Icon(
          FushiIcons.success,
          size: 14,
          color: scheme.inversePrimary,
        ),
        text: graphicSubtitle
            ? t.video_subtitle_graphic_ocr_status_ready
            : t.video_subtitle_frame_ocr_status_ready,
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

/// 暂停到图片字幕帧、而暂停 OCR 关着时的提示（BUG-3342）：图片字幕要 OCR 才能点字
/// 查词，给一个「开启」和一个关掉本次提示的按钮。识别默认关闭、由用户手动开启；文本
/// 字幕与没有字幕的视频不出现这条提示（判据见 `VideoPauseOcrScope.offersEnableHint`）。
class VideoPauseOcrEnableHint extends StatelessWidget {
  const VideoPauseOcrEnableHint({
    required this.onEnable,
    required this.onDismiss,
    super.key,
  });

  /// 开启暂停 OCR（页面写偏好）。
  final VoidCallback onEnable;

  /// 本次播放不再提示。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String text = t.video_subtitle_graphic_ocr_enable_hint;
    return DecoratedBox(
      key: const ValueKey<String>('graphic_subtitle_ocr_enable_hint'),
      decoration: ShapeDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.82),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(FushiIcons.ocr, size: 14, color: scheme.onInverseSurface),
            const SizedBox(width: 6),
            Flexible(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onInverseSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            FushiPressScale(
              child: FushiTextButton(
                key: const ValueKey<String>(
                  'graphic_subtitle_ocr_enable_button',
                ),
                onPressed: onEnable,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.inversePrimary,
                ),
                child: Text(t.video_subtitle_graphic_ocr_enable_action),
              ),
            ),
            FushiIconButtonControl(
              key: const ValueKey<String>(
                'graphic_subtitle_ocr_enable_dismiss',
              ),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: Icon(
                FushiIcons.close,
                size: 16,
                color: scheme.onInverseSurface,
              ),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
