/// 漫画阅读器的「全部页面」缩略图网格（2026-10 重设计）：一屏看完整卷 / 整章的
/// 页，点一页跳过去。
///
/// 卡片走共享卡片体系：[shelfCoverCard]（点击 / 焦点 / Enter 激活 / 按压下沉）+
/// [ShelfCoverFrame]（封面圆角 / 投影 / 内描边，MD3 与 Apple 各自的口径）+
/// [FushiHoverLift]（桌面悬停上浮）；当前屏上的页用强调色描边圈出。网格在
/// [FushiEntranceScope] 里经 [fushiStaggeredItemBuilder] 错峰进场（墨水屏 / 减弱
/// 动态效果下瞬间出现）。打开时滚到当前页附近。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 打开页面网格；返回用户点中的 0-based 页号，关掉返回 null。
///
/// [thumbnail] 只该给已经在盘上的页图（不为了缩略图去发网络请求），返回 null
/// 的格子画页码占位。
Future<int?> showMangaPageGridSheet({
  required BuildContext context,
  required int pageCount,
  required Set<int> currentPages,
  required ImageProvider? Function(int pageIndex) thumbnail,
}) {
  return adaptiveModalSheet<int>(
    context: context,
    builder: (BuildContext context) => MangaPageGridSheet(
      pageCount: pageCount,
      currentPages: currentPages,
      thumbnail: thumbnail,
    ),
  );
}

/// 网格格子的目标宽（逻辑像素）：手机竖屏一行 3–4 格，桌面一行 6–9 格。
const double kMangaPageGridCellTargetWidth = 112;

/// 格子宽高比（页图大致是 B6 / A5 的竖长方形）。
const double kMangaPageGridCoverAspect = 0.7;

/// 页码标签占的高度。
const double kMangaPageGridLabelHeight = 24;

const double _kGridSpacing = 12;
const double _kGridPadding = 20;

class MangaPageGridSheet extends StatefulWidget {
  const MangaPageGridSheet({
    super.key,
    required this.pageCount,
    required this.currentPages,
    required this.thumbnail,
  });

  final int pageCount;
  final Set<int> currentPages;
  final ImageProvider? Function(int pageIndex) thumbnail;

  @override
  State<MangaPageGridSheet> createState() => _MangaPageGridSheetState();
}

class _MangaPageGridSheetState extends State<MangaPageGridSheet> {
  ScrollController? _controller;
  int? _controllerColumns;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
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
    existing?.dispose();
    _controllerColumns = columns;
    return _controller = ScrollController(initialScrollOffset: offset);
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
          final ScrollController controller = _controllerFor(
            columns,
            cellHeight + _kGridSpacing,
          );
          return FushiEntranceScope(
            child: GridView.builder(
              key: const ValueKey<String>('manga_page_grid'),
              controller: controller,
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                _kGridPadding,
                4,
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
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int index) => _MangaPageGridCell(
                  key: ValueKey<String>('manga_page_grid_item_$index'),
                  index: index,
                  current: widget.currentPages.contains(index),
                  image: widget.thumbnail(index),
                  onTap: () => Navigator.of(context).pop(index),
                ),
              ),
            ),
          );
        },
      ),
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
                    child: provider == null
                        ? placeholder
                        : Image(
                            image: provider,
                            fit: BoxFit.cover,
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
