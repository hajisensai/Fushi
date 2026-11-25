/// 笔记编辑页单个字段的「AI 改写 / 补全」抽屉：选任务（写释义 / 翻译 / 改写 / 自定义）与变体、
/// 按需补一句要求 → 生成 → 预览 → 「替换」或「追加到末尾」。结果只回给调用方，什么都不会在
/// 点替换 / 追加之前写进字段。
///
/// 请求在抽屉里按 [buildAiSrsFieldActionRequest] 拼（与提示词编辑页预览同一份），发送由调用方注入
/// （[SrsFieldAiSender]，生产走 `sendAiSrsFieldPrompt`，测试给假的），回复按动作的回复格式解析。
///
/// - 「新建变体」（[showSrsFieldAiNewVariantSheet]，抽屉与编辑页共用）：复制当前提示词，或从样例库
///   （`ai_srs_field_samples.dart`）挑一条；新建的变体存进去后直接打开编辑页。
/// - 动作的提示词里没有 `{{instruction}}`：要求框禁用并提示，预设按钮隐藏。
/// - 自定义任务要求为空、拼出的请求超限 / 为空：生成键禁用；认不出的占位符 / 截断 / 超限提示在
///   生成键上方。
/// - 回复读不懂：说明 + 「显示回复」（原文可选中）；结构化回复格式不对时多一个「把回复当作文字
///   使用」，按纯文本重新解析成普通结果（照旧要点替换 / 追加才写）。
library;

import 'dart:async';

import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_saved_prompt_picker.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/ai/ai_srs_field_samples.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiExpansionTile;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

/// 把拼好的两条消息原样发出去，返回模型的原始回复（失败抛 [AiChatFailure]）。
typedef SrsFieldAiSender = Future<String> Function(AiSrsFieldPrompt prompt);

/// 打开 [action] 的提示词编辑页；返回编辑页关掉时该选中的动作（复制出变体后选它；
/// null = 保持原选择，变体被删了抽屉自己退回默认）。
typedef SrsFieldAiPromptEditorOpener =
    Future<AiSrsFieldAction?> Function(
      BuildContext context,
      AiSrsFieldAction action,
    );

/// 按字段名猜默认任务：翻译类字段默认翻译，释义类默认写释义，其余改写。
AiSrsFieldTask srsDefaultFieldAiTask(String fieldName) {
  final String n = fieldName.toLowerCase();
  if (n.contains('translation') || n.contains('翻译')) {
    return AiSrsFieldTask.translate;
  }
  if (RegExp(r'definition|glossary|meaning|释义|意味').hasMatch(n)) {
    return AiSrsFieldTask.define;
  }
  return AiSrsFieldTask.rewrite;
}

String srsFieldAiTaskLabel(AiSrsFieldTask task) => switch (task) {
  AiSrsFieldTask.define => t.srs_note_field_ai_define,
  AiSrsFieldTask.translate => t.srs_note_field_ai_translate,
  AiSrsFieldTask.rewrite => t.srs_note_field_ai_rewrite,
  AiSrsFieldTask.custom => t.srs_note_field_ai_custom,
};

/// 「替换」与「追加」怎么改字段值（纯函数）。
String srsApplyFieldAi(String current, String value, {required bool append}) {
  if (!append || current.trim().isEmpty) return value;
  return '$current<br>$value';
}

/// 拼好的请求要提示用户的事：认不出的占位符、截断（提示色）、超限（错误色）。抽屉与编辑页共用。
List<Widget> srsFieldAiRequestNotices(
  BuildContext context,
  AiSrsFieldRequest request,
) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final TextStyle warn = context.fushiType.bodySmall.copyWith(
    color: scheme.tertiary,
  );
  return <Widget>[
    if (request.unknownPlaceholders.isNotEmpty)
      Text(
        t.srs_field_ai_prompt_unknown(
          names: request.unknownPlaceholders
              .map((String n) => '{{$n}}')
              .join(', '),
        ),
        key: const ValueKey<String>('srs-field-ai-notice-unknown'),
        style: warn,
      ),
    if (request.truncations.isNotEmpty)
      Text(
        t.srs_field_ai_request_truncated(
          names: <String>{
            for (final AiSrsFieldTruncation x in request.truncations)
              x.source.startsWith('note:') ? x.source.substring(5) : x.source,
          }.join(', '),
        ),
        key: const ValueKey<String>('srs-field-ai-notice-truncated'),
        style: warn,
      ),
    if (request.overLimit)
      Text(
        t.srs_field_ai_request_over_limit(
          n: request.length,
          max: kAiSrsFieldRequestMax,
        ),
        key: const ValueKey<String>('srs-field-ai-notice-over-limit'),
        style: context.fushiType.bodySmall.copyWith(color: scheme.error),
      ),
  ];
}

/// 「新建变体」里选了什么：[sample] 为 null = 复制当前提示词，否则照这条样例新建。
typedef SrsFieldAiNewVariantChoice = ({AiSrsFieldSample? sample});

/// 打开「新建变体」：第一项复制当前提示词（[canCopy] 为 false 时不可点，如编辑页里模板为空 /
/// 超长），下面是样例库，按任务分组、当前任务 [task] 的一组在最前（选别的任务的样例 = 在那个
/// 任务下新建）。返回 null = 没选。
Future<SrsFieldAiNewVariantChoice?> showSrsFieldAiNewVariantSheet(
  BuildContext context, {
  required AiSrsFieldTask task,
  bool canCopy = true,
}) => adaptiveModalSheet<SrsFieldAiNewVariantChoice>(
  context: context,
  builder: (BuildContext context) =>
      _SrsFieldAiNewVariantSheet(task: task, canCopy: canCopy),
);

class _SrsFieldAiNewVariantSheet extends StatelessWidget {
  const _SrsFieldAiNewVariantSheet({required this.task, required this.canCopy});

  final AiSrsFieldTask task;
  final bool canCopy;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle muted = context.fushiType.bodySmall.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final List<AiSrsFieldTask> order = <AiSrsFieldTask>[
      task,
      for (final AiSrsFieldTask other in AiSrsFieldTask.values)
        if (other != task) other,
    ];
    final List<Widget> children = <Widget>[
      FushiListItem(
        key: const ValueKey<String>('srs-field-ai-new-variant-copy'),
        leading: const FushiIcon(FushiIcons.copy),
        title: Text(t.srs_field_ai_prompt_new_variant_copy),
        subtitle: Text(t.srs_field_ai_prompt_new_variant_copy_hint),
        onTap: canCopy
            ? () => Navigator.of(
                context,
              ).pop<SrsFieldAiNewVariantChoice>((sample: null))
            : null,
      ),
      FushiSectionTitle(
        t.srs_field_ai_prompt_new_variant_samples,
        level: FushiSectionTitleLevel.group,
      ),
      Text(t.srs_field_ai_prompt_new_variant_samples_hint, style: muted),
      for (final AiSrsFieldTask group in order)
        if (aiSrsFieldSamplesFor(group) case final List<AiSrsFieldSample> list
            when list.isNotEmpty) ...<Widget>[
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              srsFieldAiTaskLabel(group),
              key: ValueKey<String>(
                'srs-field-ai-new-variant-group-${group.name}',
              ),
              style: context.fushiType.labelLarge,
            ),
          ),
          for (final AiSrsFieldSample sample in list)
            FushiListItem(
              key: ValueKey<String>('srs-field-ai-new-variant-${sample.id}'),
              title: Text(sample.name),
              subtitle: Text(sample.firstLine),
              onTap: () => Navigator.of(
                context,
              ).pop<SrsFieldAiNewVariantChoice>((sample: sample)),
            ),
        ],
    ];
    return FushiModalSheetFrame(
      key: const ValueKey<String>('srs-field-ai-new-variant-sheet'),
      title: t.srs_field_ai_prompt_new_variant,
      leadingIcon: FushiIcons.add,
      scrollable: true,
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap / 2,
          children: <Widget>[
            for (final (int i, Widget w) in children.indexed)
              FushiStaggeredEntrance(index: i, child: w),
          ],
        ),
      ),
    );
  }
}

/// 打开抽屉；返回字段的新值（null = 没采用）。
///
/// [note] 取拼请求用的笔记（打开时与每次生成前现取：别的字段可能刚改过）。
Future<String?> showSrsFieldAiSheet(
  BuildContext context, {
  required String fieldLabel,
  required String fieldName,
  required String current,
  required AiSrsFieldNoteContext Function() note,
  required SrsFieldAiSender send,
  AiSavedPromptStore? promptStore,
  AiSrsFieldActionStore? actionStore,
  SrsFieldAiPromptEditorOpener? editPrompt,
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext context) => SrsFieldAiSheet(
    fieldLabel: fieldLabel,
    fieldName: fieldName,
    current: current,
    note: note,
    send: send,
    promptStore: promptStore,
    actionStore: actionStore,
    editPrompt: editPrompt,
  ),
);

class SrsFieldAiSheet extends StatefulWidget {
  const SrsFieldAiSheet({
    super.key,
    required this.fieldLabel,
    required this.fieldName,
    required this.current,
    required this.note,
    required this.send,
    this.promptStore,
    this.actionStore,
    this.editPrompt,
  });

  final String fieldLabel;
  final String fieldName;
  final String current;
  final AiSrsFieldNoteContext Function() note;
  final SrsFieldAiSender send;

  /// 「已保存的提示词」的存取实现（生产 = 应用偏好仓库，测试注入内存实现）；
  /// null = 不显示该按钮。
  final AiSavedPromptStore? promptStore;

  /// 卡片字段 AI 的动作改动（提示词与变体下拉读它）；null = 只有内置、不显示变体下拉。
  final AiSrsFieldActionStore? actionStore;

  /// 「编辑提示词」；null = 不显示该按钮。
  final SrsFieldAiPromptEditorOpener? editPrompt;

  @override
  State<SrsFieldAiSheet> createState() => _SrsFieldAiSheetState();
}

class _SrsFieldAiSheetState extends State<SrsFieldAiSheet> {
  late AiSrsFieldTask _task = srsDefaultFieldAiTask(widget.fieldName);

  /// 选中的变体；null = 该任务的内置动作（原样或改过的）。
  String? _variantId;
  late AiSrsFieldActions _actions =
      widget.actionStore?.aiFieldActions ?? AiSrsFieldActions.empty;
  late AiSrsFieldNoteContext _note = widget.note();
  final TextEditingController _instruction = TextEditingController();
  bool _busy = false;

  /// 请求失败（网络 / 提供商）的文案。
  String? _error;

  /// 回复读不懂（带原始回复）。
  AiSrsFieldReplyError? _replyError;
  AiSrsFieldSuggestion? _result;

  @override
  void initState() {
    super.initState();
    _instruction.addListener(_onInstruction);
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  void _onInstruction() {
    if (mounted) setState(() {});
  }

  AiSrsFieldAction get _action =>
      AiSrsFieldAction(_task, variantId: _variantId);

  AiSrsFieldRequest _request() => buildAiSrsFieldActionRequest(
    note: _note,
    actions: _actions,
    action: _action,
    instruction: _instruction.text,
  );

  /// 自定义任务的提示词要用户的一句话、而用户什么都没写。
  bool _missingInstruction(AiSrsFieldRequest request) =>
      _task == AiSrsFieldTask.custom &&
      request.usesInstruction &&
      _instruction.text.trim().isEmpty;

  bool _canRun(AiSrsFieldRequest request) =>
      !_busy &&
      !request.overLimit &&
      !request.isEmpty &&
      !_missingInstruction(request);

  Future<void> _editPrompt(SrsFieldAiPromptEditorOpener open) async {
    final AiSrsFieldAction? picked = await open(context, _action);
    if (!mounted) return;
    setState(() {
      _actions = widget.actionStore?.aiFieldActions ?? AiSrsFieldActions.empty;
      if (picked != null) {
        _task = picked.task;
        _variantId = picked.variantId;
      }
      // 变体在编辑页里被删了 / 不属于这个任务：退回默认。
      final String? id = _variantId;
      if (id != null && _actions.variant(id)?.task != _task) _variantId = null;
    });
  }

  /// 「新建变体」：复制当前动作的提示词或照样例新建，存进去、选中它，再打开编辑页。
  Future<void> _newVariant(
    SrsFieldAiPromptEditorOpener open,
    AiSrsFieldActionStore store,
  ) async {
    final SrsFieldAiNewVariantChoice? choice =
        await showSrsFieldAiNewVariantSheet(context, task: _task);
    if (choice == null || !mounted) return;
    final AiSrsFieldActions actions = store.aiFieldActions;
    final AiSrsFieldSample? sample = choice.sample;
    final String? currentId = _variantId;
    final String base =
        (currentId == null ? null : actions.variant(currentId)?.name) ??
        srsFieldAiTaskLabel(_task);
    final (AiSrsFieldActions next, AiSrsFieldVariant created) = sample == null
        ? actions.addVariant(
            task: _task,
            name: t.srs_field_ai_prompt_copy_name(name: base),
            prompt: actions.promptFor(_action),
          )
        : actions.addVariant(
            task: sample.task,
            name: sample.name,
            prompt: sample.prompt,
          );
    await store.setAiFieldActions(next);
    if (!mounted) return;
    setState(() {
      _actions = store.aiFieldActions;
      _task = created.task ?? _task;
      _variantId = _actions.variant(created.id) == null ? null : created.id;
    });
    await _editPrompt(open);
  }

  Future<void> _generate() async {
    if (_busy) return;
    _note = widget.note();
    final AiSrsFieldRequest request = _request();
    if (!_canRun(request)) {
      setState(() {});
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _replyError = null;
    });
    try {
      final String reply = await widget.send(request.prompt);
      final AiSrsFieldSuggestion s = parseAiSrsFieldReply(reply, request.mode);
      if (mounted) setState(() => _result = s);
    } on AiChatFailure catch (failure) {
      if (mounted) {
        setState(
          () => _error = t.ai_assist_failed(
            reason: aiFailureText(failure.message),
          ),
        );
      }
    } on AiSrsFieldReplyError catch (e) {
      if (mounted) setState(() => _replyError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 结构化回复格式不对：用户明确选择把原始回复当纯文本用（仍要点替换 / 追加才写）。
  void _useReplyAsText(AiSrsFieldReplyError error) {
    try {
      final AiSrsFieldSuggestion s = parseAiSrsFieldReply(
        error.raw,
        AiSrsFieldResponseMode.plain,
      );
      setState(() {
        _replyError = null;
        _result = s;
      });
    } on AiSrsFieldReplyError catch (e) {
      setState(() => _replyError = e);
    }
  }

  /// 结果的纯文字预览（`<br>` / 块标签换行，其余标签去掉）。
  static String _plain(String html) => html
      .replaceAll(
        RegExp(r'<br\s*/?>|</(p|div|li)>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .trim();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AiSrsFieldSuggestion? result = _result;
    final List<AiSrsFieldVariant> variants = _actions.variantsFor(_task);
    final AiSrsFieldRequest request = _request();
    final bool usesInstruction = request.usesInstruction;
    final List<Widget> children = <Widget>[
      adaptiveSegmentedButton<AiSrsFieldTask>(
        context: context,
        segments: <ButtonSegment<AiSrsFieldTask>>[
          for (final AiSrsFieldTask task in AiSrsFieldTask.values)
            ButtonSegment<AiSrsFieldTask>(
              value: task,
              label: Text(srsFieldAiTaskLabel(task)),
            ),
        ],
        selected: <AiSrsFieldTask>{_task},
        onSelectionChanged: (Set<AiSrsFieldTask> s) => setState(() {
          _task = s.first;
          _variantId = null;
        }),
      ),
      if (variants.isNotEmpty || widget.editPrompt != null)
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            if (variants.isNotEmpty)
              Expanded(
                child: GamepadMenuDropdown<String>(
                  key: const ValueKey<String>('srs-field-ai-variant'),
                  label: t.srs_note_field_ai_variant_label,
                  entries: <GamepadDropdownEntry<String>>[
                    (value: '', label: t.srs_note_field_ai_variant_default),
                    for (final AiSrsFieldVariant v in variants)
                      (value: v.id, label: v.name),
                  ],
                  selected: _variantId ?? '',
                  enabled: !_busy,
                  onChanged: (String id) =>
                      setState(() => _variantId = id.isEmpty ? null : id),
                ),
              )
            else
              const Spacer(),
            if (widget.editPrompt case final SrsFieldAiPromptEditorOpener open)
              FushiTextButton.icon(
                key: const ValueKey<String>('srs-field-ai-edit-prompt'),
                icon: const FushiIcon(FushiIcons.edit),
                label: Text(t.srs_note_field_ai_prompt_edit),
                onPressed: _busy ? null : () => unawaited(_editPrompt(open)),
              ),
            if ((widget.editPrompt, widget.actionStore) case (
              final SrsFieldAiPromptEditorOpener open,
              final AiSrsFieldActionStore store,
            ))
              FushiIconButton(
                key: const ValueKey<String>('srs-field-ai-new-variant'),
                icon: FushiIcons.add,
                tooltip: t.srs_field_ai_prompt_new_variant,
                enabled: !_busy,
                onTap: () => unawaited(_newVariant(open, store)),
              ),
          ],
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: FushiTextField(
              key: const ValueKey<String>('srs-field-ai-instruction'),
              controller: _instruction,
              enabled: usesInstruction && !_busy,
              hintText: _task == AiSrsFieldTask.custom
                  ? t.srs_note_field_ai_custom_hint
                  : t.srs_note_field_ai_instruction_hint,
              minLines: 1,
              maxLines: 4,
              onSubmitted: (_) => unawaited(_generate()),
            ),
          ),
          if (usesInstruction)
            if (widget.promptStore case final AiSavedPromptStore store)
              AiSavedPromptButton(
                scene: AiPromptScene.srsField,
                controller: _instruction,
                enabled: !_busy,
                storeOf: () => store,
                builtinFilter: (AiSavedPrompt p) =>
                    aiSrsFieldBuiltinPresetVisible(p, _task),
              ),
        ],
      ),
      if (!usesInstruction)
        Text(
          t.srs_note_field_ai_instruction_unused,
          key: const ValueKey<String>('srs-field-ai-instruction-unused'),
          style: context.fushiType.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ...srsFieldAiRequestNotices(context, request),
      Row(
        spacing: tokens.spacing.gap,
        children: <Widget>[
          FushiFilledButton.icon(
            key: const ValueKey<String>('srs-field-ai-run'),
            icon: const FushiIcon(FushiIcons.aiAssistant),
            label: Text(
              result == null ? t.srs_visual_ai_run : t.srs_note_field_ai_again,
            ),
            onPressed: _canRun(request) ? () => unawaited(_generate()) : null,
          ),
          if (_busy)
            const SizedBox.square(
              dimension: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: _error == null
            ? const SizedBox(width: double.infinity)
            : Text(
                _error!,
                key: const ValueKey<String>('srs-field-ai-error'),
                style: context.fushiType.bodySmall.copyWith(
                  color: scheme.error,
                ),
              ),
      ),
      FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: switch (_replyError) {
          null => const SizedBox(width: double.infinity),
          final AiSrsFieldReplyError e => _replyErrorCard(context, e),
        },
      ),
      FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.short),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: result == null
            ? const SizedBox(width: double.infinity)
            : _resultCard(context, result),
      ),
    ];
    return FushiModalSheetFrame(
      key: const ValueKey<String>('srs-field-ai-sheet'),
      title: t.srs_note_field_ai_title(field: widget.fieldLabel),
      leadingIcon: FushiIcons.aiAssistant,
      scrollable: true,
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            for (final (int i, Widget w) in children.indexed)
              FushiStaggeredEntrance(index: i, child: w),
          ],
        ),
      ),
    );
  }

  Widget _replyErrorCard(BuildContext context, AiSrsFieldReplyError error) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool malformed = error.kind == AiSrsFieldReplyErrorKind.malformed;
    return FushiCard(
      key: const ValueKey<String>('srs-field-ai-reply-error'),
      tone: FushiCardTone.neutral,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            malformed
                ? t.srs_note_field_ai_reply_unreadable
                : t.ai_assist_empty,
            key: const ValueKey<String>('srs-field-ai-reply-error-text'),
            style: context.fushiType.bodyMedium.copyWith(color: scheme.error),
          ),
          if (error.raw.trim().isNotEmpty)
            FushiExpansionTile(
              key: const ValueKey<String>('srs-field-ai-show-reply'),
              title: Text(t.srs_note_field_ai_show_reply),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SelectableText(
                  error.raw,
                  key: const ValueKey<String>('srs-field-ai-raw-reply'),
                  style: context.fushiType.bodySmall.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          if (malformed)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FushiOutlinedButton.icon(
                key: const ValueKey<String>('srs-field-ai-use-as-text'),
                icon: const FushiIcon(FushiIcons.textFields),
                label: Text(t.srs_note_field_ai_use_as_text),
                onPressed: () => _useReplyAsText(error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resultCard(BuildContext context, AiSrsFieldSuggestion result) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool hasCurrent = widget.current.trim().isNotEmpty;
    return FushiCard(
      key: const ValueKey<String>('srs-field-ai-result'),
      tone: FushiCardTone.tertiary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          SelectableText(
            _plain(result.value),
            key: const ValueKey<String>('srs-field-ai-result-text'),
            style: context.fushiType.bodyLarge,
          ),
          if (result.explanation.isNotEmpty)
            Text(result.explanation, style: context.fushiType.bodySmall),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              if (hasCurrent)
                FushiOutlinedButton.icon(
                  key: const ValueKey<String>('srs-field-ai-append'),
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.srs_note_field_ai_append),
                  onPressed: () => Navigator.of(context).pop(
                    srsApplyFieldAi(widget.current, result.value, append: true),
                  ),
                ),
              FushiFilledButton.icon(
                key: const ValueKey<String>('srs-field-ai-replace'),
                icon: const FushiIcon(FushiIcons.check),
                label: Text(t.dialog_replace),
                onPressed: () => Navigator.of(context).pop(
                  srsApplyFieldAi(widget.current, result.value, append: false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
