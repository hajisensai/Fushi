/// 首页小组件网格（spec `docs/specs/2026-11-15-home-widgets-design.md`）的纯数据层：
/// 组件目录（[HomeWidgetKind]，持久化 id 冻结）、尺寸档、两份布局（[HomeGridKind]
/// 窄 2 列 / 宽 6 列）、密集装箱、编辑操作（增删 / 移动 / 换尺寸 / 撤销）、编解码与
/// 从旧偏好 `home_dashboard_panels` 的迁移。
///
/// 全部是纯函数：不碰 Flutter、不读偏好，页面与测试都只经这里算布局。
///
/// 持久化：偏好 `home_widget_layout` 存
/// `{"v":1,"compact":[{"k":"today","c":1,"r":1},...],"wide":[...]}`。键缺失或某份
/// 布局缺失 = 用户没编辑过那份布局，渲染时由 [migrateHomeWidgetLayout] 现算（不落盘，
/// 免得同步把迁移态带到别的设备覆盖）。kind id 与 JSON 字段冻结不追改。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable, listEquals;

import 'package:fushi/src/models/home_dashboard_panel.dart';

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

  /// 「2×1」：添加面板的尺寸档缩略标签（不随语言变）。
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

/// 小组件目录。顺序 = 添加面板的展示顺序。
enum HomeWidgetKind {
  /// 「继续」主角：最近一条放大，大档再挂其余条目的横滑行。
  continueHero('continue', HomeWidgetCategory.continueMedia, <HomeWidgetSize>[
    HomeWidgetSize(2, 2),
    HomeWidgetSize(2, 3),
    HomeWidgetSize(4, 2),
  ]),

  /// 「继续阅读」：同一份继续条目里的书 / 漫画 / 字幕书 / 有声书。
  continueReading(
    'continue_reading',
    HomeWidgetCategory.continueMedia,
    <HomeWidgetSize>[HomeWidgetSize(2, 1), HomeWidgetSize(2, 2)],
  ),

  /// 「继续观看」：继续条目里的视频（本地 / 远端 / 媒体服务器）。
  continueWatching(
    'continue_watching',
    HomeWidgetCategory.continueMedia,
    <HomeWidgetSize>[HomeWidgetSize(2, 1), HomeWidgetSize(2, 2)],
  ),

  /// 「继续游玩」：继续条目里的游戏。
  continuePlaying(
    'continue_playing',
    HomeWidgetCategory.continueMedia,
    <HomeWidgetSize>[HomeWidgetSize(2, 1), HomeWidgetSize(2, 2)],
  ),

  /// 「今日」：目标环 + 今日字数 + 时长。
  today('today', HomeWidgetCategory.study, <HomeWidgetSize>[
    HomeWidgetSize(1, 1),
    HomeWidgetSize(2, 1),
  ]),

  /// 「近 7 天」柱条。
  week('week', HomeWidgetCategory.study, <HomeWidgetSize>[
    HomeWidgetSize(2, 1),
    HomeWidgetSize(2, 2),
  ]),

  /// 复习（内置 SRS）。
  srsReview('srs_review', HomeWidgetCategory.study, <HomeWidgetSize>[
    HomeWidgetSize(1, 1),
    HomeWidgetSize(2, 1),
  ]),

  /// 最近添加。
  recentlyAdded(
    'recently_added',
    HomeWidgetCategory.continueMedia,
    <HomeWidgetSize>[HomeWidgetSize(2, 2), HomeWidgetSize(4, 2)],
  ),

  /// 媒体追踪同步状态。
  tracking('tracking', HomeWidgetCategory.tools, <HomeWidgetSize>[
    HomeWidgetSize(2, 1),
  ]),

  /// AI 助手入口。
  aiAgent('ai_agent', HomeWidgetCategory.tools, <HomeWidgetSize>[
    HomeWidgetSize(1, 1),
    HomeWidgetSize(2, 1),
  ]),

  /// 媒体库全景入口（不常驻渲染 3D）。
  panorama('panorama', HomeWidgetCategory.tools, <HomeWidgetSize>[
    HomeWidgetSize(2, 2),
    HomeWidgetSize(4, 2),
  ]);

  const HomeWidgetKind(this.id, this.category, this.sizes);

  /// 持久化 id（冻结）。
  final String id;
  final HomeWidgetCategory category;

  /// 全部尺寸档（宽网格可选的全集）。
  final List<HomeWidgetSize> sizes;

  /// [grid] 里可选的尺寸档：宽度超过列数的档不出现（窄网格里没有 4×2）。
  List<HomeWidgetSize> sizesFor(HomeGridKind grid) => <HomeWidgetSize>[
    for (final HomeWidgetSize s in sizes)
      if (s.cols <= grid.columns) s,
  ];

  static HomeWidgetKind? fromId(Object? id) {
    for (final HomeWidgetKind k in HomeWidgetKind.values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// 布局里的一项：哪种组件、占多大。
@immutable
class HomeWidgetItem {
  const HomeWidgetItem(this.kind, this.size);

  final HomeWidgetKind kind;
  final HomeWidgetSize size;

  HomeWidgetItem withSize(HomeWidgetSize size) => HomeWidgetItem(kind, size);

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetItem && other.kind == kind && other.size == size;

  @override
  int get hashCode => Object.hash(kind, size);

  @override
  String toString() => '${kind.id} $size';
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
/// 布局里保留，条件恢复（模块重新打开、配好 AI 提供商）就回来。三个按类型的继续
/// 组件跟对应媒体模块走；复习跟复习模块；追踪跟媒体追踪模块；AI 跟「模块开着且
/// 指派了提供商」。其余组件始终可用（有就显示、没有就收成一行）。
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
  HomeWidgetKind.panorama => true,
};

// ── 尺寸 ────────────────────────────────────────────────────────────────

/// [grid] 里离 [size] 最近的合法档（|Δ列| + |Δ行| 最小，平局取目录里靠前的）。
HomeWidgetSize nearestHomeWidgetSize(
  HomeWidgetKind kind,
  HomeGridKind grid,
  HomeWidgetSize size,
) {
  final List<HomeWidgetSize> allowed = kind.sizesFor(grid);
  HomeWidgetSize best = allowed.first;
  int bestDistance = 1 << 30;
  for (final HomeWidgetSize s in allowed) {
    final int d = (s.cols - size.cols).abs() + (s.rows - size.rows).abs();
    if (d < bestDistance) {
      best = s;
      bestDistance = d;
    }
  }
  return best;
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

// ── 编辑操作（全部返回新列表，不改入参） ─────────────────────────────────

/// 追加到末尾（装箱后落到第一个能放下的空位）；同一种组件已在列表里则原样返回。
List<HomeWidgetItem> addHomeWidget(
  List<HomeWidgetItem> items,
  HomeWidgetItem item,
) {
  if (items.any((HomeWidgetItem e) => e.kind == item.kind)) return items;
  return <HomeWidgetItem>[...items, item];
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

/// 第 [index] 项在 [grid] 可选档里循环切到下一档（[step] = -1 时上一档）；只有
/// 一档时原样返回。当前尺寸不在可选档里时从最近的合法档起算。
List<HomeWidgetItem> cycleHomeWidgetSize(
  List<HomeWidgetItem> items,
  int index,
  HomeGridKind grid, {
  int step = 1,
}) {
  if (index < 0 || index >= items.length) return items;
  final HomeWidgetItem item = items[index];
  final List<HomeWidgetSize> allowed = item.kind.sizesFor(grid);
  if (allowed.length < 2) return items;
  final int current = allowed.indexOf(
    nearestHomeWidgetSize(item.kind, grid, item.size),
  );
  final int next = (current + step) % allowed.length;
  final HomeWidgetSize size = allowed[next < 0 ? next + allowed.length : next];
  return <HomeWidgetItem>[...items]..[index] = item.withSize(size);
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

/// 解出一份布局列表：非 Map 项 / 未知 kind 丢弃，不支持的尺寸钳到最近的合法档，
/// 重复 kind 只留第一个。
List<HomeWidgetItem> _decodeItems(Object? raw, HomeGridKind grid) {
  final List<HomeWidgetItem> out = <HomeWidgetItem>[];
  if (raw is! List) return out;
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final HomeWidgetKind? kind = HomeWidgetKind.fromId(entry['k']);
    if (kind == null) continue;
    if (out.any((HomeWidgetItem e) => e.kind == kind)) continue;
    final Object? c = entry['c'];
    final Object? r = entry['r'];
    final HomeWidgetSize size = nearestHomeWidgetSize(
      kind,
      grid,
      HomeWidgetSize(c is int ? c : 0, r is int ? r : 0),
    );
    out.add(HomeWidgetItem(kind, size));
  }
  return out;
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
  List<Map<String, Object>> items(List<HomeWidgetItem> list) =>
      <Map<String, Object>>[
        for (final HomeWidgetItem e in list)
          <String, Object>{'k': e.kind.id, 'c': e.size.cols, 'r': e.size.rows},
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
/// - 窄：继续 2×2、今日 1×1、复习 1×1、近 7 天 2×1、追踪 2×1、AI 1×1、全景 2×2；
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
      const HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(1, 1)),
      if (srs)
        const HomeWidgetItem(HomeWidgetKind.srsReview, HomeWidgetSize(1, 1)),
      const HomeWidgetItem(HomeWidgetKind.week, HomeWidgetSize(2, 1)),
      if (tracking)
        const HomeWidgetItem(HomeWidgetKind.tracking, HomeWidgetSize(2, 1)),
      if (ai)
        const HomeWidgetItem(HomeWidgetKind.aiAgent, HomeWidgetSize(1, 1)),
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
