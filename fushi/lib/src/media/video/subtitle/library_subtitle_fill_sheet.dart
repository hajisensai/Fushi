/// 「补齐字幕」面板（视频库多选批量栏 / 合集详情页共用）：选目标语言与补齐方式
/// （OCR / 下载 / 本机生成），先「预览」看每集会怎么补，再「开始」；跑着时显示进度、
/// 各结局计数与逐集结果，可取消；跑完可「撤销这次」。
///
/// 编排全部在 [LibrarySubtitleFillController]（与 `fushi_cli video sub-fill` 同一个
/// 入口）：面板只渲染它的状态。关掉面板不会停任务，重开接回同一个任务。
library;

import 'dart:async';

import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_controller.dart';
import 'package:fushi/src/models/app_model.dart';
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
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 面板可选的目标语言（下载 / 内封 / OCR 任何语言都行；本机生成只认 ja / zh，
/// 其它语言由编排层把「生成」这一步记为跳过）。
const List<String> kSubtitleFillLanguages = <String>['ja', 'zh', 'en'];

/// 打开面板。[bookUids] 为 null = 全库。
Future<void> showLibrarySubtitleFillSheet({
  required BuildContext context,
  required AppModel appModel,
  required List<String>? bookUids,
}) {
  Widget build(BuildContext ctx) =>
      LibrarySubtitleFillSheet(appModel: appModel, bookUids: bookUids);
  if (isDesktopPlatform) {
    return showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 560,
        maxHeightFactor: 0.85,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<void>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    builder: build,
  );
}

/// 结局的显示名。
String subtitleFillActionLabel(SubtitleFillAction action) => switch (action) {
  SubtitleFillAction.alreadyCovered =>
    t.video_subtitle_fill_action_already_covered,
  SubtitleFillAction.userDisabled => t.video_subtitle_fill_action_user_disabled,
  SubtitleFillAction.skipped => t.video_subtitle_fill_action_skipped,
  SubtitleFillAction.planned => t.video_subtitle_fill_action_planned,
  SubtitleFillAction.selectedEmbedded =>
    t.video_subtitle_fill_action_selected_embedded,
  SubtitleFillAction.ocr => t.video_subtitle_fill_action_ocr,
  SubtitleFillAction.downloaded => t.video_subtitle_fill_action_downloaded,
  SubtitleFillAction.downloadedRetimed =>
    t.video_subtitle_fill_action_downloaded_retimed,
  SubtitleFillAction.generated => t.video_subtitle_fill_action_generated,
  SubtitleFillAction.failed => t.video_subtitle_fill_action_failed,
  SubtitleFillAction.cancelled => t.video_subtitle_fill_action_cancelled,
};

/// 面板本体。
class LibrarySubtitleFillSheet extends StatefulWidget {
  const LibrarySubtitleFillSheet({
    super.key,
    required this.appModel,
    required this.bookUids,
  });

  final AppModel appModel;
  final List<String>? bookUids;

  @override
  State<LibrarySubtitleFillSheet> createState() =>
      _LibrarySubtitleFillSheetState();
}

class _LibrarySubtitleFillSheetState extends State<LibrarySubtitleFillSheet> {
  /// 逐集结果只显示最近这么多条（整库几百集，全列出来面板会很长）。
  static const int _recentLimit = 40;

  late final LibrarySubtitleFillController _controller =
      librarySubtitleFillController(widget.appModel);
  LibrarySubtitleFillJob? _job;
  String _language = 'ja';
  bool _ocr = true;
  bool _download = true;
  bool _generate = true;
  bool _starting = false;
  bool _undoing = false;
  bool _undone = false;

  @override
  void initState() {
    super.initState();
    // 重开面板接回正在跑的任务。
    _attach(_controller.active);
  }

  @override
  void dispose() {
    _job?.removeListener(_onJob);
    super.dispose();
  }

  void _attach(LibrarySubtitleFillJob? job) {
    if (identical(job, _job)) return;
    _job?.removeListener(_onJob);
    _job = job;
    job?.addListener(_onJob);
    if (job != null) {
      _language = job.options.language;
      _ocr = job.options.allowOcr;
      _download = job.options.allowDownload;
      _generate = job.options.allowGenerate;
    }
  }

  void _onJob() {
    if (mounted) setState(() {});
  }

  bool get _running => _job?.isRunning ?? false;

  Future<void> _start({required bool dryRun}) async {
    setState(() => _starting = true);
    try {
      final LibrarySubtitleFillJob job = await _controller.start(
        LibrarySubtitleFillOptions(
          language: _language,
          allowOcr: _ocr,
          allowDownload: _download,
          allowGenerate: _generate,
          dryRun: dryRun,
        ),
        bookUids: widget.bookUids,
      );
      if (!mounted) return;
      setState(() {
        _attach(job);
        _undone = false;
      });
    } on LibrarySubtitleFillBusy catch (busy) {
      FushiToast.show(msg: t.video_subtitle_fill_busy);
      if (mounted) setState(() => _attach(busy.active));
    } on Object catch (error) {
      FushiToast.show(
        msg: t.video_subtitle_fill_failed_start(error: '$error'),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _undo() async {
    final LibrarySubtitleFillJob? job = _job;
    if (job == null) return;
    setState(() => _undoing = true);
    try {
      final int restored = await _controller.undo(job.id);
      FushiToast.show(msg: t.video_subtitle_fill_undone(n: restored));
      if (mounted) setState(() => _undone = true);
    } on Object catch (error) {
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<(String, Widget)> parts = <(String, Widget)>[
      (t.video_subtitle_fill_language_label, _languageControl()),
      (t.video_subtitle_fill_methods_label, _methodsControl()),
    ];
    final LibrarySubtitleFillJob? job = _job;
    final Widget body = FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < parts.length; i++)
            _section(i, parts.length, parts[i].$1, parts[i].$2),
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap),
            child: Text(
              t.video_subtitle_fill_hint,
              style: tokens.type.metadata,
            ),
          ),
          FushiAnimatedSize(
            duration: context.fushiMotion.spatialDefault.duration,
            curve: context.fushiMotion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: job == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.rowVertical),
                    child: FushiStaggeredEntrance(
                      index: parts.length,
                      child: _jobView(context, tokens, job),
                    ),
                  ),
          ),
        ],
      ),
    );
    final Widget footer = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: _footerButtons(context),
    );
    return FushiModalSheetFrame(
      title: t.video_subtitle_fill_title,
      subtitle: widget.bookUids == null
          ? null
          : t.video_subtitle_fill_scope_count(n: widget.bookUids!.length),
      leadingIcon: FushiIcons.subtitles,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: body,
      footer: footer,
    );
  }

  Widget _section(int index, int count, String label, Widget child) =>
      FushiStaggeredEntrance(
        index: index,
        child: FushiGroupedListItem(
          index: index,
          count: count,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(label, style: context.fushiType.titleSmallEmphasized),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ),
      );

  Widget _languageControl() => KeyedSubtree(
    key: const ValueKey<String>('subtitle-fill-language'),
    child: adaptiveSegmentedButton<String>(
      context: context,
      segments: <ButtonSegment<String>>[
        for (final String code in kSubtitleFillLanguages)
          ButtonSegment<String>(
            value: code,
            label: Text(
              jimakuLanguageLabel(code),
              key: ValueKey<String>('subtitle-fill-language-$code'),
            ),
          ),
      ],
      selected: <String>{_language},
      onSelectionChanged: (Set<String> s) {
        if (_running) return;
        setState(() => _language = s.first);
      },
    ),
  );

  Widget _methodsControl() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _toggleRow(
        'subtitle-fill-ocr',
        t.video_subtitle_fill_method_ocr,
        _ocr,
        (bool v) => setState(() => _ocr = v),
      ),
      _toggleRow(
        'subtitle-fill-download',
        t.video_subtitle_fill_method_download,
        _download,
        (bool v) => setState(() => _download = v),
      ),
      _toggleRow(
        'subtitle-fill-generate',
        t.video_subtitle_fill_method_generate,
        _generate,
        (bool v) => setState(() => _generate = v),
      ),
    ],
  );

  Widget _toggleRow(
    String key,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: <Widget>[
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        KeyedSubtree(
          key: ValueKey<String>(key),
          child: adaptiveSwitch(
            context: context,
            value: value,
            onChanged: _running ? null : onChanged,
          ),
        ),
      ],
    ),
  );

  Widget _jobView(
    BuildContext context,
    FushiDesignTokens tokens,
    LibrarySubtitleFillJob job,
  ) {
    final List<SubtitleFillOutcome> recent = job.outcomes.length <= _recentLimit
        ? job.outcomes.reversed.toList()
        : job.outcomes
              .sublist(job.outcomes.length - _recentLimit)
              .reversed
              .toList();
    final String counts = <String>[
      for (final MapEntry<SubtitleFillAction, int> e in job.counts.entries)
        '${subtitleFillActionLabel(e.key)} ${e.value}',
    ].join(' · ');
    return Column(
      key: const ValueKey<String>('subtitle-fill-job'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${job.outcomes.length} / ${job.total}'
                '${job.options.dryRun ? ' · ${t.video_subtitle_fill_preview}' : ''}',
                style: context.fushiType.titleSmallEmphasized,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        FushiLinearProgressIndicator(
          value: job.total == 0 ? 1 : job.outcomes.length / job.total,
        ),
        if (counts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(counts, style: tokens.type.metadata),
          ),
        const SizedBox(height: 8),
        FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < recent.length; i++)
                FushiStaggeredEntrance(
                  key: ValueKey<String>(
                    'subtitle-fill-row-${recent[i].bookUid}',
                  ),
                  index: i,
                  child: FushiListItem(
                    density: FushiListDensity.compact,
                    title: Text(recent[i].title),
                    subtitle: Text(_outcomeLine(recent[i])),
                    subtitleMaxLines: 2,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _outcomeLine(SubtitleFillOutcome o) {
    final List<String> parts = <String>[
      subtitleFillActionLabel(o.action),
      if (o.matchPercent != null) '${o.matchPercent}%',
      if (o.detail != null && o.detail!.isNotEmpty) o.detail!,
    ];
    return parts.join(' · ');
  }

  List<Widget> _footerButtons(BuildContext context) {
    final LibrarySubtitleFillJob? job = _job;
    final List<Widget> buttons = <Widget>[
      FushiTextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t.dialog_close),
      ),
    ];
    if (job != null && job.isRunning) {
      buttons.add(
        FushiFilledButton.icon(
          key: const ValueKey<String>('subtitle-fill-cancel'),
          icon: const FushiIcon(FushiIcons.stop, size: 18),
          label: Text(t.cancel),
          onPressed: job.cancelRequested ? null : job.cancel,
        ),
      );
      return buttons;
    }
    final bool canUndo =
        job != null &&
        !job.options.dryRun &&
        !_undone &&
        job.outcomes.any(
          (SubtitleFillOutcome o) => o.wroteFile || o.selectionChanged,
        );
    if (canUndo) {
      buttons.add(
        FushiPressScale(
          child: FushiTextButton(
            key: const ValueKey<String>('subtitle-fill-undo'),
            onPressed: _undoing ? null : () => unawaited(_undo()),
            child: Text(t.video_subtitle_fill_undo),
          ),
        ),
      );
    }
    buttons.addAll(<Widget>[
      FushiPressScale(
        child: FushiTextButton(
          key: const ValueKey<String>('subtitle-fill-preview'),
          onPressed: _starting ? null : () => unawaited(_start(dryRun: true)),
          child: Text(t.video_subtitle_fill_preview),
        ),
      ),
      FushiPressScale(
        child: FushiFilledButton.icon(
          key: const ValueKey<String>('subtitle-fill-start'),
          icon: const FushiIcon(FushiIcons.play, size: 18),
          label: Text(t.video_subtitle_fill_start),
          onPressed: _starting ? null : () => unawaited(_start(dryRun: false)),
        ),
      ),
    ]);
    return buttons;
  }
}
