/// 刘海 / 灵动岛（传感器外壳）此刻在屏幕哪条边——全应用共享的一份。
///
/// iOS 横屏把外壳深度**左右对称**地报进安全区（实测 iPhone 17 Pro 各 61.6），
/// Dart 自己分不出真正被挡的是哪一侧；照扣的话，没有灵动岛的那一侧也空出一大截。
/// 外壳边由原生按界面方向换算后上报（`FloatingBallChannel.sensorHousingEdge`
/// 查询 + `sensorHousingEdgeChanged` 推送），常驻的悬浮球宿主
/// （`AppFloatingBallHost`，挂在 app 外壳里，球开没开都在）负责取值并写到这里，
/// 其它贴边布局（悬浮球视口、视频字幕列表侧栏……）只读这一份。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show AxisDirection, EdgeInsets;

/// 外壳所在的边；不知道（非 iOS、尚未取到值）时 null。
final ValueNotifier<AxisDirection?> sensorHousingEdge =
    ValueNotifier<AxisDirection?>(null);

/// 只保留真正挡住画面那一侧的水平安全区：外壳在左 / 右时，对侧的水平 inset
/// 归零；不知道时保守地两侧都留（Android `shortEdges` 本就只在刘海侧上报 inset，
/// 那里外壳边恒为 null，结果与原值相同）。上下 inset 原样保留。
EdgeInsets obstructedSafeInsets(EdgeInsets padding, AxisDirection? edge) =>
    EdgeInsets.fromLTRB(
      edge == AxisDirection.right ? 0 : padding.left,
      padding.top,
      edge == AxisDirection.left ? 0 : padding.right,
      padding.bottom,
    );
