/// 内置「Fushi 卡片」背面的区块布局编辑：拖动调区块顺序、勾选增删区块。
///
/// 改动写回背面模板草稿（[fushiCardBackTemplateFor]：默认背面的区块片段按新顺序放进原来的
/// 位置），骨架、脚本与样式不动——复习页认得出这种模板（[fushiCardBackLayoutOf]），仍走原生
/// Fushi 卡面，按这里的顺序画；导出到 Anki 也照常可用。背面源码改到区块内部、认不出时
/// 给出「重置区块布局」（恢复默认背面，正面与样式不变）。
library;

import 'package:fushi_anki/fushi_anki_core.dart'
    show FushiCardBlock, fushiCardBackLayoutOf, fushiCardBackTemplateFor;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
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

class SrsFushiBlockLayoutPanel extends StatefulWidget {
  const SrsFushiBlockLayoutPanel({
    super.key,
    required this.back,
    required this.frontAndCssDefault,
    required this.onChanged,
  });

  /// 背面模板源码（名字形式，草稿）。
  final String back;

  /// 正面与样式是否仍是内置版本：否则复习时整张卡走网页卡面，区块布局只影响那里的
  /// 模板顺序，这里提示一句。
  final bool frontAndCssDefault;

  /// 新的背面模板源码（写回草稿）。
  final ValueChanged<String> onChanged;

  @override
  State<SrsFushiBlockLayoutPanel> createState() =>
      _SrsFushiBlockLayoutPanelState();
}

class _SrsFushiBlockLayoutPanelState extends State<SrsFushiBlockLayoutPanel> {
  /// 全部区块：显示中的按布局顺序在前，隐藏的按默认顺序在后（勾回来时落在原地）。
  List<FushiCardBlock> _order = FushiCardBlock.values.toList();
  Set<FushiCardBlock> _on = FushiCardBlock.values.toSet();

  /// 当前背面能否被区块布局认出。
  bool _recognized = true;

  /// 上一次自己写出去的源码：草稿回传同一份时不重读（保住隐藏区块的位置）。
  String? _emitted;

  @override
  void initState() {
    super.initState();
    _read(widget.back);
  }

  @override
  void didUpdateWidget(SrsFushiBlockLayoutPanel old) {
    super.didUpdateWidget(old);
    if (widget.back != old.back && widget.back != _emitted) _read(widget.back);
  }

  void _read(String back) {
    final List<FushiCardBlock>? layout = fushiCardBackLayoutOf(back);
    _recognized = layout != null;
    if (layout == null) return;
    _on = layout.toSet();
    _order = <FushiCardBlock>[
      ...layout,
      for (final FushiCardBlock b in FushiCardBlock.values)
        if (!_on.contains(b)) b,
    ];
  }

  void _emit() {
    final String back = fushiCardBackTemplateFor(<FushiCardBlock>[
      for (final FushiCardBlock b in _order)
        if (_on.contains(b)) b,
    ]);
    _emitted = back;
    widget.onChanged(back);
  }

  void _reset() {
    setState(() {
      _recognized = true;
      _order = FushiCardBlock.values.toList();
      _on = FushiCardBlock.values.toSet();
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: Column(
        key: const ValueKey<String>('srs-fushi-block-layout'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            t.srs_fushi_layout_title,
            style: context.fushiType.titleMediumEmphasized,
          ),
          Text(t.srs_fushi_layout_hint, style: context.fushiType.bodySmall),
          if (!widget.frontAndCssDefault)
            FushiInlineNotice(
              key: const ValueKey<String>('srs-fushi-layout-web-face'),
              severity: FushiNoticeSeverity.warning,
              message: t.srs_fushi_layout_front_css_changed,
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
          else
            // 自实现的 FushiReorderableColumn：SDK 的拖拽代理不认 FushiAppUiScale 的祖先缩放
            // （BUG-778 同根因）。
            FushiReorderableColumn(
              itemCount: _order.length,
              useDragHandles: true,
              feedbackBorderRadius: FushiM3eShape.smallRadius,
              keyForIndex: (int i) => ValueKey<FushiCardBlock>(_order[i]),
              onReorder: (int from, int to) {
                setState(() {
                  final FushiCardBlock b = _order.removeAt(from);
                  _order.insert(to, b);
                });
                _emit();
              },
              itemBuilder: (BuildContext context, int i) {
                final FushiCardBlock b = _order[i];
                void toggle() {
                  setState(() {
                    if (!_on.remove(b)) _on.add(b);
                  });
                  _emit();
                }

                return FushiStaggeredEntrance(
                  index: i,
                  child: FushiListItem(
                    key: ValueKey<String>('srs-fushi-layout-${b.name}'),
                    onTap: toggle,
                    leading: FushiCheckbox(
                      value: _on.contains(b),
                      onChanged: (_) => toggle(),
                    ),
                    title: Text(srsFushiBlockLabel(b)),
                    trailing: const FushiReorderableDragHandle(
                      child: FushiIcon(FushiIcons.dragIndicator),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
