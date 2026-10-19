/// 作品专名表编辑页（spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节 S0、
/// 第 9 节「写法拿不准」）：列表增删改（正式写法 / 读音 / 类别 / 误写 / 说明），每次
/// 改动立即存进 `video_subtitle_glossaries`（改过的条目标 `userEdited`，重新生成时
/// 保留）；「重新生成」再调一次 AI；「只重跑写法统一」删掉 S4 之后的产物按新表重跑
/// （只花 S4 的费用）。
///
/// 专名表校验没通过时，面板把候选表交过来（[VideoSubtitleGlossaryPage.candidate]）：
/// 页面先显示候选、用户改一条（或点「采用」）就存下，回面板点「继续」即续跑。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart'
    show SubtitleAiRequestFailure;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart'
    show SubtitleGlossaryValidationFailure;

import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleEpisodeResult;

import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart'
    show videoSubtitleAiFailureText;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 误写一栏的分隔：半角 / 全角逗号与顿号都认。
final RegExp _kListSeparator = RegExp('[,，、]');

/// 纯函数：把「误写」输入框的文字拆成列表（去空白、去空项、去重，保持顺序）。
List<String> parseGlossaryMisrecognitions(String raw) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String part in raw.split(_kListSeparator))
      if (part.trim().isNotEmpty && seen.add(part.trim())) part.trim(),
  ];
}

class VideoSubtitleGlossaryPage extends StatefulWidget {
  const VideoSubtitleGlossaryPage({
    super.key,
    required this.service,
    required this.target,
    required this.openAiSettings,
    this.candidate,
  });

  final AppVideoSubtitleService service;

  /// 这张表属于哪部作品（[AppVideoSubtitleTarget.work]），「只重跑写法统一」跑哪些集。
  final AppVideoSubtitleTarget target;
  final Future<void> Function(BuildContext context) openAiSettings;

  /// 校验没通过的候选表（未保存）；非 null 时页面先显示它。
  final List<SubtitleGlossaryEntry>? candidate;

  @override
  State<VideoSubtitleGlossaryPage> createState() =>
      _VideoSubtitleGlossaryPageState();
}

enum _EntryAction { edit, delete }

class _VideoSubtitleGlossaryPageState extends State<VideoSubtitleGlossaryPage> {
  AppVideoSubtitleService get _service => widget.service;

  bool _loading = true;
  SubtitleGlossary? _saved;
  List<SubtitleGlossaryEntry> _entries = const <SubtitleGlossaryEntry>[];

  /// 正在看的是未保存的候选表。
  bool _candidateMode = false;
  bool _busy = false;
  String? _notice;
  AppVideoSubtitleJob? _rerun;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _rerun?.removeListener(_onRerun);
    super.dispose();
  }

  Future<void> _load() async {
    final SubtitleGlossary? saved = await _service.loadGlossary(
      widget.target.work,
    );
    if (!mounted) return;
    final List<SubtitleGlossaryEntry>? candidate = widget.candidate;
    setState(() {
      _saved = saved;
      _candidateMode = candidate != null;
      _entries = candidate ?? saved?.entries ?? const <SubtitleGlossaryEntry>[];
      _loading = false;
    });
  }

  Future<void> _persist(List<SubtitleGlossaryEntry> next) async {
    // 调用方都是 unawaited 的按钮回调：写库失败不接住就成了未捕获的 zone 错误，
    // 用户看不到任何反馈、还以为改动已经存下。
    final SubtitleGlossary saved;
    try {
      saved = await _service.saveGlossary(
        widget.target.work,
        next,
        previous: _candidateMode ? null : _saved,
      );
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _notice = t.video_subtitle_glossary_save_failed(reason: '$e'),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _entries = saved.entries;
      _candidateMode = false;
      // 存下来之后，之前的保存失败提示 / 候选表横幅都已不再成立。
      _notice = null;
    });
  }

  String? _validateJa(String value, {SubtitleGlossaryEntry? editing}) {
    final String v = value.trim();
    if (v.isEmpty) return t.video_subtitle_glossary_ja_empty;
    final bool duplicate = _entries.any(
      (SubtitleGlossaryEntry e) => !identical(e, editing) && e.ja == v,
    );
    return duplicate ? t.video_subtitle_glossary_ja_duplicate : null;
  }

  Future<void> _add() async {
    final SubtitleGlossaryEntry? created = await _editDialog(null);
    if (created == null) return;
    await _persist(<SubtitleGlossaryEntry>[..._entries, created]);
  }

  Future<void> _edit(SubtitleGlossaryEntry entry) async {
    final SubtitleGlossaryEntry? edited = await _editDialog(entry);
    if (edited == null) return;
    await _persist(<SubtitleGlossaryEntry>[
      for (final SubtitleGlossaryEntry e in _entries)
        identical(e, entry) ? edited : e,
    ]);
  }

  Future<void> _delete(SubtitleGlossaryEntry entry) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.video_subtitle_glossary_delete,
      message: t.video_subtitle_glossary_delete_confirm(ja: entry.ja),
      confirmLabel: t.video_subtitle_glossary_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok) return;
    await _persist(<SubtitleGlossaryEntry>[
      for (final SubtitleGlossaryEntry e in _entries)
        if (!identical(e, entry)) e,
    ]);
  }

  /// 采用候选表原样保存（不改任何一条）。
  Future<void> _acceptCandidate() => _persist(_entries);

  Future<void> _regenerate() async {
    if (_service.proofreadProvider == null) {
      setState(() => _notice = t.video_subtitle_ai_no_provider);
      return;
    }
    final int kept = _entries
        .where((SubtitleGlossaryEntry e) => e.userEdited)
        .length;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.video_subtitle_glossary_regenerate,
      message: t.video_subtitle_glossary_regenerate_confirm(n: kept),
      confirmLabel: t.video_subtitle_glossary_regenerate,
      cancelLabel: t.cancel,
      icon: FushiIcons.refresh,
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final SubtitleGlossary glossary = await _service.regenerateGlossary(
        widget.target,
      );
      if (!mounted) return;
      setState(() {
        _saved = glossary;
        _entries = glossary.entries;
        _candidateMode = false;
        _notice = t.video_subtitle_glossary_regenerated(
          n: glossary.entries.length,
        );
      });
    } on SubtitleGlossaryValidationFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _entries = failure.candidate;
        _candidateMode = true;
        _notice = t.video_subtitle_glossary_candidate_banner;
      });
    } on SubtitleAiRequestFailure catch (failure) {
      if (mounted) {
        setState(
          () => _notice = t.video_subtitle_ai_status_paused(
            reason: videoSubtitleAiFailureText(failure.reason),
          ),
        );
      }
    } on AppVideoSubtitleStartRefused {
      if (mounted) setState(() => _notice = t.video_subtitle_ai_no_provider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rerunConsistency() async {
    try {
      final AppVideoSubtitleJob job = await _service.startConsistencyRerun(
        widget.target,
      );
      if (!mounted) return;
      _rerun?.removeListener(_onRerun);
      setState(() {
        _rerun = job..addListener(_onRerun);
        _notice = null;
      });
    } on AppVideoSubtitleStartRefused catch (refused) {
      if (!mounted) return;
      setState(
        () => _notice = switch (refused.problem) {
          AppVideoSubtitleStartProblem.noProvider =>
            t.video_subtitle_ai_no_provider,
          AppVideoSubtitleStartProblem.busy => t.video_subtitle_ai_busy(
            title: refused.activeJob?.target.title ?? '',
          ),
          AppVideoSubtitleStartProblem.noLocalEpisodes =>
            t.video_subtitle_ai_no_local_episodes,
          AppVideoSubtitleStartProblem.nothingToRerun =>
            t.video_subtitle_ai_nothing_to_rerun,
        },
      );
    }
  }

  void _onRerun() {
    if (mounted) setState(() {});
  }

  Future<SubtitleGlossaryEntry?> _editDialog(SubtitleGlossaryEntry? entry) {
    return showAppDialog<SubtitleGlossaryEntry>(
      context: context,
      builder: (BuildContext context) => _GlossaryEntryDialog(
        entry: entry,
        validateJa: (String v) => _validateJa(v, editing: entry),
      ),
    );
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  List<FushiToolbarItem> get _actions => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('video-subtitle-glossary-add'),
      icon: FushiIcons.add,
      label: t.video_subtitle_glossary_add,
      onPressed: _loading || _busy ? null : () => unawaited(_add()),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('video-subtitle-glossary-regenerate'),
      icon: FushiIcons.refresh,
      label: t.video_subtitle_glossary_regenerate,
      onPressed: _loading || _busy ? null : () => unawaited(_regenerate()),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('video-subtitle-glossary-rerun'),
      icon: FushiIcons.play,
      label: t.video_subtitle_glossary_rerun_consistency,
      onPressed: _loading || _busy || (_rerun?.isRunning ?? false)
          ? null
          : () => unawaited(_rerunConsistency()),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.video_subtitle_glossary_title,
      subtitle: widget.target.work.japaneseTitle,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              for (final FushiToolbarItem item in _actions)
                FushiIconButton(
                  key: item.key,
                  icon: item.icon,
                  tooltip: item.label,
                  enabled: item.onPressed != null,
                  onTap: item.onPressed,
                ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      // 动作默认全部平铺，放不下才按优先级（最后一个最先）收进「⋯」。
      child: FushiFloatingTopBar(
        title: t.video_subtitle_glossary_title,
        subtitle: widget.target.work.japaneseTitle,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_actions],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AppVideoSubtitleJob? rerun = _rerun;
    final List<Widget> items = <Widget>[
      if (_busy) const FushiLinearProgressIndicator(),
      if (_candidateMode)
        FushiCard(
          key: const ValueKey<String>('video-subtitle-glossary-candidate'),
          tone: FushiCardTone.error,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: <Widget>[
              Text(t.video_subtitle_glossary_candidate_banner),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>(
                  'video-subtitle-glossary-accept-candidate',
                ),
                icon: const FushiIcon(FushiIcons.check, size: 18),
                label: Text(t.video_subtitle_glossary_accept_candidate),
                onPressed: _busy ? null : () => unawaited(_acceptCandidate()),
              ),
            ],
          ),
        ),
      if (_notice != null)
        Text(
          _notice!,
          key: const ValueKey<String>('video-subtitle-glossary-notice'),
          style: tokens.type.metadata,
        ),
      if (rerun != null) _rerunCard(rerun),
      Text(t.video_subtitle_glossary_intro, style: tokens.type.metadata),
      if (_entries.isEmpty)
        Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.edit,
            message: t.video_subtitle_glossary_empty,
          ),
        ),
      for (int i = 0; i < _entries.length; i++)
        _EntryRow(
          key: ValueKey<String>('video-subtitle-glossary-entry-$i'),
          entry: _entries[i],
          index: i,
          count: _entries.length,
          onEdit: () => unawaited(_edit(_entries[i])),
          onAction: (_EntryAction a) => unawaited(
            a == _EntryAction.edit ? _edit(_entries[i]) : _delete(_entries[i]),
          ),
        ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(height: index < items.length - _entries.length ? 8 : 0),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }

  Widget _rerunCard(AppVideoSubtitleJob job) {
    final String text = switch (job.status) {
      AppVideoSubtitleJobStatus.running =>
        t.video_subtitle_glossary_rerun_running,
      AppVideoSubtitleJobStatus.succeeded =>
        t.video_subtitle_glossary_rerun_done(
          n:
              job.result?.episodes
                  .where((VideoSubtitleEpisodeResult r) => r.exported)
                  .length ??
              0,
        ),
      AppVideoSubtitleJobStatus.cancelled =>
        t.video_subtitle_ai_status_cancelled,
      AppVideoSubtitleJobStatus.pausedAiFailure =>
        t.video_subtitle_ai_status_paused(
          reason: videoSubtitleAiFailureText(job.aiFailure?.reason ?? ''),
        ),
      AppVideoSubtitleJobStatus.glossaryInvalid =>
        t.video_subtitle_ai_status_glossary_conflicts,
      AppVideoSubtitleJobStatus.failed => t.video_subtitle_ai_status_failed(
        reason: job.errorMessage ?? '',
      ),
    };
    return FushiCard(
      key: const ValueKey<String>('video-subtitle-glossary-rerun-card'),
      tone: job.isRunning ? FushiCardTone.secondary : FushiCardTone.primary,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: <Widget>[
          Text(text),
          if (job.isRunning)
            FushiLinearProgressIndicator(value: job.progress?.fraction),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.index,
    required this.count,
    required this.onEdit,
    required this.onAction,
  });

  final SubtitleGlossaryEntry entry;
  final int index;
  final int count;
  final VoidCallback onEdit;
  final void Function(_EntryAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final List<String> meta = <String>[
      if (entry.reading.isNotEmpty) entry.reading,
      if (entry.kind.isNotEmpty) entry.kind,
      if (entry.misrecognitions.isNotEmpty)
        t.video_subtitle_glossary_misrecognitions_short(
          list: entry.misrecognitions.join('、'),
        ),
      if (entry.note.isNotEmpty) entry.note,
    ];
    return FushiPressScale(
      child: FushiGroupedListItem(
        index: index,
        count: count,
        onTap: onEdit,
        child: FushiListItem(
          leading: FushiListLeadingIcon(
            entry.isPersonName ? FushiIcons.person : FushiIcons.tag,
            tone: entry.userEdited
                ? FushiCardTone.primary
                : FushiCardTone.neutral,
          ),
          title: Text(entry.ja),
          subtitle: meta.isEmpty ? null : Text(meta.join(' · ')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (entry.userEdited)
                FushiTooltip(
                  message: t.video_subtitle_glossary_user_edited,
                  child: const FushiIcon(FushiIcons.edit, size: 16),
                ),
              FushiPopupMenuButton<_EntryAction>(
                tooltip: t.video_subtitle_glossary_entry_menu,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: onAction,
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<_EntryAction>>[
                      FushiPopupMenuItem<_EntryAction>(
                        value: _EntryAction.edit,
                        label: t.video_subtitle_glossary_edit,
                        icon: FushiIcons.edit,
                      ),
                      FushiPopupMenuItem<_EntryAction>(
                        value: _EntryAction.delete,
                        label: t.video_subtitle_glossary_delete,
                        icon: FushiIcons.delete,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条的编辑框（新增 / 修改共用）。返回编辑后的条目（`userEdited` 由服务按差异标）。
class _GlossaryEntryDialog extends StatefulWidget {
  const _GlossaryEntryDialog({required this.entry, required this.validateJa});

  final SubtitleGlossaryEntry? entry;
  final String? Function(String value) validateJa;

  @override
  State<_GlossaryEntryDialog> createState() => _GlossaryEntryDialogState();
}

class _GlossaryEntryDialogState extends State<_GlossaryEntryDialog> {
  late final TextEditingController _ja = TextEditingController(
    text: widget.entry?.ja ?? '',
  );
  late final TextEditingController _reading = TextEditingController(
    text: widget.entry?.reading ?? '',
  );
  late final TextEditingController _kind = TextEditingController(
    text: widget.entry?.kind ?? '',
  );
  late final TextEditingController _misrecognitions = TextEditingController(
    text: widget.entry?.misrecognitions.join('、') ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.entry?.note ?? '',
  );
  String? _jaError;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _ja,
      _reading,
      _kind,
      _misrecognitions,
      _note,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final String? error = widget.validateJa(_ja.text);
    if (error != null) {
      setState(() => _jaError = error);
      return;
    }
    final SubtitleGlossaryEntry base =
        widget.entry ?? SubtitleGlossaryEntry(ja: _ja.text.trim());
    Navigator.of(context).pop(
      base.copyWith(
        ja: _ja.text.trim(),
        reading: _reading.text.trim(),
        kind: _kind.text.trim(),
        misrecognitions: parseGlossaryMisrecognitions(_misrecognitions.text),
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Text(
        widget.entry == null
            ? t.video_subtitle_glossary_add
            : t.video_subtitle_glossary_edit,
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: <Widget>[
          FushiTextField(
            key: const ValueKey<String>('video-subtitle-glossary-field-ja'),
            controller: _ja,
            autofocus: true,
            labelText: t.video_subtitle_glossary_field_ja,
            errorText: _jaError,
            onChanged: (_) {
              if (_jaError != null) setState(() => _jaError = null);
            },
          ),
          FushiTextField(
            key: const ValueKey<String>(
              'video-subtitle-glossary-field-reading',
            ),
            controller: _reading,
            labelText: t.video_subtitle_glossary_field_reading,
          ),
          FushiTextField(
            key: const ValueKey<String>('video-subtitle-glossary-field-kind'),
            controller: _kind,
            labelText: t.video_subtitle_glossary_field_kind,
            helperText: t.video_subtitle_glossary_field_kind_hint,
          ),
          FushiTextField(
            key: const ValueKey<String>(
              'video-subtitle-glossary-field-misrecognitions',
            ),
            controller: _misrecognitions,
            labelText: t.video_subtitle_glossary_field_misrecognitions,
            helperText: t.video_subtitle_glossary_field_misrecognitions_hint,
          ),
          FushiTextField(
            key: const ValueKey<String>('video-subtitle-glossary-field-note'),
            controller: _note,
            labelText: t.video_subtitle_glossary_field_note,
            maxLines: 3,
            minLines: 1,
          ),
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('video-subtitle-glossary-save'),
          onPressed: _submit,
          child: Text(t.video_subtitle_glossary_save),
        ),
      ],
    );
  }
}
