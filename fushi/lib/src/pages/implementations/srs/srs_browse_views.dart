/// 浏览页的另外两种视图与宽屏健康条（spec §3 / §4 / §5）：
///
/// - 表格（只在宽屏）：列可选可排序（[showSrsBrowseColumnsSheet]），点表头按该列排序（有对应排序列的才可点），
///   双击「正面」/ 字段列原地改（Enter / Tab 存并跳到下一行同一格，Esc 取消；写入走浏览页的改字段，进撤销栈），
///   按牌组 / 添加日期分组（分组即按该键排序，表头行插在键变化处）。
/// - 出处：按作品分组（[SrsBrowseResult.sources] 一条命令算完），组头「今天到期 x / 共 y」+「只看这一作」，
///   组里前几张卡带配图缩略图与原声播放。
/// - 健康条：问题卡（主字段为空 / Fushi 卡片缺音频）、难卡、疑似重复的计数，点一下换成对应条件；
///   「修复」由浏览页确认后执行（可撤销）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_card_tile.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart'
    show srsSoundPlayerProvider;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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
enum SrsBrowseTableGroup { none, deck, added }

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
  SrsBrowseTableColumn.added => SrsBrowseSortColumn.created,
  SrsBrowseTableColumn.modified => SrsBrowseSortColumn.modified,
  _ => null,
};

/// 能原地改的列（正面 = 排序字段，字段 1 / 2 = [SrsBrowseRow.fieldPreview] 那两个字段）。
bool srsBrowseColumnEditable(SrsBrowseTableColumn c) =>
    c == SrsBrowseTableColumn.front;

/// 列宽（flex）。
int _flexOf(SrsBrowseTableColumn c) => switch (c) {
  SrsBrowseTableColumn.front => 4,
  SrsBrowseTableColumn.field1 || SrsBrowseTableColumn.field2 => 4,
  SrsBrowseTableColumn.deck ||
  SrsBrowseTableColumn.noteType ||
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
  SrsBrowseTableColumn.tags => r.tags.join(' '),
  SrsBrowseTableColumn.added => _date(context, r.addedAt),
  SrsBrowseTableColumn.modified => _date(context, r.modifiedAt),
  SrsBrowseTableColumn.source =>
    r.sourceKey == null ? '' : srsBrowseSourceTitle(r.source, r.sourceKind),
};

/// 分组键（同键的连续行归一组）。
String srsBrowseGroupKey(
  BuildContext context,
  SrsBrowseRow r,
  SrsBrowseTableGroup g,
) => switch (g) {
  SrsBrowseTableGroup.none => '',
  SrsBrowseTableGroup.deck => r.deckName,
  SrsBrowseTableGroup.added => _date(context, r.addedAt),
};

/// 分组对应的排序（分组生效时浏览页用它代替用户的排序）。
SrsBrowseSort? srsBrowseGroupSort(SrsBrowseTableGroup g) => switch (g) {
  SrsBrowseTableGroup.none => null,
  SrsBrowseTableGroup.deck => const SrsBrowseSort(
    column: SrsBrowseSortColumn.deck,
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
              child: ReorderableListView.builder(
                key: const ValueKey<String>('srs-browse-columns'),
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                onReorder: (int from, int to) => setState(() {
                  final SrsBrowseTableColumn c = _order.removeAt(from);
                  _order.insert(to > from ? to - 1 : to, c);
                }),
                itemBuilder: (BuildContext context, int i) {
                  final SrsBrowseTableColumn c = _order[i];
                  return FushiStaggeredEntrance(
                    key: ValueKey<SrsBrowseTableColumn>(c),
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
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const FushiIcon(FushiIcons.dragIndicator),
                      ),
                    ),
                  );
                },
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
    required this.onSaveFront,
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

  /// 改排序字段（「正面」列）；写入由浏览页做（条件写 + 进撤销栈）。
  final Future<void> Function(SrsBrowseRow row, String value) onSaveFront;

  /// 表格上方（搜索栏等，跟着一起滚）。
  final Widget? header;

  @override
  State<SrsBrowseTable> createState() => _SrsBrowseTableState();
}

class _SrsBrowseTableState extends State<SrsBrowseTable> {
  /// 正在原地改的那一格（行号；只有「正面」列能改）。
  int? _editing;
  final TextEditingController _cell = TextEditingController();
  final FocusNode _cellFocus = FocusNode(debugLabel: 'srs-browse-cell');

  @override
  void dispose() {
    _cell.dispose();
    _cellFocus.dispose();
    super.dispose();
  }

  void _startEdit(int index, SrsBrowseRow row) {
    setState(() {
      _editing = index;
      _cell.text = row.sortText;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cellFocus.requestFocus();
    });
  }

  Future<void> _commit({required bool next}) async {
    final int? index = _editing;
    if (index == null) return;
    final SrsBrowseRow? row = widget.rowAt(index);
    final String value = _cell.text;
    if (row != null && value != row.sortText) {
      await widget.onSaveFront(row, value);
    }
    if (!mounted) return;
    final SrsBrowseRow? following = next && index + 1 < widget.length
        ? widget.rowAt(index + 1)
        : null;
    if (following != null) {
      _startEdit(index + 1, following);
    } else {
      setState(() => _editing = null);
    }
  }

  KeyEventResult _onCellKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _editing = null);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      unawaited(_commit(next: true));
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
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        spacing: 8,
        children: <Widget>[
          for (final SrsBrowseTableColumn c in widget.columns)
            Expanded(
              flex: _flexOf(c),
              child: _editing == index && srsBrowseColumnEditable(c)
                  ? Focus(
                      onKeyEvent: _onCellKey,
                      child: FushiTextField(
                        key: const ValueKey<String>('srs-browse-cell-editor'),
                        controller: _cell,
                        focusNode: _cellFocus,
                        hintText: t.srs_browse_cell_hint,
                        onSubmitted: (_) => unawaited(_commit(next: true)),
                      ),
                    )
                  : _cellView(context, r, c, index, muted),
            ),
        ],
      ),
    );
    return FushiPressScale(
      child: GestureDetector(
        key: ValueKey<String>('srs-browse-row-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onRowTap(id, index),
        onSecondaryTap: () => widget.onRowSecondaryTap(id, index),
        child: line,
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
    if (!srsBrowseColumnEditable(c)) return text;
    return GestureDetector(
      key: ValueKey<String>('srs-browse-cell-$index-${c.name}'),
      onDoubleTap: () => _startEdit(index, r),
      child: text,
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
                  key.isEmpty ? '—' : key,
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

/// 出处视图：按作品分组。
class SrsBrowseSourcesView extends ConsumerStatefulWidget {
  const SrsBrowseSourcesView({
    super.key,
    required this.result,
    required this.revision,
    required this.idOf,
    required this.selected,
    required this.onOnlySource,
    required this.onOpen,
    this.header,
  });

  final SrsBrowseResult result;
  final int revision;
  final String Function(SrsBrowseRow row) idOf;
  final Set<String> selected;

  /// 「只看这一作」：把查询换成该出处（[srsSourceQuery]）。
  final void Function(String? sourceKey) onOnlySource;

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
              FushiTextButton(
                key: ValueKey<String>(
                  'srs-browse-source-only-${g.key ?? 'none'}',
                ),
                onPressed: () => widget.onOnlySource(g.key),
                child: Text(t.srs_browse_source_only),
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
              borderRadius: BorderRadius.circular(8),
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

/// 健康条的计数（-1 = 没算出来 / 语法不支持，那一项不显示）。
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

  int get problems =>
      (emptyField < 0 ? 0 : emptyField) + (missingAudio < 0 ? 0 : missingAudio);

  bool get isEmpty => problems == 0 && hard <= 0 && dupes <= 0;
}

/// 健康条（宽屏）：几项计数，点「查看」换成对应条件，「修复」交给浏览页。
class SrsBrowseHealthBar extends StatelessWidget {
  const SrsBrowseHealthBar({
    super.key,
    required this.counts,
    required this.onViewProblems,
    required this.onViewHard,
    required this.onViewDupes,
    required this.onFix,
  });

  final SrsBrowseHealthCounts counts;
  final VoidCallback onViewProblems;
  final VoidCallback onViewHard;
  final VoidCallback onViewDupes;

  /// null = 没有可修的（问题卡为 0）。
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsBrowseHealthCounts c = counts;
    final List<Widget> items = <Widget>[
      if (c.problems > 0)
        _item(
          context,
          keyName: 'problems',
          tone: FushiStatusTone.error,
          icon: FushiIcons.warning,
          text: t.srs_browse_health_problems(
            n: c.problems,
            e: c.emptyField < 0 ? 0 : c.emptyField,
            a: c.missingAudio < 0 ? 0 : c.missingAudio,
          ),
          onView: onViewProblems,
          onFix: onFix,
        ),
      if (c.hard > 0)
        _item(
          context,
          keyName: 'hard',
          tone: FushiStatusTone.warning,
          icon: FushiIcons.speed,
          text: t.srs_browse_health_hard(n: c.hard),
          onView: onViewHard,
        ),
      if (c.dupes > 0)
        _item(
          context,
          keyName: 'dupes',
          tone: FushiStatusTone.warning,
          icon: FushiIcons.copyAll,
          text: t.srs_browse_health_dupes(n: c.dupes),
          onView: onViewDupes,
        ),
    ];
    return AnimatedSize(
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
    VoidCallback? onFix,
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
          if (onFix != null)
            FushiFilledButton.tonal(
              key: ValueKey<String>('srs-browse-health-$keyName-fix'),
              onPressed: onFix,
              child: Text(t.srs_browse_health_fix),
            ),
        ],
      ),
    );
  }
}
