/// 内置「Fushi 卡片」正面 / 背面的区块布局编辑：拖动调区块顺序、勾选增删内置区块、点开改
/// 内置区块的选项，加自己的「字段区块」「HTML 区块」。
///
/// 改动写回这一面的模板草稿（[fushiCardTemplateFor]：骨架、脚本与样式不动，区块写成带
/// `data-fc-block` 标记与 `data-fc-opt-*` 选项的片段）——模板就是唯一的数据来源。复习页认得出
/// 这种模板（[fushiCardLayoutOf]），仍走原生 Fushi 卡面；导出到 Anki 也照常可用。HTML 区块编辑
/// 时当场按原生 HTML 子集判一次，画不了就说是哪一句（复习时整张卡回退网页卡面）。这一面骨架
/// 被改到认不出时给出「重置区块布局」（恢复这一面的默认模板，另一面与样式不变）。
library;

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_fushi_card_items.dart'
    show srsHtmlFragmentProbe;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 区块的显示名（笔记编辑页的字段分组与区块布局编辑共用）。
String srsFushiBlockLabel(FushiCardBlock b) => switch (b) {
  FushiCardBlock.term => t.srs_note_block_term,
  FushiCardBlock.reading => t.srs_note_block_reading,
  FushiCardBlock.picture => t.srs_note_block_picture,
  FushiCardBlock.sentence => t.srs_note_block_sentence,
  FushiCardBlock.definitions => t.srs_note_block_definitions,
  FushiCardBlock.frequency => t.srs_note_block_frequency,
  FushiCardBlock.source => t.srs_note_block_source,
};

/// 正面内置区块的显示名。
String srsFushiFrontBlockLabel(FushiCardFrontBlock b) => switch (b) {
  FushiCardFrontBlock.frequency => t.srs_fushi_block_front_frequency,
  FushiCardFrontBlock.prompt => t.srs_fushi_block_prompt,
  FushiCardFrontBlock.hint => t.srs_fushi_block_hint,
};

String _optionLabel(String name) => switch (name) {
  kFushiOptPitch => t.srs_fushi_opt_pitch,
  kFushiOptAudio => t.srs_fushi_opt_audio,
  kFushiOptFreq => t.srs_fushi_opt_freq,
  kFushiOptTranslation => t.srs_fushi_opt_translation,
  kFushiOptExpand => t.srs_fushi_opt_expand,
  kFushiOptLabel => t.srs_fushi_opt_label,
  _ => name,
};

String _styleLabel(FushiCardFieldStyle s) => switch (s) {
  FushiCardFieldStyle.body => t.srs_fushi_block_style_body,
  FushiCardFieldStyle.tag => t.srs_fushi_block_style_tag,
  FushiCardFieldStyle.quote => t.srs_fushi_block_style_quote,
  FushiCardFieldStyle.small => t.srs_fushi_block_style_small,
};

/// 面板里的一行：布局项、是否显示（只有内置区块能隐藏）、稳定 id（拖动 / 展开状态的 key）。
class _Entry {
  _Entry(this.id, this.item, {this.on = true});

  final int id;
  FushiCardItem item;
  bool on;
}

class SrsFushiBlockLayoutPanel extends StatefulWidget {
  const SrsFushiBlockLayoutPanel({
    super.key,
    required this.side,
    required this.template,
    required this.cssDefault,
    required this.fieldNames,
    required this.onChanged,
  });

  /// 编辑哪一面。
  final FushiCardSide side;

  /// 这一面的模板源码（名字形式，草稿）。
  final String template;

  /// 样式是否仍是内置版本：否则复习时整张卡走网页卡面，区块布局只影响那里的模板，这里
  /// 提示一句。
  final bool cssDefault;

  /// 笔记类型的字段名（字段区块的下拉选项）。
  final List<String> fieldNames;

  /// 这一面新的模板源码（写回草稿）。
  final ValueChanged<String> onChanged;

  @override
  State<SrsFushiBlockLayoutPanel> createState() =>
      _SrsFushiBlockLayoutPanelState();
}

class _SrsFushiBlockLayoutPanelState extends State<SrsFushiBlockLayoutPanel> {
  List<_Entry> _entries = <_Entry>[];
  final Set<int> _open = <int>{};
  int _nextId = 0;

  /// 当前这一面能否被区块布局认出。
  bool _recognized = true;

  /// 上一次自己写出去的源码：草稿回传同一份时不重读（保住隐藏区块的位置与展开状态）。
  String? _emitted;

  List<Enum> get _builtins => widget.side == FushiCardSide.front
      ? FushiCardFrontBlock.values
      : FushiCardBlock.values;

  @override
  void initState() {
    super.initState();
    _read(widget.template);
  }

  @override
  void didUpdateWidget(SrsFushiBlockLayoutPanel old) {
    super.didUpdateWidget(old);
    if (widget.side != old.side ||
        (widget.template != old.template && widget.template != _emitted)) {
      _open.clear();
      _read(widget.template);
    }
  }

  void _read(String template) {
    final List<FushiCardItem>? layout = fushiCardLayoutOf(
      template,
      widget.side,
    );
    _recognized = layout != null;
    if (layout == null) return;
    final Set<Enum> present = <Enum>{
      for (final FushiCardItem x in layout)
        if (x is FushiCardBlockItem) x.block,
    };
    _entries = <_Entry>[
      for (final FushiCardItem x in layout) _Entry(_nextId++, x),
      // 隐藏的内置区块排在后面（勾回来时落在原地）。
      for (final Enum b in _builtins)
        if (!present.contains(b))
          _Entry(_nextId++, FushiCardBlockItem(b), on: false),
    ];
  }

  void _emit() {
    final String template = fushiCardTemplateFor(widget.side, <FushiCardItem>[
      for (final _Entry e in _entries)
        if (e.on) e.item,
    ]);
    _emitted = template;
    widget.onChanged(template);
  }

  void _update(VoidCallback change) {
    setState(change);
    _emit();
  }

  void _reset() {
    setState(() {
      _open.clear();
      _read(
        widget.side == FushiCardSide.front
            ? kFushiCardFrontTemplate
            : kFushiCardBackTemplate,
      );
    });
    _emit();
  }

  void _add(FushiCardItem item) {
    final _Entry e = _Entry(_nextId++, item);
    // 加在最后一个显示中的区块后面（隐藏的内置区块仍排在最后）。
    final int at = _entries.lastIndexWhere((_Entry x) => x.on) + 1;
    _update(() {
      _entries.insert(at, e);
      _open.add(e.id);
    });
  }

  String _title(FushiCardItem item) => switch (item) {
    FushiCardBlockItem(:final FushiCardBlock block) => srsFushiBlockLabel(
      block,
    ),
    FushiCardBlockItem(:final FushiCardFrontBlock block) =>
      srsFushiFrontBlockLabel(block),
    FushiCardBlockItem() => '',
    FushiCardFieldItem(:final String field, :final String title) =>
      '${t.srs_fushi_block_field} · ${title.isEmpty ? field : title}',
    FushiCardHtmlItem() => t.srs_fushi_block_html,
  };

  String? _subtitle(FushiCardItem item) => switch (item) {
    FushiCardFieldItem(:final String field, :final FushiCardFieldStyle style) =>
      '$field · ${_styleLabel(style)}',
    FushiCardHtmlItem(wrapped: false) => t.srs_fushi_block_html_raw,
    FushiCardHtmlItem(:final String html) =>
      html.replaceAll(RegExp(r'\s+'), ' ').trim(),
    FushiCardBlockItem() => null,
  };

  bool _editable(FushiCardItem item) => switch (item) {
    FushiCardBlockItem(:final Enum block) => fushiCardBlockOptions(
      block,
    ).isNotEmpty,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool front = widget.side == FushiCardSide.front;
    return FushiEntranceScope(
      child: Column(
        key: ValueKey<String>('srs-fushi-block-layout-${widget.side.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            front
                ? t.srs_fushi_layout_front_title
                : t.srs_fushi_layout_back_title,
            style: context.fushiType.titleMediumEmphasized,
          ),
          Text(t.srs_fushi_layout_hint, style: context.fushiType.bodySmall),
          if (!widget.cssDefault)
            FushiInlineNotice(
              key: const ValueKey<String>('srs-fushi-layout-web-face'),
              severity: FushiNoticeSeverity.warning,
              message: t.srs_fushi_layout_css_changed,
            ),
          if (!_recognized)
            FushiInlineNotice(
              key: const ValueKey<String>('srs-fushi-layout-unrecognized'),
              severity: FushiNoticeSeverity.warning,
              message: t.srs_fushi_layout_unrecognized,
              actions: <Widget>[
                FushiOutlinedButton(
                  key: const ValueKey<String>('srs-fushi-layout-reset'),
                  onPressed: _reset,
                  child: Text(t.srs_fushi_layout_reset),
                ),
              ],
            )
          else ...<Widget>[
            // 自实现的 FushiReorderableColumn：SDK 的拖拽代理不认 FushiAppUiScale 的祖先缩放
            // （BUG-778 同根因）。
            FushiReorderableColumn(
              itemCount: _entries.length,
              useDragHandles: true,
              feedbackBorderRadius: FushiM3eShape.smallRadius,
              keyForIndex: (int i) => ValueKey<int>(_entries[i].id),
              onReorder: (int from, int to) => _update(() {
                final _Entry e = _entries.removeAt(from);
                _entries.insert(to, e);
              }),
              itemBuilder: (BuildContext context, int i) =>
                  FushiStaggeredEntrance(
                    index: i,
                    child: _row(context, _entries[i]),
                  ),
            ),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                FushiOutlinedButton(
                  key: const ValueKey<String>('srs-fushi-layout-add-field'),
                  onPressed: widget.fieldNames.isEmpty
                      ? null
                      : () => _add(
                          FushiCardFieldItem(field: widget.fieldNames.first),
                        ),
                  child: Text(t.srs_fushi_block_add_field),
                ),
                FushiOutlinedButton(
                  key: const ValueKey<String>('srs-fushi-layout-add-html'),
                  onPressed: () => _add(const FushiCardHtmlItem('')),
                  child: Text(t.srs_fushi_block_add_html),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, _Entry e) {
    final FushiCardItem item = e.item;
    final bool builtin = item is FushiCardBlockItem;
    final bool editable = _editable(item) && e.on;
    final bool open = editable && _open.contains(e.id);
    final String key = switch (item) {
      FushiCardBlockItem(:final Enum block) => block.name,
      _ => 'item-${e.id}',
    };
    void toggleOpen() => setState(() {
      if (!_open.remove(e.id)) _open.add(e.id);
    });
    void toggleOn() => _update(() => e.on = !e.on);
    final String? subtitle = _subtitle(item);
    return Column(
      key: ValueKey<String>('srs-fushi-layout-$key'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiListItem(
          onTap: editable ? toggleOpen : (builtin ? toggleOn : null),
          leading: builtin
              ? FushiCheckbox(value: e.on, onChanged: (_) => toggleOn())
              : FushiIcon(
                  item is FushiCardHtmlItem ? FushiIcons.code : FushiIcons.edit,
                ),
          title: Text(_title(item)),
          subtitle: subtitle == null || subtitle.isEmpty
              ? null
              : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (editable)
                FushiIconButton(
                  key: ValueKey<String>('srs-fushi-layout-$key-edit'),
                  icon: open ? FushiIcons.expandLess : FushiIcons.expandMore,
                  tooltip: t.srs_fushi_block_edit,
                  onTap: toggleOpen,
                ),
              if (!builtin)
                FushiIconButton(
                  key: ValueKey<String>('srs-fushi-layout-$key-remove'),
                  icon: FushiIcons.delete,
                  tooltip: t.srs_fushi_block_remove,
                  onTap: () => _update(() {
                    _entries.remove(e);
                    _open.remove(e.id);
                  }),
                ),
              const FushiReorderableDragHandle(
                child: FushiIcon(FushiIcons.dragIndicator),
              ),
            ],
          ),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.enter,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 12),
                  child: _editor(context, e, key),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _editor(BuildContext context, _Entry e, String key) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiCardItem item = e.item;
    final List<Widget> children = switch (item) {
      FushiCardBlockItem(:final Enum block) => <Widget>[
        for (final FushiCardBlockOption o in fushiCardBlockOptions(block))
          if (o.kind == FushiCardOptionKind.toggle)
            FushiSwitchListTile(
              key: ValueKey<String>('srs-fushi-layout-$key-opt-${o.name}'),
              title: Text(_optionLabel(o.name)),
              value: item.flag(o.name),
              onChanged: (bool v) => _update(
                () => e.item = item.withOption(o.name, v ? '1' : '0'),
              ),
            )
          else
            FushiTextField(
              key: ValueKey<String>('srs-fushi-layout-$key-opt-${o.name}'),
              labelText: _optionLabel(o.name),
              initialValue: item.text(o.name),
              onChanged: (String v) => _update(
                () => e.item = (e.item as FushiCardBlockItem).withOption(
                  o.name,
                  v,
                ),
              ),
            ),
      ],
      FushiCardFieldItem() => <Widget>[
        GamepadMenuDropdown<String>(
          key: ValueKey<String>('srs-fushi-layout-$key-field'),
          label: t.srs_fushi_block_field_label,
          entries: <GamepadDropdownEntry<String>>[
            for (final String f in <String>{item.field, ...widget.fieldNames})
              (value: f, label: f),
          ],
          selected: item.field,
          onChanged: (String f) => _update(
            () => e.item = (e.item as FushiCardFieldItem).copyWith(field: f),
          ),
        ),
        adaptiveSegmentedButton<FushiCardFieldStyle>(
          context: context,
          segments: <ButtonSegment<FushiCardFieldStyle>>[
            for (final FushiCardFieldStyle s in FushiCardFieldStyle.values)
              ButtonSegment<FushiCardFieldStyle>(
                value: s,
                label: Text(_styleLabel(s)),
              ),
          ],
          selected: <FushiCardFieldStyle>{item.style},
          onSelectionChanged: (Set<FushiCardFieldStyle> s) => _update(
            () => e.item = (e.item as FushiCardFieldItem).copyWith(
              style: s.first,
            ),
          ),
        ),
        FushiTextField(
          key: ValueKey<String>('srs-fushi-layout-$key-title'),
          labelText: t.srs_fushi_block_title_label,
          initialValue: item.title,
          onChanged: (String v) => _update(
            () => e.item = (e.item as FushiCardFieldItem).copyWith(title: v),
          ),
        ),
      ],
      FushiCardHtmlItem(:final String html) => <Widget>[
        FushiTextField(
          key: ValueKey<String>('srs-fushi-layout-$key-html'),
          labelText: t.srs_fushi_block_html_label,
          initialValue: html,
          minLines: 3,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          // 改过内部的区块一经编辑就成了标准的 HTML 区块（整段原文包进去，标记照旧在里面，
          // 写回模板仍认得）。
          onChanged: (String v) => _update(() => e.item = FushiCardHtmlItem(v)),
        ),
        _htmlCheck(html),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap,
      children: children,
    );
  }

  /// HTML 区块当场判一次：标签是否配对（写回模板后区块布局还读得回来），原生画不画得了
  /// （字段引用按空值展开，只看结构与样式写法）。
  Widget _htmlCheck(String html) {
    if (html.trim().isEmpty) return const SizedBox.shrink();
    final FushiCardHtmlItem item = FushiCardHtmlItem(html);
    final List<FushiCardItem>? back = fushiCardLayoutOf(
      fushiCardTemplateFor(widget.side, <FushiCardItem>[item]),
      widget.side,
    );
    if (back == null || back.length != 1 || back.single != item) {
      return FushiInlineNotice(
        key: const ValueKey<String>('srs-fushi-layout-html-check'),
        severity: FushiNoticeSeverity.warning,
        message: t.srs_fushi_block_html_unbalanced,
      );
    }
    final String? reason = srsHtmlFragmentProbe(
      renderAnkiTemplate(html, const <String, String>{}),
    ).reason;
    return FushiInlineNotice(
      key: const ValueKey<String>('srs-fushi-layout-html-check'),
      severity: reason == null
          ? FushiNoticeSeverity.success
          : FushiNoticeSeverity.warning,
      message: reason == null
          ? t.srs_fushi_block_html_native
          : t.srs_fushi_block_html_unsupported(reason: reason),
    );
  }
}
