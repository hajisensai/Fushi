/// 卡片字段 AI 的提示词编辑页：改一份内置模板（总体说明 / 某个任务）或一个变体。
///
/// - 多行正文 + 占位符 chip（点一下插到光标处）；变体多一个名称框。
/// - 总体说明下方只读显示锁定的契约（「始终附加」）——用户改不到回复格式。
/// - 警告：认不出的占位符（运行时原样发出）、超过 [kAiSrsFieldPromptMax]（超长不能保存）。
/// - 预览：按当前正文拼出整条系统消息 + 用户消息（生产同一个 [buildAiSrsFieldPrompt]）。
/// - 恢复默认（内置模板，先确认）、复制为变体、删除（变体，先确认）、内置版本更新提示（对比 / 恢复）。
///
/// 保存才写存储；有未保存的修改时返回先问要不要放弃。返回值是关页时该选中的动作
/// （复制出变体后 = 新变体；删掉变体后 = 该任务的默认）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart'
    show srsFieldAiTaskLabel;
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_navigation.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardNoteType;
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;

/// 编辑的是哪一份：内置模板（按 id）或变体（按 id）。
class SrsFieldAiPromptRef {
  const SrsFieldAiPromptRef.template(String this.templateId) : variantId = null;
  const SrsFieldAiPromptRef.variant(String this.variantId) : templateId = null;

  /// 抽屉里的 [action] 对应的那一份：选了变体就是变体，否则是该任务的模板。
  factory SrsFieldAiPromptRef.forAction(AiSrsFieldAction action) =>
      action.variantId == null
      ? SrsFieldAiPromptRef.template(aiSrsFieldTaskTemplate(action.task).id)
      : SrsFieldAiPromptRef.variant(action.variantId!);

  final String? templateId;
  final String? variantId;

  @override
  bool operator ==(Object other) =>
      other is SrsFieldAiPromptRef &&
      other.templateId == templateId &&
      other.variantId == variantId;

  @override
  int get hashCode => Object.hash(templateId, variantId);
}

/// 预览用的笔记（从笔记打开 = 当前笔记；从设置打开 = 示例笔记）。
class SrsFieldAiPromptPreview {
  const SrsFieldAiPromptPreview({
    required this.noteTypeName,
    required this.fields,
    required this.valuesById,
    required this.targetFieldId,
    required this.outputLanguage,
    this.task = AiSrsFieldTask.define,
    this.isSample = false,
  });

  final String noteTypeName;
  final List<SrsFieldDef> fields;
  final Map<String, String> valuesById;
  final String targetFieldId;

  /// 输出语言名（不是标签）。
  final String outputLanguage;

  /// 预览总体说明时配哪个任务（任务模板 / 变体用它自己的任务）。
  final AiSrsFieldTask task;

  /// true = 示例笔记（页面上注明），字段占位符 chip 不列示例笔记的字段。
  final bool isSample;
}

/// 从设置打开（没有笔记）时的预览：卡面定制页同一份示例笔记（[srsSampleCardFields]），
/// 要写的字段按任务挑（翻译 → 例句翻译，改写 → 例句，其余 → 主释义）。
SrsFieldAiPromptPreview srsFieldAiSamplePreview({
  required AiSrsFieldTask task,
  required String outputLanguage,
}) {
  final Map<String, String> values = srsSampleCardFields();
  final List<SrsFieldDef> fields = <SrsFieldDef>[
    for (final (int i, String name) in FushiCardNoteType.fields.indexed)
      SrsFieldDef(id: 'sample_$i', name: name, ord: i),
  ];
  final String targetName = switch (task) {
    AiSrsFieldTask.translate => FushiCardNoteType.sentenceTranslationField,
    AiSrsFieldTask.rewrite => 'Sentence',
    AiSrsFieldTask.define || AiSrsFieldTask.custom => 'MainDefinition',
  };
  return SrsFieldAiPromptPreview(
    noteTypeName: FushiCardNoteType.modelName,
    fields: fields,
    valuesById: <String, String>{
      for (final SrsFieldDef f in fields) f.id: values[f.name] ?? '',
    },
    targetFieldId:
        fields.where((SrsFieldDef f) => f.name == targetName).firstOrNull?.id ??
        fields.first.id,
    outputLanguage: outputLanguage,
    task: task,
    isSample: true,
  );
}

/// 打开编辑页；返回关页时该选中的动作（null = 编辑的是总体说明，或没有变化）。
Future<AiSrsFieldAction?> openSrsFieldAiPromptEditor(
  BuildContext context, {
  required AiSrsFieldActionStore store,
  required SrsFieldAiPromptRef target,
  required SrsFieldAiPromptPreview preview,
}) => srsPushPage<AiSrsFieldAction?>(
  context,
  (_) => SrsFieldAiPromptEditorPage(
    store: store,
    target: target,
    preview: preview,
  ),
);

/// 一份模板 / 变体的显示名（编辑页标题、设置行标题共用）。
String srsFieldAiPromptTitle(SrsFieldAiPromptRef ref, AiSrsFieldActions all) {
  final String? variantId = ref.variantId;
  if (variantId != null) return all.variant(variantId)?.name ?? '';
  final AiSrsFieldTask? task = aiSrsFieldTemplateById(ref.templateId!)?.task;
  return task == null
      ? t.srs_field_ai_prompt_title_system
      : t.srs_field_ai_prompt_title_task(task: srsFieldAiTaskLabel(task));
}

class SrsFieldAiPromptEditorPage extends StatefulWidget {
  const SrsFieldAiPromptEditorPage({
    super.key,
    required this.store,
    required this.target,
    required this.preview,
  });

  final AiSrsFieldActionStore store;
  final SrsFieldAiPromptRef target;
  final SrsFieldAiPromptPreview preview;

  @override
  State<SrsFieldAiPromptEditorPage> createState() =>
      _SrsFieldAiPromptEditorPageState();
}

class _SrsFieldAiPromptEditorPageState
    extends State<SrsFieldAiPromptEditorPage> {
  late SrsFieldAiPromptRef _ref = widget.target;
  late AiSrsFieldActions _actions = widget.store.aiFieldActions;
  final TextEditingController _text = TextEditingController();
  final TextEditingController _name = TextEditingController();
  String _savedText = '';
  String _savedName = '';
  bool _busy = false;

  /// 变体在本页被删掉了（关页时退回任务默认）。
  AiSrsFieldTask? _deletedVariantTask;

  @override
  void initState() {
    super.initState();
    _load();
    _text.addListener(_onEdit);
    _name.addListener(_onEdit);
  }

  @override
  void dispose() {
    _text.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  AiSrsFieldVariant? get _variant =>
      _ref.variantId == null ? null : _actions.variant(_ref.variantId!);

  AiSrsFieldTemplate? get _template =>
      _ref.templateId == null ? null : aiSrsFieldTemplateById(_ref.templateId!);

  /// 本页编辑的那份所属的任务；总体说明为 null。
  AiSrsFieldTask? get _task => _variant?.task ?? _template?.task;

  void _load() {
    final AiSrsFieldVariant? v = _variant;
    _savedText = v?.text ?? _actions.textOf(_ref.templateId ?? '');
    _savedName = v?.name ?? '';
    _text.text = _savedText;
    _name.text = _savedName;
  }

  bool get _dirty =>
      _text.text != _savedText ||
      (_variant != null && _name.text.trim() != _savedName);

  bool get _tooLong => _text.text.length > kAiSrsFieldPromptMax;

  bool get _canSave =>
      _dirty &&
      !_tooLong &&
      !_busy &&
      (_variant == null || _name.text.trim().isNotEmpty);

  /// 当前正文代进去后的改动（预览用，不落盘）。
  AiSrsFieldActions get _draft {
    final AiSrsFieldVariant? v = _variant;
    if (v != null) return _actions.updateVariant(v.id, text: _text.text);
    final String? templateId = _ref.templateId;
    // 变体刚被删（关页动画期间还会重建一次）：没有可代入的正文。
    if (templateId == null) return _actions;
    return _actions.withTemplateText(templateId, _text.text);
  }

  AiSrsFieldAction get _previewAction {
    final AiSrsFieldVariant? v = _variant;
    if (v != null) return AiSrsFieldAction(v.task!, variantId: v.id);
    return AiSrsFieldAction(_task ?? widget.preview.task);
  }

  /// 关页时交回的动作。
  AiSrsFieldAction? get _result {
    if (_deletedVariantTask case final AiSrsFieldTask task) {
      return AiSrsFieldAction(task);
    }
    final AiSrsFieldVariant? v = _variant;
    if (v != null) return AiSrsFieldAction(v.task!, variantId: v.id);
    final AiSrsFieldTask? task = _task;
    return task == null ? null : AiSrsFieldAction(task);
  }

  Future<void> _write(AiSrsFieldActions next) async {
    setState(() => _busy = true);
    try {
      await widget.store.setAiFieldActions(next);
      if (!mounted) return;
      _actions = widget.store.aiFieldActions;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final AiSrsFieldVariant? v = _variant;
    final String? templateId = _ref.templateId;
    if (v == null && templateId == null) return;
    await _write(
      v != null
          ? _actions.updateVariant(v.id, name: _name.text, text: _text.text)
          : _actions.withTemplateText(templateId!, _text.text),
    );
    if (mounted) setState(_load);
  }

  Future<void> _reset() async {
    final AiSrsFieldTemplate? template = _template;
    if (template == null) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.settings_reset_to_default,
      message: t.srs_field_ai_prompt_reset_confirm,
      confirmLabel: t.settings_reset_to_default,
      cancelLabel: t.cancel,
      icon: FushiIcons.restart,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _write(_actions.resetTemplate(template.id));
    if (mounted) setState(_load);
  }

  Future<void> _duplicate() async {
    final AiSrsFieldTask? task = _task;
    if (task == null || _tooLong) return;
    final String base = _variant?.name ?? srsFieldAiTaskLabel(task);
    final (AiSrsFieldActions next, AiSrsFieldVariant created) = _actions
        .addVariant(
          task: task,
          name: t.srs_field_ai_prompt_copy_name(name: base),
          text: _text.text,
        );
    await _write(next);
    if (!mounted) return;
    setState(() {
      _ref = SrsFieldAiPromptRef.variant(created.id);
      _load();
    });
  }

  Future<void> _delete() async {
    final AiSrsFieldVariant? v = _variant;
    if (v == null) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_field_ai_prompt_delete,
      message: t.srs_field_ai_prompt_delete_confirm(name: v.name),
      confirmLabel: t.dialog_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _write(_actions.removeVariant(v.id));
    if (!mounted) return;
    _deletedVariantTask = v.task;
    Navigator.of(context).pop(_result);
  }

  Future<void> _compare() async {
    final AiSrsFieldTemplate? template = _template;
    if (template == null) return;
    await showFushiConfirmDialog(
      context: context,
      title: t.srs_field_ai_prompt_compare,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(t.srs_field_ai_prompt_compare_yours),
          SelectableText(
            _actions.textOf(template.id),
            key: const ValueKey<String>('srs-field-ai-prompt-compare-yours'),
          ),
          FushiSectionTitle(t.srs_field_ai_prompt_compare_builtin),
          SelectableText(
            template.text,
            key: const ValueKey<String>('srs-field-ai-prompt-compare-builtin'),
          ),
        ],
      ),
      confirmLabel: t.dialog_close,
      icon: FushiIcons.compare,
    );
  }

  Future<void> _maybePop() async {
    if (_dirty) {
      final bool discard = await showFushiConfirmDialog(
        context: context,
        title: t.srs_field_ai_prompt_discard_confirm,
        confirmLabel: t.srs_field_ai_prompt_discard,
        cancelLabel: t.cancel,
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    Navigator.of(context).pop(_result);
  }

  void _insert(String placeholder) {
    final String token = '{{$placeholder}}';
    final TextSelection sel = _text.selection;
    final String text = _text.text;
    final int start = sel.isValid ? sel.start : text.length;
    final int end = sel.isValid ? sel.end : text.length;
    _text.value = TextEditingValue(
      text: text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AiSrsFieldTemplate? template = _template;
    final AiSrsFieldVariant? variant = _variant;
    final bool isSystem = template?.isSystem ?? false;
    final SrsFieldAiPromptPreview preview = widget.preview;
    final List<String> unknown = aiSrsFieldUnknownPlaceholders(
      _text.text,
      preview.fields.map((SrsFieldDef f) => f.name),
    );
    final AiSrsFieldPrompt assembled = buildAiSrsFieldPrompt(
      noteTypeName: preview.noteTypeName,
      fields: preview.fields,
      valuesById: preview.valuesById,
      targetFieldId: preview.targetFieldId,
      action: _previewAction,
      actions: _draft,
      instruction: '',
      outputLanguage: preview.outputLanguage,
    );
    final TextStyle mono = context.fushiType.bodySmall.copyWith(
      fontFamily: 'monospace',
    );
    final List<String> chips = <String>[
      kAiSrsFieldOutputLanguagePlaceholder,
      kAiSrsFieldTargetFieldPlaceholder,
      if (!preview.isSample)
        for (final SrsFieldDef f in preview.fields) f.name,
    ];

    final List<Widget> children = <Widget>[
      if (template != null && _actions.isOutdated(template.id))
        FushiCard(
          key: const ValueKey<String>('srs-field-ai-prompt-outdated'),
          tone: FushiCardTone.tertiary,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Text(t.srs_field_ai_prompt_outdated),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiTextButton.icon(
                    key: const ValueKey<String>('srs-field-ai-prompt-compare'),
                    icon: const FushiIcon(FushiIcons.compare),
                    label: Text(t.srs_field_ai_prompt_compare),
                    onPressed: () => unawaited(_compare()),
                  ),
                  FushiTextButton.icon(
                    key: const ValueKey<String>(
                      'srs-field-ai-prompt-outdated-reset',
                    ),
                    icon: const FushiIcon(FushiIcons.restart),
                    label: Text(t.settings_reset_to_default),
                    onPressed: _busy ? null : () => unawaited(_reset()),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (variant != null)
        FushiTextField(
          key: const ValueKey<String>('srs-field-ai-prompt-name'),
          controller: _name,
          labelText: t.srs_field_ai_prompt_name_label,
          maxLength: kAiSrsFieldVariantNameMax,
        ),
      FushiTextField(
        key: const ValueKey<String>('srs-field-ai-prompt-text'),
        controller: _text,
        labelText: t.srs_field_ai_prompt_text_label,
        keyboardType: TextInputType.multiline,
        minLines: isSystem ? 8 : 3,
        maxLines: 20,
        style: mono,
        errorText: _tooLong
            ? t.srs_field_ai_prompt_too_long(
                n: _text.text.length,
                max: kAiSrsFieldPromptMax,
              )
            : null,
      ),
      if (unknown.isNotEmpty)
        Text(
          t.srs_field_ai_prompt_unknown(names: unknown.join(', ')),
          key: const ValueKey<String>('srs-field-ai-prompt-unknown'),
          style: context.fushiType.bodySmall.copyWith(color: scheme.error),
        ),
      FushiSectionTitle(t.srs_field_ai_prompt_placeholders),
      Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final String name in chips)
            FushiPressScale(
              child: FushiActionChip(
                key: ValueKey<String>('srs-field-ai-prompt-chip-$name'),
                label: '{{$name}}',
                icon: FushiIcons.add,
                onPressed: () => _insert(name),
              ),
            ),
        ],
      ),
      if (isSystem) ...<Widget>[
        FushiSectionTitle(t.srs_field_ai_prompt_contract_header),
        Text(
          t.srs_field_ai_prompt_contract_hint,
          style: context.fushiType.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        FushiCard(
          key: const ValueKey<String>('srs-field-ai-prompt-contract'),
          child: SelectableText(kAiSrsFieldContract, style: mono),
        ),
      ],
      FushiSectionTitle(t.srs_field_ai_prompt_preview),
      if (preview.isSample)
        Text(
          t.srs_field_ai_prompt_preview_sample,
          style: context.fushiType.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_field_ai_prompt_preview_system,
              style: context.fushiType.labelLarge,
            ),
            SelectableText(
              assembled.system,
              key: const ValueKey<String>('srs-field-ai-prompt-preview-system'),
              style: mono,
            ),
            Text(
              t.srs_field_ai_prompt_preview_user,
              style: context.fushiType.labelLarge,
            ),
            SelectableText(
              assembled.user,
              key: const ValueKey<String>('srs-field-ai-prompt-preview-user'),
              style: mono,
            ),
          ],
        ),
      ),
    ];

    final List<Widget> actions = <Widget>[
      if (template != null)
        FushiIconButton(
          key: const ValueKey<String>('srs-field-ai-prompt-reset'),
          icon: FushiIcons.restart,
          tooltip: t.settings_reset_to_default,
          enabled: !_busy && _actions.isOverridden(template.id),
          onTap: _reset,
        ),
      if (_task != null)
        FushiIconButton(
          key: const ValueKey<String>('srs-field-ai-prompt-duplicate'),
          icon: FushiIcons.copy,
          tooltip: t.srs_field_ai_prompt_duplicate,
          enabled: !_busy && !_tooLong,
          onTap: _duplicate,
        ),
      if (variant != null)
        FushiIconButton(
          key: const ValueKey<String>('srs-field-ai-prompt-delete'),
          icon: FushiIcons.delete,
          tooltip: t.srs_field_ai_prompt_delete,
          enabled: !_busy,
          onTap: _delete,
        ),
      FushiIconButton(
        key: const ValueKey<String>('srs-field-ai-prompt-save'),
        icon: FushiIcons.check,
        tooltip: t.dialog_save,
        enabled: _canSave,
        onTap: _save,
      ),
    ];

    return PopScope<AiSrsFieldAction?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, AiSrsFieldAction? _) {
        if (!didPop) unawaited(_maybePop());
      },
      child: AdaptiveSettingsScaffold(
        title: Text(srsFieldAiPromptTitle(_ref, _actions)),
        subtitle: variant?.task == null
            ? null
            : Text(
                t.srs_field_ai_prompt_variant_of(
                  task: srsFieldAiTaskLabel(variant!.task!),
                ),
              ),
        actions: actions,
        children: <Widget>[
          // 新页面动效：各块错峰进场，chip 按压缩放；时长走 FushiMotion（组件内部）。
          FushiEntranceScope(
            child: Column(
              key: const ValueKey<String>('srs-field-ai-prompt-editor'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                for (final (int i, Widget w) in children.indexed)
                  FushiStaggeredEntrance(index: i, child: w),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
