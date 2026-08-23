import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/utils.dart';

/// 词典查词结果的可视化样式面板：选部位 → 调属性。
///
/// 不持有真相源。规则表由外层对话框的草稿会话拥有（与手写 CSS 同一个「保存 /
/// 取消」闸门），本组件只负责把改动回调出去——边改边落盘会让「取消」只能撤回
/// 一半，同一个对话框出现两套生效语义。
class DictStyleVisualEditor extends StatelessWidget {
  const DictStyleVisualEditor({
    super.key,
    required this.rules,
    required this.scopeDictionary,
    required this.selectedPart,
    required this.onSelectPart,
    required this.onRulesChanged,
  });

  /// 当前规则表（全部作用域）。
  final List<DictStyleRule> rules;

  /// null = 全部词典；非 null = 仅该本。
  final String? scopeDictionary;

  final DictStylePart selectedPart;
  final ValueChanged<DictStylePart> onSelectPart;
  final ValueChanged<List<DictStyleRule>> onRulesChanged;

  /// 当前生效的作用域：非释义部位恒为全局，哪怕下拉里选着某本词典。
  ///
  /// 作用域锚点 `[data-dictionary]` 只包住释义子树，别的部位限定到单本词典在
  /// DOM 上就无从谈起（一个词条的词头是所有词典共用的）。
  String? get _effectiveScope =>
      dictStylePartSupportsPerDictionary(selectedPart) ? scopeDictionary : null;

  DictStyleProps get _props =>
      dictStylePropsFor(rules, selectedPart, _effectiveScope);

  void _update(DictStyleProps next) {
    onRulesChanged(
      dictStyleRulesWith(rules, selectedPart, _effectiveScope, next),
    );
  }

  /// 该部位在当前作用域下有没有设过东西（给选择器打个点，否则设过什么全靠记）。
  bool _hasRules(DictStylePart part) {
    final String? scope =
        dictStylePartSupportsPerDictionary(part) ? scopeDictionary : null;
    return !dictStylePropsFor(rules, part, scope).isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool scopeIgnored = scopeDictionary != null &&
        !dictStylePartSupportsPerDictionary(selectedPart);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final DictStylePart part in DictStylePart.values)
                FilterChip(
                  selected: part == selectedPart,
                  onSelected: (_) => onSelectPart(part),
                  avatar: _hasRules(part)
                      ? const Icon(Icons.brush_outlined, size: 16)
                      : null,
                  label: Text(dictStylePartLabel(part)),
                ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          if (scopeIgnored)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: tokens.surfaces.outline,
                  ),
                  SizedBox(width: tokens.spacing.gap / 2),
                  Expanded(
                    child: Text(
                      t.dict_style_global_only,
                      style: tokens.type.listSubtitle,
                    ),
                  ),
                ],
              ),
            ),
          _buildColorRow(
            context: context,
            tokens: tokens,
            label: t.dict_style_prop_text_color,
            value: _props.textColor,
            presets: _kTextPresets,
            enableAlpha: false,
            onChanged: (int? v) => _update(_props.copyWith(textColor: v)),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildColorRow(
            context: context,
            tokens: tokens,
            label: t.dict_style_prop_background,
            value: _props.backgroundColor,
            presets: _kHighlightPresets,
            // 高亮几乎总要半透明，否则盖住下面的文字底色、深浅主题各坏一个。
            enableAlpha: true,
            onChanged: (int? v) => _update(_props.copyWith(backgroundColor: v)),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildTriState(
            tokens: tokens,
            label: t.dict_style_prop_bold,
            value: _props.bold,
            onChanged: (bool? v) => _update(_props.copyWith(bold: v)),
          ),
          _buildTriState(
            tokens: tokens,
            label: t.dict_style_prop_italic,
            value: _props.italic,
            onChanged: (bool? v) => _update(_props.copyWith(italic: v)),
          ),
          _buildTriState(
            tokens: tokens,
            label: t.dict_style_prop_underline,
            value: _props.underline,
            onChanged: (bool? v) => _update(_props.copyWith(underline: v)),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildOptionalSlider(
            label: t.dict_style_prop_font_scale,
            value: _props.fontScale,
            enabledValue: 1.2,
            min: 0.6,
            max: 2.4,
            divisions: 18,
            format: (double v) => '${(v * 100).round()}%',
            onChanged: (double? v) => _update(_props.copyWith(fontScale: v)),
          ),
          _buildOptionalSlider(
            label: t.dict_style_prop_corner_radius,
            value: _props.cornerRadius,
            enabledValue: 4,
            min: 0,
            max: 24,
            divisions: 24,
            format: (double v) => '${v.round()}px',
            onChanged: (double? v) => _update(_props.copyWith(cornerRadius: v)),
          ),
          SizedBox(height: tokens.spacing.gap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed:
                  _props.isEmpty ? null : () => _update(const DictStyleProps()),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(t.dict_style_part_reset),
            ),
          ),
        ],
      ),
    );
  }

  /// 三态开关：默认（不设）/ 开 / 关。
  ///
  /// 两态不够用——「关」和「不设」必须分得开：不设 = 继承词典自己的样式，关 =
  /// 强行压成 normal。词典自带 styles.css 里就有加粗的释义，用户要能压掉它。
  Widget _buildTriState({
    required FushiDesignTokens tokens,
    required String label,
    required bool? value,
    required ValueChanged<bool?> onChanged,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: tokens.type.listSubtitle)),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: <ButtonSegment<int>>[
              ButtonSegment<int>(
                  value: 0, label: Text(t.dict_style_prop_default)),
              ButtonSegment<int>(value: 1, label: Text(t.dict_style_prop_on)),
              ButtonSegment<int>(value: 2, label: Text(t.dict_style_prop_off)),
            ],
            selected: <int>{
              value == null
                  ? 0
                  : value
                      ? 1
                      : 2,
            },
            onSelectionChanged: (Set<int> picked) {
              switch (picked.first) {
                case 1:
                  onChanged(true);
                case 2:
                  onChanged(false);
                default:
                  onChanged(null);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOptionalSlider({
    required String label,
    required double? value,
    required double enabledValue,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double?> onChanged,
  }) {
    return Column(
      children: <Widget>[
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(value == null ? label : '$label · ${format(value)}'),
          value: value != null,
          onChanged: (bool on) => onChanged(on ? enabledValue : null),
        ),
        if (value != null)
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: format(value),
            onChanged: onChanged,
          ),
      ],
    );
  }

  Widget _buildColorRow({
    required BuildContext context,
    required FushiDesignTokens tokens,
    required String label,
    required int? value,
    required List<int> presets,
    required bool enableAlpha,
    required ValueChanged<int?> onChanged,
  }) {
    // 取色器选出来的色多半不在预设里。不补一颗的话选完当前色就从盘上消失，
    // 用户看不出选中的是什么、也无从改回（与 Lapis 编辑器同款处理）。
    final bool isCustom = value != null && !presets.contains(value);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: tokens.type.listSubtitle),
          SizedBox(height: tokens.spacing.gap / 2),
          Wrap(
            spacing: tokens.spacing.gap / 2,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              _ColorChoice(
                argb: null,
                selected: value == null,
                tooltip: t.dict_style_prop_default,
                onTap: () => onChanged(null),
              ),
              for (final int preset in presets)
                _ColorChoice(
                  argb: preset,
                  selected: value == preset,
                  tooltip: _hexLabel(preset),
                  onTap: () => onChanged(preset),
                ),
              if (isCustom)
                _ColorChoice(
                  argb: value,
                  selected: true,
                  tooltip: _hexLabel(value),
                  onTap: () => unawaited(
                    _pickCustom(context, value, enableAlpha, onChanged),
                  ),
                ),
              _ColorChoice(
                argb: value,
                selected: false,
                showPaletteIcon: true,
                tooltip: t.dict_style_prop_text_color,
                onTap: () => unawaited(
                  _pickCustom(context, value, enableAlpha, onChanged),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustom(
    BuildContext context,
    int? initialArgb,
    bool enableAlpha,
    ValueChanged<int?> onChanged,
  ) async {
    final Color initial = initialArgb == null
        ? Theme.of(context).colorScheme.primary
        : Color(initialArgb);
    Color picked = initial;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: initial,
            onColorChanged: (Color color) => picked = color,
            portraitOnly: true,
            enableAlpha: enableAlpha,
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
    if (confirmed == true) onChanged(picked.toARGB32());
  }
}

/// 部位的本地化名。
///
/// 与 [DictStylePart] 同文件的 [dictStylePartSelector] 是「机器名」，这里是给人
/// 看的名字；两者必须一一对应，新增部位漏了这里会编译期报缺 case。
String dictStylePartLabel(DictStylePart part) {
  switch (part) {
    case DictStylePart.entryCard:
      return t.dict_style_part_entry_card;
    case DictStylePart.expression:
      return t.dict_style_part_expression;
    case DictStylePart.ruby:
      return t.dict_style_part_ruby;
    case DictStylePart.expressionTag:
      return t.dict_style_part_expression_tag;
    case DictStylePart.deinflectionTag:
      return t.dict_style_part_deinflection_tag;
    case DictStylePart.frequency:
      return t.dict_style_part_frequency;
    case DictStylePart.pitch:
      return t.dict_style_part_pitch;
    case DictStylePart.dictionaryLabel:
      return t.dict_style_part_dictionary_label;
    case DictStylePart.glossaryContent:
      return t.dict_style_part_glossary_content;
    case DictStylePart.glossaryTag:
      return t.dict_style_part_glossary_tag;
  }
}

String _hexLabel(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// 文字色预设：深浅主题下都要能读，故取中等明度。
const List<int> _kTextPresets = <int>[
  0xFFD32F2F,
  0xFFE65100,
  0xFF2E7D32,
  0xFF1565C0,
  0xFF6A1B9A,
  0xFF546E7A,
];

/// 高亮预设：一律半透明，压在文字底色上不吃掉对比度，深浅主题共用一套。
const List<int> _kHighlightPresets = <int>[
  0x66FFEB3B,
  0x66FF9800,
  0x664CAF50,
  0x662196F3,
  0x66E040FB,
  0x66FF5252,
];

class _ColorChoice extends StatelessWidget {
  const _ColorChoice({
    required this.argb,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.showPaletteIcon = false,
  });

  final int? argb;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final bool showPaletteIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: argb == null ? scheme.surfaceContainerHighest : Color(argb!),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: showPaletteIcon
              ? Icon(Icons.colorize, size: 16, color: scheme.onSurfaceVariant)
              : (argb == null
                  ? Icon(
                      Icons.block,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    )
                  : null),
        ),
      ),
    );
  }
}
