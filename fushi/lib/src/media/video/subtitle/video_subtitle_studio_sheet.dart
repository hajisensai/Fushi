/// 「字幕工作台」面板（反馈 E1pq561P2q，维护者批示：把「自动生成字幕」那块改成工作台
/// 样式，带各种可参考信息与开关）。
///
/// 上半是**参考**：当前画面截图、当前字幕的语言、播放头前后几句主字幕与同一时刻的
/// 其它语言字幕（副字幕轨）逐句对照——两个开关分别管画面与其它语言字幕显示与否；
/// 表格随播放实时滚动，点某句跳过去。中间是**交给 AI 的参考**（spec
/// `2026-11-11-video-subtitle-ai-reference`）：上面这两样不只给人看——「生成字幕」开着
/// AI 校对时，画面（开关，首次说明会发送什么）与其它语言字幕会真的交给 AI。下半是**工具**：生成字幕（原入口，管线 / 本机
/// 转录分流不变）、拆出双语字幕中的日语、按每句语音逐句对轴（模型重定时）、按内嵌
/// 字幕对齐。
///
/// 面板只渲染与分派：每个工具都是视频页注入的回调（编排、落盘、换轨、OSD 都在视频
/// 页既有路径里），点了先关面板再跑，跑的过程照旧由视频页提示。ASR / 重定时算法在
/// 上游 `fushi-subtitles`，双语拆分是 `fushi_engine` 的纯函数。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 参考区的数据源。全部是**读取函数**而不是快照：面板开着时视频照常播，
/// [listenable]（播放位置推送）一响就按当前值重算对照表。
class VideoSubtitleStudioReference {
  const VideoSubtitleStudioReference({
    required this.listenable,
    required this.primaryCues,
    required this.secondaryCues,
    required this.primaryPositionMs,
    required this.secondaryPositionMs,
    required this.primaryLanguage,
    this.captureFrame,
    this.jumpToCue,
  });

  /// 播放位置变化的推送源（视频页给 `positionMsListenable`）。
  final Listenable listenable;

  /// 当前主字幕轨的 cue（文本轨；图形字幕没有 cue）。
  final List<AudioCue> Function() primaryCues;

  /// 当前副字幕轨（其它语言字幕）的 cue；没选副字幕时为空。
  final List<AudioCue> Function() secondaryCues;

  /// 主 / 副字幕各自的「查 cue 用等效位置」（已扣各自的调轴偏移）。
  final int Function() primaryPositionMs;
  final int Function() secondaryPositionMs;

  /// 主字幕正文语言（视频页开面板时检测一次）；决定「拆出日语」能不能点。
  final SubtitleContentLanguage primaryLanguage;

  /// 截取当前画面（裸画面 JPEG）；null = 这种播放来源截不了，不显示画面开关。
  final Future<Uint8List?> Function()? captureFrame;

  /// 点对照表某句跳过去；null = 只读。
  final void Function(AudioCue cue)? jumpToCue;
}

/// 画面现在发不到 AI 手里的原因（面板写在「参考画面」那一行下面）。
enum VideoSubtitleStudioFramesProblem {
  /// 「字幕校对」没指派提供商。
  noProvider,

  /// 指派的提供商没开图片输入。
  providerRejectsImages,

  /// 不是本机视频文件，管线取不到画面。
  notLocalFile,
}

/// 「交给 AI 的参考」区的数据源（视频页注入）。全部是读取函数：开关改完面板现读。
class VideoSubtitleStudioAiReference {
  const VideoSubtitleStudioAiReference({
    required this.framesEnabled,
    required this.setFramesEnabled,
    required this.framesProblem,
  });

  /// 「参考画面」开关的现值（设备本地偏好，与生成面板里的是同一个）。
  final bool Function() framesEnabled;

  /// 改「参考画面」。打开时由实现负责首次的「会发送什么」说明；用户没同意就不改。
  final Future<void> Function(BuildContext context, bool value)
  setFramesEnabled;

  /// 画面现在发不出去的原因；null = 发得出去。
  final VideoSubtitleStudioFramesProblem? Function() framesProblem;
}

/// 工具区的动作。null = 当前视频用不了这一项（面板显示原因、按钮置灰）。
class VideoSubtitleStudioActions {
  const VideoSubtitleStudioActions({
    this.generate,
    this.splitBilingual,
    this.retime,
    this.alignEmbedded,
  });

  /// 生成字幕（原「生成字幕」入口：管线 / 本机转录分流）。
  final Future<void> Function()? generate;

  /// 拆出双语字幕中的日语（只在主字幕被检测为中日双语时可点）。
  final Future<void> Function()? splitBilingual;

  /// 按每句语音逐句对轴（模型重定时）。
  final Future<void> Function()? retime;

  /// 按视频内嵌文本字幕轨对齐。
  final Future<void> Function()? alignEmbedded;
}

/// 对照表的一行：主字幕一句 + 同一时刻的其它语言字幕。
class VideoSubtitleStudioRow {
  const VideoSubtitleStudioRow({
    required this.cue,
    required this.current,
    required this.secondaryText,
  });

  final AudioCue cue;

  /// 播放头正落在这一句里。
  final bool current;

  /// 与这一句时间重叠的副字幕正文（多句用换行连）；没有重叠为 null。
  final String? secondaryText;
}

/// **纯函数**：播放头附近的对照表。
///
/// 以「起点 ≤ 播放头的最后一句」为锚（播放头在第一句之前时锚在第一句），取它前后
/// 各 [around] 句。副字幕按 [secondaryShiftMs]（= 副等效位置 − 主等效位置）把主句的
/// 时间窗平移到副字幕轴上再找重叠，两条轨各自的调轴偏移因此都算进去了。
/// 渲染专用 cue（ASS 矢量绘图）和空文本 cue 不进表。
List<VideoSubtitleStudioRow> videoSubtitleStudioRows({
  required List<AudioCue> primary,
  required List<AudioCue> secondary,
  required int primaryPositionMs,
  required int secondaryShiftMs,
  int around = 2,
}) {
  final List<AudioCue> cues = <AudioCue>[
    for (final AudioCue c in primary)
      if (!c.isRenderOnly && c.text.trim().isNotEmpty) c,
  ];
  if (cues.isEmpty) return const <VideoSubtitleStudioRow>[];
  int anchor = 0;
  for (int i = 0; i < cues.length; i++) {
    if (cues[i].startMs <= primaryPositionMs) {
      anchor = i;
    } else {
      break;
    }
  }
  final int from = (anchor - around).clamp(0, cues.length - 1);
  final int to = (anchor + around).clamp(0, cues.length - 1);
  return <VideoSubtitleStudioRow>[
    for (int i = from; i <= to; i++)
      VideoSubtitleStudioRow(
        cue: cues[i],
        current:
            cues[i].startMs <= primaryPositionMs &&
            primaryPositionMs < cues[i].endMs,
        secondaryText: _overlappingText(
          secondary,
          cues[i].startMs + secondaryShiftMs,
          cues[i].endMs + secondaryShiftMs,
        ),
      ),
  ];
}

String? _overlappingText(List<AudioCue> cues, int startMs, int endMs) {
  final List<String> texts = <String>[
    for (final AudioCue c in cues)
      if (!c.isRenderOnly &&
          c.text.trim().isNotEmpty &&
          c.startMs < endMs &&
          startMs < c.endMs)
        c.text.trim(),
  ];
  return texts.isEmpty ? null : texts.join('\n');
}

/// **纯函数**：播放器里一条字幕轨 → 交给 AI 校对的参考轨（`SubtitleEvidenceTrack`）。
///
/// [delayMs] 是这条轨在播放器里的调轴偏移：cue 的时刻加上它才是视频时间（播放器查
/// cue 用 `位置 − 偏移`），所以用户眼前对齐成什么样，AI 拿到的就是什么样。渲染专用
/// cue 与空文本不收；语言按文字判（判不出 → null：不知道是什么语言的轨不能当参考）。
/// 与目标语言相同的轨由管线那头丢掉（`SubtitleEvidenceWithPinnedTracks`）。
SubtitleEvidenceTrack? videoSubtitleStudioEvidenceTrack({
  required List<AudioCue> cues,
  required int delayMs,
  required String label,
}) {
  final List<SubtitleEvidenceCue> lines =
      <SubtitleEvidenceCue>[
        for (final AudioCue c in cues)
          if (!c.isRenderOnly &&
              c.text.trim().isNotEmpty &&
              c.endMs > c.startMs)
            SubtitleEvidenceCue(
              startMs: c.startMs + delayMs,
              endMs: c.endMs + delayMs,
              text: c.text.trim(),
              role: classifyPlainEvidenceText(c.text),
            ),
      ]..sort(
        (SubtitleEvidenceCue a, SubtitleEvidenceCue b) =>
            a.startMs.compareTo(b.startMs),
      );
  if (lines.isEmpty) return null;
  final String? language = detectSubtitleTextLanguage(<String>[
    for (final SubtitleEvidenceCue c in lines) c.text,
  ]);
  if (language == null) return null;
  return SubtitleEvidenceTrack(
    label: label,
    kind: SubtitleEvidenceKind.text,
    language: language,
    cues: lines,
  );
}

/// `m:ss`（≥1 小时 `h:mm:ss`）。
String videoSubtitleStudioClock(int ms) {
  final int v = ms < 0 ? 0 : ms;
  final int h = v ~/ 3600000;
  final int m = (v ~/ 60000) % 60;
  final String s = ((v ~/ 1000) % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// 当前字幕语言的显示名（母语写法，与字幕搜索同口径）；检测不出时「语言未知」。
String videoSubtitleStudioLanguageLabel(SubtitleContentLanguage language) =>
    subtitleContentLanguageNativeLabel(language) ??
    t.video_subtitle_studio_language_unknown;

/// 打开字幕工作台（桌面对话框 / 移动端底部 sheet，同「生成字幕」面板）。
Future<void> showVideoSubtitleStudioSheet({
  required BuildContext context,
  required VideoSubtitleStudioReference reference,
  required VideoSubtitleStudioActions actions,
  VideoSubtitleStudioAiReference? aiReference,
}) {
  Widget build(BuildContext ctx) => VideoSubtitleStudioSheet(
    reference: reference,
    actions: actions,
    aiReference: aiReference,
  );
  if (isDesktopPlatform) {
    return showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 640,
        maxHeightFactor: 0.9,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<void>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

class VideoSubtitleStudioSheet extends StatefulWidget {
  const VideoSubtitleStudioSheet({
    super.key,
    required this.reference,
    required this.actions,
    this.aiReference,
  });

  final VideoSubtitleStudioReference reference;
  final VideoSubtitleStudioActions actions;

  /// 「交给 AI 的参考」区；null = 这个视频走不了带 AI 校对的生成管线，不显示这一区。
  final VideoSubtitleStudioAiReference? aiReference;

  @override
  State<VideoSubtitleStudioSheet> createState() =>
      _VideoSubtitleStudioSheetState();
}

class _VideoSubtitleStudioSheetState extends State<VideoSubtitleStudioSheet> {
  VideoSubtitleStudioReference get _ref => widget.reference;

  bool _showFrame = true;
  bool _showSecondary = true;

  Uint8List? _frame;
  bool _capturing = false;
  bool _frameFailed = false;

  @override
  void initState() {
    super.initState();
    if (_ref.captureFrame != null) unawaited(_capture());
  }

  Future<void> _capture() async {
    final Future<Uint8List?> Function()? capture = _ref.captureFrame;
    if (capture == null || _capturing) return;
    setState(() {
      _capturing = true;
      _frameFailed = false;
    });
    Uint8List? bytes;
    try {
      bytes = await capture();
    } on Exception catch (error, stack) {
      // 截不到就在面板里说「截不到当前画面」，原因留日志可查。
      ErrorLogService.instance.log('video.subtitleStudioFrame', error, stack);
      bytes = null;
    }
    if (!mounted) return;
    setState(() {
      _capturing = false;
      _frame = bytes ?? _frame;
      _frameFailed = bytes == null;
    });
  }

  /// 工具都会起自己的弹层 / OSD：先关工作台再跑，免得两层面板叠着。
  Future<void> _run(Future<void> Function() action) async {
    await Navigator.of(context).maybePop();
    await action();
  }

  bool get _bilingual =>
      _ref.primaryLanguage == SubtitleContentLanguage.bilingualJaZh;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoSubtitleStudioAiReference? ai = widget.aiReference;
    final int toolsAt = ai == null ? 2 : 5;
    final List<Widget> sections = <Widget>[
      _sectionTitle(0, t.video_subtitle_studio_reference_label),
      _referenceCard(context, 1),
      if (ai != null) ...<Widget>[
        _sectionTitle(2, t.video_subtitle_studio_ai_label),
        ..._aiRows(context, ai, 3),
      ],
      _sectionTitle(toolsAt, t.video_subtitle_studio_tools_label),
      ..._toolRows(context, toolsAt + 1),
    ];
    return FushiModalSheetFrame(
      title: t.video_subtitle_studio_title,
      leadingIcon: FushiIcons.subtitles,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        ),
      ),
      footer: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FushiTextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ),
    );
  }

  Widget _sectionTitle(int index, String label) => FushiStaggeredEntrance(
    index: index,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(label, style: context.fushiType.titleSmallEmphasized),
    ),
  );

  Widget _hint(String text, {Key? key}) =>
      Text(text, key: key, style: FushiDesignTokens.of(context).type.metadata);

  Widget _toggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    required Key key,
  }) => Row(
    children: <Widget>[
      Expanded(child: Text(label, style: context.fushiType.bodyMedium)),
      KeyedSubtree(
        key: key,
        child: adaptiveSwitch(
          context: context,
          value: value,
          onChanged: onChanged,
        ),
      ),
    ],
  );

  // ── 参考 ────────────────────────────────────────────────────────────────

  Widget _referenceCard(BuildContext context, int index) {
    return FushiStaggeredEntrance(
      index: index,
      child: FushiGroupedListItem(
        index: 0,
        count: 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: <Widget>[
              _hint(
                t.video_subtitle_studio_track_language(
                  language: videoSubtitleStudioLanguageLabel(
                    _ref.primaryLanguage,
                  ),
                ),
                key: const ValueKey<String>('video-subtitle-studio-language'),
              ),
              if (_ref.captureFrame != null) ...<Widget>[
                _toggle(
                  t.video_subtitle_studio_show_frame,
                  _showFrame,
                  (bool v) => setState(() => _showFrame = v),
                  key: const ValueKey<String>('video-subtitle-studio-frame'),
                ),
                FushiAnimatedSize(
                  duration: context.fushiMotion.spatialDefault.duration,
                  curve: context.fushiMotion.spatialDefault.curve,
                  alignment: Alignment.topCenter,
                  child: _showFrame
                      ? _framePreview(context)
                      : const SizedBox(width: double.infinity),
                ),
              ],
              _toggle(
                t.video_subtitle_studio_show_secondary,
                _showSecondary,
                (bool v) => setState(() => _showSecondary = v),
                key: const ValueKey<String>('video-subtitle-studio-secondary'),
              ),
              ListenableBuilder(
                listenable: _ref.listenable,
                builder: (BuildContext context, _) => _comparison(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _framePreview(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Uint8List? frame = _frame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radii.control),
              child: ColoredBox(
                color: tokens.surfaces.overlay,
                child: frame != null
                    ? Image.memory(
                        frame,
                        key: const ValueKey<String>(
                          'video-subtitle-studio-frame-image',
                        ),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : Center(
                        child: _capturing
                            ? const SizedBox(
                                width: 120,
                                child: FushiLinearProgressIndicator(),
                              )
                            : const FushiIcon(FushiIcons.image, size: 32),
                      ),
              ),
            ),
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: _frameFailed
                  ? _hint(t.video_subtitle_studio_frame_unavailable)
                  : const SizedBox.shrink(),
            ),
            FushiPressScale(
              child: FushiOutlinedButton.icon(
                key: const ValueKey<String>('video-subtitle-studio-capture'),
                icon: const FushiIcon(FushiIcons.refresh, size: 18),
                label: Text(t.video_subtitle_studio_frame_refresh),
                onPressed: _capturing ? null : () => unawaited(_capture()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _comparison(BuildContext context) {
    final List<AudioCue> secondary = _ref.secondaryCues();
    final int primaryPos = _ref.primaryPositionMs();
    final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioRows(
      primary: _ref.primaryCues(),
      secondary: _showSecondary ? secondary : const <AudioCue>[],
      primaryPositionMs: primaryPos,
      secondaryShiftMs: _ref.secondaryPositionMs() - primaryPos,
    );
    if (rows.isEmpty) {
      return _hint(
        t.video_subtitle_studio_no_primary,
        key: const ValueKey<String>('video-subtitle-studio-no-primary'),
      );
    }
    final bool showSecondary = _showSecondary && secondary.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_showSecondary && secondary.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _hint(
              t.video_subtitle_studio_no_secondary,
              key: const ValueKey<String>('video-subtitle-studio-no-secondary'),
            ),
          ),
        for (final VideoSubtitleStudioRow row in rows)
          _comparisonRow(context, row, showSecondary),
      ],
    );
  }

  Widget _comparisonRow(
    BuildContext context,
    VideoSubtitleStudioRow row,
    bool showSecondary,
  ) {
    final void Function(AudioCue cue)? jump = _ref.jumpToCue;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle primaryStyle = row.current
        ? context.fushiType.titleSmallEmphasized
        : context.fushiType.bodyMedium;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(row.cue.text.trim(), style: primaryStyle),
        if (showSecondary)
          Text(
            row.secondaryText ?? '—',
            style: context.fushiType.bodySmall.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
      ],
    );
    final Widget tile = FushiListTileControl(
      key: ValueKey<String>('video-subtitle-studio-row-${row.cue.startMs}'),
      dense: true,
      selected: row.current,
      leading: Text(
        videoSubtitleStudioClock(row.cue.startMs),
        style: context.fushiType.labelSmall.copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      title: content,
      onTap: jump == null ? null : () => jump(row.cue),
    );
    return jump == null
        ? tile
        : FushiTooltip(
            message: t.video_subtitle_studio_jump_tooltip,
            child: tile,
          );
  }

  // ── 交给 AI 的参考 ────────────────────────────────────────────────────────

  Future<void> _setAiFrames(VideoSubtitleStudioAiReference ai, bool on) async {
    await ai.setFramesEnabled(context, on);
    if (mounted) setState(() {});
  }

  /// 副字幕的语言名（给「其它语言字幕」那行）；没选副字幕 → null。
  String? _secondaryLanguageLabel() {
    final List<AudioCue> secondary = _ref.secondaryCues();
    final String text = <String>[
      for (final AudioCue c in secondary)
        if (!c.isRenderOnly && c.text.trim().isNotEmpty) c.text,
    ].join('\n');
    if (text.isEmpty) return null;
    return videoSubtitleStudioLanguageLabel(
      detectSubtitleContentLanguage(text),
    );
  }

  List<Widget> _aiRows(
    BuildContext context,
    VideoSubtitleStudioAiReference ai,
    int firstIndex,
  ) {
    final VideoSubtitleStudioFramesProblem? problem = ai.framesProblem();
    final bool framesOn = ai.framesEnabled();
    final String framesHint = switch (problem) {
      null => t.video_subtitle_ai_frames_hint,
      VideoSubtitleStudioFramesProblem.noProvider =>
        t.video_subtitle_ai_no_provider,
      VideoSubtitleStudioFramesProblem.providerRejectsImages =>
        t.video_subtitle_ai_frames_unsupported,
      VideoSubtitleStudioFramesProblem.notLocalFile =>
        t.video_subtitle_studio_ai_frames_not_local,
    };
    final bool framesLocked =
        problem == VideoSubtitleStudioFramesProblem.notLocalFile;
    final String? secondaryLanguage = _secondaryLanguageLabel();
    return <Widget>[
      FushiStaggeredEntrance(
        index: firstIndex,
        child: FushiGroupedListItem(
          index: 0,
          count: 2,
          child: FushiListTileControl(
            key: const ValueKey<String>('video-subtitle-studio-ai-frames'),
            leading: const FushiIcon(FushiIcons.image),
            title: Text(t.video_subtitle_ai_frames_label),
            subtitle: Text(
              framesHint,
              key: const ValueKey<String>(
                'video-subtitle-studio-ai-frames-hint',
              ),
            ),
            enabled: !framesLocked,
            trailing: KeyedSubtree(
              key: const ValueKey<String>(
                'video-subtitle-studio-ai-frames-switch',
              ),
              child: adaptiveSwitch(
                context: context,
                value: framesOn && !framesLocked,
                onChanged: framesLocked
                    ? null
                    : (bool v) => unawaited(_setAiFrames(ai, v)),
              ),
            ),
          ),
        ),
      ),
      FushiStaggeredEntrance(
        index: firstIndex + 1,
        child: FushiGroupedListItem(
          index: 1,
          count: 2,
          child: FushiListTileControl(
            key: const ValueKey<String>('video-subtitle-studio-ai-subtitles'),
            leading: const FushiIcon(FushiIcons.language),
            title: Text(t.video_subtitle_studio_show_secondary),
            subtitle: Text(
              secondaryLanguage == null
                  ? t.video_subtitle_studio_ai_subtitles_auto
                  : t.video_subtitle_studio_ai_subtitles_secondary(
                      language: secondaryLanguage,
                    ),
              key: const ValueKey<String>(
                'video-subtitle-studio-ai-subtitles-hint',
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: _hint(
          t.video_subtitle_studio_ai_scope_hint,
          key: const ValueKey<String>('video-subtitle-studio-ai-scope'),
        ),
      ),
    ];
  }

  // ── 工具 ────────────────────────────────────────────────────────────────

  List<Widget> _toolRows(BuildContext context, int firstIndex) {
    final VideoSubtitleStudioActions a = widget.actions;
    final List<
      ({
        String key,
        IconData icon,
        String title,
        String hint,
        Future<void> Function()? action,
      })
    >
    tools =
        <
          ({
            String key,
            IconData icon,
            String title,
            String hint,
            Future<void> Function()? action,
          })
        >[
          (
            key: 'generate',
            icon: FushiIcons.subtitles,
            title: t.video_subtitle_ai_generate_title,
            hint: a.generate == null
                ? t.video_subtitle_studio_needs_audio
                : t.video_subtitle_generate_entry_hint,
            action: a.generate,
          ),
          (
            key: 'split',
            icon: FushiIcons.language,
            title: t.video_subtitle_studio_split_action,
            hint: _bilingual && a.splitBilingual != null
                ? t.video_subtitle_studio_split_hint
                : t.video_subtitle_studio_split_not_bilingual,
            action: _bilingual ? a.splitBilingual : null,
          ),
          (
            key: 'retime',
            icon: FushiIcons.modelTraining,
            title: t.video_subtitle_retime_action,
            hint: a.retime == null
                ? t.video_subtitle_studio_needs_audio
                : t.video_subtitle_studio_retime_hint,
            action: a.retime,
          ),
          (
            key: 'align',
            icon: FushiIcons.sync,
            title: t.video_subtitle_reference_sync_action,
            hint: a.alignEmbedded == null
                ? t.video_subtitle_studio_needs_local_file
                : t.video_subtitle_studio_align_hint,
            action: a.alignEmbedded,
          ),
        ];
    return <Widget>[
      for (int i = 0; i < tools.length; i++)
        FushiStaggeredEntrance(
          index: firstIndex + i,
          child: FushiGroupedListItem(
            index: i,
            count: tools.length,
            child: FushiPressScale(
              child: FushiListTileControl(
                key: ValueKey<String>('video-subtitle-studio-${tools[i].key}'),
                leading: FushiIcon(tools[i].icon),
                title: Text(tools[i].title),
                subtitle: Text(tools[i].hint),
                enabled: tools[i].action != null,
                onTap: switch (tools[i].action) {
                  null => null,
                  final Future<void> Function() action => () => unawaited(
                    _run(action),
                  ),
                },
              ),
            ),
          ),
        ),
    ];
  }
}
