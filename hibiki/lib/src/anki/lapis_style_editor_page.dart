import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

typedef LapisPreviewBuilder = Widget Function(
  BuildContext context,
  LapisVisualField selectedField,
  bool showBack,
);

/// Lapis 自定义 CSS 的可视化入口。
///
/// 预览使用 vendored Lapis 原始 CSS 和与真实模板同名的 DOM selector；字段级控件
/// 只改 [lapisVisualCssBeginMarker] 托管区，完整手写 CSS 仍在「高级 CSS」中保留。
class LapisStyleEditorPage extends StatefulWidget {
  const LapisStyleEditorPage({
    required this.initialCustomCss,
    required this.fontScalePercent,
    this.previewBuilder,
    super.key,
  });

  final String initialCustomCss;
  final int fontScalePercent;

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

  @override
  void initState() {
    super.initState();
    final LapisVisualStyleSheet sheet =
        splitLapisVisualStyleSheet(widget.initialCustomCss);
    _rules = Map<LapisVisualField, LapisVisualRule>.of(sheet.rules);
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
      );

  bool get _isDirty => _composeCustomCss() != _initialComposedCss;

  LapisVisualRule get _selectedRule =>
      _rules[_selectedField] ?? const LapisVisualRule();

  void _handleAdvancedCssChanged() {
    setState(() {});
    _refreshPreview();
  }

  void _selectField(LapisVisualField field) {
    final bool backOnly = field == LapisVisualField.reading ||
        field == LapisVisualField.primaryDefinition ||
        field == LapisVisualField.glossaries;
    if (_selectedField == field && (_showBack || !backOnly)) return;
    setState(() {
      _selectedField = field;
      if (backOnly) _showBack = true;
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
        source: '''
document.getElementById('lapis-style').textContent = ${_jsonForScript(css)};
window.hibikiLapisEditor.showSide(${_jsonForScript(_showBack ? 'back' : 'front')});
window.hibikiLapisEditor.selectField(${_jsonForScript(_selectedField.wireName)});
''',
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

  void _save() => _pop(_composeCustomCss());

  void _pop([String? result]) {
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
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: tokens.radii.cardRadius,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final LapisVisualField field in LapisVisualField.values)
                HibikiSelectableChip(
                  label: _fieldLabel(field),
                  selected: field == _selectedField,
                  onSelected: (_) => _selectField(field),
                ),
            ],
          ),
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
          Text(
            t.anki_lapis_visual_color,
            style: tokens.type.listSubtitle,
          ),
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              _LapisColorChoice(
                colorHex: null,
                selected: rule.colorHex == null,
                tooltip: t.anki_lapis_visual_default,
                onTap: () => _updateSelectedRule(rule.copyWith(colorHex: null)),
              ),
              for (final String colorHex in _colorChoices)
                _LapisColorChoice(
                  colorHex: colorHex,
                  selected: rule.colorHex == colorHex,
                  tooltip: colorHex,
                  onTap: () => _updateSelectedRule(
                    rule.copyWith(colorHex: colorHex),
                  ),
                ),
            ],
          ),
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
        LapisVisualField.primaryDefinition =>
          t.anki_lapis_visual_field_primary_definition,
        LapisVisualField.glossaries => t.anki_lapis_visual_field_glossaries,
      };
}

class _LapisColorChoice extends StatelessWidget {
  const _LapisColorChoice({
    required this.colorHex,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final String? colorHex;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color color = colorHex == null
        ? colors.surfaceContainerHighest
        : Color(int.parse(colorHex!.substring(1), radix: 16) | 0xFF000000);
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
            child: selected
                ? Icon(
                    Icons.check,
                    color: color.computeLuminance() > 0.55
                        ? colors.onSurface
                        : colors.surface,
                  )
                : colorHex == null
                    ? const Icon(Icons.format_color_reset_outlined)
                    : null,
          ),
        ),
      ),
    );
  }
}

String _jsonForScript(String value) =>
    jsonEncode(value).replaceAll('<', r'\u003C');
