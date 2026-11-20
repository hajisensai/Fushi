import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart'
    show kFushiHoverLiftOverflow;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart'
    show SectionSwipeCascade;
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable, desktopAwareScrollPhysics;

// =============================================================================
// 封面色块的两种排法：拼贴（库页布局 [ShellContentLayout.collage]）与等尺寸色块
// （`layout` 传 null：首页「最近添加」等固定排成等尺寸色块的分区；库页布局里的
// 「规整色块」档已于 2026-11-12 删掉）。[ShellContentLayout.grid] 不走这里——调用点
// 保留原封面网格。
//
// - 等尺寸：色块网格。块高 204（窄窗 184）；按可用宽度定列数（目标块宽
//   视频 / 漫画 / 音乐约 400，书 / 游戏约 600），窗口更宽时加列，块不无限变大。
// - collage：第一项是加大块（高 264，占约 2/3 行宽；整行超过 1500 时最多一半），
//   旁边每列叠两张半高卡（宽行只第一列是半高叠，再往右是与大块同高的普通块）；
//   其余按等尺寸排。
// - collage + `uniformAfterHero`（音乐曲库，设计稿 M2）：只有首块加大（占 2 列 ×
//   2 行），其余全是等尺寸块，先填满首块旁边的列、再按等尺寸往下排，网格不出洞。
//
// 规整摆放下相邻块的间距处处等于 `spacing`（行内、半高叠内、行与行之间同一个
// 值）；悬停放大溢出由 [computeFushiCoverBlockPlacement] 在两侧留边，不靠缩间距。
//
// 几何是纯函数（[computeFushiCoverBlockPlan]），sliver 只按行懒构建；方向键导航
// 走 Flutter 的几何焦点遍历，不依赖列数。
// =============================================================================

/// 视频 / 漫画 / 音乐的目标块宽。
const double kFushiCoverBlockTargetWidthMedia = 400;

/// 书 / 游戏的目标块宽。
const double kFushiCoverBlockTargetWidthWide = 600;

/// 规整块高。
const double kFushiCoverBlockHeight = 204;

/// 窄窗（单列）规整块高。
const double kFushiCoverBlockHeightCompact = 184;

/// 拼贴首块高。
const double kFushiCoverBlockHeroHeight = 264;

/// 窄窗拼贴首块高。
const double kFushiCoverBlockHeroHeightCompact = 250;

/// 色块间距（与库页网格的左右边距同一档）。
const double kFushiCoverBlockSpacing = 14;

/// 拼贴首行超过这个宽度时，加大块最多占一半。
const double kFushiCoverBlockHeroCapRowWidth = 1500;

/// 布局里的一格。
@immutable
class FushiCoverBlockCell {
  const FushiCoverBlockCell({
    required this.index,
    required this.size,
    required this.rect,
  });

  /// 条目下标。
  final int index;
  final FushiCoverBlockSize size;

  /// 行内的起始边（start）坐标与尺寸：`left` 是 start 方向的偏移。
  final Rect rect;
}

/// 一行：行高 + 行内各格。
@immutable
class FushiCoverBlockRow {
  const FushiCoverBlockRow({required this.height, required this.cells});

  final double height;
  final List<FushiCoverBlockCell> cells;
}

/// 列数：按目标块宽取整（四舍五入，至少 1），块宽随行宽均分。
int fushiCoverBlockColumns(double width, double targetWidth, double spacing) =>
    math.max(1, ((width + spacing) / (targetWidth + spacing)).round());

/// 单本条目（书架 / 漫画库里的一本书，不是合集）的目标块宽。一本书的色块只有
/// 一张斜放的书封：按合集的 600 排会被拉成半行宽、封面很小、大片空色块
/// （2026-11-12 用户：「感觉一本书占太多位置了」）；收到 300 又窄得书名两行都
/// 放不下（同日：「单本书又太小，标题显示不全」）。取 400，实际宽度随行宽伸缩
/// （[computeFushiCoverBlockPlan] 的两端对齐，一般落在 340～470）。
const double kFushiCoverBlockTargetWidthSingle = 400;

/// 条目是不是「宽块」（合集），见 [computeFushiCoverBlockPlan] 的 `isWideItem`。
typedef FushiCoverBlockWideOf = bool Function(int index);

/// 两端对齐地切一段：从 [natural] 的第 [from] 项起往行里放，放到「再放一块要压缩
/// 的比例比不放要拉伸的比例更大」为止（至少一块），返回放进来的块数。
int _justifiedCount(
  List<double> natural,
  int from,
  double width,
  double spacing,
) {
  double used = natural[from];
  int count = 1;
  while (from + count < natural.length) {
    final double withNext = used + spacing + natural[from + count];
    // 放得下就放；放不下时比缩放比例：塞进来要压缩的倍数比不塞要拉伸的倍数
    // 小才塞（块宽离自然宽更近）。
    if (withNext <= width || withNext / width < width / used) {
      used = withNext;
      count++;
    } else {
      break;
    }
  }
  return count;
}

/// [natural] 的 [from] 起 [count] 块排进 [width]：等比缩放到正好铺满；[fill]
/// 为 false（末行）且本来放得下时保持自然宽，不拉宽。返回各块宽。
List<double> _justifiedWidths(
  List<double> natural,
  int from,
  int count,
  double width,
  double spacing, {
  required bool fill,
}) {
  double sum = 0;
  for (int i = from; i < from + count; i++) {
    sum += natural[i];
  }
  final double room = width - (count - 1) * spacing;
  final double scale = (!fill && sum <= room) ? 1 : room / sum;
  return <double>[for (int i = from; i < from + count; i++) natural[i] * scale];
}

/// 算整份布局。[layout] 为 [ShellContentLayout.collage] 时首行是拼贴头部，其余
/// （null = 等尺寸色块；grid 调用点本不该传进来，按等尺寸处理）全部等尺寸排。
///
/// 给了 [narrowTargetWidth] 时块不再等宽：[isWideItem] 为 true 的条目（合集）
/// 按 [targetWidth]、其余（单本）按 [narrowTargetWidth] 取自然宽，每行两端对齐
/// ——放到「再放一块要压缩得比不放要拉伸得更多」为止，再整行等比缩放铺满（末行放得下时
/// 不拉宽）。拼贴头部右侧的列（半高叠取其中较宽者）同样两端对齐。不给时与原来
/// 一样：所有条目按 [targetWidth] 等宽分栏。
///
/// [uniformAfterHero]（只在 [layout] 为 collage、且不给 [narrowTargetWidth] 时
/// 生效）：首块是占 2 列 × 2 行的加大块，其余全是等尺寸块——首块旁边的列排两行
/// 等尺寸块，之后按等尺寸逐行排（设计稿 M2「只有首块加大，其余等尺寸」）。不足
/// 3 列时首块独占一行（拼贴首块高），其余照常。
List<FushiCoverBlockRow> computeFushiCoverBlockPlan({
  required double width,
  required int itemCount,
  required ShellContentLayout? layout,
  required double targetWidth,
  double spacing = kFushiCoverBlockSpacing,
  double? narrowTargetWidth,
  FushiCoverBlockWideOf? isWideItem,
  bool uniformAfterHero = false,
}) {
  final List<FushiCoverBlockRow> rows = <FushiCoverBlockRow>[];
  if (itemCount <= 0 || width <= 0) return rows;
  if (uniformAfterHero &&
      layout == ShellContentLayout.collage &&
      narrowTargetWidth == null) {
    return _uniformAfterHeroPlan(
      width: width,
      itemCount: itemCount,
      targetWidth: targetWidth,
      spacing: spacing,
    );
  }
  final double? narrow = narrowTargetWidth;
  double naturalOf(int index) => narrow == null
      ? targetWidth
      : ((isWideItem?.call(index) ?? false) ? targetWidth : narrow);
  final int columns = fushiCoverBlockColumns(
    width,
    narrow ?? targetWidth,
    spacing,
  );
  final bool compact = columns == 1;
  final double blockHeight = compact
      ? kFushiCoverBlockHeightCompact
      : kFushiCoverBlockHeight;
  final double heroHeight = compact
      ? kFushiCoverBlockHeroHeightCompact
      : kFushiCoverBlockHeroHeight;
  final double halfHeight = (heroHeight - spacing) / 2;
  int next = 0;
  if (layout == ShellContentLayout.collage) {
    if (compact || itemCount == 1) {
      rows.add(
        FushiCoverBlockRow(
          height: heroHeight,
          cells: <FushiCoverBlockCell>[
            FushiCoverBlockCell(
              index: next++,
              size: FushiCoverBlockSize.hero,
              rect: Rect.fromLTWH(0, 0, width, heroHeight),
            ),
          ],
        ),
      );
      // 窄窗：两张半高卡各占一整行（设计稿手机版）。
      for (int i = 0; i < 2 && next < itemCount && compact; i++) {
        rows.add(
          FushiCoverBlockRow(
            height: halfHeight,
            cells: <FushiCoverBlockCell>[
              FushiCoverBlockCell(
                index: next++,
                size: FushiCoverBlockSize.half,
                rect: Rect.fromLTWH(0, 0, width, halfHeight),
              ),
            ],
          ),
        );
      }
    } else {
      // 宽行（> 1500）：大块最多一半，右侧紧挨一叠两张半高卡，再往右放普通块
      // （与大块顶对齐、拉到同高，不留下方空隙）。窄行：大块约 2/3，其余每列
      // 都是一叠半高卡。
      final bool wide = width > kFushiCoverBlockHeroCapRowWidth;
      final double heroWidth = wide
          ? (width - spacing) / 2
          : (width - spacing) * 2 / 3;
      final double rest = width - heroWidth - spacing;
      final List<FushiCoverBlockCell> cells = <FushiCoverBlockCell>[
        FushiCoverBlockCell(
          index: next++,
          size: FushiCoverBlockSize.hero,
          rect: Rect.fromLTWH(0, 0, heroWidth, heroHeight),
        ),
      ];
      // 右侧的列：宽行第一列 / 窄行每列是一叠两张半高卡，宽行其余列是一块
      // 普通块。
      final List<List<int>> groups = <List<int>>[];
      final List<double> groupNatural = <double>[];
      for (int cursor = next; cursor < itemCount;) {
        final bool stack = !wide || groups.isEmpty;
        final List<int> members = <int>[
          cursor,
          if (stack && cursor + 1 < itemCount) cursor + 1,
        ];
        groups.add(members);
        groupNatural.add(members.map(naturalOf).reduce(math.max));
        cursor += members.length;
      }
      final int count;
      final List<double> widths;
      if (narrow == null) {
        // 原排法：右侧按目标块宽等分成列。
        final int slots = fushiCoverBlockColumns(rest, targetWidth, spacing);
        final double columnWidth = (rest - (slots - 1) * spacing) / slots;
        count = math.min(groups.length, slots);
        widths = List<double>.filled(count, columnWidth);
      } else {
        count = _justifiedCount(groupNatural, 0, rest, spacing);
        widths = _justifiedWidths(
          groupNatural,
          0,
          count,
          rest,
          spacing,
          fill: count < groups.length,
        );
      }
      double left = heroWidth + spacing;
      for (int g = 0; g < count; g++) {
        final List<int> members = groups[g];
        final bool stack = !wide || g == 0;
        for (int k = 0; k < members.length; k++) {
          cells.add(
            FushiCoverBlockCell(
              index: members[k],
              size: stack
                  ? FushiCoverBlockSize.half
                  : FushiCoverBlockSize.regular,
              rect: stack
                  ? Rect.fromLTWH(
                      left,
                      k * (halfHeight + spacing),
                      widths[g],
                      halfHeight,
                    )
                  : Rect.fromLTWH(left, 0, widths[g], heroHeight),
            ),
          );
        }
        left += widths[g] + spacing;
        next = members.last + 1;
      }
      rows.add(FushiCoverBlockRow(height: heroHeight, cells: cells));
    }
  }
  if (narrow == null) {
    final double blockWidth = (width - (columns - 1) * spacing) / columns;
    while (next < itemCount) {
      final List<FushiCoverBlockCell> cells = <FushiCoverBlockCell>[];
      for (int c = 0; c < columns && next < itemCount; c++) {
        cells.add(
          FushiCoverBlockCell(
            index: next++,
            size: FushiCoverBlockSize.regular,
            rect: Rect.fromLTWH(
              c * (blockWidth + spacing),
              0,
              blockWidth,
              blockHeight,
            ),
          ),
        );
      }
      rows.add(FushiCoverBlockRow(height: blockHeight, cells: cells));
    }
    return rows;
  }
  final List<double> natural = <double>[
    for (int i = 0; i < itemCount; i++) naturalOf(i),
  ];
  while (next < itemCount) {
    final int count = _justifiedCount(natural, next, width, spacing);
    final List<double> widths = _justifiedWidths(
      natural,
      next,
      count,
      width,
      spacing,
      fill: next + count < itemCount,
    );
    final List<FushiCoverBlockCell> cells = <FushiCoverBlockCell>[];
    double left = 0;
    for (int c = 0; c < count; c++) {
      cells.add(
        FushiCoverBlockCell(
          index: next + c,
          size: FushiCoverBlockSize.regular,
          rect: Rect.fromLTWH(left, 0, widths[c], blockHeight),
        ),
      );
      left += widths[c] + spacing;
    }
    next += count;
    rows.add(FushiCoverBlockRow(height: blockHeight, cells: cells));
  }
  return rows;
}

/// [computeFushiCoverBlockPlan] 的 `uniformAfterHero` 排法。
List<FushiCoverBlockRow> _uniformAfterHeroPlan({
  required double width,
  required int itemCount,
  required double targetWidth,
  required double spacing,
}) {
  final List<FushiCoverBlockRow> rows = <FushiCoverBlockRow>[];
  final int columns = fushiCoverBlockColumns(width, targetWidth, spacing);
  final bool compact = columns == 1;
  final double blockHeight = compact
      ? kFushiCoverBlockHeightCompact
      : kFushiCoverBlockHeight;
  final double blockWidth = (width - (columns - 1) * spacing) / columns;
  int next = 0;
  // 等尺寸块的一整行，从第 [startColumn] 列起。
  List<FushiCoverBlockCell> fillRow(int startColumn, double top) {
    final List<FushiCoverBlockCell> cells = <FushiCoverBlockCell>[];
    for (int c = startColumn; c < columns && next < itemCount; c++) {
      cells.add(
        FushiCoverBlockCell(
          index: next++,
          size: FushiCoverBlockSize.regular,
          rect: Rect.fromLTWH(
            c * (blockWidth + spacing),
            top,
            blockWidth,
            blockHeight,
          ),
        ),
      );
    }
    return cells;
  }

  if (columns < 3) {
    final double heroHeight = compact
        ? kFushiCoverBlockHeroHeightCompact
        : kFushiCoverBlockHeroHeight;
    rows.add(
      FushiCoverBlockRow(
        height: heroHeight,
        cells: <FushiCoverBlockCell>[
          FushiCoverBlockCell(
            index: next++,
            size: FushiCoverBlockSize.hero,
            rect: Rect.fromLTWH(0, 0, width, heroHeight),
          ),
        ],
      ),
    );
  } else {
    // 首块占 2 列；旁边 columns − 2 列。条目只够旁边排一行时首块也只占一行高，
    // 不在第二行留洞。
    final int beside = columns - 2;
    final int bandRows = itemCount - 1 > beside ? 2 : 1;
    final double bandHeight = bandRows * blockHeight + (bandRows - 1) * spacing;
    final List<FushiCoverBlockCell> cells = <FushiCoverBlockCell>[
      FushiCoverBlockCell(
        index: next++,
        size: FushiCoverBlockSize.hero,
        rect: Rect.fromLTWH(0, 0, blockWidth * 2 + spacing, bandHeight),
      ),
    ];
    for (int r = 0; r < bandRows; r++) {
      cells.addAll(fillRow(2, r * (blockHeight + spacing)));
    }
    rows.add(FushiCoverBlockRow(height: bandHeight, cells: cells));
  }
  while (next < itemCount) {
    rows.add(FushiCoverBlockRow(height: blockHeight, cells: fillRow(0, 0)));
  }
  return rows;
}

/// 摆好、留出悬停余量的布局（[computeFushiCoverBlockPlacement] 给出）。
@immutable
class FushiCoverBlockPlacement {
  const FushiCoverBlockPlacement({required this.rows, required this.inset});

  /// 各行；格子的 `rect.left` 已含 [inset]（起始边量起，直接按它摆）。
  final List<FushiCoverBlockRow> rows;

  /// 两侧各留的边（逻辑像素）。
  final double inset;
}

/// 贴着行两端的格子悬停放大后单侧溢出的最大量（[kFushiHoverLiftOverflow]：两套
/// 设计系统里较大的放大倍数）。
double _edgeHoverOverflow(List<FushiCoverBlockRow> rows, double width) {
  double overflow = 0;
  for (final FushiCoverBlockRow row in rows) {
    for (final FushiCoverBlockCell cell in row.cells) {
      if (cell.rect.left <= 0.5 || cell.rect.right >= width - 0.5) {
        overflow = math.max(
          overflow,
          cell.rect.width * kFushiHoverLiftOverflow,
        );
      }
    }
  }
  return overflow;
}

/// [computeFushiCoverBlockPlan] 加悬停余量：库页卡片的悬停抬升（`FushiHoverLift`
/// 以格子中心放大）会让贴行首 / 行尾的块越出 sliver 的横向范围，被滚动视口裁掉
/// 一条（设计稿 V1：「右列块悬停放大后超出内容区被裁」——裁切发生在页面
/// `CustomScrollView` 的视口矩形，左右只有页边距那 12）。这里在两侧各留出边缘块
/// 的放大溢出量，再把行宽缩进去排：放大后的块整块留在 [width] 之内，块与块之间的
/// 间距不变。留边会让列宽变窄，按新宽度重算到稳定（列数变了就再量一次）。
///
/// [hoverBleed]：块外两侧本来就有、放大后可以越进去的空白（调用点 sliver 外的
/// 页边距）。只有溢出量超出它的那部分才往行里留边——否则行首 / 行尾的块会比页边
/// 再缩进一截，与页面其它内容的左右竖线对不齐（合集详情色块成员墙，2026-11-16）。
///
/// [SliverFushiCoverBlocks] / [FushiCoverBlocks] 都按它摆；在外面按行数算容量的
/// 调用点（「前 N 行放得下几块」）也要用它，几何才与真正摆出来的一致。
FushiCoverBlockPlacement computeFushiCoverBlockPlacement({
  required double width,
  required int itemCount,
  required ShellContentLayout? layout,
  required double targetWidth,
  double spacing = kFushiCoverBlockSpacing,
  double? narrowTargetWidth,
  FushiCoverBlockWideOf? isWideItem,
  bool uniformAfterHero = false,
  double hoverBleed = 0,
}) {
  List<FushiCoverBlockRow> plan(double w) => computeFushiCoverBlockPlan(
    width: w,
    itemCount: itemCount,
    layout: layout,
    targetWidth: targetWidth,
    spacing: spacing,
    narrowTargetWidth: narrowTargetWidth,
    isWideItem: isWideItem,
    uniformAfterHero: uniformAfterHero,
  );
  double inset = 0;
  List<FushiCoverBlockRow> rows = plan(width);
  // 留边只会让块变窄（溢出变小），除非列数随之减少、块又变宽。inset 只增不减、
  // 列数只减不增，几轮内必然收敛；上限按列数可能的减少次数留足。
  for (int pass = 0; pass < 8; pass++) {
    final double need = _edgeHoverOverflow(
      rows,
      width - inset * 2,
    ).ceilToDouble();
    if (need <= inset + hoverBleed) break;
    inset = need - hoverBleed;
    rows = plan(math.max(0, width - inset * 2));
  }
  if (inset == 0) return FushiCoverBlockPlacement(rows: rows, inset: 0);
  return FushiCoverBlockPlacement(
    inset: inset,
    rows: <FushiCoverBlockRow>[
      for (final FushiCoverBlockRow row in rows)
        FushiCoverBlockRow(
          height: row.height,
          cells: <FushiCoverBlockCell>[
            for (final FushiCoverBlockCell cell in row.cells)
              FushiCoverBlockCell(
                index: cell.index,
                size: cell.size,
                rect: cell.rect.translate(inset, 0),
              ),
          ],
        ),
    ],
  );
}

/// 一块色块的摆放姿态：位移（逻辑像素）与旋转（度）。
typedef FushiCoverBlockPose = ({double dx, double dy, double rotation});

/// 按序号定的伪随机数（0～1），同一序号恒同值——散落的姿态不随重建 / 滚动变。
double _poseNoise(int seed) {
  final double x = math.sin(seed * 99.13 + 7) * 10000;
  return x - x.floorToDouble();
}

/// 色块在 [arrangement] 下的姿态（设计稿 `ARR` + `arrPose`）：
///
/// - 规整：不偏不转；
/// - 交错：奇数块下移 6、转 +2.2°，偶数块上移 3、转 −2.2°；
/// - 散落：横向 ±5、纵向 ±8、旋转 ±5.5°。
///
/// 块越宽偏得越少（系数 `160 / 宽`，夹在 0.14～1）：同样的角度在宽块上扫出的
/// 位移大得多，拼贴首块几乎不动。占满整行（> 80%）的块不横移。
FushiCoverBlockPose fushiCoverBlockPose(
  ShellBlockArrangement arrangement, {
  required int index,
  required double width,
  required double rowWidth,
}) {
  final FushiCoverBlockPose raw = switch (arrangement) {
    ShellBlockArrangement.aligned => (dx: 0, dy: 0, rotation: 0),
    ShellBlockArrangement.staggered => (
      dx: 0,
      dy: index.isOdd ? 6 : -3,
      rotation: index.isOdd ? 2.2 : -2.2,
    ),
    ShellBlockArrangement.scattered => (
      dx: (_poseNoise(index) - 0.5) * 10,
      dy: (_poseNoise(index + 9) - 0.5) * 16,
      rotation: (_poseNoise(index + 4) - 0.5) * 11,
    ),
  };
  if (width <= 0) return (dx: 0, dy: 0, rotation: 0);
  final double k = (160 / width).clamp(0.14, 1.0);
  return (
    dx: width > rowWidth * 0.8 ? 0 : raw.dx,
    dy: raw.dy * (0.4 + 0.6 * k),
    rotation: raw.rotation * k,
  );
}

/// 把 [pose] 画到一块色块上；指针悬停时转回三成半（设计稿 `place()` 的
/// `r: hover ? r * .35 : r`），配合卡片自己的悬停抬升。
class _ArrangedBlock extends StatefulWidget {
  const _ArrangedBlock({required this.pose, required this.child});

  final FushiCoverBlockPose pose;
  final Widget child;

  @override
  State<_ArrangedBlock> createState() => _ArrangedBlockState();
}

class _ArrangedBlockState extends State<_ArrangedBlock> {
  bool _hover = false;

  void _setHover(bool value) {
    if (_hover == value) return;
    setState(() => _hover = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockPose pose = widget.pose;
    if (pose.dx == 0 && pose.dy == 0 && pose.rotation == 0) {
      return widget.child;
    }
    return MouseRegion(
      opaque: false,
      onEnter: (PointerEnterEvent _) => _setHover(true),
      onExit: (PointerExitEvent _) => _setHover(false),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: _hover ? 0.35 : 1),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        builder: (BuildContext context, double factor, Widget? child) =>
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(pose.dx, pose.dy, 0, 1)
                ..rotateZ(pose.rotation * factor * math.pi / 180),
              child: child,
            ),
        child: widget.child,
      ),
    );
  }
}

/// 把布局截到 [maxRows] 行。拼贴头部（加大块 + 旁边的半高叠；窄窗是加大块加
/// 两张各占一行的半高卡）整体算一行，其后每个规整行算一行——窄窗不会因为头部
/// 本身就占三行而一块规整块都排不进去。
List<FushiCoverBlockRow> fushiCoverBlockRowsCapped(
  List<FushiCoverBlockRow> rows,
  int maxRows,
) {
  int head = 0;
  while (head < rows.length &&
      rows[head].cells.any(
        (FushiCoverBlockCell cell) => cell.size != FushiCoverBlockSize.regular,
      )) {
    head++;
  }
  final int keep = head > 0 ? head + maxRows - 1 : maxRows;
  return rows.length <= keep ? rows : rows.sublist(0, keep);
}

/// 色块格的构造：[size] 是这一格的尺寸档，交给 [FushiCoverBlock.size]。
typedef FushiCoverBlockItemBuilder =
    Widget Function(BuildContext context, int index, FushiCoverBlockSize size);

/// 色块布局 sliver：按行懒构建，每格包 [FushiStaggeredEntrance]（错峰进场由祖先
/// [FushiEntranceScope] 管）。左右边距由调用点的 `SliverPadding` 给。
class SliverFushiCoverBlocks extends StatelessWidget {
  const SliverFushiCoverBlocks({
    required this.itemCount,
    required this.itemBuilder,
    this.targetWidth = kFushiCoverBlockTargetWidthMedia,
    this.spacing = kFushiCoverBlockSpacing,
    this.maxRows,
    this.narrowTargetWidth,
    this.isWideItem,
    this.layout,
    this.uniformAfterHero = false,
    this.hoverBleed = 0,
    super.key,
  });

  /// 调用点 sliver 外两侧的页边距：悬停放大可以越进去，不再往行里额外留边
  /// （见 [computeFushiCoverBlockPlacement]）。
  final double hoverBleed;

  /// [ShellContentLayout.collage] = 拼贴；null = 等尺寸色块。
  final ShellContentLayout? layout;

  /// 拼贴下只有首块加大、其余等尺寸（见 [computeFushiCoverBlockPlan]）。
  final bool uniformAfterHero;
  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;

  /// 目标块宽（[kFushiCoverBlockTargetWidthMedia] / [kFushiCoverBlockTargetWidthWide]）。
  final double targetWidth;
  final double spacing;

  /// 单本条目的目标块宽（[kFushiCoverBlockTargetWidthSingle]）；给了就两端对齐排、
  /// [isWideItem] 的条目按 [targetWidth] 占宽块。见 [computeFushiCoverBlockPlan]。
  final double? narrowTargetWidth;
  final FushiCoverBlockWideOf? isWideItem;

  /// 行数上限（[fushiCoverBlockRowsCapped] 的口径）；排不下的条目不画。null = 全画。
  final int? maxRows;

  @override
  Widget build(BuildContext context) {
    final ShellBlockArrangement arrangement = shellBlockArrangementOf(context);
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        final List<FushiCoverBlockRow> plan = computeFushiCoverBlockPlacement(
          width: constraints.crossAxisExtent,
          itemCount: itemCount,
          layout: layout,
          targetWidth: targetWidth,
          spacing: spacing,
          narrowTargetWidth: narrowTargetWidth,
          isWideItem: isWideItem,
          uniformAfterHero: uniformAfterHero,
          hoverBleed: hoverBleed,
        ).rows;
        final int? cap = maxRows;
        final List<FushiCoverBlockRow> rows = cap == null
            ? plan
            : fushiCoverBlockRowsCapped(plan, cap);
        return SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (BuildContext context, int r) => _blockRow(
            context,
            rows,
            r,
            arrangement: arrangement,
            rowWidth: constraints.crossAxisExtent,
            spacing: spacing,
            itemBuilder: itemBuilder,
            staggerEntrance: true,
          ),
        );
      },
    );
  }
}

/// 色块布局的一行（[SliverFushiCoverBlocks] 与 [FushiCoverBlocks] 共用）：行高
/// 定死，各格按 [computeFushiCoverBlockPlan] 的矩形摆放，套摆放姿态；
/// [staggerEntrance] 时每格包 [FushiStaggeredEntrance]。
Widget _blockRow(
  BuildContext context,
  List<FushiCoverBlockRow> rows,
  int r, {
  required ShellBlockArrangement arrangement,
  required double rowWidth,
  required double spacing,
  required FushiCoverBlockItemBuilder itemBuilder,
  required bool staggerEntrance,
}) {
  final FushiCoverBlockRow row = rows[r];
  return Padding(
    padding: EdgeInsets.only(bottom: r == rows.length - 1 ? 0 : spacing),
    child: SizedBox(
      height: row.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (final FushiCoverBlockCell cell in row.cells)
            PositionedDirectional(
              key: ValueKey<int>(cell.index),
              start: cell.rect.left,
              top: cell.rect.top,
              width: cell.rect.width,
              height: cell.rect.height,
              child: _maybeStaggered(
                staggerEntrance: staggerEntrance,
                index: cell.index,
                child: _ArrangedBlock(
                  pose: fushiCoverBlockPose(
                    arrangement,
                    index: cell.index,
                    width: cell.rect.width,
                    rowWidth: rowWidth,
                  ),
                  child: itemBuilder(context, cell.index, cell.size),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

Widget _maybeStaggered({
  required bool staggerEntrance,
  required int index,
  required Widget child,
}) => staggerEntrance
    ? FushiStaggeredEntrance(index: index, child: child)
    : child;

/// 「主块 + 横滑条」排法的主块 / 条内小块尺寸。主块高：宽屏 = 拼贴首块高，窄屏
/// 收到 200（信息密度优先）；条内小块 = 半高卡。
const double kFushiCoverBlockStripHeroHeightCompact = 200;
const double kFushiCoverBlockStripTileWidth = 300;

/// 「主块 + 横滑条」排法（首页「继续」）：信息密度优先，整段不往下堆行。
///
/// - 宽屏：主块在起始侧，其余条目是它旁边的两行半高卡，横向滑动；整段只占
///   一个主块的高度。条目少到一屏排得下时不滑，主块吃掉余下的宽度。
/// - 窄屏：主块在上，下面一行半高卡横向滑动。
///
/// 结构同重设计前的「主卡 + 封面横滑行」，外观是封面色块（2026-11-12 用户：
/// 「窄屏需要信息效率高，最好跟以前一样但是用新设计」）。第 0 项是主块
/// （[FushiCoverBlockSize.hero]），其余是 [FushiCoverBlockSize.half]。横滑条里的
/// 块不带交错 / 散落姿态（会被滚动区裁掉）。每格错峰进场。
///
/// [leadingHero] 为 false 时不分主次：全部条目排成**一行**半高卡横向滑动（库页
/// 「继续阅读 / 继续观看 / 继续游戏」，见 [FushiContinueBlocks]；2026-11-12 用户：
/// 「继续阅读占空间太大了还是保持跟之前一样侧滑」），宽窄屏同一排法，只有卡宽
/// 随窗宽收窄。
class FushiCoverBlockStrip extends StatelessWidget {
  const FushiCoverBlockStrip({
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = kFushiCoverBlockSpacing,
    this.stripKey,
    this.leadingHero = true,
    this.staggerEntrance = true,
    this.rowSize = FushiCoverBlockSize.half,
    this.rows = 1,
    this.tileHeight,
    this.tileWidth,
    this.besideLeading = false,
    super.key,
  });

  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;

  /// 横滑条起始侧紧挨着另一张卡（视频首页「继续观看」主卡右侧那两行）：
  /// 起始侧不外扩悬停余量，视口就从条自己的起点开始，滑走的卡在视口边上被
  /// 裁掉，不会伸进与主卡之间的间距、盖住主卡的圆角（2026-11-20 用户截图：
  /// 主卡右缘两个角变直角，横滑卡在主卡边上竖直硬切）。
  final bool besideLeading;
  final double spacing;

  /// 单行排法（[leadingHero] 为 false）每格的尺寸：默认半高卡；
  /// [FushiCoverBlockSize.regular] 时是与等尺寸色块网格同高同宽的整块（视频首页
  /// 「继续观看」其余条目：2026-11-12 用户「继续观看那些小的改成横滑一排，不要
  /// 展开」，同日又要求整块大小与「系列」页签一致）。
  final FushiCoverBlockSize rowSize;

  /// 整块横滑（[rowSize] 为 regular）的行数：视频首页宽屏主卡旁排两行。
  final int rows;

  /// 整块横滑的格高 / 格宽；null = 等尺寸网格同款（[kFushiCoverBlockHeight] /
  /// [regularTileWidth]）。
  final double? tileHeight;
  final double? tileWidth;

  /// 整块单行在 [width] 宽下的卡宽：与 [FushiCoverBlocks] 等尺寸网格同列宽
  /// （按 [kFushiCoverBlockTargetWidthMedia] 定列数）；窄屏一列时取约八成五
  /// 行宽，露出下一张的一角提示能滑。
  static double regularTileWidth(
    double width, {
    double spacing = kFushiCoverBlockSpacing,
  }) {
    final int columns = fushiCoverBlockColumns(
      width,
      kFushiCoverBlockTargetWidthMedia,
      spacing,
    );
    if (columns == 1) return width * 0.85;
    return (width - (columns - 1) * spacing) / columns;
  }

  /// true：第 0 项是主块、其余进横滑条（首页）；false：全部条目一行横滑。
  final bool leadingHero;

  /// 每格各自错峰进场；外层已整块包了进场动画的调用方传 false。
  final bool staggerEntrance;

  /// 一行半高卡的高（不含悬停余量）：骨架按它占位，换真内容不跳。
  static double rowHeight({double spacing = kFushiCoverBlockSpacing}) =>
      (kFushiCoverBlockHeroHeight - spacing) / 2;

  /// 窄屏（一列色块）下横滑条的卡宽：约七成行宽，夹在 220…
  /// [kFushiCoverBlockStripTileWidth]，露出下一张的一角提示能滑。
  static double compactTileWidth(double width) =>
      (width * 0.72).clamp(220.0, kFushiCoverBlockStripTileWidth);

  /// [leadingHero] 排法在 [width] 宽下的主块高：窄屏
  /// [kFushiCoverBlockStripHeroHeightCompact]，否则 [kFushiCoverBlockHeroHeight]。
  static double heroHeightFor(
    double width, {
    double spacing = kFushiCoverBlockSpacing,
  }) => isCompact(width, spacing: spacing)
      ? kFushiCoverBlockStripHeroHeightCompact
      : kFushiCoverBlockHeroHeight;

  /// 窄屏判据：这么宽只排得下一列色块。
  static bool isCompact(
    double width, {
    double spacing = kFushiCoverBlockSpacing,
  }) =>
      fushiCoverBlockColumns(
        width,
        kFushiCoverBlockTargetWidthMedia,
        spacing,
      ) ==
      1;

  /// 单行排法（[leadingHero] 为 false）在 [width] 宽下的卡宽：窄屏
  /// [compactTileWidth]，否则 [kFushiCoverBlockStripTileWidth]。骨架按它摆。
  static double rowTileWidth(
    double width, {
    double spacing = kFushiCoverBlockSpacing,
  }) => isCompact(width, spacing: spacing)
      ? compactTileWidth(width)
      : kFushiCoverBlockStripTileWidth;

  /// 横滑条的 key（测试按它找那一行）。
  final Key? stripKey;

  /// 悬停放大 / 投影在滚动区里要的余量：滚动区按这个量向四周外扩（内容起点
  /// 不变），半高卡的投影（[kFushiCoverBlockHalfShadowExtent]）连同悬停放大
  /// （1.05 倍，半高卡上下各约 3、左右各约 7.5）整段留在视口里，
  /// 不被视口矩形裁出一条带硬边的阴影带（2026-11-12 用户：「继续阅读底部阴影有点
  /// 大，感觉总体不协调」）。左右取页边距 20：再宽就画进侧栏，投影尾巴那 1～2px
  /// 的淡影被页边裁掉看不出来。
  static final EdgeInsets _kBleed = EdgeInsets.fromLTRB(
    20,
    kFushiCoverBlockHalfShadowExtent.top + 3,
    20,
    kFushiCoverBlockHalfShadowExtent.bottom + 5,
  );

  /// 整块（[FushiCoverBlockSize.regular]）的投影（模糊 26、下移 10）连同悬停放大
  /// 要的余量。
  static const EdgeInsets _kRegularBleed = EdgeInsets.fromLTRB(20, 22, 20, 42);

  Widget _cell(BuildContext context, int i, FushiCoverBlockSize size) =>
      _maybeStaggered(
        staggerEntrance: staggerEntrance,
        index: i,
        child: itemBuilder(context, i, size),
      );

  /// 横滑条：[rows] 行半高卡，从第 [first] 项排到末项。视口向四周外扩
  /// [_kBleed]（内容起点不变）。
  Widget _strip(
    BuildContext context, {
    required int rows,
    required double tile,
    int first = 1,
    FushiCoverBlockSize size = FushiCoverBlockSize.half,
    double? tileHeight,
    bool clipLeading = false,
  }) {
    final double half = tileHeight ?? rowHeight(spacing: spacing);
    final double height = rows * half + (rows - 1) * spacing;
    final int count = itemCount - first;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final EdgeInsets baseBleed = size == FushiCoverBlockSize.regular
        ? _kRegularBleed
        : _kBleed;
    // 起始侧紧挨着别的卡时不外扩（见 [besideLeading]）：外扩量（20）比卡间距
    // （16）大，视口会伸进主卡里 4dp，横滑卡就画在主卡圆角之上。
    final EdgeInsets bleed = !clipLeading
        ? baseBleed
        : rtl
        ? baseBleed.copyWith(right: 0)
        : baseBleed.copyWith(left: 0);
    final EdgeInsets padding = bleed;
    Widget item(BuildContext context, int i) => _cell(context, i + first, size);
    // 单行 / 多行两种滚动件各自包 [HorizontalDragScrollable]（桌面鼠标可横拖）。
    Widget list(ScrollController? controller) => rows == 1
        ? HorizontalDragScrollable(
            child: ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              physics: desktopAwareScrollPhysics(),
              padding: padding,
              itemCount: count,
              separatorBuilder: (BuildContext _, int _) =>
                  SizedBox(width: spacing),
              itemBuilder: (BuildContext context, int i) =>
                  SizedBox(width: tile, child: item(context, i)),
            ),
          )
        : HorizontalDragScrollable(
            child: GridView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              physics: desktopAwareScrollPhysics(),
              padding: padding,
              itemCount: count,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: rows,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                mainAxisExtent: tile,
              ),
              itemBuilder: item,
            ),
          );
    return SizedBox(
      key: stripKey,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: -bleed.left,
            top: -bleed.top,
            right: -bleed.right,
            bottom: -bleed.bottom,
            child: clipLeading
                ? _TrailingEdgeFade(
                    trailingInset: rtl ? bleed.left : bleed.right,
                    builder: (ScrollController controller) =>
                        SectionSwipeCascade(child: list(controller)),
                  )
                : SectionSwipeCascade(child: list(null)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (itemCount <= 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        if (!leadingHero && rowSize == FushiCoverBlockSize.regular) {
          final bool compact = isCompact(width, spacing: spacing);
          return _strip(
            context,
            rows: rows,
            first: 0,
            size: FushiCoverBlockSize.regular,
            clipLeading: besideLeading,
            tileHeight:
                tileHeight ??
                (compact
                    ? kFushiCoverBlockHeightCompact
                    : kFushiCoverBlockHeight),
            tile: tileWidth ?? regularTileWidth(width, spacing: spacing),
          );
        }
        if (!leadingHero) {
          return _strip(
            context,
            rows: 1,
            first: 0,
            tile: rowTileWidth(width, spacing: spacing),
          );
        }
        final bool compact = isCompact(width, spacing: spacing);
        final int rest = itemCount - 1;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: kFushiCoverBlockStripHeroHeightCompact,
                child: _cell(context, 0, FushiCoverBlockSize.hero),
              ),
              if (rest > 0) ...<Widget>[
                SizedBox(height: spacing),
                _strip(context, rows: 1, tile: compactTileWidth(width)),
              ],
            ],
          );
        }
        final Widget hero = SizedBox(
          height: kFushiCoverBlockHeroHeight,
          child: _cell(context, 0, FushiCoverBlockSize.hero),
        );
        if (rest <= 0) return hero;
        const double tile = kFushiCoverBlockStripTileWidth;
        // 主块宽：约四成行宽，夹在 420–640。条目少、整条排得下时条取内容宽，
        // 主块吃掉余下的宽度。
        final double heroWidth = (width * 0.42).clamp(420.0, 640.0);
        final int columns = (rest / 2).ceil();
        final double contentWidth = columns * tile + (columns - 1) * spacing;
        final bool fits = contentWidth <= width - heroWidth - spacing;
        final Widget strip = _strip(
          context,
          rows: 2,
          tile: tile,
          clipLeading: true,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (fits)
              Expanded(child: hero)
            else
              SizedBox(width: heroWidth, child: hero),
            SizedBox(width: spacing),
            if (fits)
              SizedBox(width: contentWidth, child: strip)
            else
              Expanded(child: strip),
          ],
        );
      },
    );
  }
}

/// 首行行高：骨架按它占位，换真内容不跳（拼贴 = 首块高，规整 = 块高；窄窗
/// 各取紧凑档）。
double fushiCoverBlockFirstRowHeight({
  required double width,
  required ShellContentLayout? layout,
  double targetWidth = kFushiCoverBlockTargetWidthMedia,
  double spacing = kFushiCoverBlockSpacing,
  bool uniformAfterHero = false,
}) {
  // uniformAfterHero 的首行高取决于条目够不够填首块旁两行：骨架按填满算。
  final List<FushiCoverBlockRow> rows = computeFushiCoverBlockPlacement(
    width: width,
    itemCount: uniformAfterHero ? 64 : 1,
    layout: layout,
    targetWidth: targetWidth,
    spacing: spacing,
    uniformAfterHero: uniformAfterHero,
  ).rows;
  return rows.isEmpty ? 0 : rows.first.height;
}

/// [SliverFushiCoverBlocks] 的盒子版：条目少（「继续」区，十几项以内）、排在
/// 普通 Column 里时用，一次建完所有行。几何、摆放姿态与 sliver 版逐格一致。
class FushiCoverBlocks extends StatelessWidget {
  const FushiCoverBlocks({
    required this.itemCount,
    required this.itemBuilder,
    this.layout,
    this.targetWidth = kFushiCoverBlockTargetWidthMedia,
    this.spacing = kFushiCoverBlockSpacing,
    this.staggerEntrance = true,
    this.uniformAfterHero = false,
    super.key,
  });

  /// [ShellContentLayout.collage] = 拼贴；null = 等尺寸色块。
  final ShellContentLayout? layout;

  /// 拼贴下只有首块加大、其余等尺寸（见 [computeFushiCoverBlockPlan]）。
  final bool uniformAfterHero;
  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;
  final double targetWidth;
  final double spacing;

  /// 每格各自错峰进场；外层已整块包了进场动画的调用方传 false，免得叠两层。
  final bool staggerEntrance;

  @override
  Widget build(BuildContext context) {
    final ShellBlockArrangement arrangement = shellBlockArrangementOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<FushiCoverBlockRow> rows = computeFushiCoverBlockPlacement(
          width: constraints.maxWidth,
          itemCount: itemCount,
          layout: layout,
          targetWidth: targetWidth,
          spacing: spacing,
          uniformAfterHero: uniformAfterHero,
        ).rows;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int r = 0; r < rows.length; r++)
              _blockRow(
                context,
                rows,
                r,
                arrangement: arrangement,
                rowWidth: constraints.maxWidth,
                spacing: spacing,
                itemBuilder: itemBuilder,
                staggerEntrance: staggerEntrance,
              ),
          ],
        );
      },
    );
  }
}

/// 横滑视口的结束侧渐隐：还能往结束方向滑时，视口结束边（减去外扩余量
/// [trailingInset]，即条本身的结束边附近）那一段渐隐成透明，提示「右边还有」；
/// 滑到底就不渐隐，最后一张卡完整显示。渐隐的出现 / 消失走 [FushiMotion]。
class _TrailingEdgeFade extends StatefulWidget {
  const _TrailingEdgeFade({required this.trailingInset, required this.builder});

  final double trailingInset;

  /// 滚动件（用给的 controller，渐隐按它的位置判断还能不能往后滑）。
  final Widget Function(ScrollController controller) builder;

  @override
  State<_TrailingEdgeFade> createState() => _TrailingEdgeFadeState();
}

class _TrailingEdgeFadeState extends State<_TrailingEdgeFade> {
  /// 渐隐段宽（不含外扩余量）。
  static const double _kFadeExtent = 48;

  final ScrollController _controller = ScrollController();
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_sync)
      ..dispose();
    super.dispose();
  }

  /// 按当前滚动位置更新「还能往后滑」。首次布局不发 [ScrollMetricsNotification]，
  /// 所以每帧建完后对一次；之后尺寸变化走通知、滚动走 controller 监听。
  void _sync() {
    if (!mounted || !_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    final bool more =
        position.hasContentDimensions && position.extentAfter > 0.5;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _sync());
    final Widget listened = NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification _) {
        _sync();
        return false;
      },
      child: widget.builder(_controller),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _more ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      child: listened,
      // ShaderMask 恒在（t = 0 时全不透明）：渐隐开关不改子树结构，滚动件的
      // 状态（位置）不会因此重建。
      builder: (BuildContext context, double t, Widget? child) {
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) {
            final double w = math.max(bounds.width, 1);
            final double end = ((w - widget.trailingInset) / w).clamp(0.0, 1.0);
            final double start = ((w - widget.trailingInset - _kFadeExtent) / w)
                .clamp(0.0, end);
            final Color faded = Color.fromRGBO(255, 255, 255, 1 - t);
            return LinearGradient(
              begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
              end: rtl ? Alignment.centerLeft : Alignment.centerRight,
              colors: <Color>[
                const Color(0xFFFFFFFF),
                const Color(0xFFFFFFFF),
                faded,
                faded,
              ],
              stops: <double>[0, start, end, 1],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}
