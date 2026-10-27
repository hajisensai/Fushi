/// 模板编辑器的「可视化」页：把一面卡当成一串块（字段 / 文字 / 分隔线 / 正面内容）来拼，
/// 点块展开它的属性，拖动或用菜单调顺序；底部是「让 AI 帮忙」。
///
/// 面板不持有块：块归模板编辑器（[SrsTemplateEditorPage]）所有，每次改动经 [onChanged] 交回去，
/// 由它编译进模板正文、刷新预览、判断是否有未保存修改——可视化与代码两页改的是同一份正文。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/srs/srs_builtin.dart' show kSrsBuiltinFushiCardKey;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart'
    show kSrsFieldColorPalette;
import 'package:fushi/src/pages/implementations/srs/srs_field_label.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_field_markup.dart' show srsCssColor;
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 字段的图标（按字段大类）。
IconData srsFieldKindIcon(SrsFieldKind kind) => switch (kind) {
  SrsFieldKind.text => FushiIcons.textFields,
  SrsFieldKind.rich => FushiIcons.dictionary,
  SrsFieldKind.audio => FushiIcons.audio,
  SrsFieldKind.image => FushiIcons.image,
  SrsFieldKind.flag => FushiIcons.flag,
  SrsFieldKind.data => FushiIcons.dataUsage,
};

String srsVisualSizeLabel(SrsVisualSize s) => switch (s) {
  SrsVisualSize.display => t.srs_visual_size_display,
  SrsVisualSize.title => t.srs_visual_size_title,
  SrsVisualSize.body => t.srs_visual_size_body,
  SrsVisualSize.small => t.srs_visual_size_small,
};

String srsVisualAlignLabel(SrsVisualAlign a) => switch (a) {
  SrsVisualAlign.start => t.srs_visual_align_start,
  SrsVisualAlign.center => t.srs_visual_align_center,
  SrsVisualAlign.end => t.srs_visual_align_end,
};

String srsVisualSpacingLabel(SrsVisualSpacing v) => switch (v) {
  SrsVisualSpacing.none => t.srs_visual_spacing_none,
  SrsVisualSpacing.compact => t.srs_visual_spacing_compact,
  SrsVisualSpacing.normal => t.srs_visual_spacing_normal,
  SrsVisualSpacing.loose => t.srs_visual_spacing_loose,
};

String srsVisualImageSizeLabel(SrsVisualImageSize v) => switch (v) {
  SrsVisualImageSize.auto => t.srs_visual_image_auto,
  SrsVisualImageSize.small => t.srs_visual_image_small,
  SrsVisualImageSize.medium => t.srs_visual_image_medium,
  SrsVisualImageSize.large => t.srs_visual_image_large,
  SrsVisualImageSize.full => t.srs_visual_image_full,
};

String srsVisualToneLabel(SrsVisualTone v) => switch (v) {
  SrsVisualTone.normal => t.srs_visual_tone_normal,
  SrsVisualTone.accent => t.srs_visual_tone_accent,
  SrsVisualTone.muted => t.srs_visual_tone_muted,
};

String srsVisualFilterLabel(SrsVisualFilter f) => switch (f) {
  SrsVisualFilter.plain => t.srs_visual_filter_plain,
  SrsVisualFilter.furigana => t.srs_visual_filter_furigana,
  SrsVisualFilter.kanji => t.srs_visual_filter_kanji,
  SrsVisualFilter.kana => t.srs_visual_filter_kana,
  SrsVisualFilter.hint => t.srs_visual_filter_hint,
  SrsVisualFilter.cloze => t.srs_visual_filter_cloze,
};

String srsVisualFilterHint(SrsVisualFilter f) => switch (f) {
  SrsVisualFilter.plain => t.srs_visual_filter_plain_hint,
  SrsVisualFilter.furigana => t.srs_visual_filter_furigana_hint,
  SrsVisualFilter.kanji => t.srs_visual_filter_kanji_hint,
  SrsVisualFilter.kana => t.srs_visual_filter_kana_hint,
  SrsVisualFilter.hint => t.srs_visual_filter_hint_hint,
  SrsVisualFilter.cloze => t.srs_visual_filter_cloze_hint,
};

/// 让用户挑一个字段：每项带人话名字 + 说明（不认识的字段原样显示名字）。
Future<String?> pickSrsField(
  BuildContext context, {
  required SrsNoteTypeView type,
  String? selected,
}) => showFushiChoiceDialog<String>(
  context: context,
  title: t.srs_visual_pick_field,
  icon: FushiIcons.textFields,
  selected: selected,
  options: <FushiChoiceOption<String>>[
    for (final SrsFieldDef f in type.fields)
      FushiChoiceOption<String>(
        value: f.id,
        label: srsFieldDisplayName(f) == f.name
            ? f.name
            : '${srsFieldDisplayName(f)} · ${f.name}',
        subtitle: srsFieldDisplayDescription(f).isEmpty
            ? null
            : srsFieldDisplayDescription(f),
        icon: srsFieldKindIcon(srsFieldKind(f)),
      ),
  ],
);

/// AI 请求的结果（给面板显示状态用）：null = 成功且已并进草稿；否则是要显示的提示。
typedef SrsVisualAiRunner = Future<String?> Function(String request);

class SrsVisualTemplatePanel extends StatefulWidget {
  const SrsVisualTemplatePanel({
    super.key,
    required this.type,
    required this.back,
    required this.blocks,
    required this.edited,
    required this.onChanged,
    required this.onGenerate,
    this.onAi,
    this.aiExplanation = '',
  });

  final SrsNoteTypeView type;

  /// 当前编辑的是背面。
  final bool back;

  /// 这一面的块；null = 这面还不是可视化做的（显示「转成可视化」）。
  final List<SrsVisualBlock>? blocks;

  /// 代码页手改过这一面（再改会覆盖）。
  final bool edited;

  final ValueChanged<List<SrsVisualBlock>> onChanged;

  /// 按字段自动生成两面布局（替换当前模板）。
  final VoidCallback onGenerate;

  /// 让 AI 生成 / 修改；null = AI 模块关闭（整块不显示）。
  final SrsVisualAiRunner? onAi;

  /// 上一次 AI 给的说明。
  final String aiExplanation;

  @override
  State<SrsVisualTemplatePanel> createState() => _SrsVisualTemplatePanelState();
}

class _SrsVisualTemplatePanelState extends State<SrsVisualTemplatePanel> {
  String? _expanded;
  final TextEditingController _aiRequest = TextEditingController();
  bool _aiBusy = false;
  String? _aiMessage;

  @override
  void dispose() {
    _aiRequest.dispose();
    super.dispose();
  }

  /// 文字 / 小标题输入框 key 的代号：块被外部整体替换（AI、按字段生成、换了模板）时加一，
  /// 让 `initialValue` 输入框按新内容重建。否则重编号后同 id 的新块会沿用旧块的输入框，
  /// 一打字就把旧文字写进新块。
  int _generation = 0;

  /// 面板自己最近一次交出去的块（签名），用来区分「自己的改动回流」与「外部整体替换」。
  String? _emitted;

  List<SrsVisualBlock> get _blocks => widget.blocks ?? const <SrsVisualBlock>[];

  /// 块的签名：不含编译时补记的字段名（回流时它会多出来，不算外部改动）。
  static String _signature(List<SrsVisualBlock>? blocks) =>
      jsonEncode(<Object?>[
        for (final SrsVisualBlock b in blocks ?? const <SrsVisualBlock>[])
          b.toJson()..remove('n'),
      ]);

  @override
  void didUpdateWidget(SrsVisualTemplatePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String now = _signature(widget.blocks);
    if (now != _signature(oldWidget.blocks) && now != _emitted) {
      _expanded = null;
      _generation++;
    }
    _emitted = now;
  }

  void _emit(List<SrsVisualBlock> blocks) {
    _emitted = _signature(blocks);
    widget.onChanged(blocks);
  }

  void _replace(SrsVisualBlock next) => _emit(<SrsVisualBlock>[
    for (final SrsVisualBlock b in _blocks) b.id == next.id ? next : b,
  ]);

  void _move(int from, int to) {
    final List<SrsVisualBlock> list = List<SrsVisualBlock>.of(_blocks);
    if (from < 0 || from >= list.length) return;
    final SrsVisualBlock b = list.removeAt(from);
    list.insert(to.clamp(0, list.length), b);
    _emit(list);
  }

  void _remove(SrsVisualBlock block) {
    if (_expanded == block.id) _expanded = null;
    _emit(<SrsVisualBlock>[
      for (final SrsVisualBlock b in _blocks)
        if (b.id != block.id) b,
    ]);
  }

  Future<void> _add(SrsVisualBlockKind kind) async {
    String? fieldId;
    if (kind == SrsVisualBlockKind.field) {
      fieldId = await pickSrsField(context, type: widget.type);
      if (fieldId == null || !mounted) return;
    }
    final SrsFieldDef? field = widget.type.fieldById(fieldId ?? '');
    final SrsFieldInfo? info = field == null ? null : srsKnownField(field.name);
    final SrsVisualBlock block = SrsVisualBlock(
      id: srsNextVisualBlockId(_blocks),
      kind: kind,
      fieldId: fieldId,
      text: kind == SrsVisualBlockKind.text ? t.srs_visual_text_default : '',
      size: info?.suggestedSize ?? SrsVisualSize.body,
      filter: info?.suggestedFilter ?? SrsVisualFilter.plain,
    );
    setState(() => _expanded = block.id);
    _emit(<SrsVisualBlock>[..._blocks, block]);
  }

  Future<void> _runAi() async {
    final SrsVisualAiRunner? run = widget.onAi;
    final String request = _aiRequest.text.trim();
    if (run == null || request.isEmpty || _aiBusy) return;
    setState(() {
      _aiBusy = true;
      _aiMessage = null;
    });
    try {
      final String? message = await run(request);
      if (mounted) setState(() => _aiMessage = message);
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> children = <Widget>[
      if (widget.blocks == null)
        _convertCard(context)
      else ...<Widget>[
        if (widget.edited)
          FushiInlineNotice(
            key: const ValueKey<String>('srs-visual-edited'),
            icon: FushiIcons.warning,
            message: t.srs_visual_edited_warning,
          ),
        if (_blocks.isEmpty)
          FushiPlaceholderMessage(
            icon: FushiIcons.widgets,
            message: t.srs_visual_empty,
          ),
        for (final (int i, SrsVisualBlock b) in _blocks.indexed)
          _blockCard(context, i, b),
        _addRow(context),
      ],
      if (widget.onAi != null) _aiCard(context),
    ];
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          for (final (int i, Widget w) in children.indexed)
            FushiStaggeredEntrance(index: i, child: w),
        ],
      ),
    );
  }

  /// 代码写的模板：说明它为什么不是可视化的、生成之后会怎样。内置类型（Lapis / Fushi 卡片）
  /// 不是「来自 Anki 或旧版本」——它们用了可视化块表达不了的卡型开关与脚本，没改过就随应用
  /// 更新；这里要说清楚生成并保存后就脱离内置版本（Fushi 卡片还会失去原生卡面）。
  Widget _convertCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? builtin = widget.type.builtinKey;
    return FushiCard(
      key: const ValueKey<String>('srs-visual-convert'),
      tone: FushiCardTone.secondary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            builtin == null
                ? t.srs_visual_convert_title
                : t.srs_visual_builtin_title,
            style: context.fushiType.titleSmall,
          ),
          Text(
            builtin == null
                ? t.srs_visual_convert_body
                : t.srs_visual_builtin_body,
            style: context.fushiType.bodyMedium,
          ),
          if (builtin != null)
            Text(
              builtin == kSrsBuiltinFushiCardKey
                  ? t.srs_visual_builtin_fushi_note
                  : t.srs_visual_builtin_other_note,
              key: const ValueKey<String>('srs-visual-builtin-note'),
              style: context.fushiType.bodySmall,
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('srs-visual-generate'),
              icon: const FushiIcon(FushiIcons.widgets),
              label: Text(t.srs_visual_generate),
              onPressed: widget.onGenerate,
            ),
          ),
        ],
      ),
    );
  }

  String _blockTitle(SrsVisualBlock b) => switch (b.kind) {
    SrsVisualBlockKind.field => () {
      final SrsFieldDef? f = widget.type.fieldById(b.fieldId ?? '');
      return f == null ? t.srs_visual_field_missing : srsFieldDisplayName(f);
    }(),
    SrsVisualBlockKind.text =>
      b.text.trim().isEmpty ? t.srs_visual_kind_text : b.text.trim(),
    SrsVisualBlockKind.divider => t.srs_visual_kind_divider,
    SrsVisualBlockKind.frontSide => t.srs_visual_kind_front_side,
  };

  /// 块标题：字段块显示人话名 + 原名 + ⓘ（点开看字段说明），其余块是纯文字。
  Widget _blockTitleWidget(BuildContext context, SrsVisualBlock b) {
    final SrsFieldDef? f = b.kind == SrsVisualBlockKind.field
        ? widget.type.fieldById(b.fieldId ?? '')
        : null;
    if (f == null) return Text(_blockTitle(b));
    return SrsFieldLabel(
      help: SrsFieldHelp.of(f),
      style: context.fushiType.bodyLarge,
    );
  }

  String _blockSummary(SrsVisualBlock b) => switch (b.kind) {
    SrsVisualBlockKind.field || SrsVisualBlockKind.text => <String>[
      srsVisualSizeLabel(b.size),
      srsVisualAlignLabel(b.align),
      if (b.filter != SrsVisualFilter.plain) srsVisualFilterLabel(b.filter),
      if (b.tone != SrsVisualTone.normal) srsVisualToneLabel(b.tone),
      if (b.italic) t.srs_visual_prop_italic,
      ?b.color,
      if (b.spacing != SrsVisualSpacing.normal)
        '${t.srs_visual_prop_spacing} ${srsVisualSpacingLabel(b.spacing)}',
      if (b.kind == SrsVisualBlockKind.field &&
          b.imageSize != SrsVisualImageSize.auto)
        '${t.srs_visual_prop_image_size} ${srsVisualImageSizeLabel(b.imageSize)}',
    ].where((String s) => s.isNotEmpty).join(' · '),
    SrsVisualBlockKind.divider => <String>[
      srsVisualToneLabel(b.tone),
      if (b.spacing != SrsVisualSpacing.normal)
        '${t.srs_visual_prop_spacing} ${srsVisualSpacingLabel(b.spacing)}',
    ].join(' · '),
    SrsVisualBlockKind.frontSide => t.srs_visual_kind_front_side_hint,
  };

  IconData _blockIcon(SrsVisualBlock b) => switch (b.kind) {
    SrsVisualBlockKind.field => () {
      final SrsFieldDef? f = widget.type.fieldById(b.fieldId ?? '');
      return f == null ? FushiIcons.warning : srsFieldKindIcon(srsFieldKind(f));
    }(),
    SrsVisualBlockKind.text => FushiIcons.title,
    SrsVisualBlockKind.divider => FushiIcons.remove,
    SrsVisualBlockKind.frontSide => FushiIcons.viewAgenda,
  };

  Widget _blockCard(BuildContext context, int index, SrsVisualBlock b) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool open = _expanded == b.id;
    final bool hasProps = b.kind != SrsVisualBlockKind.frontSide;
    return FushiCard(
      key: ValueKey<String>('srs-visual-block-${b.id}'),
      tone: open ? FushiCardTone.secondary : FushiCardTone.neutral,
      padding: EdgeInsets.zero,
      pressScale: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiPressScale(
            child: FushiListItem(
              key: ValueKey<String>('srs-visual-block-tile-${b.id}'),
              leading: FushiListLeadingIcon(_blockIcon(b)),
              title: _blockTitleWidget(context, b),
              subtitle: Text(_blockSummary(b)),
              onTap: hasProps
                  ? () => setState(() => _expanded = open ? null : b.id)
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIconButton(
                    key: ValueKey<String>('srs-visual-up-${b.id}'),
                    icon: FushiIcons.arrowUp,
                    tooltip: t.srs_visual_move_up,
                    enabled: index > 0,
                    onTap: () => _move(index, index - 1),
                  ),
                  FushiIconButton(
                    key: ValueKey<String>('srs-visual-down-${b.id}'),
                    icon: FushiIcons.arrowDown,
                    tooltip: t.srs_visual_move_down,
                    enabled: index < _blocks.length - 1,
                    onTap: () => _move(index, index + 1),
                  ),
                  FushiIconButton(
                    key: ValueKey<String>('srs-visual-delete-${b.id}'),
                    icon: FushiIcons.delete,
                    tooltip: t.srs_visual_delete,
                    onTap: () => _remove(b),
                  ),
                ],
              ),
            ),
          ),
          FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.enter,
            alignment: Alignment.topCenter,
            child: open && hasProps
                ? Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.card,
                      0,
                      tokens.spacing.card,
                      tokens.spacing.card,
                    ),
                    child: _props(context, b),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _props(BuildContext context, SrsVisualBlock b) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool textual =
        b.kind == SrsVisualBlockKind.field || b.kind == SrsVisualBlockKind.text;
    final SrsFieldDef? field = widget.type.fieldById(b.fieldId ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        if (b.kind == SrsVisualBlockKind.field)
          AdaptiveSettingsNavigationRow(
            key: ValueKey<String>('srs-visual-field-${b.id}'),
            title: t.srs_visual_prop_field,
            subtitle: field == null
                ? t.srs_visual_field_missing
                : <String>[
                    srsFieldDisplayName(field),
                    if (srsFieldDisplayDescription(field).isNotEmpty)
                      srsFieldDisplayDescription(field),
                  ].join('\n'),
            icon: FushiIcons.textFields,
            onTap: () => unawaited(() async {
              final String? id = await pickSrsField(
                context,
                type: widget.type,
                selected: b.fieldId,
              );
              if (id != null) _replace(b.copyWith(fieldId: id));
            }()),
          ),
        if (b.kind == SrsVisualBlockKind.text)
          FushiTextField(
            key: ValueKey<String>('srs-visual-text-${b.id}-$_generation'),
            initialValue: b.text,
            labelText: t.srs_visual_prop_text,
            minLines: 1,
            maxLines: 4,
            onChanged: (String v) => _replace(b.copyWith(text: v)),
          ),
        if (textual) ...<Widget>[
          AdaptiveSettingsSegmentedRow<SrsVisualSize>(
            key: ValueKey<String>('srs-visual-size-${b.id}'),
            title: t.srs_visual_prop_size,
            selected: b.size,
            segments: <ButtonSegment<SrsVisualSize>>[
              for (final SrsVisualSize s in SrsVisualSize.values)
                ButtonSegment<SrsVisualSize>(
                  value: s,
                  label: Text(srsVisualSizeLabel(s)),
                ),
            ],
            onChanged: (SrsVisualSize v) => _replace(b.copyWith(size: v)),
          ),
          AdaptiveSettingsSegmentedRow<SrsVisualAlign>(
            key: ValueKey<String>('srs-visual-align-${b.id}'),
            title: t.srs_visual_prop_align,
            selected: b.align,
            segments: <ButtonSegment<SrsVisualAlign>>[
              for (final SrsVisualAlign a in SrsVisualAlign.values)
                ButtonSegment<SrsVisualAlign>(
                  value: a,
                  label: Text(srsVisualAlignLabel(a)),
                ),
            ],
            onChanged: (SrsVisualAlign v) => _replace(b.copyWith(align: v)),
          ),
        ],
        AdaptiveSettingsSegmentedRow<SrsVisualTone>(
          key: ValueKey<String>('srs-visual-tone-${b.id}'),
          title: t.srs_visual_prop_tone,
          selected: b.tone,
          segments: <ButtonSegment<SrsVisualTone>>[
            for (final SrsVisualTone v in SrsVisualTone.values)
              if (b.kind != SrsVisualBlockKind.divider ||
                  v != SrsVisualTone.muted)
                ButtonSegment<SrsVisualTone>(
                  value: v,
                  label: Text(srsVisualToneLabel(v)),
                ),
          ],
          onChanged: (SrsVisualTone v) => _replace(b.copyWith(tone: v)),
        ),
        if (b.kind == SrsVisualBlockKind.field)
          AdaptiveSettingsNavigationRow(
            key: ValueKey<String>('srs-visual-filter-${b.id}'),
            title: t.srs_visual_prop_filter,
            subtitle:
                '${srsVisualFilterLabel(b.filter)}\n${srsVisualFilterHint(b.filter)}',
            icon: FushiIcons.formatShapes,
            onTap: () => unawaited(() async {
              final SrsVisualFilter? f =
                  await showFushiChoiceDialog<SrsVisualFilter>(
                    context: context,
                    title: t.srs_visual_prop_filter,
                    icon: FushiIcons.formatShapes,
                    selected: b.filter,
                    options: <FushiChoiceOption<SrsVisualFilter>>[
                      for (final SrsVisualFilter v in SrsVisualFilter.values)
                        if (v != SrsVisualFilter.cloze || widget.type.isCloze)
                          FushiChoiceOption<SrsVisualFilter>(
                            value: v,
                            label: srsVisualFilterLabel(v),
                            subtitle: srsVisualFilterHint(v),
                          ),
                    ],
                  );
              if (f != null) _replace(b.copyWith(filter: f));
            }()),
          ),
        if (textual) ...<Widget>[
          AdaptiveSettingsSwitchRow(
            key: ValueKey<String>('srs-visual-bold-${b.id}'),
            title: t.srs_visual_prop_bold,
            value: b.bold,
            onChanged: (bool v) => _replace(b.copyWith(bold: v)),
          ),
          AdaptiveSettingsSwitchRow(
            key: ValueKey<String>('srs-visual-italic-${b.id}'),
            title: t.srs_visual_prop_italic,
            value: b.italic,
            onChanged: (bool v) => _replace(b.copyWith(italic: v)),
          ),
        ],
        _colorRow(context, b),
        AdaptiveSettingsSegmentedRow<SrsVisualSpacing>(
          key: ValueKey<String>('srs-visual-spacing-${b.id}'),
          title: t.srs_visual_prop_spacing,
          selected: b.spacing,
          segments: <ButtonSegment<SrsVisualSpacing>>[
            for (final SrsVisualSpacing v in SrsVisualSpacing.values)
              ButtonSegment<SrsVisualSpacing>(
                value: v,
                label: Text(srsVisualSpacingLabel(v)),
              ),
          ],
          onChanged: (SrsVisualSpacing v) => _replace(b.copyWith(spacing: v)),
        ),
        if (b.kind == SrsVisualBlockKind.field)
          AdaptiveSettingsSegmentedRow<SrsVisualImageSize>(
            key: ValueKey<String>('srs-visual-image-size-${b.id}'),
            title: t.srs_visual_prop_image_size,
            subtitle: t.srs_visual_prop_image_size_hint,
            selected: b.imageSize,
            segments: <ButtonSegment<SrsVisualImageSize>>[
              for (final SrsVisualImageSize v in SrsVisualImageSize.values)
                ButtonSegment<SrsVisualImageSize>(
                  value: v,
                  label: Text(srsVisualImageSizeLabel(v)),
                ),
            ],
            onChanged: (SrsVisualImageSize v) =>
                _replace(b.copyWith(imageSize: v)),
          ),
        if (textual) ...<Widget>[
          AdaptiveSettingsSwitchRow(
            key: ValueKey<String>('srs-visual-boxed-${b.id}'),
            title: t.srs_visual_prop_boxed,
            value: b.boxed,
            onChanged: (bool v) => _replace(b.copyWith(boxed: v)),
          ),
        ],
        if (b.kind == SrsVisualBlockKind.field) ...<Widget>[
          AdaptiveSettingsSwitchRow(
            key: ValueKey<String>('srs-visual-hide-empty-${b.id}'),
            title: t.srs_visual_prop_hide_empty,
            subtitle: t.srs_visual_prop_hide_empty_hint,
            value: b.hideWhenEmpty,
            onChanged: (bool v) => _replace(b.copyWith(hideWhenEmpty: v)),
          ),
          FushiTextField(
            key: ValueKey<String>('srs-visual-label-${b.id}-$_generation'),
            initialValue: b.label,
            labelText: t.srs_visual_prop_label,
            hintText: t.srs_visual_prop_label_hint,
            onChanged: (String v) => _replace(b.copyWith(label: v)),
          ),
        ],
      ],
    );
  }

  /// 自定义颜色：一排色板（第一格 = 不用自定义颜色，按上面的「颜色」走）。
  Widget _colorRow(BuildContext context, SrsVisualBlock b) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    Widget swatch(int? argb) {
      final String? css = argb == null ? null : srsCssColor(argb);
      final bool selected = b.color == css;
      return FushiTooltip(
        message: css ?? t.srs_note_format_color_default,
        child: Semantics(
          button: true,
          selected: selected,
          label: css ?? t.srs_note_format_color_default,
          child: FushiPressScale(
            child: GestureDetector(
              key: ValueKey<String>(
                'srs-visual-color-${b.id}-${css ?? 'none'}',
              ),
              onTap: () => _replace(
                css == null
                    ? b.copyWith(clearColor: true)
                    : b.copyWith(color: css),
              ),
              child: AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: argb == null ? tokens.surfaces.page : Color(argb),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: argb == null
                    ? FushiIcon(
                        FushiIcons.block,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      )
                    : null,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      key: ValueKey<String>('srs-visual-color-${b.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        Text(t.srs_visual_prop_color, style: context.fushiType.bodyLarge),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            swatch(null),
            for (final int c in kSrsFieldColorPalette) swatch(c),
          ],
        ),
      ],
    );
  }

  Widget _addRow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      key: const ValueKey<String>('srs-visual-add'),
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        FushiFilledButton.icon(
          key: const ValueKey<String>('srs-visual-add-field'),
          icon: const FushiIcon(FushiIcons.add),
          label: Text(t.srs_visual_add_field),
          onPressed: () => unawaited(_add(SrsVisualBlockKind.field)),
        ),
        FushiActionChip(
          key: const ValueKey<String>('srs-visual-add-text'),
          icon: FushiIcons.title,
          label: t.srs_visual_kind_text,
          onPressed: () => unawaited(_add(SrsVisualBlockKind.text)),
        ),
        FushiActionChip(
          key: const ValueKey<String>('srs-visual-add-divider'),
          icon: FushiIcons.remove,
          label: t.srs_visual_kind_divider,
          onPressed: () => unawaited(_add(SrsVisualBlockKind.divider)),
        ),
        if (widget.back)
          FushiActionChip(
            key: const ValueKey<String>('srs-visual-add-front-side'),
            icon: FushiIcons.viewAgenda,
            label: t.srs_visual_kind_front_side,
            onPressed: () => unawaited(_add(SrsVisualBlockKind.frontSide)),
          ),
      ],
    );
  }

  Widget _aiCard(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color? onCard = fushiCardToneColors(
      context,
      FushiCardTone.tertiary,
    )?.onContainer;
    final String? message = _aiMessage;
    return FushiCard(
      key: const ValueKey<String>('srs-visual-ai'),
      tone: FushiCardTone.tertiary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.ai_assist_section,
            style: tokens.type.sectionLabel.copyWith(color: onCard),
          ),
          FushiTextField(
            key: const ValueKey<String>('srs-visual-ai-request'),
            controller: _aiRequest,
            hintText: t.srs_visual_ai_hint,
            minLines: 1,
            maxLines: 4,
            onSubmitted: (_) => unawaited(_runAi()),
          ),
          Row(
            children: <Widget>[
              FushiFilledButton.icon(
                key: const ValueKey<String>('srs-visual-ai-run'),
                icon: const FushiIcon(FushiIcons.aiAssistant),
                label: Text(t.srs_visual_ai_run),
                onPressed: _aiBusy ? null : () => unawaited(_runAi()),
              ),
              if (_aiBusy) ...<Widget>[
                SizedBox(width: tokens.spacing.gap),
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (message != null)
            Text(
              message,
              key: const ValueKey<String>('srs-visual-ai-message'),
              style: context.fushiType.bodySmall.copyWith(color: onCard),
            ),
          if (message == null && widget.aiExplanation.isNotEmpty)
            Text(
              widget.aiExplanation,
              key: const ValueKey<String>('srs-visual-ai-explanation'),
              style: context.fushiType.bodySmall.copyWith(color: onCard),
            ),
        ],
      ),
    );
  }
}
