/// 浏览页的另外两种视图与宽屏健康条（spec §3 / §4 / §5）：
///
/// - 表格（只在宽屏）：列可选可排序（[showSrsBrowseColumnsSheet]；选了哪些列、什么顺序存 profile 偏好
///   `srs_browse_table_columns`，[encodeSrsBrowseColumns]），点表头按该列排序（有对应排序列的才可点），
///   双击「正面」/ 两个字段摘要列 / 标签列原地改（编辑框拿笔记里的原值，不拿摘要；Enter 存并跳到下一行同一格，
///   Tab 存并跳到下一个能改的格，Esc 取消；写入走浏览页的改字段 / 改标签，进撤销栈），按牌组 / 出处 / 添加日期
///   分组（分组即按该键排序，表头行插在键变化处）。
/// - 出处：按作品分组（[SrsBrowseResult.sources] 一条命令算完），组头「今天到期 x / 共 y」+「只看这一作」
///   +「只复习这一作」（浏览页开一轮只出这部作品到期卡的自定义学习），组里前几张卡带配图缩略图与原声播放。
/// - 健康条：问题卡（主字段为空 / Fushi 卡片缺音频）、难卡、疑似重复的计数，点一下换成对应条件；
///   「修复」由浏览页确认后执行（可撤销）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsDeckTree;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_card_tile.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart'
    show srsSoundPlayerProvider;
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';

// ================================================================ 表格

/// 表格的列。
enum SrsBrowseTableColumn {
  front,
  field1,
  field2,
  status,
  due,
  interval,
  retention,
  difficulty,
  reps,
  lapses,
  deck,
  noteType,

  /// 卡片类型（模板名）：笔记类型有多个卡片类型时区分同一个词的几张卡。
  cardType,
  tags,
  added,
  modified,
  source,
}

/// 默认显示的列（顺序即显示顺序）。
const List<SrsBrowseTableColumn> kSrsBrowseDefaultColumns =
    <SrsBrowseTableColumn>[
      SrsBrowseTableColumn.front,
      SrsBrowseTableColumn.field1,
      SrsBrowseTableColumn.status,
      SrsBrowseTableColumn.due,
      SrsBrowseTableColumn.retention,
      SrsBrowseTableColumn.lapses,
      SrsBrowseTableColumn.deck,
    ];

/// 表格分组。分组 = 先按该键排序，再在键变化处插组头。
enum SrsBrowseTableGroup { none, deck, source, added }

/// 选列偏好（`srs_browse_table_columns`）的编码：列名按显示顺序用逗号连起来。
String encodeSrsBrowseColumns(List<SrsBrowseTableColumn> columns) =>
    columns.map((SrsBrowseTableColumn c) => c.name).join(',');

/// 选列偏好解码：不认识的列名（旧版本 / 手改）跳过、重复的只留第一个；「正面」总在（缺了补在最前）；
/// 空串或一列都认不出 = 默认列。
List<SrsBrowseTableColumn> decodeSrsBrowseColumns(String raw) {
  final List<SrsBrowseTableColumn> out = <SrsBrowseTableColumn>[];
  for (final String name in raw.split(',')) {
    final SrsBrowseTableColumn? c = SrsBrowseTableColumn.values
        .where((SrsBrowseTableColumn x) => x.name == name.trim())
        .firstOrNull;
    if (c != null && !out.contains(c)) out.add(c);
  }
  if (out.isEmpty) return kSrsBrowseDefaultColumns;
  if (!out.contains(SrsBrowseTableColumn.front)) {
    out.insert(0, SrsBrowseTableColumn.front);
  }
  return List<SrsBrowseTableColumn>.unmodifiable(out);
}

/// 列名。
String srsBrowseColumnLabel(SrsBrowseTableColumn c) => switch (c) {
  SrsBrowseTableColumn.front => t.srs_browse_col_front,
  SrsBrowseTableColumn.field1 => t.srs_browse_col_field(n: 1),
  SrsBrowseTableColumn.field2 => t.srs_browse_col_field(n: 2),
  SrsBrowseTableColumn.status => t.srs_browse_col_status,
  SrsBrowseTableColumn.due => t.srs_browse_sort_due,
  SrsBrowseTableColumn.interval => t.srs_browse_sort_interval,
  SrsBrowseTableColumn.retention => t.srs_browse_sort_retention,
  SrsBrowseTableColumn.difficulty => t.srs_browse_sort_difficulty,
  SrsBrowseTableColumn.reps => t.srs_browse_sort_reps,
  SrsBrowseTableColumn.lapses => t.srs_browse_sort_lapses,
  SrsBrowseTableColumn.deck => t.srs_key_deck,
  SrsBrowseTableColumn.noteType => t.srs_note_type,
  SrsBrowseTableColumn.cardType => t.srs_browse_col_card_type,
  SrsBrowseTableColumn.tags => t.srs_browse_edit_tags,
  SrsBrowseTableColumn.added => t.srs_browse_sort_created,
  SrsBrowseTableColumn.modified => t.srs_browse_sort_modified,
  SrsBrowseTableColumn.source => t.srs_browse_view_sources,
};

/// 列对应的排序列；null = 这一列不能排序。
SrsBrowseSortColumn? srsBrowseColumnSort(SrsBrowseTableColumn c) => switch (c) {
  SrsBrowseTableColumn.front => SrsBrowseSortColumn.sortField,
  SrsBrowseTableColumn.due => SrsBrowseSortColumn.due,
  SrsBrowseTableColumn.interval => SrsBrowseSortColumn.interval,
  SrsBrowseTableColumn.retention => SrsBrowseSortColumn.retention,
  SrsBrowseTableColumn.difficulty => SrsBrowseSortColumn.difficulty,
  SrsBrowseTableColumn.reps => SrsBrowseSortColumn.reps,
  SrsBrowseTableColumn.lapses => SrsBrowseSortColumn.lapses,
  SrsBrowseTableColumn.deck => SrsBrowseSortColumn.deck,
  SrsBrowseTableColumn.noteType => SrsBrowseSortColumn.noteType,
  SrsBrowseTableColumn.source => SrsBrowseSortColumn.source,
  SrsBrowseTableColumn.added => SrsBrowseSortColumn.created,
  SrsBrowseTableColumn.modified => SrsBrowseSortColumn.modified,
  _ => null,
};

/// 能原地改的列（正面 = 排序字段，字段 1 / 2 = [SrsBrowseRow.fieldPreview] 那两个字段，标签）。
bool srsBrowseColumnEditable(SrsBrowseTableColumn c) => switch (c) {
  SrsBrowseTableColumn.front ||
  SrsBrowseTableColumn.field1 ||
  SrsBrowseTableColumn.field2 ||
  SrsBrowseTableColumn.tags => true,
  _ => false,
};

/// 这一行的这一格能不能原地改：字段摘要列只有这一行真有那条摘要时才能改（摘要取的是非空字段，没有就不知道
/// 改哪个字段）。
bool srsBrowseCellEditable(SrsBrowseRow r, SrsBrowseTableColumn c) =>
    switch (c) {
      SrsBrowseTableColumn.field1 => r.fieldPreviewNames.isNotEmpty,
      SrsBrowseTableColumn.field2 => r.fieldPreviewNames.length > 1,
      _ => srsBrowseColumnEditable(c),
    };

/// 字段摘要列对应的字段名（[SrsBrowseRow.fieldPreviewNames]）；不是字段摘要列或这一行没有那条摘要 null。
String? srsBrowsePreviewFieldName(SrsBrowseRow r, SrsBrowseTableColumn c) =>
    switch (c) {
      SrsBrowseTableColumn.field1 => r.fieldPreviewNames.elementAtOrNull(0),
      SrsBrowseTableColumn.field2 => r.fieldPreviewNames.elementAtOrNull(1),
      _ => null,
    };

/// 标签格的输入 → 标签列表（空白分隔，去重，保持顺序）。
List<String> parseSrsBrowseTagsCell(String raw) => <String>{
  for (final String tag in raw.split(RegExp(r'\s+')))
    if (tag.isNotEmpty) tag,
}.toList();

/// 列宽（flex）。
int _flexOf(SrsBrowseTableColumn c) => switch (c) {
  SrsBrowseTableColumn.front => 4,
  SrsBrowseTableColumn.field1 || SrsBrowseTableColumn.field2 => 4,
  SrsBrowseTableColumn.deck ||
  SrsBrowseTableColumn.noteType ||
  SrsBrowseTableColumn.cardType ||
  SrsBrowseTableColumn.tags ||
  SrsBrowseTableColumn.source => 3,
  _ => 2,
};

String _date(BuildContext context, int ms) => MaterialLocalizations.of(
  context,
).formatShortDate(DateTime.fromMillisecondsSinceEpoch(ms));

/// 一格的文字。
String srsBrowseCellText(
  BuildContext context,
  SrsBrowseRow r,
  SrsBrowseTableColumn c,
) => switch (c) {
  SrsBrowseTableColumn.front => r.sortText.isEmpty ? '—' : r.sortText,
  SrsBrowseTableColumn.field1 =>
    r.fieldPreview.isNotEmpty ? r.fieldPreview[0] : '',
  SrsBrowseTableColumn.field2 =>
    r.fieldPreview.length > 1 ? r.fieldPreview[1] : '',
  SrsBrowseTableColumn.status => srsBrowseCardStatus(r),
  SrsBrowseTableColumn.due => srsBrowseDueText(r),
  SrsBrowseTableColumn.interval =>
    r.intervalDays == null ? '' : t.srs_browse_history_days(n: r.intervalDays!),
  SrsBrowseTableColumn.retention =>
    r.retention == null ? '' : srsBrowsePercent(r.retention!),
  SrsBrowseTableColumn.difficulty =>
    r.difficulty == null ? '' : r.difficulty!.toStringAsFixed(1),
  SrsBrowseTableColumn.reps => '${r.reps}',
  SrsBrowseTableColumn.lapses => '${r.lapses}',
  SrsBrowseTableColumn.deck => r.deckName,
  SrsBrowseTableColumn.noteType => r.noteTypeName,
  SrsBrowseTableColumn.cardType => r.templateName,
  SrsBrowseTableColumn.tags => r.tags.join(' '),
  SrsBrowseTableColumn.added => _date(context, r.addedAt),
  SrsBrowseTableColumn.modified => _date(context, r.modifiedAt),
  SrsBrowseTableColumn.source =>
    r.sourceKey == null ? '' : srsBrowseSourceTitle(r.source, r.sourceKind),
};

/// 分组键（同键的连续行归一组）。出处按出处键分（同名的两部作品不并组），组头显示 [srsBrowseGroupLabel]。
String srsBrowseGroupKey(
  BuildContext context,
  SrsBrowseRow r,
  SrsBrowseTableGroup g,
) => switch (g) {
  SrsBrowseTableGroup.none => '',
  SrsBrowseTableGroup.deck => r.deckName,
  SrsBrowseTableGroup.source => r.sourceKey ?? '',
  SrsBrowseTableGroup.added => _date(context, r.addedAt),
};

/// 组头的文字。
String srsBrowseGroupLabel(
  BuildContext context,
  SrsBrowseRow r,
  SrsBrowseTableGroup g,
) => switch (g) {
  SrsBrowseTableGroup.source =>
    r.sourceKey == null
        ? t.srs_browse_source_none
        : srsBrowseSourceTitle(r.source, r.sourceKind),
  _ => srsBrowseGroupKey(context, r, g),
};

/// 分组对应的排序（分组生效时浏览页用它代替用户的排序）。
SrsBrowseSort? srsBrowseGroupSort(SrsBrowseTableGroup g) => switch (g) {
  SrsBrowseTableGroup.none => null,
  SrsBrowseTableGroup.deck => const SrsBrowseSort(
    column: SrsBrowseSortColumn.deck,
  ),
  SrsBrowseTableGroup.source => const SrsBrowseSort(
    column: SrsBrowseSortColumn.source,
    ascending: true,
  ),
  SrsBrowseTableGroup.added => const SrsBrowseSort(
    column: SrsBrowseSortColumn.created,
    ascending: false,
  ),
};

/// 选列 / 排列顺序的面板。返回 null = 取消。
Future<List<SrsBrowseTableColumn>?> showSrsBrowseColumnsSheet(
  BuildContext context, {
  required List<SrsBrowseTableColumn> current,
}) => adaptiveModalSheet<List<SrsBrowseTableColumn>>(
  context: context,
  builder: (BuildContext context) => _ColumnsSheet(current: current),
);

class _ColumnsSheet extends StatefulWidget {
  const _ColumnsSheet({required this.current});

  final List<SrsBrowseTableColumn> current;

  @override
  State<_ColumnsSheet> createState() => _ColumnsSheetState();
}

class _ColumnsSheetState extends State<_ColumnsSheet> {
  late final List<SrsBrowseTableColumn> _order = <SrsBrowseTableColumn>[
    ...widget.current,
    for (final SrsBrowseTableColumn c in SrsBrowseTableColumn.values)
      if (!widget.current.contains(c)) c,
  ];
  late final Set<SrsBrowseTableColumn> _on = widget.current.toSet();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Text(
              t.srs_browse_table_columns,
              style: context.fushiType.titleMediumEmphasized,
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey<String>('srs-browse-columns'),
                // 自实现的 FushiReorderableColumn 而非 SDK ReorderableListView：
                // 整棵树活在 FushiAppUiScale 的 Transform.scale 之下，SDK 的拖拽代理
                // 不认祖先缩放，「界面大小」非 100% 时拖拽浮层漂移（BUG-778 同根因）。
                child: FushiReorderableColumn(
                  itemCount: _order.length,
                  useDragHandles: true,
                  feedbackBorderRadius: FushiM3eShape.smallRadius,
                  keyForIndex: (int i) =>
                      ValueKey<SrsBrowseTableColumn>(_order[i]),
                  onReorder: (int from, int to) => setState(() {
                    final SrsBrowseTableColumn c = _order.removeAt(from);
                    _order.insert(to, c);
                  }),
                  itemBuilder: (BuildContext context, int i) {
                    final SrsBrowseTableColumn c = _order[i];
                    return FushiStaggeredEntrance(
                      index: i,
                      child: FushiListItem(
                        key: ValueKey<String>('srs-browse-column-${c.name}'),
                        leading: FushiCheckbox(
                          value: _on.contains(c),
                          onChanged: c == SrsBrowseTableColumn.front
                              ? null
                              : (_) => setState(() {
                                  if (!_on.remove(c)) _on.add(c);
                                }),
                        ),
                        title: Text(srsBrowseColumnLabel(c)),
                        trailing: const FushiReorderableDragHandle(
                          child: FushiIcon(FushiIcons.dragIndicator),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            FushiFilledButton(
              key: const ValueKey<String>('srs-browse-columns-apply'),
              onPressed: () => Navigator.of(context).pop(<SrsBrowseTableColumn>[
                for (final SrsBrowseTableColumn c in _order)
                  if (_on.contains(c)) c,
              ]),
              child: Text(t.srs_browse_chip_apply),
            ),
          ],
        ),
      ),
    );
  }
}

/// 表格（宽屏）。行按页向原生会话取（[rowAt] 取不到就 [loadRow]，取到后浏览页重画）。
class SrsBrowseTable extends StatefulWidget {
  const SrsBrowseTable({
    super.key,
    required this.length,
    required this.rowAt,
    required this.loadRow,
    required this.idOf,
    required this.columns,
    required this.group,
    required this.sort,
    required this.selected,
    required this.currentId,
    required this.controller,
    required this.onSort,
    required this.onRowTap,
    required this.onRowSecondaryTap,
    required this.loadCell,
    required this.onSaveCell,
    this.header,
  });

  final int length;
  final SrsBrowseRow? Function(int index) rowAt;
  final void Function(int index) loadRow;
  final String Function(SrsBrowseRow row) idOf;
  final List<SrsBrowseTableColumn> columns;
  final SrsBrowseTableGroup group;
  final SrsBrowseSort sort;
  final Set<String> selected;
  final String? currentId;
  final ScrollController controller;
  final ValueChanged<SrsBrowseSortColumn> onSort;
  final void Function(String id, int index) onRowTap;
  final void Function(String id, int index) onRowSecondaryTap;

  /// 原地改一格时编辑框的初值（笔记里的原值，不是摘要）；null = 这一格改不了（笔记类型 / 字段已不在）。
  final Future<String?> Function(SrsBrowseRow row, SrsBrowseTableColumn column)
  loadCell;

  /// 存一格（只在值变了时调用）；写入由浏览页做（条件写 + 进撤销栈）。
  final Future<void> Function(
    SrsBrowseRow row,
    SrsBrowseTableColumn column,
    String value,
  )
  onSaveCell;

  /// 表格上方（搜索栏等，跟着一起滚）。
  final Widget? header;

  @override
  State<SrsBrowseTable> createState() => _SrsBrowseTableState();
}

class _SrsBrowseTableState extends State<SrsBrowseTable> {
  /// 正在原地改的那一格（行号 + 列）。
  ({int index, SrsBrowseTableColumn column})? _editing;

  /// 编辑框打开时的初值（没改就不写）。
  String _initial = '';

  /// 最近一次开编辑框的序号：取初值是异步的，换了格的旧请求作废。
  int _editSeq = 0;
  final TextEditingController _cell = TextEditingController();
  final FocusNode _cellFocus = FocusNode(debugLabel: 'srs-browse-cell');

  @override
  void dispose() {
    _cell.dispose();
    _cellFocus.dispose();
    super.dispose();
  }

  Future<void> _startEdit(
    int index,
    SrsBrowseRow row,
    SrsBrowseTableColumn column,
  ) async {
    final int seq = ++_editSeq;
    final String? value = await widget.loadCell(row, column);
    if (!mounted || seq != _editSeq) return;
    if (value == null) {
      setState(() => _editing = null);
      return;
    }
    setState(() {
      _editing = (index: index, column: column);
      _initial = value;
      _cell.text = value;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cellFocus.requestFocus();
    });
  }

  void _cancel() {
    _editSeq++;
    setState(() => _editing = null);
  }

  /// 存当前格，再按 [nextCell]（Tab：同一行下一个能改的格，行尾接下一行）或下一行同一格（Enter）接着改。
  Future<void> _commit({required bool nextCell}) async {
    final ({int index, SrsBrowseTableColumn column})? at = _editing;
    if (at == null) return;
    final SrsBrowseRow? row = widget.rowAt(at.index);
    final String value = _cell.text;
    _editSeq++;
    if (row != null && value != _initial) {
      await widget.onSaveCell(row, at.column, value);
    }
    if (!mounted) return;
    final ({int index, SrsBrowseRow row, SrsBrowseTableColumn column})? next =
        nextCell
        ? _nextCell(at.index, at.column)
        : _nextRow(at.index, at.column);
    if (next == null) {
      setState(() => _editing = null);
      return;
    }
    await _startEdit(next.index, next.row, next.column);
  }

  ({int index, SrsBrowseRow row, SrsBrowseTableColumn column})? _nextRow(
    int index,
    SrsBrowseTableColumn column,
  ) {
    if (index + 1 >= widget.length) return null;
    final SrsBrowseRow? row = widget.rowAt(index + 1);
    if (row == null || !srsBrowseCellEditable(row, column)) return null;
    return (index: index + 1, row: row, column: column);
  }

  ({int index, SrsBrowseRow row, SrsBrowseTableColumn column})? _nextCell(
    int index,
    SrsBrowseTableColumn column,
  ) {
    final List<SrsBrowseTableColumn> cols = widget.columns;
    int i = index;
    int k = cols.indexOf(column) + 1;
    // 最多看到下一行行尾（再往后的行可能还没取到）。
    while (i <= index + 1 && i < widget.length) {
      final SrsBrowseRow? row = widget.rowAt(i);
      if (row == null) return null;
      for (; k < cols.length; k++) {
        if (srsBrowseCellEditable(row, cols[k])) {
          return (index: i, row: row, column: cols[k]);
        }
      }
      i++;
      k = 0;
    }
    return null;
  }

  KeyEventResult _onCellKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      unawaited(_commit(nextCell: true));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _headerRow(BuildContext context, Color muted) {
    final List<Widget> cells = <Widget>[
      for (final SrsBrowseTableColumn c in widget.columns)
        Expanded(
          flex: _flexOf(c),
          child: Builder(
            builder: (BuildContext context) {
              final SrsBrowseSortColumn? s = srsBrowseColumnSort(c);
              final bool active = s != null && s == widget.sort.column;
              final Widget label = Row(
                spacing: 2,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      srsBrowseColumnLabel(c),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.labelMedium.copyWith(
                        color: muted,
                        fontWeight: active ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                  if (active)
                    FushiIcon(
                      widget.sort.ascending
                          ? FushiIcons.arrowUp
                          : FushiIcons.arrowDown,
                      size: 14,
                      color: muted,
                    ),
                ],
              );
              if (s == null) return label;
              return FushiPressScale(
                child: GestureDetector(
                  key: ValueKey<String>('srs-browse-col-${c.name}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onSort(s),
                  child: label,
                ),
              );
            },
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(spacing: 8, children: cells),
    );
  }

  Widget _row(BuildContext context, int index, Color muted) {
    final SrsBrowseRow? r = widget.rowAt(index);
    if (r == null) {
      widget.loadRow(index);
      return SizedBox(
        key: ValueKey<String>('srs-browse-row-pending-$index'),
        height: 40,
      );
    }
    final String id = widget.idOf(r);
    final bool selected =
        widget.selected.contains(id) || id == widget.currentId;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color highlight = apple
        ? appleColorsOf(context).accent.withValues(alpha: 0.14)
        : scheme.secondaryContainer;
    final Widget line = AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.micro),
      curve: FushiMotion.standard,
      decoration: BoxDecoration(
        color: selected ? highlight : Colors.transparent,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        spacing: 8,
        children: <Widget>[
          for (final SrsBrowseTableColumn c in widget.columns)
            Expanded(
              flex: _flexOf(c),
              child: _editing?.index == index && _editing?.column == c
                  ? Focus(
                      onKeyEvent: _onCellKey,
                      child: FushiTextField(
                        key: const ValueKey<String>('srs-browse-cell-editor'),
                        controller: _cell,
                        focusNode: _cellFocus,
                        hintText: c == SrsBrowseTableColumn.tags
                            ? t.srs_browse_cell_tags_hint
                            : t.srs_browse_cell_hint,
                        onSubmitted: (_) => unawaited(_commit(nextCell: false)),
                      ),
                    )
                  : _cellView(context, r, c, index, muted),
            ),
        ],
      ),
    );
    return FushiPressScale(
      // 右键菜单由绑定表决定唤出键（默认右键），右键被别的动作占用时自动让位。
      child: ContextMenuTrigger(
        onInvoke: (Offset _) => widget.onRowSecondaryTap(id, index),
        child: GestureDetector(
          key: ValueKey<String>('srs-browse-row-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onRowTap(id, index),
          child: line,
        ),
      ),
    );
  }

  Widget _cellView(
    BuildContext context,
    SrsBrowseRow r,
    SrsBrowseTableColumn c,
    int index,
    Color muted,
  ) {
    if (c == SrsBrowseTableColumn.status) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: FushiTag(
          key: ValueKey<String>('srs-browse-status-${widget.idOf(r)}'),
          text: srsBrowseCardStatus(r),
          tone: srsBrowseCardStatusTone(r),
          dense: true,
        ),
      );
    }
    if (c == SrsBrowseTableColumn.retention && r.retention != null) {
      return Row(
        spacing: 6,
        children: <Widget>[
          SrsBrowseRetentionBar(retention: r.retention!, width: 36),
          Text(
            srsBrowsePercent(r.retention!),
            style: context.fushiType.bodySmall,
          ),
        ],
      );
    }
    final Text text = Text(
      srsBrowseCellText(context, r, c),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: c == SrsBrowseTableColumn.front
          ? context.fushiType.bodyMedium.copyWith(fontWeight: FontWeight.w600)
          : context.fushiType.bodySmall.copyWith(color: muted),
    );
    if (!srsBrowseCellEditable(r, c)) return text;
    return GestureDetector(
      key: ValueKey<String>('srs-browse-cell-$index-${c.name}'),
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => unawaited(_startEdit(index, r, c)),
      child: Align(alignment: AlignmentDirectional.centerStart, child: text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final int offset = widget.header == null ? 1 : 2;
    return FushiEntranceScope(
      replayKey: '${widget.columns.join(',')}|${widget.group.name}',
      child: ListView.builder(
        key: const ValueKey<String>('srs-browse-table'),
        controller: widget.controller,
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap + MediaQuery.paddingOf(context).top,
          tokens.spacing.page,
          tokens.spacing.section,
        ),
        itemCount: widget.length + offset,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (widget.header != null && i == 0) {
            return Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: widget.header,
            );
          }
          if (i == offset - 1) return _headerRow(context, muted);
          final int index = i - offset;
          final Widget row = _row(context, index, muted);
          if (widget.group == SrsBrowseTableGroup.none) return row;
          final SrsBrowseRow? r = widget.rowAt(index);
          final SrsBrowseRow? prev = index > 0 ? widget.rowAt(index - 1) : null;
          if (r == null) return row;
          final String key = srsBrowseGroupKey(context, r, widget.group);
          if (index > 0 &&
              (prev == null ||
                  srsBrowseGroupKey(context, prev, widget.group) == key)) {
            return row;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  index == 0 ? 0 : tokens.spacing.gap,
                  12,
                  4,
                ),
                child: Text(
                  switch (srsBrowseGroupLabel(context, r, widget.group)) {
                    '' => '—',
                    final String label => label,
                  },
                  key: ValueKey<String>('srs-browse-group-$index'),
                  style: context.fushiType.titleSmall,
                ),
              ),
              row,
            ],
          );
        }),
      ),
    );
  }
}

// ================================================================ 出处

/// 从 [deckId] 往上到顶层的牌组链（含自己）；牌组已不在树里 = 空。
List<String> _deckChain(SrsDeckTree tree, String deckId) {
  final List<String> out = <String>[];
  for (String? d = deckId; d != null && tree[d] != null; d = tree.parentOf(d)) {
    if (out.contains(d)) break;
    out.add(d);
  }
  return out;
}

/// [deckIds] 的最近公共祖先（含它们自己：都在同一个牌组就是那个牌组）；分在不同顶层牌组里 / 一个都不在树里
/// null。「只复习这一作」在它上面开自定义学习（会话按子树出卡）。
String? srsCommonDeckAncestor(SrsDeckTree tree, List<String> deckIds) {
  List<String>? common;
  for (final String id in deckIds) {
    final List<String> chain = _deckChain(tree, id);
    if (chain.isEmpty) continue;
    common = common == null
        ? chain
        : <String>[
            for (final String d in common)
              if (chain.contains(d)) d,
          ];
    if (common.isEmpty) return null;
  }
  return common?.first;
}

/// [deckIds] 各自所在的顶层牌组（去重，首次出现的顺序）。
List<String> srsTopLevelDecks(SrsDeckTree tree, List<String> deckIds) =>
    <String>{
      for (final String id in deckIds)
        if (_deckChain(tree, id) case final List<String> c when c.isNotEmpty)
          c.last,
    }.toList();

/// 出处视图：按作品分组。
class SrsBrowseSourcesView extends ConsumerStatefulWidget {
  const SrsBrowseSourcesView({
    super.key,
    required this.result,
    required this.revision,
    required this.idOf,
    required this.selected,
    required this.onOnlySource,
    required this.onReviewSource,
    required this.onOpen,
    this.header,
  });

  final SrsBrowseResult result;
  final int revision;
  final String Function(SrsBrowseRow row) idOf;
  final Set<String> selected;

  /// 「只看这一作」：把查询换成该出处（[srsSourceQuery]）。
  final void Function(String? sourceKey) onOnlySource;

  /// 「只复习这一作」：开一轮只出这部作品到期卡的自定义学习（只给有出处、今天有到期的组）。
  final void Function(SrsBrowseSourceGroup group) onReviewSource;

  /// 点组里的一张卡（行号）。
  final void Function(String id, int index) onOpen;
  final Widget? header;

  @override
  ConsumerState<SrsBrowseSourcesView> createState() =>
      _SrsBrowseSourcesViewState();
}

class _SrsBrowseSourcesViewState extends ConsumerState<SrsBrowseSourcesView> {
  List<SrsBrowseSourceGroup>? _groups;
  SrsMediaStore? _media;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SrsBrowseSourcesView old) {
    super.didUpdateWidget(old);
    if (!identical(old.result, widget.result) ||
        old.revision != widget.revision) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int seq = ++_seq;
    final SrsBrowseResult r = widget.result;
    try {
      final List<SrsBrowseSourceGroup> groups = await r.sources();
      // 组里预览行一次取齐（按页取，同一页的只取一次）。
      for (final SrsBrowseSourceGroup g in groups) {
        for (final int i in g.preview) {
          await r.ensure(i, i + 1);
        }
      }
      final SrsMediaStore? media = await ref.read(srsMediaStoreProvider.future);
      if (!mounted || seq != _seq) return;
      setState(() {
        _groups = groups;
        _media = media;
      });
    } on SrsBrowseResultGone {
      // 结果被换掉：浏览页会带新结果重建本视图。
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.sources', e, stack);
      if (mounted && seq == _seq) {
        setState(() => _groups = const <SrsBrowseSourceGroup>[]);
      }
    }
  }

  Future<void> _play(String name) async {
    final File? file = _media?.resolve(name);
    if (file == null || !await file.exists()) {
      FushiToast.show(msg: t.srs_media_missing(name: name));
      return;
    }
    await ref.read(srsSoundPlayerProvider)(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SrsBrowseSourceGroup>? groups = _groups;
    final int total = groups == null
        ? 0
        : groups.fold<int>(0, (int a, SrsBrowseSourceGroup g) => a + g.count);
    final List<Widget> items = <Widget>[
      ?widget.header,
      if (groups == null)
        const Padding(padding: EdgeInsets.all(32), child: FushiLoadingView())
      else ...<Widget>[
        Text(
          t.srs_browse_sources_summary(
            n: groups.where((SrsBrowseSourceGroup g) => g.key != null).length,
            m: total,
          ),
          style: context.fushiType.labelLarge,
        ),
        for (final SrsBrowseSourceGroup g in groups) _group(context, g),
      ],
    ];
    return FushiEntranceScope(
      replayKey: identityHashCode(widget.result),
      child: ListView.builder(
        key: const ValueKey<String>('srs-browse-sources'),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap + MediaQuery.paddingOf(context).top,
          tokens.spacing.page,
          tokens.spacing.section,
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap * 1.5),
            child: items[i],
          ),
        ),
      ),
    );
  }

  Widget _group(BuildContext context, SrsBrowseSourceGroup g) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final String title = g.key == null
        ? t.srs_browse_source_none
        : srsBrowseSourceTitle(g.source, g.kind);
    final String sub = g.key == null
        ? t.srs_browse_source_none_hint
        : '${srsBrowseSourceKindLabel(g.kind)} · ${t.srs_browse_source_due(due: g.due, count: g.count)}';
    final List<SrsBrowseRow> rows = <SrsBrowseRow>[
      for (final int i in g.preview) ?widget.result.rowAt(i),
    ];
    return FushiCard(
      key: ValueKey<String>('srs-browse-source-${g.key ?? 'none'}'),
      pressScale: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Row(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              FushiIcon(
                g.key == null
                    ? FushiIcons.ankiCard
                    : srsBrowseSourceKindIcon(g.kind),
                color: muted,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.titleMediumEmphasized,
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: 4,
            children: <Widget>[
              FushiTextButton(
                key: ValueKey<String>(
                  'srs-browse-source-only-${g.key ?? 'none'}',
                ),
                onPressed: () => widget.onOnlySource(g.key),
                child: Text(t.srs_browse_source_only),
              ),
              if (g.key != null)
                FushiFilledButton.tonal(
                  key: ValueKey<String>('srs-browse-source-review-${g.key}'),
                  onPressed: g.due > 0 ? () => widget.onReviewSource(g) : null,
                  child: Text(t.srs_browse_source_review),
                ),
            ],
          ),
          for (int k = 0; k < rows.length; k++)
            _tile(context, rows[k], g.preview[k], muted),
          if (g.count > rows.length)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiTextButton(
                onPressed: () => widget.onOnlySource(g.key),
                child: Text(t.srs_browse_source_more(n: g.count - rows.length)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, SrsBrowseRow r, int index, Color muted) {
    final String id = widget.idOf(r);
    final File? image = r.imageRef == null
        ? null
        : _media?.resolve(r.imageRef!);
    final String? locator = srsBrowseSourceLocator(r.source);
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiCard(
        key: ValueKey<String>('srs-browse-row-$id'),
        selected: widget.selected.contains(id),
        padding: const EdgeInsets.all(8),
        onTap: () => widget.onOpen(id, index),
        child: Row(
          spacing: 12,
          children: <Widget>[
            ClipRRect(
              borderRadius: FushiM3eShape.smallRadius,
              child: SizedBox.square(
                dimension: 48,
                child: image == null
                    ? ColoredBox(
                        color: muted.withValues(alpha: 0.12),
                        child: FushiIcon(FushiIcons.ankiCard, color: muted),
                      )
                    : Image.file(
                        image,
                        fit: BoxFit.cover,
                        cacheWidth: 144,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: muted.withValues(alpha: 0.12)),
                      ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    r.sortText.isEmpty ? '—' : r.sortText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleMediumEmphasized,
                  ),
                  if (r.fieldPreview.isNotEmpty || locator != null)
                    Text(
                      <String>[
                        ?locator,
                        if (r.fieldPreview.isNotEmpty) r.fieldPreview.first,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall.copyWith(color: muted),
                    ),
                ],
              ),
            ),
            if (r.audioRef != null)
              FushiIconButton(
                key: ValueKey<String>('srs-browse-source-play-$id'),
                icon: FushiIcons.volumeUp,
                tooltip: t.srs_browse_source_play,
                onTap: () => srsRunLogged(
                  'SrsBrowse.sourcePlay',
                  () => _play(r.audioRef!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================ 健康条

/// 健康条的计数：全部按**笔记**数（-1 = 没算出来 / 语法不支持，那一项不显示）。
class SrsBrowseHealthCounts {
  const SrsBrowseHealthCounts({
    required this.emptyField,
    required this.missingAudio,
    required this.hard,
    required this.dupes,
  });

  final int emptyField;
  final int missingAudio;
  final int hard;
  final int dupes;

  bool get isEmpty =>
      emptyField <= 0 && missingAudio <= 0 && hard <= 0 && dupes <= 0;
}

/// 健康条（宽屏）：几项按笔记计的问题，每项只有「查看」——把对应条件作为查询积木套到列表上，
/// 用户看过再自己选中处理（批量删除 / 补音频都走选择后的批量操作），这里不做任何写入。
class SrsBrowseHealthBar extends StatelessWidget {
  const SrsBrowseHealthBar({
    super.key,
    required this.counts,
    required this.onViewEmptyField,
    required this.onViewMissingAudio,
    required this.onViewHard,
    required this.onViewDupes,
  });

  final SrsBrowseHealthCounts counts;
  final VoidCallback onViewEmptyField;
  final VoidCallback onViewMissingAudio;
  final VoidCallback onViewHard;
  final VoidCallback onViewDupes;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsBrowseHealthCounts c = counts;
    final List<Widget> items = <Widget>[
      if (c.emptyField > 0)
        _item(
          context,
          keyName: 'empty',
          tone: FushiStatusTone.error,
          icon: FushiIcons.warning,
          text: t.srs_browse_health_empty_notes(n: c.emptyField),
          onView: onViewEmptyField,
        ),
      if (c.missingAudio > 0)
        _item(
          context,
          keyName: 'audio',
          tone: FushiStatusTone.warning,
          icon: FushiIcons.warning,
          text: t.srs_browse_health_missing_audio_notes(n: c.missingAudio),
          onView: onViewMissingAudio,
        ),
      if (c.hard > 0)
        _item(
          context,
          keyName: 'hard',
          tone: FushiStatusTone.warning,
          icon: FushiIcons.speed,
          text: t.srs_browse_health_hard_notes(n: c.hard),
          onView: onViewHard,
        ),
      if (c.dupes > 0)
        _item(
          context,
          keyName: 'dupes',
          tone: FushiStatusTone.warning,
          icon: FushiIcons.copyAll,
          text: t.srs_browse_health_dupe_notes(n: c.dupes),
          onView: onViewDupes,
        ),
    ];
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: items.isEmpty
          ? const SizedBox(width: double.infinity)
          : Column(
              key: const ValueKey<String>('srs-browse-health'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                for (int i = 0; i < items.length; i++)
                  FushiStaggeredEntrance(index: i, child: items[i]),
              ],
            ),
    );
  }

  Widget _item(
    BuildContext context, {
    required String keyName,
    required FushiStatusTone tone,
    required IconData icon,
    required String text,
    required VoidCallback onView,
  }) {
    final Color color = fushiStatusColor(context, tone);
    return FushiCard(
      key: ValueKey<String>('srs-browse-health-$keyName'),
      pressScale: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        spacing: 8,
        children: <Widget>[
          FushiIcon(icon, size: 18, color: color),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodySmall,
            ),
          ),
          FushiTextButton(
            key: ValueKey<String>('srs-browse-health-$keyName-view'),
            onPressed: onView,
            child: Text(t.srs_browse_health_view),
          ),
        ],
      ),
    );
  }
}
