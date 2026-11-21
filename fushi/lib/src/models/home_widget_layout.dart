/// 首页小组件网格（spec `docs/specs/2026-11-15-home-widgets-design.md`）的纯数据层：
/// 组件目录（[HomeWidgetKind]，持久化 id 冻结）、连续可调尺寸范围、两份布局（[HomeGridKind]
/// 窄 2 列 / 宽 6 列）、密集装箱、编辑操作（增删 / 移动 / 改尺寸 / 撤销）、编解码与
/// 从旧偏好 `home_dashboard_panels` 的迁移。
///
/// 全部是纯函数：不碰 Flutter、不读偏好，页面与测试都只经这里算布局。
///
/// 持久化：偏好 `home_widget_layout` 存
/// `{"v":1,"compact":[{"k":"today","c":1,"r":1},...],"wide":[...]}`（可配置的组件多一个
/// 可选字段 `"l"`：「语言目标」格的语言，老版本读的时候忽略它）。键缺失或某份
/// 布局缺失 = 用户没编辑过那份布局，渲染时由 [migrateHomeWidgetLayout] 现算（不落盘，
/// 免得同步把迁移态带到别的设备覆盖）。kind id 与 JSON 字段冻结不追改。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable, listEquals;

import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalLanguage, resolveStudyGoalLanguage;

/// 小组件在网格里占的格数（列 × 行）。
@immutable
class HomeWidgetSize {
  const HomeWidgetSize(this.cols, this.rows);

  final int cols;
  final int rows;

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetSize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  /// 「2×1」：尺寸标签（添加面板 / 尺寸选择网格 / 拖角预览，不随语言变）。
  @override
  String toString() => '$cols×$rows';
}

/// 添加面板的分类。
enum HomeWidgetCategory { study, continueMedia, tools }

/// 一份布局对应的网格：窄（手机竖屏 / 窄窗，2 列）与宽（平板 / 桌面，6 列）。
/// 两份分开存，窗口跨断点时切到另一份，不互相换算。
enum HomeGridKind {
  compact('compact', 2),
  wide('wide', 6);

  const HomeGridKind(this.wire, this.columns);

  /// JSON 字段名（冻结）。
  final String wire;

  /// 网格列数。
  final int columns;
}

/// 组件高度上限（行）：任何组件都不超过 4 行高（spec「尺寸」）。
const int kHomeWidgetMaxRows = 4;

/// 小组件目录。顺序 = 添加面板的展示顺序。
///
/// 每种组件有一段连续的可调范围 [min]…[max]（列 × 行，宽网格口径）；在窄网格里
/// 宽度再封顶到 2 列（[maxFor]）。默认尺寸（添加 / 默认模板用）按网格分开给。
enum HomeWidgetKind {
  /// 「继续」主角：最近一条放大，格子够大再挂其余条目（横滑小行 / 封面行）。
  continueHero(
    'continue',
    HomeWidgetCategory.continueMedia,
    min: HomeWidgetSize(1, 2),
    max: HomeWidgetSize(6, 4),
    compactDefault: HomeWidgetSize(2, 2),
    wideDefault: HomeWidgetSize(4, 2),
  ),

  /// 「继续阅读」：同一份继续条目里的书 / 漫画 / 字幕书 / 有声书。
  continueReading(
    'continue_reading',
    HomeWidgetCategory.continueMedia,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 3),
    compactDefault: HomeWidgetSize(2, 1),
    wideDefault: HomeWidgetSize(2, 2),
  ),

  /// 「继续观看」：继续条目里的视频（本地 / 远端 / 媒体服务器）。
  continueWatching(
    'continue_watching',
    HomeWidgetCategory.continueMedia,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 3),
    compactDefault: HomeWidgetSize(2, 1),
    wideDefault: HomeWidgetSize(2, 2),
  ),

  /// 「继续游玩」：继续条目里的游戏。
  continuePlaying(
    'continue_playing',
    HomeWidgetCategory.continueMedia,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 3),
    compactDefault: HomeWidgetSize(2, 1),
    wideDefault: HomeWidgetSize(2, 2),
  ),

  /// 「今日」：今日字数 + 时长 / 目标；格子变宽 / 变高再挂近 7 天柱条。
  today(
    'today',
    HomeWidgetCategory.study,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(3, 2),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(2, 1),
  ),

  /// 「近 7 天」柱条（格子越高柱越高）。
  week(
    'week',
    HomeWidgetCategory.study,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 3),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(2, 2),
  ),

  /// 复习（内置 SRS）。
  srsReview(
    'srs_review',
    HomeWidgetCategory.study,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(3, 2),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(1, 1),
  ),

  /// 最近添加（格子越大列得越多）。
  recentlyAdded(
    'recently_added',
    HomeWidgetCategory.continueMedia,
    min: HomeWidgetSize(1, 2),
    max: HomeWidgetSize(6, 4),
    compactDefault: HomeWidgetSize(2, 2),
    wideDefault: HomeWidgetSize(4, 2),
  ),

  /// 媒体追踪同步状态。
  tracking(
    'tracking',
    HomeWidgetCategory.tools,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 2),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(2, 1),
  ),

  /// AI 助手入口。
  aiAgent(
    'ai_agent',
    HomeWidgetCategory.tools,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(3, 2),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(1, 1),
  ),

  /// 媒体库全景入口（不常驻渲染 3D）。
  panorama(
    'panorama',
    HomeWidgetCategory.tools,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(6, 4),
    compactDefault: HomeWidgetSize(2, 2),
    wideDefault: HomeWidgetSize(2, 2),
  ),

  /// 「语言目标」：一种语言的日 / 周 / 月目标环（[HomeWidgetItem.language]；null =
  /// 不限语言的目标）。可以放多块，每块一种语言（[repeatable]）。
  languageGoals(
    'language_goals',
    HomeWidgetCategory.study,
    min: HomeWidgetSize(1, 1),
    max: HomeWidgetSize(3, 2),
    compactDefault: HomeWidgetSize(1, 1),
    wideDefault: HomeWidgetSize(2, 1),
  );

  const HomeWidgetKind(
    this.id,
    this.category, {
    required this.min,
    required this.max,
    required this.compactDefault,
    required this.wideDefault,
  });

  /// 持久化 id（冻结）。
  final String id;
  final HomeWidgetCategory category;

  /// 可调范围的下限 / 上限（宽网格口径，列 × 行）。
  final HomeWidgetSize min;
  final HomeWidgetSize max;

  /// 两种网格各自的默认尺寸（添加面板「添加」与默认模板用）。
  final HomeWidgetSize compactDefault;
  final HomeWidgetSize wideDefault;

  /// [grid] 里的下限：宽度不超过网格列数。
  HomeWidgetSize minFor(HomeGridKind grid) =>
      HomeWidgetSize(math.min(min.cols, grid.columns), min.rows);

  /// [grid] 里的上限：宽度封顶到网格列数，高度封顶 [kHomeWidgetMaxRows]。
  HomeWidgetSize maxFor(HomeGridKind grid) => HomeWidgetSize(
    math.min(max.cols, grid.columns),
    math.min(max.rows, kHomeWidgetMaxRows),
  );

  /// [grid] 里的默认尺寸（已在范围内）。
  HomeWidgetSize defaultFor(HomeGridKind grid) =>
      clampHomeWidgetSize(this, grid, switch (grid) {
        HomeGridKind.compact => compactDefault,
        HomeGridKind.wide => wideDefault,
      });

  /// [grid] 里能不能调尺寸（范围不止一格）。
  bool resizableIn(HomeGridKind grid) => minFor(grid) != maxFor(grid);

  /// 能放多块（每块配置不同）：身份是 kind + 配置（[HomeWidgetItem.slot]）。
  bool get repeatable => this == languageGoals;

  static HomeWidgetKind? fromId(Object? id) {
    for (final HomeWidgetKind k in HomeWidgetKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// [kind] + 配置的布局身份（[HomeWidgetItem.slot]）：不可重复的组件就是 kind id，
/// 可重复的再带上配置（`language_goals:ja`；不限语言就是 kind id `language_goals`）。
String homeWidgetSlot(HomeWidgetKind kind, {String? language}) =>
    kind.repeatable && language != null ? '${kind.id}:$language' : kind.id;

/// 布局里的一项：哪种组件、占多大、（可配置的组件）怎么配。
@immutable
class HomeWidgetItem {
  const HomeWidgetItem(
    this.kind,
    this.size, {
    String? language,
    this.goals = const <String>[],
  }) : language = language == '' ? null : language;

  final HomeWidgetKind kind;
  final HomeWidgetSize size;

  /// 「语言目标」格的语言（BCP-47；null = 不限语言的目标）。别的组件恒为 null。
  final String? language;

  /// 「语言目标」格用户挑的目标（记录 id，按显示顺序，至多 3 条）；空 = 自动（这种
  /// 语言的目标，按周期挑）。删掉的记录渲染时静默跳过，一条都不剩就回到自动。
  final List<String> goals;

  /// 布局里的身份：同一份布局里每个 slot 至多一块（见 [homeWidgetSlot]）。
  String get slot => homeWidgetSlot(kind, language: language);

  HomeWidgetItem withSize(HomeWidgetSize size) =>
      HomeWidgetItem(kind, size, language: language, goals: goals);

  HomeWidgetItem withLanguage(String? language) => HomeWidgetItem(
    kind,
    size,
    language: kind.repeatable ? language : null,
    goals: goals,
  );

  HomeWidgetItem withGoals(List<String> goals) => HomeWidgetItem(
    kind,
    size,
    language: language,
    goals: kind.repeatable
        ? List<String>.unmodifiable(goals)
        : const <String>[],
  );

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetItem &&
      other.kind == kind &&
      other.size == size &&
      other.language == language &&
      listEquals(other.goals, goals);

  @override
  int get hashCode => Object.hash(kind, size, language, Object.hashAll(goals));

  @override
  String toString() =>
      language == null ? '${kind.id} $size' : '${kind.id}($language) $size';
}

/// 用户存下的两份布局；某份为 null = 那份没编辑过（渲染时走迁移 / 默认模板）。
@immutable
class HomeWidgetLayout {
  const HomeWidgetLayout({this.compact, this.wide});

  final List<HomeWidgetItem>? compact;
  final List<HomeWidgetItem>? wide;

  List<HomeWidgetItem>? itemsFor(HomeGridKind grid) => switch (grid) {
    HomeGridKind.compact => compact,
    HomeGridKind.wide => wide,
  };

  HomeWidgetLayout withItems(HomeGridKind grid, List<HomeWidgetItem> items) =>
      switch (grid) {
        HomeGridKind.compact => HomeWidgetLayout(compact: items, wide: wide),
        HomeGridKind.wide => HomeWidgetLayout(compact: compact, wide: items),
      };
}

/// 一条「继续」条目归哪个按类型的继续组件：书 / 漫画 / 字幕书 / 有声书 = 继续阅读，
/// 视频 = 继续观看，游戏 = 继续游玩；都不是（不应出现）为 null。
HomeWidgetKind? homeWidgetContinueKindOf({
  required bool isBook,
  required bool isAudiobook,
  required bool isVideo,
  required bool isGame,
}) {
  if (isVideo) return HomeWidgetKind.continueWatching;
  if (isGame) return HomeWidgetKind.continuePlaying;
  if (isBook || isAudiobook) return HomeWidgetKind.continueReading;
  return null;
}

/// 组件此刻可不可用（spec「显隐语义」）：不可用 = 不渲染、不出现在添加面板里，但
/// 布局里保留，模块重新打开就回来。三个按类型的继续组件跟对应媒体模块走；复习跟
/// 复习模块；追踪跟媒体追踪模块；AI 只跟 AI 模块（未指派提供商仍可用：入口可见、
/// 点击引导去设置，fushi/CLAUDE.md §13）。其余组件始终可用（有就显示、没有就收成一行）。
bool homeWidgetAvailable(
  HomeWidgetKind kind, {
  required bool reading,
  required bool watching,
  required bool playing,
  required bool srs,
  required bool tracking,
  required bool ai,
}) => switch (kind) {
  HomeWidgetKind.continueReading => reading,
  HomeWidgetKind.continueWatching => watching,
  HomeWidgetKind.continuePlaying => playing,
  HomeWidgetKind.srsReview => srs,
  HomeWidgetKind.tracking => tracking,
  HomeWidgetKind.aiAgent => ai,
  HomeWidgetKind.continueHero ||
  HomeWidgetKind.today ||
  HomeWidgetKind.week ||
  HomeWidgetKind.recentlyAdded ||
  HomeWidgetKind.panorama ||
  HomeWidgetKind.languageGoals => true,
};

// ── 尺寸 ────────────────────────────────────────────────────────────────

/// 把 [size] 钳进 [kind] 在 [grid] 里的可调范围（各轴独立钳）。
HomeWidgetSize clampHomeWidgetSize(
  HomeWidgetKind kind,
  HomeGridKind grid,
  HomeWidgetSize size,
) {
  final HomeWidgetSize lo = kind.minFor(grid);
  final HomeWidgetSize hi = kind.maxFor(grid);
  return HomeWidgetSize(
    size.cols.clamp(lo.cols, hi.cols),
    size.rows.clamp(lo.rows, hi.rows),
  );
}

/// 拖右下角改尺寸的吸附（纯函数）：从按下时的尺寸 [start] 起，指针移了
/// ([dx], [dy])（逻辑方向：[dx] 正 = 朝结束侧，RTL 由调用方翻号）后，右下角落在
/// 哪一格就取那一格（四舍五入到最近的格线），再钳进可调范围。
///
/// [columnExtent] / [rowExtent] 是单格宽 / 高，[gap] 是格间距；一格的「步长」=
/// 格宽 + 间距（n 格宽 = n × 步长 − 间距）。
HomeWidgetSize homeWidgetDragSize({
  required HomeWidgetKind kind,
  required HomeGridKind grid,
  required HomeWidgetSize start,
  required double dx,
  required double dy,
  required double columnExtent,
  required double rowExtent,
  required double gap,
}) {
  int snap(int cells, double extent, double delta) {
    final double step = extent + gap;
    if (step <= 0) return cells;
    final double span = cells * step - gap + delta;
    return ((span + gap) / step).round();
  }

  return clampHomeWidgetSize(
    kind,
    grid,
    HomeWidgetSize(
      snap(start.cols, columnExtent, dx),
      snap(start.rows, rowExtent, dy),
    ),
  );
}

/// 网格行高（逻辑像素）：窄网格约 84、宽网格约 118 的基准，按列宽微调。
///
/// [width] 是网格可用宽，[gap] 是格间距（与库页色块同档 `kFushiCoverBlockSpacing`）。
/// 列宽 = (宽 − 间距 × (列数 − 1)) / 列数；窄网格行高 = 列宽 × 0.48 夹在 76…96
/// （390 宽手机 ≈ 84），宽网格 = 列宽 × 0.675 夹在 104…140（桌面 ≈ 118）。
double homeWidgetRowExtent(HomeGridKind grid, double width, double gap) {
  final int columns = grid.columns;
  final double column = math.max(0, (width - gap * (columns - 1)) / columns);
  return switch (grid) {
    HomeGridKind.compact => (column * 0.48).clamp(76.0, 96.0),
    HomeGridKind.wide => (column * 0.675).clamp(104.0, 140.0),
  };
}

// ── 装箱 ────────────────────────────────────────────────────────────────

/// 装箱后一项的位置（列 / 行都从 0 起；列是逻辑起始侧起算，RTL 由渲染镜像）。
@immutable
class HomeWidgetPlacement {
  const HomeWidgetPlacement({
    required this.index,
    required this.item,
    required this.col,
    required this.row,
    required this.cols,
  });

  /// 在被装箱列表里的下标。
  final int index;
  final HomeWidgetItem item;
  final int col;
  final int row;

  /// 实际占的列数（宽于网格的项被钳到网格列数）。
  final int cols;

  int get rows => item.size.rows;

  @override
  String toString() => '${item.kind.id}@($col,$row)';
}

/// 装箱结果：每项的位置 + 总行数。
@immutable
class HomeWidgetPacking {
  const HomeWidgetPacking(this.placements, this.rowCount);

  final List<HomeWidgetPlacement> placements;
  final int rowCount;
}

/// 密集装箱：按列表顺序逐个放到第一个能放下的位置（自上而下、每行自起始侧到
/// 结束侧）。不存绝对坐标，所以增删 / 换尺寸后自动补位，不会重叠或悬空。
HomeWidgetPacking packHomeWidgets(List<HomeWidgetItem> items, int columns) {
  final List<List<bool>> occupied = <List<bool>>[];
  bool free(int row, int col, int cols, int rows) {
    for (int r = row; r < row + rows; r++) {
      if (r >= occupied.length) continue;
      for (int c = col; c < col + cols; c++) {
        if (occupied[r][c]) return false;
      }
    }
    return true;
  }

  void mark(int row, int col, int cols, int rows) {
    while (occupied.length < row + rows) {
      occupied.add(List<bool>.filled(columns, false));
    }
    for (int r = row; r < row + rows; r++) {
      for (int c = col; c < col + cols; c++) {
        occupied[r][c] = true;
      }
    }
  }

  final List<HomeWidgetPlacement> placements = <HomeWidgetPlacement>[];
  for (int i = 0; i < items.length; i++) {
    final HomeWidgetItem item = items[i];
    final int cols = item.size.cols.clamp(1, columns);
    final int rows = math.max(1, item.size.rows);
    int row = 0;
    int? col;
    while (col == null) {
      for (int c = 0; c + cols <= columns; c++) {
        if (free(row, c, cols, rows)) {
          col = c;
          break;
        }
      }
      if (col == null) row++;
    }
    mark(row, col, cols, rows);
    placements.add(
      HomeWidgetPlacement(index: i, item: item, col: col, row: row, cols: cols),
    );
  }
  return HomeWidgetPacking(placements, occupied.length);
}

/// 默认布局补洞（用户 2026-11-17：默认布局要填满，自定义过的完全尊重自定义）：
/// 装箱后留下的空格由相邻组件扩展补上，返回每项的「渲染尺寸」。只给**没编辑过**
/// 的那份网格用；结果不落盘（首次编辑以它为起点）。
///
/// 对每个空格（自上而下、自起始侧到结束侧）依次试：
/// 1. 正上方的组件列范围恰好落在这一行的空段里 → 它向下长一行；
/// 2. 否则同一行紧挨在起始侧的组件、整段高度那一列都空 → 它朝结束侧拉宽一列。
///
/// 每次扩展都受 [HomeWidgetKind.maxFor] 约束，并且要求按新尺寸重新装箱后**所有
/// 组件的位置不变、总行数不增**（装箱按顺序找空位，长高 / 拉宽可能把后面的组件
/// 挤走——那种扩展不做）。补不上的空格留空。
List<HomeWidgetItem> fillHomeWidgetGaps(
  List<HomeWidgetItem> items,
  HomeGridKind grid,
) {
  final int columns = grid.columns;
  List<HomeWidgetItem> current = <HomeWidgetItem>[
    for (final HomeWidgetItem item in items)
      item.withSize(
        HomeWidgetSize(item.size.cols.clamp(1, columns), item.size.rows),
      ),
  ];
  final Set<int> unfillable = <int>{};
  while (true) {
    final HomeWidgetPacking packing = packHomeWidgets(current, columns);
    final List<List<int>> owner = <List<int>>[
      for (int r = 0; r < packing.rowCount; r++) List<int>.filled(columns, -1),
    ];
    for (final HomeWidgetPlacement p in packing.placements) {
      for (int r = p.row; r < p.row + p.rows; r++) {
        for (int c = p.col; c < p.col + p.cols; c++) {
          owner[r][c] = p.index;
        }
      }
    }
    int? holeRow;
    int? holeCol;
    for (int r = 0; r < packing.rowCount && holeRow == null; r++) {
      for (int c = 0; c < columns; c++) {
        if (owner[r][c] == -1 && !unfillable.contains(r * columns + c)) {
          holeRow = r;
          holeCol = c;
          break;
        }
      }
    }
    if (holeRow == null || holeCol == null) return current;
    final int r = holeRow;
    final int c = holeCol;

    bool accept(int index, HomeWidgetSize size) {
      final HomeWidgetItem item = current[index];
      final HomeWidgetSize max = item.kind.maxFor(grid);
      if (size.cols > max.cols || size.rows > max.rows) return false;
      final List<HomeWidgetItem> next = <HomeWidgetItem>[...current]
        ..[index] = item.withSize(size);
      final HomeWidgetPacking repacked = packHomeWidgets(next, columns);
      if (repacked.rowCount > packing.rowCount) return false;
      for (int i = 0; i < next.length; i++) {
        final HomeWidgetPlacement a = packing.placements[i];
        final HomeWidgetPlacement b = repacked.placements[i];
        if (a.col != b.col || a.row != b.row) return false;
      }
      current = next;
      return true;
    }

    bool grown = false;
    // 1. 正上方的组件向下长一行：它整段列宽在第 r 行都得是空的。
    if (r > 0 && owner[r - 1][c] != -1) {
      final HomeWidgetPlacement above = packing.placements[owner[r - 1][c]];
      bool rowFree = above.row + above.rows == r;
      for (int k = above.col; rowFree && k < above.col + above.cols; k++) {
        if (owner[r][k] != -1) rowFree = false;
      }
      if (rowFree) {
        grown = accept(
          above.index,
          HomeWidgetSize(above.cols, above.item.size.rows + 1),
        );
      }
    }
    // 2. 同一行起始侧紧挨的组件朝结束侧拉宽一列：它整段高度在第 c 列都得是空的。
    if (!grown && c > 0 && owner[r][c - 1] != -1) {
      final HomeWidgetPlacement left = packing.placements[owner[r][c - 1]];
      bool colFree = left.col + left.cols == c;
      for (int k = left.row; colFree && k < left.row + left.rows; k++) {
        if (owner[k][c] != -1) colFree = false;
      }
      if (colFree) {
        grown = accept(
          left.index,
          HomeWidgetSize(left.cols + 1, left.item.size.rows),
        );
      }
    }
    if (!grown) unfillable.add(r * columns + c);
  }
}

// ── 编辑操作（全部返回新列表，不改入参） ─────────────────────────────────

/// 追加到末尾（装箱后落到第一个能放下的空位）；同一 slot（不可重复的组件 = 同一种，
/// 「语言目标」= 同一种语言）已在列表里则原样返回。
List<HomeWidgetItem> addHomeWidget(
  List<HomeWidgetItem> items,
  HomeWidgetItem item,
) {
  if (items.any((HomeWidgetItem e) => e.slot == item.slot)) return items;
  return <HomeWidgetItem>[...items, item];
}

/// 新加一块「语言目标」格时默认用的语言：[candidates] 里第一种还没有格子的
/// （[taken] 是布局里已有的 slot）；都有了返回 null（调用方让用户挑）。
String? homeLanguageGoalsDefaultLanguage({
  required List<String> candidates,
  required Set<String> taken,
}) {
  for (final String language in candidates) {
    final String slot = homeWidgetSlot(
      HomeWidgetKind.languageGoals,
      language: language,
    );
    if (!taken.contains(slot)) return language;
  }
  return null;
}

/// 把第 [index] 项（可配置的组件）的语言换成 [language]；换成的 slot 已被别的块
/// 占着、组件不可配置或没变时原样返回。
List<HomeWidgetItem> setHomeWidgetLanguage(
  List<HomeWidgetItem> items,
  int index,
  String? language,
) {
  if (index < 0 || index >= items.length) return items;
  final HomeWidgetItem item = items[index];
  if (!item.kind.repeatable) return items;
  final HomeWidgetItem next = item.withLanguage(language);
  if (next == item || items.any((HomeWidgetItem e) => e.slot == next.slot)) {
    return items;
  }
  return <HomeWidgetItem>[...items]..[index] = next;
}

/// 移除第 [index] 项。
List<HomeWidgetItem> removeHomeWidgetAt(List<HomeWidgetItem> items, int index) {
  if (index < 0 || index >= items.length) return items;
  return <HomeWidgetItem>[...items]..removeAt(index);
}

/// 把第 [from] 项挪到第 [to] 位（挪完后它的下标就是 [to]）。
List<HomeWidgetItem> moveHomeWidget(
  List<HomeWidgetItem> items,
  int from,
  int to,
) {
  if (from < 0 || from >= items.length) return items;
  final int target = to.clamp(0, items.length - 1);
  if (target == from) return items;
  final List<HomeWidgetItem> out = <HomeWidgetItem>[...items];
  final HomeWidgetItem moved = out.removeAt(from);
  out.insert(target, moved);
  return out;
}

/// 把第 [index] 项设成 [size]（钳进 [grid] 的可调范围）；尺寸没变时原样返回。
List<HomeWidgetItem> setHomeWidgetSize(
  List<HomeWidgetItem> items,
  int index,
  HomeGridKind grid,
  HomeWidgetSize size,
) {
  if (index < 0 || index >= items.length) return items;
  final HomeWidgetItem item = items[index];
  final HomeWidgetSize next = clampHomeWidgetSize(item.kind, grid, size);
  if (next == item.size) return items;
  return <HomeWidgetItem>[...items]..[index] = item.withSize(next);
}

/// 键盘 / 手柄逐格改尺寸：第 [index] 项宽加 [dCols]、高加 [dRows]（钳进范围；
/// 当前尺寸不在范围内时先钳再加）。
List<HomeWidgetItem> resizeHomeWidgetBy(
  List<HomeWidgetItem> items,
  int index,
  HomeGridKind grid, {
  int dCols = 0,
  int dRows = 0,
}) {
  if (index < 0 || index >= items.length) return items;
  final HomeWidgetItem item = items[index];
  final HomeWidgetSize from = clampHomeWidgetSize(item.kind, grid, item.size);
  return setHomeWidgetSize(
    items,
    index,
    grid,
    HomeWidgetSize(from.cols + dCols, from.rows + dRows),
  );
}

/// 键盘 / 手柄「上 / 下」移动：装箱后跳到上一行 / 下一行里离当前组件水平中心最近
/// 的那块的位置（返回挪去的列表下标）。没有上一行 → 原位；没有下一行 → 末尾。
///
/// [up] = true 为上移。列表下标与 [packHomeWidgets] 的输入一致。
int homeWidgetVerticalTarget(
  List<HomeWidgetItem> items,
  int index,
  int columns, {
  required bool up,
}) {
  if (index < 0 || index >= items.length) return index;
  final HomeWidgetPacking packing = packHomeWidgets(items, columns);
  final HomeWidgetPlacement me = packing.placements[index];
  final int band = up ? me.row - 1 : me.row + me.rows;
  if (band < 0) return index;
  final double center = me.col + me.cols / 2;
  HomeWidgetPlacement? best;
  double bestDistance = double.infinity;
  for (final HomeWidgetPlacement p in packing.placements) {
    if (p.index == index) continue;
    if (band < p.row || band >= p.row + p.rows) continue;
    final double d = (p.col + p.cols / 2 - center).abs();
    if (d < bestDistance) {
      best = p;
      bestDistance = d;
    }
  }
  if (best == null) return up ? index : items.length - 1;
  return best.index;
}

/// 编辑会话：当前列表 + 操作栈（撤销用）。不可变；每次操作返回新会话。
@immutable
class HomeWidgetEditSession {
  const HomeWidgetEditSession(
    this.items, {
    this.history = const <List<HomeWidgetItem>>[],
  });

  final List<HomeWidgetItem> items;

  /// 之前的各个状态（最后一个是上一步）。
  final List<List<HomeWidgetItem>> history;

  bool get canUndo => history.isNotEmpty;

  /// 应用一次编辑；结果与当前相同（无效操作）时不进撤销栈。
  HomeWidgetEditSession apply(List<HomeWidgetItem> next) {
    if (listEquals(next, items)) return this;
    return HomeWidgetEditSession(
      next,
      history: <List<HomeWidgetItem>>[...history, items],
    );
  }

  /// 撤销上一步；没有可撤销的时原样返回。
  HomeWidgetEditSession undo() {
    if (history.isEmpty) return this;
    return HomeWidgetEditSession(
      history.last,
      history: history.sublist(0, history.length - 1),
    );
  }
}

// ── 编解码 ──────────────────────────────────────────────────────────────

/// 当前 JSON 版本。
const int kHomeWidgetLayoutVersion = 1;

/// 解出一份布局列表：非 Map 项 / 未知 kind 丢弃，尺寸钳进该组件在这份网格里的可调范围，
/// 重复 slot（[HomeWidgetItem.slot]）只留第一个。
List<HomeWidgetItem> _decodeItems(Object? raw, HomeGridKind grid) {
  final List<HomeWidgetItem> out = <HomeWidgetItem>[];
  if (raw is! List) return out;
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final HomeWidgetKind? kind = HomeWidgetKind.fromId(entry['k']);
    if (kind == null) continue;
    final Object? l = entry['l'];
    final String? language = kind.repeatable && l is String
        ? _layoutLanguage(l, scriptExact: entry['lx'] == true)
        : null;
    final Object? g = entry['goals'];
    final List<String> goals = kind.repeatable && g is List
        ? <String>[
            for (final Object? id in g)
              if (id is String && id.isNotEmpty) id,
          ].take(kHomeLanguageGoalsMaxGoals).toList()
        : const <String>[];
    final String slot = homeWidgetSlot(kind, language: language);
    if (out.any((HomeWidgetItem e) => e.slot == slot)) continue;
    final Object? c = entry['c'];
    final Object? r = entry['r'];
    final HomeWidgetSize size = clampHomeWidgetSize(
      kind,
      grid,
      HomeWidgetSize(c is int ? c : 0, r is int ? r : 0),
    );
    out.add(HomeWidgetItem(kind, size, language: language, goals: goals));
  }
  return out;
}

/// 「语言目标」格至多显示几条目标。
const int kHomeLanguageGoalsMaxGoals = 3;

/// 存盘的格子语言：没有 `lx` 标记的带文字写法（`zh-Hans`）是只按主语言匹配时期存的，
/// 当时也算繁体 → 整门语言（`zh`）。与目标记录同一规则（`study_goal_record.dart`）。
String _layoutLanguage(String tag, {required bool scriptExact}) {
  if (scriptExact) return tag;
  final StudyGoalLanguage? language = resolveStudyGoalLanguage(tag);
  return language?.script == null ? tag : language!.combined.tag;
}

/// 解出偏好 `home_widget_layout`。空串 / 坏 JSON / 非对象 → 两份都为 null（走迁移）；
/// 某份字段缺失或不是数组 → 那份为 null。
HomeWidgetLayout decodeHomeWidgetLayout(String json) {
  if (json.isEmpty) return const HomeWidgetLayout();
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const HomeWidgetLayout();
  }
  if (decoded is! Map) return const HomeWidgetLayout();
  final Map<Object?, Object?> map = decoded;
  List<HomeWidgetItem>? read(HomeGridKind grid) {
    final Object? raw = map[grid.wire];
    if (raw is! List) return null;
    return _decodeItems(raw, grid);
  }

  return HomeWidgetLayout(
    compact: read(HomeGridKind.compact),
    wide: read(HomeGridKind.wide),
  );
}

/// 编码布局；null 的那份不写（保持「没编辑过」）。两份都为 null 时返回空串。
String encodeHomeWidgetLayout(HomeWidgetLayout layout) {
  List<Map<String, Object>> items(
    List<HomeWidgetItem> list,
  ) => <Map<String, Object>>[
    for (final HomeWidgetItem e in list)
      <String, Object>{
        'k': e.kind.id,
        'c': e.size.cols,
        'r': e.size.rows,
        'l': ?e.language,
        if (resolveStudyGoalLanguage(e.language)?.script != null) 'lx': true,
        if (e.goals.isNotEmpty) 'goals': e.goals,
      },
  ];
  final List<HomeWidgetItem>? compact = layout.compact;
  final List<HomeWidgetItem>? wide = layout.wide;
  if (compact == null && wide == null) return '';
  return jsonEncode(<String, Object>{
    'v': kHomeWidgetLayoutVersion,
    'compact': ?(compact == null ? null : items(compact)),
    'wide': ?(wide == null ? null : items(wide)),
  });
}

// ── 迁移 / 默认模板 ─────────────────────────────────────────────────────

/// 旧可选面板「自动」档在迁移那一刻的判据结果（各面板自己的默认判据，见
/// `home_srs_panel.dart` / `home_tracking_panel.dart` / `home_ai_agent_panel.dart` /
/// `home_panorama_panel.dart`）。
@immutable
class HomeWidgetAutoFacts {
  const HomeWidgetAutoFacts({
    this.srsReview = false,
    this.tracking = false,
    this.aiAgent = false,
    this.panorama = false,
  });

  final bool srsReview;
  final bool tracking;
  final bool aiAgent;
  final bool panorama;
}

/// 用户从没编辑过 [grid] 那份布局时的首个布局：默认模板里，旧偏好钉成 hidden 的
/// 可选面板不放、钉成 shown 的放上，auto 的按 [auto]（迁移那一刻的默认判据）决定。
/// 「恢复默认」也走这里。
///
/// - 窄：继续 2×2；半栏组件今日 / 近 7 天 / 复习 / 追踪 / AI 各 1×1 两两并排（个数为奇数
///   时最后一个放宽成 2×1，不留半格空洞，见 [_pairHalves]）；全景 2×2。
/// - 宽：继续 4×2、今日 2×1、复习 1×1、AI 1×1、近 7 天 2×2、最近添加 4×2、
///   追踪 2×1、全景 2×2。
List<HomeWidgetItem> migrateHomeWidgetLayout({
  required HomeGridKind grid,
  required Map<HomeDashboardPanel, HomeDashboardPanelMode> modes,
  required HomeWidgetAutoFacts auto,
}) {
  bool place(HomeDashboardPanel panel, bool autoValue) =>
      switch (modes[panel] ?? HomeDashboardPanelMode.auto) {
        HomeDashboardPanelMode.shown => true,
        HomeDashboardPanelMode.hidden => false,
        HomeDashboardPanelMode.auto => autoValue,
      };
  final bool srs = place(HomeDashboardPanel.srsReview, auto.srsReview);
  final bool tracking = place(HomeDashboardPanel.tracking, auto.tracking);
  final bool ai = place(HomeDashboardPanel.aiAgent, auto.aiAgent);
  final bool panorama = place(HomeDashboardPanel.panorama, auto.panorama);
  return switch (grid) {
    HomeGridKind.compact => <HomeWidgetItem>[
      const HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(2, 2)),
      ..._pairHalves(<HomeWidgetKind>[
        HomeWidgetKind.today,
        HomeWidgetKind.week,
        if (srs) HomeWidgetKind.srsReview,
        if (tracking) HomeWidgetKind.tracking,
        if (ai) HomeWidgetKind.aiAgent,
      ]),
      if (panorama)
        const HomeWidgetItem(HomeWidgetKind.panorama, HomeWidgetSize(2, 2)),
    ],
    HomeGridKind.wide => <HomeWidgetItem>[
      const HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(4, 2)),
      const HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
      if (srs)
        const HomeWidgetItem(HomeWidgetKind.srsReview, HomeWidgetSize(1, 1)),
      if (ai)
        const HomeWidgetItem(HomeWidgetKind.aiAgent, HomeWidgetSize(1, 1)),
      const HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 2)),
      const HomeWidgetItem(HomeWidgetKind.recentlyAdded, HomeWidgetSize(4, 2)),
      if (tracking)
        const HomeWidgetItem(HomeWidgetKind.tracking, HomeWidgetSize(2, 1)),
      if (panorama)
        const HomeWidgetItem(HomeWidgetKind.panorama, HomeWidgetSize(2, 2)),
    ],
  };
}

/// 窄网格默认模板里的半栏组件：按顺序两两并排（各 1×1）；个数为奇数时最后一个
/// 放宽成 2×1 占满那一行，后面的整行组件不会在它旁边留下半格空洞。
List<HomeWidgetItem> _pairHalves(List<HomeWidgetKind> kinds) =>
    <HomeWidgetItem>[
      for (int i = 0; i < kinds.length; i++)
        HomeWidgetItem(
          kinds[i],
          kinds.length.isOdd && i == kinds.length - 1
              ? const HomeWidgetSize(2, 1)
              : const HomeWidgetSize(1, 1),
        ),
    ];
