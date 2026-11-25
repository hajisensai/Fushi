/// 卡片字段 AI 的提示词编辑页：改一个内置动作（某个任务）或一个变体。「写的就是发的」——
/// 这里写的模板就是用户消息本身，预览按 [buildAiSrsFieldRequest] 拼出真正会发的两条消息。
///
/// - 基本：名称（变体）、**提示词**（模板，多行）+ 插入占位符（可搜索的清单，插到光标处）、
///   **回复格式**（纯文本 / 附带说明）、预览用的要求（模板用到 `{{instruction}}` 时）。
/// - 高级（折叠）：**AI 说明**（系统消息里用户可改的部分，可空）。
/// - 预览：先用户消息（用户改的就是它），再系统消息 = AI 说明（你的）+ 应用规则（固定，只读、
///   锁图标）；警告：认不出的占位符、截断、超限。从设置打开用示例笔记。
/// - 恢复默认（内置动作，三部分一起，先确认）、新建变体（[showSrsFieldAiNewVariantSheet]：复制当前
///   三部分，或照样例库里的一条；照样例新建时有未保存的修改先问要不要放弃）、删除（变体，先确认）、
///   内置版本更新提示（对比 / 恢复）。
///
/// 保存才写存储；有未保存的修改时返回先问要不要放弃。返回值是关页时该选中的动作
/// （新建变体后 = 新变体；删掉变体后 = 该任务的默认）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/ai/ai_srs_field_samples.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart'
    show
        SrsFieldAiNewVariantChoice,
        showSrsFieldAiNewVariantSheet,
        srsFieldAiRequestNotices,
        srsFieldAiTaskLabel;
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart'
    show srsFieldDisplayDescription;
import 'package:fushi/src/srs/srs_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiExpansionTile;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardNoteType;
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;

/// 编辑的是哪一份：内置动作（按 id）或变体（按 id）。
class SrsFieldAiPromptRef {
  const SrsFieldAiPromptRef.template(String this.templateId) : variantId = null;
  const SrsFieldAiPromptRef.variant(String this.variantId) : templateId = null;

  /// 抽屉里的 [action] 对应的那一份：选了变体就是变体，否则是该任务的内置动作。
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
    required this.note,
    this.task = AiSrsFieldTask.define,
    this.isSample = false,
  });

  final AiSrsFieldNoteContext note;

  /// 打开时所在的任务（编辑页按自己编辑的那份的任务，这里只作兜底）。
  final AiSrsFieldTask task;

  /// true = 示例笔记（页面上注明，占位符清单把字段标成「示例笔记的字段」）。
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
    note: AiSrsFieldNoteContext(
      noteTypeName: FushiCardNoteType.modelName,
      fields: fields,
      valuesById: <String, String>{
        for (final SrsFieldDef f in fields) f.id: values[f.name] ?? '',
      },
      targetFieldId:
          fields
              .where((SrsFieldDef f) => f.name == targetName)
              .firstOrNull
              ?.id ??
          fields.first.id,
      outputLanguage: outputLanguage,
    ),
    task: task,
    isSample: true,
  );
}

/// 打开编辑页；返回关页时该选中的动作（null = 没有变化）。
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

/// 一份内置动作 / 变体的显示名（编辑页标题、设置行标题共用）。
String srsFieldAiPromptTitle(SrsFieldAiPromptRef ref, AiSrsFieldActions all) {
  final String? variantId = ref.variantId;
  if (variantId != null) return all.variant(variantId)?.name ?? '';
  final AiSrsFieldTask? task = aiSrsFieldTemplateById(ref.templateId!)?.task;
  return task == null
      ? ''
      : t.srs_field_ai_prompt_title_task(task: srsFieldAiTaskLabel(task));
}

/// 把 [token] 插到 [value] 的光标处（有选区就替换选区，没有光标就接在末尾）；光标前一个字符
/// 不是空白 / 行首时先补一个空格。返回新值，光标落在插入内容之后。
TextEditingValue srsFieldAiInsertPlaceholder(
  TextEditingValue value,
  String token,
) {
  final String text = value.text;
  final TextSelection sel = value.selection;
  final int start = sel.isValid ? sel.start : text.length;
  final int end = sel.isValid ? sel.end : text.length;
  final bool needsSpace = start > 0 && !RegExp(r'\s').hasMatch(text[start - 1]);
  final String insert = needsSpace ? ' $token' : token;
  return TextEditingValue(
    text: text.replaceRange(start, end, insert),
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}

/// 占位符清单的一项。
typedef SrsFieldAiPlaceholderEntry = ({
  String key,
  String token,
  String description,
});

String _reservedDescription(String name) => switch (name) {
  kAiSrsFieldNotePlaceholder => t.srs_field_ai_placeholder_note,
  kAiSrsFieldNoteTypePlaceholder => t.srs_field_ai_placeholder_note_type,
  kAiSrsFieldTargetFieldPlaceholder => t.srs_field_ai_placeholder_target_field,
  kAiSrsFieldTargetMeaningPlaceholder =>
    t.srs_field_ai_placeholder_target_meaning,
  kAiSrsFieldTargetContentPlaceholder =>
    t.srs_field_ai_placeholder_target_content,
  kAiSrsFieldOutputLanguagePlaceholder =>
    t.srs_field_ai_placeholder_output_language,
  kAiSrsFieldInstructionPlaceholder => t.srs_field_ai_placeholder_instruction,
  _ => '',
};

/// 编辑页占位符清单：保留占位符在前，然后是 [fields]（同名 / 带花括号的写成 `{{field:…}}`）。
List<SrsFieldAiPlaceholderEntry> srsFieldAiPlaceholderEntries(
  List<SrsFieldDef> fields, {
  required bool isSample,
}) => <SrsFieldAiPlaceholderEntry>[
  for (final String name in kAiSrsFieldReservedPlaceholders)
    (key: name, token: '{{$name}}', description: _reservedDescription(name)),
  for (final SrsFieldDef f in fields)
    (
      key: 'field-${f.name}',
      token: aiSrsFieldPlaceholderToken(f.name),
      description: () {
        final String scope = isSample
            ? t.srs_field_ai_placeholder_field_sample
            : t.srs_field_ai_placeholder_field;
        final String meaning = srsFieldDisplayDescription(f);
        return meaning.isEmpty ? scope : '$scope · $meaning';
      }(),
    ),
];

/// 打开占位符清单（可搜索）；返回选中的占位符文字（null = 没选）。
Future<String?> showSrsFieldAiPlaceholderPicker(
  BuildContext context, {
  required List<SrsFieldAiPlaceholderEntry> entries,
}) => adaptiveModalSheet<String>(
  context: context,
  builder: (BuildContext context) =>
      _SrsFieldAiPlaceholderSheet(entries: entries),
);

class _SrsFieldAiPlaceholderSheet extends StatefulWidget {
  const _SrsFieldAiPlaceholderSheet({required this.entries});

  final List<SrsFieldAiPlaceholderEntry> entries;

  @override
  State<_SrsFieldAiPlaceholderSheet> createState() =>
      _SrsFieldAiPlaceholderSheetState();
}

class _SrsFieldAiPlaceholderSheetState
    extends State<_SrsFieldAiPlaceholderSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String q = _query.text.trim().toLowerCase();
    final List<SrsFieldAiPlaceholderEntry> shown = <SrsFieldAiPlaceholderEntry>[
      for (final SrsFieldAiPlaceholderEntry e in widget.entries)
        if (q.isEmpty ||
            e.token.toLowerCase().contains(q) ||
            e.description.toLowerCase().contains(q))
          e,
    ];
    final TextStyle mono = context.fushiType.bodyMedium.copyWith(
      fontFamily: 'monospace',
    );
    return FushiModalSheetFrame(
      key: const ValueKey<String>('srs-field-ai-placeholder-sheet'),
      title: t.srs_field_ai_prompt_placeholders,
      leadingIcon: FushiIcons.add,
      scrollable: true,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          FushiTextField(
            key: const ValueKey<String>('srs-field-ai-placeholder-search'),
            controller: _query,
            hintText: t.srs_field_ai_placeholder_search,
            prefixIcon: const FushiIcon(FushiIcons.search),
            clearable: true,
          ),
          if (shown.isEmpty)
            Text(
              t.srs_field_ai_placeholder_empty,
              style: context.fushiType.bodySmall,
            ),
          FushiEntranceScope(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (int i, SrsFieldAiPlaceholderEntry e)
                    in shown.indexed)
                  FushiStaggeredEntrance(
                    index: i,
                    child: FushiListItem(
                      key: ValueKey<String>(
                        'srs-field-ai-placeholder-${e.key}',
                      ),
                      title: Text(e.token, style: mono),
                      subtitle: Text(e.description),
                      onTap: () => Navigator.of(context).pop(e.token),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
  final TextEditingController _template = TextEditingController();
  final TextEditingController _guidance = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _previewInstruction = TextEditingController();
  AiSrsFieldResponseMode _mode = AiSrsFieldResponseMode.structured;
  AiSrsFieldActionPrompt? _saved;
  String _savedName = '';
  bool _busy = false;

  /// 变体在本页被删掉了（关页时退回任务默认）。
  AiSrsFieldTask? _deletedVariantTask;

  @override
  void initState() {
    super.initState();
    _load();
    for (final TextEditingController c in <TextEditingController>[
      _template,
      _guidance,
      _name,
      _previewInstruction,
    ]) {
      c.addListener(_onEdit);
    }
  }

  @override
  void dispose() {
    _template.dispose();
    _guidance.dispose();
    _name.dispose();
    _previewInstruction.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  AiSrsFieldVariant? get _variant =>
      _ref.variantId == null ? null : _actions.variant(_ref.variantId!);

  AiSrsFieldTemplate? get _template0 =>
      _ref.templateId == null ? null : aiSrsFieldTemplateById(_ref.templateId!);

  /// 本页编辑的那份所属的任务。
  AiSrsFieldTask? get _task => _variant?.task ?? _template0?.task;

  void _load() {
    final AiSrsFieldVariant? v = _variant;
    final AiSrsFieldActionPrompt? p =
        v?.prompt ?? _actions.promptOf(_ref.templateId ?? '');
    _saved = p;
    _savedName = v?.name ?? '';
    _template.text = p?.template ?? '';
    _guidance.text = p?.guidance ?? '';
    _mode = p?.mode ?? AiSrsFieldResponseMode.structured;
    _name.text = _savedName;
  }

  AiSrsFieldActionPrompt get _current => AiSrsFieldActionPrompt(
    template: _template.text,
    guidance: _guidance.text,
    mode: _mode,
  );

  bool get _dirty =>
      _current != _saved ||
      (_variant != null && _name.text.trim() != _savedName);

  bool get _templateTooLong => _template.text.length > kAiSrsFieldPromptMax;

  bool get _guidanceTooLong => _guidance.text.length > kAiSrsFieldPromptMax;

  bool get _templateEmpty => _template.text.trim().isEmpty;

  bool get _invalid => _templateTooLong || _guidanceTooLong || _templateEmpty;

  bool get _canSave =>
      _dirty &&
      !_invalid &&
      !_busy &&
      (_variant == null || _name.text.trim().isNotEmpty);

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
          ? _actions.updateVariant(v.id, name: _name.text, prompt: _current)
          : _actions.withTemplatePrompt(templateId!, _current),
    );
    if (mounted) setState(_load);
  }

  Future<void> _reset() async {
    final AiSrsFieldTemplate? template = _template0;
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
    if (task == null || _invalid) return;
    final String base = _variant?.name ?? srsFieldAiTaskLabel(task);
    final (AiSrsFieldActions next, AiSrsFieldVariant created) = _actions
        .addVariant(
          task: task,
          name: t.srs_field_ai_prompt_copy_name(name: base),
          prompt: _current,
        );
    await _write(next);
    if (!mounted) return;
    setState(() {
      _ref = SrsFieldAiPromptRef.variant(created.id);
      _load();
    });
  }

  /// 「新建变体」：复制当前三部分（[_duplicate]），或照样例新建并切过去编辑。
  Future<void> _newVariant() async {
    final AiSrsFieldTask? task = _task;
    if (task == null) return;
    final SrsFieldAiNewVariantChoice? choice =
        await showSrsFieldAiNewVariantSheet(
          context,
          task: task,
          canCopy: !_invalid,
        );
    if (choice == null || !mounted) return;
    final AiSrsFieldSample? sample = choice.sample;
    if (sample == null) return _duplicate();
    // 照样例新建会换掉本页正在编辑的内容：没保存的修改先问。
    if (_dirty && !await _confirmDiscard()) return;
    if (!mounted) return;
    final (AiSrsFieldActions next, AiSrsFieldVariant created) = _actions
        .addVariant(
          task: sample.task,
          name: sample.name,
          prompt: sample.prompt,
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

  static String _modeLabel(AiSrsFieldResponseMode mode) => switch (mode) {
    AiSrsFieldResponseMode.plain => t.srs_field_ai_prompt_response_plain,
    AiSrsFieldResponseMode.structured =>
      t.srs_field_ai_prompt_response_structured,
  };

  Future<void> _compare() async {
    final AiSrsFieldTemplate? template = _template0;
    if (template == null) return;
    final AiSrsFieldActionPrompt yours =
        _actions.promptOf(template.id) ?? template.prompt;
    final AiSrsFieldActionPrompt builtin = template.prompt;
    final TextStyle mono = context.fushiType.bodySmall.copyWith(
      fontFamily: 'monospace',
    );
    Widget pair(String label, String a, String b, String key) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiSectionTitle(label),
        Text(t.srs_field_ai_prompt_compare_yours),
        SelectableText(
          a,
          key: ValueKey<String>('srs-field-ai-prompt-compare-$key-yours'),
          style: mono,
        ),
        Text(t.srs_field_ai_prompt_compare_builtin),
        SelectableText(
          b,
          key: ValueKey<String>('srs-field-ai-prompt-compare-$key-builtin'),
          style: mono,
        ),
      ],
    );
    await showFushiConfirmDialog(
      context: context,
      title: t.srs_field_ai_prompt_compare,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          pair(
            t.srs_field_ai_prompt_text_label,
            yours.template,
            builtin.template,
            'template',
          ),
          if (yours.guidance != builtin.guidance)
            pair(
              t.srs_field_ai_prompt_guidance_label,
              yours.guidance,
              builtin.guidance,
              'guidance',
            ),
          if (yours.mode != builtin.mode)
            pair(
              t.srs_field_ai_prompt_response_format,
              _modeLabel(yours.mode),
              _modeLabel(builtin.mode),
              'mode',
            ),
        ],
      ),
      confirmLabel: t.dialog_close,
      icon: FushiIcons.compare,
    );
  }

  Future<bool> _confirmDiscard() => showFushiConfirmDialog(
    context: context,
    title: t.srs_field_ai_prompt_discard_confirm,
    confirmLabel: t.srs_field_ai_prompt_discard,
    cancelLabel: t.cancel,
    destructive: true,
  );

  Future<void> _maybePop() async {
    if (_dirty) {
      final bool discard = await _confirmDiscard();
      if (!discard || !mounted) return;
    }
    Navigator.of(context).pop(_result);
  }

  Future<void> _pickPlaceholder(TextEditingController into) async {
    final String? token = await showSrsFieldAiPlaceholderPicker(
      context,
      entries: srsFieldAiPlaceholderEntries(
        widget.preview.note.fields,
        isSample: widget.preview.isSample,
      ),
    );
    if (token == null || !mounted) return;
    into.value = srsFieldAiInsertPlaceholder(into.value, token);
  }

  Widget _insertButton(String key, TextEditingController into) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: FushiPressScale(
      child: FushiTextButton.icon(
        key: ValueKey<String>(key),
        icon: const FushiIcon(FushiIcons.add),
        label: Text(t.srs_field_ai_prompt_placeholders),
        onPressed: () => unawaited(_pickPlaceholder(into)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AiSrsFieldTemplate? template = _template0;
    final AiSrsFieldVariant? variant = _variant;
    final SrsFieldAiPromptPreview preview = widget.preview;
    final AiSrsFieldActionPrompt current = _current;
    final AiSrsFieldRequest request = buildAiSrsFieldRequest(
      note: preview.note,
      prompt: current,
      instruction: _previewInstruction.text,
    );
    final TextStyle mono = context.fushiType.bodySmall.copyWith(
      fontFamily: 'monospace',
    );
    final TextStyle muted = context.fushiType.bodySmall.copyWith(
      color: scheme.onSurfaceVariant,
    );
    String? tooLong(TextEditingController c) =>
        c.text.length > kAiSrsFieldPromptMax
        ? t.srs_field_ai_prompt_too_long(
            n: c.text.length,
            max: kAiSrsFieldPromptMax,
          )
        : null;

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
        controller: _template,
        labelText: t.srs_field_ai_prompt_text_label,
        keyboardType: TextInputType.multiline,
        minLines: 6,
        maxLines: 24,
        style: mono,
        errorText:
            tooLong(_template) ??
            (_templateEmpty ? t.srs_field_ai_prompt_template_empty : null),
      ),
      _insertButton('srs-field-ai-prompt-insert', _template),
      FushiSectionTitle(t.srs_field_ai_prompt_response_format),
      adaptiveSegmentedButton<AiSrsFieldResponseMode>(
        context: context,
        segments: <ButtonSegment<AiSrsFieldResponseMode>>[
          for (final AiSrsFieldResponseMode mode
              in AiSrsFieldResponseMode.values)
            ButtonSegment<AiSrsFieldResponseMode>(
              value: mode,
              label: Text(
                _modeLabel(mode),
                key: ValueKey<String>('srs-field-ai-prompt-mode-${mode.name}'),
              ),
            ),
        ],
        selected: <AiSrsFieldResponseMode>{_mode},
        onSelectionChanged: (Set<AiSrsFieldResponseMode> s) =>
            setState(() => _mode = s.first),
      ),
      Text(t.srs_field_ai_prompt_response_hint, style: muted),
      if (request.usesInstruction)
        FushiTextField(
          key: const ValueKey<String>(
            'srs-field-ai-prompt-preview-instruction',
          ),
          controller: _previewInstruction,
          labelText: t.srs_field_ai_prompt_preview_instruction,
          minLines: 1,
          maxLines: 3,
        ),
      FushiExpansionTile(
        key: const ValueKey<String>('srs-field-ai-prompt-advanced'),
        title: Text(t.srs_field_ai_prompt_advanced),
        maintainState: true,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: EdgeInsets.only(bottom: tokens.spacing.gap),
        children: <Widget>[
          Text(t.srs_field_ai_prompt_guidance_hint, style: muted),
          SizedBox(height: tokens.spacing.gap),
          FushiTextField(
            key: const ValueKey<String>('srs-field-ai-prompt-guidance'),
            controller: _guidance,
            labelText: t.srs_field_ai_prompt_guidance_label,
            keyboardType: TextInputType.multiline,
            minLines: 4,
            maxLines: 20,
            style: mono,
            errorText: tooLong(_guidance),
          ),
          _insertButton('srs-field-ai-prompt-guidance-insert', _guidance),
        ],
      ),
      FushiSectionTitle(t.srs_field_ai_prompt_preview),
      if (preview.isSample)
        Text(t.srs_field_ai_prompt_preview_sample, style: muted),
      ...srsFieldAiRequestNotices(context, request),
      // 用户消息在前：用户改的就是它。
      FushiCard(
        key: const ValueKey<String>('srs-field-ai-prompt-preview-user-card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_field_ai_prompt_preview_user,
              style: context.fushiType.labelLarge,
            ),
            SelectableText(
              request.prompt.user,
              key: const ValueKey<String>('srs-field-ai-prompt-preview-user'),
              style: mono,
            ),
          ],
        ),
      ),
      Text(
        t.srs_field_ai_prompt_preview_system,
        style: context.fushiType.labelLarge,
      ),
      FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_field_ai_prompt_preview_guidance,
              style: context.fushiType.labelMedium,
            ),
            if (request.guidance.isEmpty)
              Text(
                t.srs_field_ai_prompt_preview_guidance_empty,
                key: const ValueKey<String>(
                  'srs-field-ai-prompt-preview-guidance-empty',
                ),
                style: muted,
              )
            else
              SelectableText(
                request.guidance,
                key: const ValueKey<String>(
                  'srs-field-ai-prompt-preview-guidance',
                ),
                style: mono,
              ),
          ],
        ),
      ),
      // 应用规则：只读、弱化、带锁——与用户能改的部分一眼分开。
      FushiCard(
        key: const ValueKey<String>('srs-field-ai-prompt-preview-rules-card'),
        tone: FushiCardTone.secondary,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Row(
              spacing: tokens.spacing.gap / 2,
              children: <Widget>[
                const FushiIcon(FushiIcons.lock, size: 16),
                Expanded(
                  child: Text(
                    t.srs_field_ai_prompt_preview_rules,
                    style: context.fushiType.labelMedium,
                  ),
                ),
              ],
            ),
            Text(t.srs_field_ai_prompt_preview_rules_hint, style: muted),
            SelectableText(
              request.appRules,
              key: const ValueKey<String>('srs-field-ai-prompt-preview-rules'),
              style: mono.copyWith(color: scheme.onSurfaceVariant),
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
          key: const ValueKey<String>('srs-field-ai-prompt-new-variant'),
          icon: FushiIcons.add,
          tooltip: t.srs_field_ai_prompt_new_variant,
          enabled: !_busy,
          onTap: _newVariant,
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
          // 新页面动效：各块错峰进场，按钮按压缩放；时长走 FushiMotion（组件内部）。
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
