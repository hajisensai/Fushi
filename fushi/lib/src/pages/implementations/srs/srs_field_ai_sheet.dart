/// 笔记编辑页单个字段的「AI 改写 / 补全」抽屉：选任务（写释义 / 翻译 / 改写 / 自定义）、
/// 可选补一句要求 → 生成 → 预览 → 「替换」或「追加到末尾」。结果只回给编辑页草稿，点保存才落库。
///
/// 请求怎么发由调用方注入（[SrsFieldAiRunner]，生产走 ai_srs_field_assistant.dart，测试给假的）。
///
/// 任务有用户复制的变体时，任务选择下面多一个「默认 / 变体」下拉；「编辑提示词」打开当前
/// 任务 / 变体的编辑页（[SrsFieldAiPromptEditorOpener]），关掉后重读提示词——不另设「试一下」，
/// 现有的生成键就是试，替换 / 追加前什么都不写。
library;

import 'dart:async';

import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_saved_prompt_picker.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
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

/// 跑一次字段 AI。
typedef SrsFieldAiRunner =
    Future<AiSrsFieldSuggestion> Function(
      AiSrsFieldAction action,
      String instruction,
    );

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

/// 打开抽屉；返回字段的新值（null = 没采用）。
Future<String?> showSrsFieldAiSheet(
  BuildContext context, {
  required String fieldLabel,
  required String fieldName,
  required String current,
  required SrsFieldAiRunner run,
  AiSavedPromptStore? promptStore,
  AiSrsFieldActionStore? actionStore,
  SrsFieldAiPromptEditorOpener? editPrompt,
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext context) => SrsFieldAiSheet(
    fieldLabel: fieldLabel,
    fieldName: fieldName,
    current: current,
    run: run,
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
    required this.run,
    this.promptStore,
    this.actionStore,
    this.editPrompt,
  });

  final String fieldLabel;
  final String fieldName;
  final String current;
  final SrsFieldAiRunner run;

  /// 「已保存的提示词」的存取实现（生产 = 应用偏好仓库，测试注入内存实现）；
  /// null = 不显示该按钮。
  final AiSavedPromptStore? promptStore;

  /// 卡片字段 AI 的提示词改动（变体下拉读它）；null = 只有内置、不显示变体下拉。
  final AiSrsFieldActionStore? actionStore;

  /// 「编辑提示词」；null = 不显示该按钮。
  final SrsFieldAiPromptEditorOpener? editPrompt;

  @override
  State<SrsFieldAiSheet> createState() => _SrsFieldAiSheetState();
}

class _SrsFieldAiSheetState extends State<SrsFieldAiSheet> {
  late AiSrsFieldTask _task = srsDefaultFieldAiTask(widget.fieldName);

  /// 选中的变体；null = 该任务的模板（内置或改过的）。
  String? _variantId;
  late AiSrsFieldActions _actions =
      widget.actionStore?.aiFieldActions ?? AiSrsFieldActions.empty;
  final TextEditingController _instruction = TextEditingController();
  bool _busy = false;
  String? _error;
  AiSrsFieldSuggestion? _result;

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  AiSrsFieldAction get _action =>
      AiSrsFieldAction(_task, variantId: _variantId);

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

  Future<void> _generate() async {
    if (_busy) return;
    if (_task == AiSrsFieldTask.custom && _instruction.text.trim().isEmpty) {
      setState(() => _error = t.srs_note_field_ai_custom_hint);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AiSrsFieldSuggestion s = await widget.run(
        _action,
        _instruction.text,
      );
      if (mounted) setState(() => _result = s);
    } on AiChatFailure catch (failure) {
      if (mounted) {
        setState(
          () => _error = t.ai_assist_failed(
            reason: aiFailureText(failure.message),
          ),
        );
      }
    } on AiSrsFieldEmpty {
      if (mounted) setState(() => _error = t.ai_assist_empty);
    } finally {
      if (mounted) setState(() => _busy = false);
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
          ],
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: FushiTextField(
              key: const ValueKey<String>('srs-field-ai-instruction'),
              controller: _instruction,
              hintText: _task == AiSrsFieldTask.custom
                  ? t.srs_note_field_ai_custom_hint
                  : t.srs_note_field_ai_instruction_hint,
              minLines: 1,
              maxLines: 4,
              onSubmitted: (_) => unawaited(_generate()),
            ),
          ),
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
      Row(
        spacing: tokens.spacing.gap,
        children: <Widget>[
          FushiFilledButton.icon(
            key: const ValueKey<String>('srs-field-ai-run'),
            icon: const FushiIcon(FushiIcons.aiAssistant),
            label: Text(
              result == null ? t.srs_visual_ai_run : t.srs_note_field_ai_again,
            ),
            onPressed: _busy ? null : () => unawaited(_generate()),
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
