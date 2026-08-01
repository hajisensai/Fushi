import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

typedef LapisPreviewBuilder = Widget Function(
  BuildContext context,
  LapisVisualField selectedField,
  bool showBack,
);

/// 选中某个 Anki 字段的占位符时弹选择器；返回 null = 用户取消。
typedef LapisHandlebarPicker = Future<String?> Function(
  String ankiField,
  String currentValue,
);

/// 可视化编辑器的保存结果。
///
/// 字段映射与 CSS 一起走「保存/取消」这一个闸门：映射如果边改边落盘，「取消」
/// 就只能撤回样式、撤不回映射，同一个页面出现两套生效语义。
class LapisVisualEditorResult {
  const LapisVisualEditorResult({
    required this.customCss,
    required this.fieldMappings,
  });

  final String customCss;

  /// Anki 字段名 → Hibiki 占位符。只含**本次被改过**的字段，调用方逐条写回即可。
  final Map<String, String> fieldMappings;
}

/// Lapis 卡片的可视化编辑入口：样式 + 区块位置 + 字段映射。
///
/// 预览使用 vendored Lapis 原始 CSS 和与真实模板同名的 DOM selector；样式与布局
/// 只改 [lapisVisualCssBeginMarker] 托管区，完整手写 CSS 仍在「高级 CSS」中保留。
class LapisStyleEditorPage extends StatefulWidget {
  const LapisStyleEditorPage({
    required this.initialCustomCss,
    required this.fontScalePercent,
    this.noteTypeFields = const <String>[],
    this.initialFieldMappings = const <String, String>{},
    this.pickHandlebar,
    this.previewBuilder,
    super.key,
  });

  final String initialCustomCss;
  final int fontScalePercent;

  /// 当前所选 Anki 卡型的字段名。字段映射区按它自我门控：卡型里没有的字段一律
  /// 不显示，所以用户选的不是 Lapis 时不会把映射写到别的卡型头上。
  final List<String> noteTypeFields;

  /// 当前 Anki 字段 → 占位符映射。
  final Map<String, String> initialFieldMappings;

  /// 为 null = 不提供映射编辑（例如未连接 Anki）。
  final LapisHandlebarPicker? pickHandlebar;

  /// Widget 测试用替身，避免测试环境创建原生 WebView。
  @visibleForTesting
  final LapisPreviewBuilder? previewBuilder;

  @override
  State<LapisStyleEditorPage> createState() => _LapisStyleEditorPageState();
}

class _LapisStyleEditorPageState extends State<LapisStyleEditorPage> {
  late final TextEditingController _advancedCssController;
  late final String _initialComposedCss;
  late final Map<LapisVisualField, LapisVisualRule> _rules;
  late LapisVisualLayout _layout;

  /// 本次改过的字段映射（Anki 字段名 → 占位符），保存时才回传。
  final Map<String, String> _mappingEdits = <String, String>{};

  /// 打开时托管区段相对用户自由 CSS 的位置，保存时原样写回（见
  /// [composeLapisVisualStyleSheet]）。托管区段整块 `!important`，把用户写在
  /// 它之后的覆盖搬到前面就等于静默推翻用户改动。
  late final bool _managedFirst;
  LapisVisualField _selectedField = LapisVisualField.expression;
  bool _showBack = true;
  bool _allowPop = false;
  InAppWebViewController? _previewController;

  static const List<String> _colorChoices = <String>[
    '#2F6B5F',
    '#3D5A80',
    '#8A5A44',
    '#A13D63',
    '#C47F17',
  ];
  static const List<String> _highlightChoices = <String>[
    '#FFF0A6',
    '#D9EAD3',
    '#DDEBFF',
    '#F7D7E3',
    '#E8DDF5',
  ];

  @override
  void initState() {
    super.initState();
    final LapisVisualStyleSheet sheet =
        splitLapisVisualStyleSheet(widget.initialCustomCss);
    _rules = Map<LapisVisualField, LapisVisualRule>.of(sheet.rules);
    _layout = sheet.layout;
    _managedFirst = sheet.managedFirst;
    _advancedCssController = TextEditingController(text: sheet.freeformCss)
      ..addListener(_handleAdvancedCssChanged);
    _initialComposedCss = _composeCustomCss();
  }

  @override
  void dispose() {
    _previewController = null;
    _advancedCssController
      ..removeListener(_handleAdvancedCssChanged)
      ..dispose();
    super.dispose();
  }

  String _composeCustomCss() => composeLapisVisualStyleSheet(
        freeformCss: _advancedCssController.text,
        rules: _rules,
        layout: _layout,
        managedFirst: _managedFirst,
      );

  bool get _isDirty =>
      _composeCustomCss() != _initialComposedCss || _mappingEdits.isNotEmpty;

  /// 字段当前占位符：本次改过的优先，否则取进页面时的值。
  String _mappingFor(String ankiField) =>
      _mappingEdits[ankiField] ?? widget.initialFieldMappings[ankiField] ?? '';

  LapisVisualRule get _selectedRule =>
      _rules[_selectedField] ?? const LapisVisualRule();

  void _handleAdvancedCssChanged() {
    setState(() {});
    _refreshPreview();
  }

  void _selectField(LapisVisualField field) {
    if (_selectedField == field && (_showBack || !field.backOnly)) return;
    setState(() {
      _selectedField = field;
      if (field.backOnly) _showBack = true;
    });
    _refreshPreview();
  }

  void _updateSelectedRule(LapisVisualRule rule) {
    setState(() {
      if (rule.isDefault) {
        _rules.remove(_selectedField);
      } else {
        _rules[_selectedField] = rule;
      }
    });
    _refreshPreview();
  }

  void _updateLayout(LapisVisualLayout layout) {
    setState(() => _layout = layout);
    _refreshPreview();
  }

  Future<void> _editMapping(String ankiField) async {
    final LapisHandlebarPicker? picker = widget.pickHandlebar;
    if (picker == null) return;
    final String current = _mappingFor(ankiField);
    final String? next = await picker(ankiField, current);
    if (next == null || !mounted || next == current) return;
    setState(() {
      // 改回进页面时的原值 = 没改过，从 diff 里撤掉，别让保存按钮假亮。
      if (next == (widget.initialFieldMappings[ankiField] ?? '')) {
        _mappingEdits.remove(ankiField);
      } else {
        _mappingEdits[ankiField] = next;
      }
    });
  }

  void _setShowBack(bool value) {
    if (_showBack == value) return;
    setState(() => _showBack = value);
    _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    final InAppWebViewController? controller = _previewController;
    if (controller == null) return;
    final String css = composeLapisCss(
      fontScalePercent: widget.fontScalePercent,
      customCss: _composeCustomCss(),
    );
    try {
      await controller.evaluateJavascript(
        source: buildLapisStylePreviewRefreshScript(
          css: css,
          selectedField: _selectedField,
          showBack: _showBack,
        ),
      );
    } catch (_) {
      // 页面退出或平台 WebView 正在重建时的刷新是尽力而为；下一次 onLoadStop
      // 会用当前 Dart 状态完整重放。
    }
  }

  Future<void> _attemptClose() async {
    if (!_isDirty) {
      _pop();
      return;
    }
    final bool? discard = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.book_css_editor_unsaved_changes),
        content: Text(t.book_css_editor_unsaved_changes_message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.book_css_editor_discard),
          ),
        ],
      ),
    );
    if (discard == true) _pop();
  }

  void _save() => _pop(
        LapisVisualEditorResult(
          customCss: _composeCustomCss(),
          fieldMappings: Map<String, String>.of(_mappingEdits),
        ),
      );

  void _pop([LapisVisualEditorResult? result]) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) unawaited(_attemptClose());
      },
      child: HibikiToolScaffold(
        title: t.anki_lapis_visual_editor,
        actions: <Widget>[
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                icon: const Icon(Icons.flip_to_front_outlined),
                label: Text(t.anki_lapis_visual_front),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: const Icon(Icons.flip_to_back_outlined),
                label: Text(t.anki_lapis_visual_back),
              ),
            ],
            selected: <bool>{_showBack},
            onSelectionChanged: (Set<bool> value) => _setShowBack(value.first),
          ),
        ],
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.gap,
                tokens.spacing.card,
                0,
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget preview = _buildPreview(tokens);
                  final Widget controls = _buildControls(tokens);
                  if (constraints.maxWidth >= 820) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(flex: 5, child: preview),
                        SizedBox(width: tokens.spacing.card),
                        SizedBox(width: 340, child: controls),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(height: 360, child: preview),
                      SizedBox(height: tokens.spacing.card),
                      Expanded(child: controls),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.gap,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: _attemptClose,
                  child: Text(t.dialog_cancel),
                ),
                SizedBox(width: tokens.spacing.gap),
                FilledButton.icon(
                  onPressed: _isDirty ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(t.dialog_save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(HibikiDesignTokens tokens) {
    final Widget? testPreview = widget.previewBuilder?.call(
      context,
      _selectedField,
      _showBack,
    );
    final Widget preview = testPreview ?? _buildWebPreview();
    return Semantics(
      label: t.anki_lapis_visual_preview,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaces.page,
          borderRadius: tokens.radii.cardRadius,
          border: Border.all(color: tokens.surfaces.outline),
        ),
        child: ClipRRect(
          borderRadius: tokens.radii.cardRadius,
          child: preview,
        ),
      ),
    );
  }

  Widget _buildWebPreview() {
    final String css = composeLapisCss(
      fontScalePercent: widget.fontScalePercent,
      customCss: _composeCustomCss(),
    );
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: buildLapisStylePreviewHtml(
          css: css,
          selectedField: _selectedField,
          showBack: _showBack,
          darkMode: Theme.of(context).brightness == Brightness.dark,
        ),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: false,
        disableContextMenu: true,
        horizontalScrollBarEnabled: false,
        transparentBackground: false,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        _previewController = controller;
        controller.addJavaScriptHandler(
          handlerName: 'selectLapisVisualField',
          callback: (List<dynamic> arguments) {
            final Object? raw = arguments.isEmpty ? null : arguments.first;
            if (raw is! String) return null;
            final LapisVisualField? field = LapisVisualField.fromWireName(raw);
            if (field != null && mounted) _selectField(field);
            return null;
          },
        );
      },
      onLoadStop: (_, __) => _refreshPreview(),
    );
  }

  Widget _buildControls(HibikiDesignTokens tokens) {
    final LapisVisualRule rule = _selectedRule;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.anki_lapis_visual_select_field,
            style: tokens.type.sectionLabel,
          ),
          SizedBox(height: tokens.spacing.gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  _targetPath(_selectedField).join('  ›  '),
                  style: tokens.type.listSubtitle,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          _buildTargetGroup(
            tokens: tokens,
            label: t.anki_lapis_visual_target_card_content,
            fields: const <LapisVisualField>[
              LapisVisualField.expression,
              LapisVisualField.reading,
              LapisVisualField.sentence,
            ],
          ),
          SizedBox(height: tokens.spacing.card),
          _buildTargetGroup(
            tokens: tokens,
            label: t.anki_lapis_visual_target_definition,
            fields: const <LapisVisualField>[
              LapisVisualField.definitionBox,
              LapisVisualField.definitionContent,
              LapisVisualField.selectedDefinition,
              LapisVisualField.primaryDefinition,
              LapisVisualField.glossaries,
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.only(bottom: tokens.spacing.gap),
            leading: const Icon(Icons.tune_outlined),
            title: Text(t.anki_lapis_visual_target_inside_definition),
            initiallyExpanded: _isDetailedDefinitionTarget(_selectedField),
            children: <Widget>[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  children: <Widget>[
                    for (final LapisVisualField field
                        in const <LapisVisualField>[
                      LapisVisualField.definitionInfo,
                      LapisVisualField.dictionaryEntry,
                      LapisVisualField.dictionaryName,
                      LapisVisualField.definitionExample,
                    ])
                      HibikiSelectableChip(
                        label: _fieldLabel(field),
                        selected: field == _selectedField,
                        onSelected: (_) => _selectField(field),
                      ),
                  ],
                ),
              ),
            ],
          ),
          _buildLayoutSection(tokens),
          SizedBox(height: tokens.spacing.card),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _fieldLabel(_selectedField),
                  style: tokens.type.listTitle,
                ),
              ),
              TextButton(
                onPressed: rule.isDefault
                    ? null
                    : () => _updateSelectedRule(const LapisVisualRule()),
                child: Text(t.anki_lapis_visual_reset_field),
              ),
            ],
          ),
          if (_fieldNote(_selectedField) case final String note)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: tokens.surfaces.onVariant,
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(note, style: tokens.type.listSubtitle),
                  ),
                ],
              ),
            ),
          Text(
            t.anki_lapis_visual_font_size(
              percent: rule.fontScalePercent,
            ),
            style: tokens.type.listSubtitle,
          ),
          Slider(
            value: rule.fontScalePercent.toDouble(),
            min: 70,
            max: 180,
            divisions: 22,
            label: '${rule.fontScalePercent}%',
            onChanged: (double value) => _updateSelectedRule(
              rule.copyWith(fontScalePercent: value.round()),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(t.anki_lapis_visual_bold),
            value: rule.bold,
            onChanged: (bool value) =>
                _updateSelectedRule(rule.copyWith(bold: value)),
          ),
          SizedBox(height: tokens.spacing.gap),
          DropdownMenu<int>(
            key: ValueKey<String>(
              'line-height-${_selectedField.wireName}-'
              '${rule.lineHeightPercent}',
            ),
            expandedInsets: EdgeInsets.zero,
            initialSelection: rule.lineHeightPercent ?? 0,
            label: Text(t.anki_lapis_visual_line_height),
            dropdownMenuEntries: <DropdownMenuEntry<int>>[
              DropdownMenuEntry<int>(
                value: 0,
                label: t.anki_lapis_visual_default,
              ),
              const DropdownMenuEntry<int>(value: 120, label: '1.2'),
              const DropdownMenuEntry<int>(value: 150, label: '1.5'),
              const DropdownMenuEntry<int>(value: 175, label: '1.75'),
              const DropdownMenuEntry<int>(value: 200, label: '2.0'),
            ],
            onSelected: (int? value) => _updateSelectedRule(
              rule.copyWith(
                lineHeightPercent: value == null || value == 0 ? null : value,
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.anki_lapis_visual_alignment,
            style: tokens.type.listSubtitle,
          ),
          SizedBox(height: tokens.spacing.gap),
          SegmentedButton<LapisVisualTextAlign?>(
            showSelectedIcon: false,
            segments: <ButtonSegment<LapisVisualTextAlign?>>[
              ButtonSegment<LapisVisualTextAlign?>(
                value: null,
                label: Text(t.anki_lapis_visual_default),
              ),
              const ButtonSegment<LapisVisualTextAlign?>(
                value: LapisVisualTextAlign.start,
                icon: Icon(Icons.format_align_left_outlined),
              ),
              const ButtonSegment<LapisVisualTextAlign?>(
                value: LapisVisualTextAlign.center,
                icon: Icon(Icons.format_align_center_outlined),
              ),
              const ButtonSegment<LapisVisualTextAlign?>(
                value: LapisVisualTextAlign.end,
                icon: Icon(Icons.format_align_right_outlined),
              ),
            ],
            selected: <LapisVisualTextAlign?>{rule.alignment},
            onSelectionChanged: (Set<LapisVisualTextAlign?> value) =>
                _updateSelectedRule(
              rule.copyWith(alignment: value.first),
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          _buildColorRow(
            tokens: tokens,
            label: t.anki_lapis_visual_color,
            selectedHex: rule.colorHex,
            presets: _colorChoices,
            onChanged: (String? colorHex) =>
                _updateSelectedRule(rule.copyWith(colorHex: colorHex)),
          ),
          SizedBox(height: tokens.spacing.card),
          _buildColorRow(
            tokens: tokens,
            label: t.anki_lapis_visual_background_color,
            selectedHex: rule.backgroundColorHex,
            presets: _highlightChoices,
            onChanged: (String? colorHex) => _updateSelectedRule(
              rule.copyWith(backgroundColorHex: colorHex),
            ),
          ),
          if (_selectedField.supportsBoxLayout) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              leading: const Icon(Icons.crop_square_outlined),
              title: Text(t.anki_lapis_visual_box_layout),
              children: <Widget>[
                _buildOptionalSlider(
                  title: t.anki_lapis_visual_border_width,
                  value: rule.borderWidthPx,
                  enabledValue: 1,
                  max: 8,
                  onChanged: (int? value) => _updateSelectedRule(
                    rule.copyWith(
                      borderWidthPx: value,
                      borderColorHex:
                          value == null ? null : rule.borderColorHex,
                    ),
                  ),
                ),
                if (rule.borderWidthPx != null) ...<Widget>[
                  _buildColorRow(
                    tokens: tokens,
                    label: t.anki_lapis_visual_border_color,
                    selectedHex: rule.borderColorHex,
                    presets: _colorChoices,
                    onChanged: (String? colorHex) => _updateSelectedRule(
                      rule.copyWith(borderColorHex: colorHex),
                    ),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                ],
                _buildOptionalSlider(
                  title: t.anki_lapis_visual_corner_radius,
                  value: rule.borderRadiusPx,
                  enabledValue: 8,
                  max: 32,
                  onChanged: (int? value) => _updateSelectedRule(
                    rule.copyWith(borderRadiusPx: value),
                  ),
                ),
                _buildOptionalSlider(
                  title: t.anki_lapis_visual_padding,
                  value: rule.paddingPx,
                  enabledValue: 12,
                  max: 32,
                  onChanged: (int? value) => _updateSelectedRule(
                    rule.copyWith(paddingPx: value),
                  ),
                ),
                _buildOptionalSlider(
                  title: t.anki_lapis_visual_margin,
                  value: rule.marginBlockPx,
                  enabledValue: 8,
                  max: 32,
                  onChanged: (int? value) => _updateSelectedRule(
                    rule.copyWith(marginBlockPx: value),
                  ),
                ),
              ],
            ),
          ],
          _buildFieldMappingSection(tokens),
          SizedBox(height: tokens.spacing.card),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code_outlined),
            title: Text(t.anki_lapis_visual_advanced_css),
            subtitle: Text(t.anki_lapis_custom_css_hint),
            children: <Widget>[
              TextField(
                controller: _advancedCssController,
                minLines: 8,
                maxLines: 16,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: '.front-vocab { color: #8ab4f8; }',
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.card),
        ],
      ),
    );
  }

  String _fieldLabel(LapisVisualField field) => switch (field) {
        LapisVisualField.expression => t.anki_lapis_visual_field_expression,
        LapisVisualField.reading => t.anki_lapis_visual_field_reading,
        LapisVisualField.sentence => t.anki_lapis_visual_field_sentence,
        LapisVisualField.definitionInfo =>
          t.anki_lapis_visual_field_definition_info,
        LapisVisualField.definitionBox =>
          t.anki_lapis_visual_field_definition_box,
        LapisVisualField.definitionContent =>
          t.anki_lapis_visual_field_definition_content,
        LapisVisualField.selectedDefinition =>
          t.anki_lapis_visual_field_selected_definition,
        LapisVisualField.primaryDefinition =>
          t.anki_lapis_visual_field_primary_definition,
        LapisVisualField.glossaries => t.anki_lapis_visual_field_glossaries,
        LapisVisualField.dictionaryEntry =>
          t.anki_lapis_visual_field_dictionary_entry,
        LapisVisualField.dictionaryName =>
          t.anki_lapis_visual_field_dictionary_name,
        LapisVisualField.definitionExample =>
          t.anki_lapis_visual_field_definition_example,
      };

  /// 字段在真卡上的可见性/结构限制。预览是理想卡，真卡不一定长这样——把差异
  /// 说清楚，别让用户以为改了没生效是 bug。
  String? _fieldNote(LapisVisualField field) => switch (field) {
        LapisVisualField.definitionInfo =>
          t.anki_lapis_visual_field_definition_info_note,
        LapisVisualField.dictionaryName =>
          t.anki_lapis_visual_field_dictionary_name_note,
        _ => null,
      };

  List<String> _targetPath(LapisVisualField field) {
    if (const <LapisVisualField>{
      LapisVisualField.expression,
      LapisVisualField.reading,
      LapisVisualField.sentence,
    }.contains(field)) {
      return <String>[
        t.anki_lapis_visual_target_card_content,
        _fieldLabel(field),
      ];
    }
    if (_isDetailedDefinitionTarget(field)) {
      return <String>[
        t.anki_lapis_visual_target_definition,
        t.anki_lapis_visual_target_inside_definition,
        _fieldLabel(field),
      ];
    }
    return <String>[
      t.anki_lapis_visual_target_definition,
      _fieldLabel(field),
    ];
  }

  bool _isDetailedDefinitionTarget(LapisVisualField field) =>
      const <LapisVisualField>{
        LapisVisualField.definitionInfo,
        LapisVisualField.dictionaryEntry,
        LapisVisualField.dictionaryName,
        LapisVisualField.definitionExample,
      }.contains(field);

  Widget _buildTargetGroup({
    required HibikiDesignTokens tokens,
    required String label,
    required List<LapisVisualField> fields,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(label, style: tokens.type.listSubtitle),
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final LapisVisualField field in fields)
                HibikiSelectableChip(
                  label: _fieldLabel(field),
                  selected: field == _selectedField,
                  onSelected: (_) => _selectField(field),
                ),
            ],
          ),
        ],
      );

  /// 卡片区块位置。三项都直接映射 vendored Lapis 自己的 user settings 变量
  /// （见 [LapisVisualLayout]）——空值 = 不覆写 = 保持出厂布局。
  Widget _buildLayoutSection(HibikiDesignTokens tokens) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.only(bottom: tokens.spacing.gap),
        leading: const Icon(Icons.dashboard_customize_outlined),
        title: Text(t.anki_lapis_visual_layout),
        subtitle: Text(t.anki_lapis_visual_layout_hint),
        initiallyExpanded: !_layout.isDefault,
        children: <Widget>[
          _buildLayoutPicker(
            label: t.anki_lapis_visual_layout_sentence,
            selected: _layout.sentencePosition?.cssValue ?? '',
            options: <MapEntry<String, String>>[
              MapEntry<String, String>(
                LapisSentencePosition.above.cssValue,
                t.anki_lapis_visual_layout_sentence_above,
              ),
              MapEntry<String, String>(
                LapisSentencePosition.below.cssValue,
                t.anki_lapis_visual_layout_sentence_below,
              ),
            ],
            onSelected: (String value) => _updateLayout(
              _layout.copyWith(
                sentencePosition: LapisSentencePosition.fromCssValue(value),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildLayoutPicker(
            label: t.anki_lapis_visual_layout_picture,
            selected: _layout.picturePosition?.cssValue ?? '',
            options: <MapEntry<String, String>>[
              MapEntry<String, String>(
                LapisPicturePosition.right.cssValue,
                t.anki_lapis_visual_layout_picture_right,
              ),
              MapEntry<String, String>(
                LapisPicturePosition.left.cssValue,
                t.anki_lapis_visual_layout_picture_left,
              ),
              MapEntry<String, String>(
                LapisPicturePosition.alt.cssValue,
                t.anki_lapis_visual_layout_picture_alt,
              ),
            ],
            onSelected: (String value) => _updateLayout(
              _layout.copyWith(
                picturePosition: LapisPicturePosition.fromCssValue(value),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildLayoutPicker(
            label: t.anki_lapis_visual_layout_audio,
            selected: _layout.audioButtonsPosition?.cssValue ?? '',
            options: <MapEntry<String, String>>[
              MapEntry<String, String>(
                LapisAudioButtonsPosition.header.cssValue,
                t.anki_lapis_visual_layout_audio_header,
              ),
              MapEntry<String, String>(
                LapisAudioButtonsPosition.fixed.cssValue,
                t.anki_lapis_visual_layout_audio_fixed,
              ),
              MapEntry<String, String>(
                LapisAudioButtonsPosition.alt.cssValue,
                t.anki_lapis_visual_layout_audio_alt,
              ),
            ],
            onSelected: (String value) => _updateLayout(
              _layout.copyWith(
                audioButtonsPosition:
                    LapisAudioButtonsPosition.fromCssValue(value),
              ),
            ),
          ),
        ],
      );

  /// 位置下拉。空串是「默认」的哨兵值——`DropdownMenu` 的 `initialSelection`
  /// 传 null 会显示成空输入框（看不出当前是默认还是没选），与「行高」同一处理。
  Widget _buildLayoutPicker({
    required String label,
    required String selected,
    required List<MapEntry<String, String>> options,
    required ValueChanged<String> onSelected,
  }) =>
      DropdownMenu<String>(
        key: ValueKey<String>('lapis-layout-$label-$selected'),
        expandedInsets: EdgeInsets.zero,
        initialSelection: selected,
        label: Text(label),
        dropdownMenuEntries: <DropdownMenuEntry<String>>[
          DropdownMenuEntry<String>(
            value: '',
            label: t.anki_lapis_visual_default,
          ),
          for (final MapEntry<String, String> option in options)
            DropdownMenuEntry<String>(
              value: option.key,
              label: option.value,
            ),
        ],
        onSelected: (String? value) => onSelected(value ?? ''),
      );

  /// 选中区域由哪些 Anki 字段填充。只列**当前卡型真有**的字段：用户选的不是
  /// Lapis 时这里自然空掉，不会把 Lapis 的字段名写到别的卡型头上。
  Widget _buildFieldMappingSection(HibikiDesignTokens tokens) {
    if (widget.pickHandlebar == null || widget.noteTypeFields.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<String> sources = lapisVisualFieldSources(_selectedField);
    final List<String> present =
        sources.where(widget.noteTypeFields.contains).toList();
    // 有来源字段、但当前卡型一个都没有 = 用户选的不是 Lapis 系卡型。整块收起，
    // 而不是拿「这块没有字段」的说法糊过去——那是另一回事（下面那条分支）。
    if (sources.isNotEmpty && present.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Text(t.anki_field_mappings, style: tokens.type.sectionLabel),
        SizedBox(height: tokens.spacing.gap),
        Text(
          present.isEmpty
              ? t.anki_lapis_visual_mapping_none
              : t.anki_lapis_visual_mapping_hint,
          style: tokens.type.listSubtitle,
        ),
        for (final String ankiField in present)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(ankiField),
            subtitle: Text(
              _mappingFor(ankiField).isEmpty
                  ? t.anki_field_not_mapped
                  : _mappingFor(ankiField),
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => unawaited(_editMapping(ankiField)),
          ),
      ],
    );
  }

  /// 一行色板：默认 + 预设 + 当前自定义色 + 取色器入口。
  Widget _buildColorRow({
    required HibikiDesignTokens tokens,
    required String label,
    required String? selectedHex,
    required List<String> presets,
    required ValueChanged<String?> onChanged,
  }) {
    // 取色器选出来的色多半不在预设里。不单独补一颗的话，选完当前色就从盘上消失，
    // 用户看不出选中的是什么、也无从改回。
    final bool isCustom = selectedHex != null && !presets.contains(selectedHex);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: tokens.type.listSubtitle),
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              _LapisColorChoice(
                colorHex: null,
                selected: selectedHex == null,
                tooltip: t.anki_lapis_visual_default,
                onTap: () => onChanged(null),
              ),
              for (final String colorHex in presets)
                _LapisColorChoice(
                  colorHex: colorHex,
                  selected: selectedHex == colorHex,
                  tooltip: colorHex,
                  onTap: () => onChanged(colorHex),
                ),
              if (isCustom)
                _LapisColorChoice(
                  colorHex: selectedHex,
                  selected: true,
                  tooltip: selectedHex,
                  onTap: () =>
                      unawaited(_pickCustomColor(selectedHex, onChanged)),
                ),
              _LapisColorChoice(
                colorHex: selectedHex,
                selected: false,
                tooltip: t.anki_lapis_visual_color_custom,
                showPaletteIcon: true,
                onTap: () =>
                    unawaited(_pickCustomColor(selectedHex, onChanged)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 任意取色。卡片 CSS 只接受 `#RRGGBB`（[LapisVisualRule.fromJson] 的校验），
  /// 所以关掉 alpha 通道并强制不透明——半透明选出来也会在回读时被丢掉。
  Future<void> _pickCustomColor(
    String? initialHex,
    ValueChanged<String?> onChanged,
  ) async {
    final Color initial = initialHex == null
        ? Theme.of(context).colorScheme.primary
        : lapisColorFromHex(initialHex);
    Color picked = initial;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t.anki_lapis_visual_color_picker_title),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: initial,
            onColorChanged: (Color color) => picked = color,
            portraitOnly: true,
            enableAlpha: false,
            displayThumbColor: true,
            hexInputBar: true,
            labelTypes: const <ColorLabelType>[],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_ok),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) onChanged(lapisHexFromColor(picked));
  }

  Widget _buildOptionalSlider({
    required String title,
    required int? value,
    required int enabledValue,
    required int max,
    required ValueChanged<int?> onChanged,
  }) =>
      Column(
        children: <Widget>[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(value == null ? title : '$title · ${value}px'),
            value: value != null,
            onChanged: (bool enabled) =>
                onChanged(enabled ? enabledValue : null),
          ),
          if (value != null)
            Slider(
              value: value.toDouble(),
              min: 0,
              max: max.toDouble(),
              divisions: max,
              label: '${value}px',
              onChanged: (double next) => onChanged(next.round()),
            ),
        ],
      );
}

class _LapisColorChoice extends StatelessWidget {
  const _LapisColorChoice({
    required this.colorHex,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.showPaletteIcon = false,
  });

  final String? colorHex;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  /// 取色器入口：不代表某个具体色，只画调色板图标。
  final bool showPaletteIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color color = colorHex == null || showPaletteIcon
        ? tokens.surfaces.overlay
        : lapisColorFromHex(colorHex!);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Semantics(
          button: true,
          selected: selected,
          label: tooltip,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: switch ((showPaletteIcon, selected, colorHex)) {
              (true, _, _) => const Icon(Icons.palette_outlined, size: 20),
              (_, true, _) => Icon(
                  Icons.check,
                  color: color.computeLuminance() > 0.55
                      ? colors.onSurface
                      : colors.surface,
                ),
              (_, _, null) => const Icon(Icons.format_color_reset_outlined),
              _ => null,
            },
          ),
        ),
      ),
    );
  }
}

/// `#RRGGBB` → 不透明 [Color]。
Color lapisColorFromHex(String colorHex) =>
    Color(int.parse(colorHex.substring(1), radix: 16) | 0xFF000000);

/// [Color] → `#RRGGBB`（大写）。大写是硬要求：[LapisVisualRule.fromJson] 回读时
/// 统一大写，取色器若吐小写，同一个颜色在「选中判定」与「是否 dirty」上会被判成
/// 两个不同值。
String lapisHexFromColor(Color color) => '#'
    '${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
