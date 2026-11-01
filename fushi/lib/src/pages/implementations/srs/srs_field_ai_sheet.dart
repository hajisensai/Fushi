/// 笔记编辑页单个字段的「AI 改写 / 补全」抽屉：选任务（写释义 / 翻译 / 改写 / 自定义）、
/// 可选补一句要求 → 生成 → 预览 → 「替换」或「追加到末尾」。结果只回给编辑页草稿，点保存才落库。
///
/// 请求怎么发由调用方注入（[SrsFieldAiRunner]，生产走 ai_srs_field_assistant.dart，测试给假的）。
library;

import 'dart:async';

import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/ai/ai_saved_prompt_picker.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 跑一次字段 AI。
typedef SrsFieldAiRunner =
    Future<AiSrsFieldSuggestion> Function(
      AiSrsFieldTask task,
      String instruction,
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
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext context) => SrsFieldAiSheet(
    fieldLabel: fieldLabel,
    fieldName: fieldName,
    current: current,
    run: run,
    promptStore: promptStore,
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
  });

  final String fieldLabel;
  final String fieldName;
  final String current;
  final SrsFieldAiRunner run;

  /// 「已保存的提示词」的存取实现；null = 应用偏好（测试注入内存实现）。
  final AiSavedPromptStore? promptStore;

  @override
  State<SrsFieldAiSheet> createState() => _SrsFieldAiSheetState();
}

class _SrsFieldAiSheetState extends State<SrsFieldAiSheet> {
  late AiSrsFieldTask _task = srsDefaultFieldAiTask(widget.fieldName);
  final TextEditingController _instruction = TextEditingController();
  bool _busy = false;
  String? _error;
  AiSrsFieldSuggestion? _result;

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
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
      final AiSrsFieldSuggestion s = await widget.run(_task, _instruction.text);
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
        onSelectionChanged: (Set<AiSrsFieldTask> s) =>
            setState(() => _task = s.first),
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
          AiSavedPromptButton(
            scene: AiPromptScene.srsField,
            controller: _instruction,
            enabled: !_busy,
            store: widget.promptStore,
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
