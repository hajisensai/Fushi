/// 漫画阅读器的「全部页面」缩略图网格（2026-10 重设计）：一屏看完整卷 / 整章的
/// 页，点一页跳过去。
///
/// 卡片走共享卡片体系：[shelfCoverCard]（点击 / 焦点 / Enter 激活 / 按压下沉）+
/// [ShelfCoverFrame]（封面圆角 / 投影 / 内描边，MD3 与 Apple 各自的口径）+
/// [FushiHoverLift]（桌面悬停上浮）；当前屏上的页用强调色描边圈出。网格在
/// [FushiEntranceScope] 里经 [fushiStaggeredItemBuilder] 错峰进场（墨水屏 / 减弱
/// 动态效果下瞬间出现）。打开时滚到当前页附近。
///
/// 在线直读章还没取到的页由 [MangaPageGridPrefetcher] 预取（反馈 3VwZimDVBE）：
/// 网格只负责按滚动位置给出「可见优先」的有序页表、页到了就重画格子，取页本身
/// （缓存、并发、请求头、取消）全在阅读器的页会话里。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';

/// 网格的页图预取方：网格按滚动位置交给它有序页表（可见行在前），页落盘后它
/// 通知网格重画；面板关掉时网格调 [stop]。
abstract interface class MangaPageGridPrefetcher implements Listenable {
  /// 想要的页（0-based），按优先级排好；不在表里的旧请求由实现方撤掉。
  void requestPages(List<int> orderedPages);

  /// 面板关了：撤掉所有还在排队的请求，之后的 [requestPages] 不再发请求。
  void stop();
}

/// 打开页面网格；返回用户点中的 0-based 页号，关掉返回 null。
///
/// [thumbnail] 只给已经在盘上的页图（同步、不发请求），返回 null 的格子画页码
/// 占位；要让没取到的页也能预览，传 [prefetcher]，页落盘后格子自动换成页图。
Future<int?> showMangaPageGridSheet({
  required BuildContext context,
  required int pageCount,
  required Set<int> currentPages,
  required ImageProvider? Function(int pageIndex) thumbnail,
  MangaPageGridPrefetcher? prefetcher,
}) {
  return adaptiveModalSheet<int>(
    context: context,
    builder: (BuildContext context) => MangaPageGridSheet(
      pageCount: pageCount,
      currentPages: currentPages,
      thumbnail: thumbnail,
      prefetcher: prefetcher,
    ),
  );
}

/// 可见行之外往下（阅读方向）至少多预取几行；实际取 max(本值, 一屏行数)。
const int kMangaPageGridPrefetchMinAheadRows = 2;

/// 可见行之外往上多预取几行。
const int kMangaPageGridPrefetchBehindRows = 1;

/// 纯函数：网格可见行 [firstVisibleRow]..[lastVisibleRow]（含）时要预取的页，
/// 按优先级排好——可见行从上到下，再往下 [aheadRows] 行，最后往上 [behindRows] 行。
List<int> mangaPageGridPrefetchOrder({
  required int pageCount,
  required int columns,
  required int firstVisibleRow,
  required int lastVisibleRow,
  required int aheadRows,
  int behindRows = kMangaPageGridPrefetchBehindRows,
}) {
  if (pageCount <= 0 || columns <= 0) return const <int>[];
  final int lastRow = (pageCount - 1) ~/ columns;
  final int first = firstVisibleRow.clamp(0, lastRow);
  final int last = lastVisibleRow.clamp(first, lastRow);
  final List<int> order = <int>[];
  void addRow(int row) {
    if (row < 0 || row > lastRow) return;
    final int start = row * columns;
    final int end = math.min(start + columns, pageCount);
    for (int index = start; index < end; index++) {
      order.add(index);
    }
  }

  for (int row = first; row <= last; row++) {
    addRow(row);
  }
  for (int row = last + 1; row <= last + aheadRows; row++) {
    addRow(row);
  }
  for (int row = first - 1; row >= first - behindRows; row--) {
    addRow(row);
  }
  return order;
}

/// 网格格子的目标宽（逻辑像素）：手机竖屏一行 3–4 格，桌面一行 6–9 格。
const double kMangaPageGridCellTargetWidth = 112;

/// 格子宽高比（页图大致是 B6 / A5 的竖长方形）。
const double kMangaPageGridCoverAspect = 0.7;

/// 页码标签占的高度。
const double kMangaPageGridLabelHeight = 24;

const double _kGridSpacing = 12;
const double _kGridPadding = 20;
const double _kGridTopPadding = 4;

class MangaPageGridSheet extends StatefulWidget {
  const MangaPageGridSheet({
    super.key,
    required this.pageCount,
    required this.currentPages,
    required this.thumbnail,
    this.prefetcher,
  });

  final int pageCount;
  final Set<int> currentPages;
  final ImageProvider? Function(int pageIndex) thumbnail;
  final MangaPageGridPrefetcher? prefetcher;

  @override
  State<MangaPageGridSheet> createState() => _MangaPageGridSheetState();
}

class _MangaPageGridSheetState extends State<MangaPageGridSheet> {
  ScrollController? _controller;
  int? _controllerColumns;
  double _rowExtent = 1;

  /// 上一次交给预取方的可见行区间；没变就不重发。
  (int, int)? _requestedRows;
  bool _prefetchScheduled = false;

  @override
  void dispose() {
    widget.prefetcher?.stop();
    _controller?.removeListener(_requestVisiblePages);
    _controller?.dispose();
    super.dispose();
  }

  /// 按当前滚动位置算可见行，变了就把「可见优先」的页表交给预取方。
  void _requestVisiblePages() {
    final MangaPageGridPrefetcher? prefetcher = widget.prefetcher;
    final ScrollController? controller = _controller;
    final int? columns = _controllerColumns;
    if (prefetcher == null ||
        controller == null ||
        columns == null ||
        !controller.hasClients) {
      return;
    }
    final ScrollPosition position = controller.position;
    if (!position.hasViewportDimension || !position.hasPixels) return;
    final double top = position.pixels - _kGridTopPadding;
    final int firstRow = math.max(0, (top / _rowExtent).floor());
    final int lastRow = math.max(
      firstRow,
      ((top + position.viewportDimension) / _rowExtent).floor(),
    );
    final (int, int) rows = (firstRow, lastRow);
    if (rows == _requestedRows) return;
    _requestedRows = rows;
    prefetcher.requestPages(
      mangaPageGridPrefetchOrder(
        pageCount: widget.pageCount,
        columns: columns,
        firstVisibleRow: firstRow,
        lastVisibleRow: lastRow,
        // 往下至少预读一屏。
        aheadRows: math.max(
          kMangaPageGridPrefetchMinAheadRows,
          lastRow - firstRow + 1,
        ),
      ),
    );
  }

  /// 布局完（有了视口尺寸）再算第一次可见区；列数变了也重算。
  void _schedulePrefetch() {
    if (widget.prefetcher == null || _prefetchScheduled) return;
    _prefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _prefetchScheduled = false;
      if (mounted) _requestVisiblePages();
    });
  }

  /// 列数变化（窗口改宽）时重建控制器，初始偏移按新列数重新对准当前页。
  ScrollController _controllerFor(int columns, double rowExtent) {
    final ScrollController? existing = _controller;
    if (existing != null && _controllerColumns == columns) return existing;
    final int current = widget.currentPages.isEmpty
        ? 0
        : widget.currentPages.reduce(math.min);
    final int row = current ~/ columns;
    // 当前页所在行上方留半行，让它不贴着网格顶边。
    final double offset = math.max(0, row * rowExtent - rowExtent / 2);
    existing?.removeListener(_requestVisiblePages);
    existing?.dispose();
    _controllerColumns = columns;
    _requestedRows = null;
    _schedulePrefetch();
    return _controller = ScrollController(initialScrollOffset: offset)
      ..addListener(_requestVisiblePages);
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.manga_reader_page_grid,
      subtitle: '${widget.pageCount} ${t.manga_series_page_count}',
      maxHeightFactor: 0.86,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth - 2 * _kGridPadding;
          final int columns = math.max(
            3,
            ((width + _kGridSpacing) /
                    (kMangaPageGridCellTargetWidth + _kGridSpacing))
                .floor(),
          );
          final double cellWidth =
              (width - (columns - 1) * _kGridSpacing) / columns;
          final double cellHeight =
              cellWidth / kMangaPageGridCoverAspect + kMangaPageGridLabelHeight;
          _rowExtent = cellHeight + _kGridSpacing;
          final ScrollController controller = _controllerFor(
            columns,
            _rowExtent,
          );
          return FushiEntranceScope(
            child: GridView.builder(
              key: const ValueKey<String>('manga_page_grid'),
              controller: controller,
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                _kGridPadding,
                _kGridTopPadding,
                _kGridPadding,
                _kGridPadding,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: _kGridSpacing,
                crossAxisSpacing: _kGridSpacing,
                mainAxisExtent: cellHeight,
              ),
              itemCount: widget.pageCount,
              itemBuilder: fushiStaggeredItemBuilder(_buildCell),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCell(BuildContext context, int index) {
    Widget cell(BuildContext context) => _MangaPageGridCell(
      key: ValueKey<String>('manga_page_grid_item_$index'),
      index: index,
      current: widget.currentPages.contains(index),
      image: widget.thumbnail(index),
      onTap: () => Navigator.of(context).pop(index),
    );
    final MangaPageGridPrefetcher? prefetcher = widget.prefetcher;
    if (prefetcher == null) return cell(context);
    // 预取的页落盘后只重画格子，不重建整张网格（不重放错峰进场）。
    return ListenableBuilder(
      listenable: prefetcher,
      builder: (BuildContext context, Widget? _) => cell(context),
    );
  }
}

class _MangaPageGridCell extends StatelessWidget {
  const _MangaPageGridCell({
    super.key,
    required this.index,
    required this.current,
    required this.image,
    required this.onTap,
  });

  final int index;
  final bool current;
  final ImageProvider? image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final Color accent = apple
        ? appleColorsOf(context).accent
        : theme.colorScheme.primary;
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSurfaceVariant;
    final BorderRadius coverRadius = shelfCoverRadius(context);
    final ImageProvider? provider = image;
    final Widget placeholder = Center(
      child: Text(
        '${index + 1}',
        style: theme.textTheme.titleMedium?.copyWith(color: muted),
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        child: Semantics(
          label: '${index + 1}',
          selected: current,
          button: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                // 当前页：强调色描边圈（外扩 3 + 间隙 2）；其余格子同一结构、
                // 描边透明，选中切换时不增删父包装层。
                child: AnimatedContainer(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  curve: FushiMotion.standard,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(
                      Radius.circular(coverRadius.topLeft.x + 3),
                    ),
                    border: Border.all(
                      color: current ? accent : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: ShelfCoverFrame(
                    // 预取的页到了：占位淡出换成页图。
                    child: AnimatedSwitcher(
                      duration: fushiMotionDuration(
                        context,
                        FushiMotion.medium,
                      ),
                      switchInCurve: FushiMotion.standard,
                      child: provider == null
                          ? KeyedSubtree(
                              key: const ValueKey<String>('placeholder'),
                              child: placeholder,
                            )
                          : Image(
                              key: const ValueKey<String>('image'),
                              image: provider,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              gaplessPlayback: true,
                              errorBuilder:
                                  (
                                    BuildContext context,
                                    Object error,
                                    StackTrace? stack,
                                  ) => placeholder,
                            ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: kMangaPageGridLabelHeight,
                child: Center(
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: current ? accent : muted,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
