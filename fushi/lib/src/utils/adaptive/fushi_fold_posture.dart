import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';

/// 折叠屏姿态（对齐 Android「Make your app fold aware」指南的三种形态）。
///
/// - [flat]：没有折痕 / 铰链，或屏幕完全展开且折痕不遮挡内容——按普通屏幕排版。
/// - [book]：**竖向**折痕把屏幕分成左右两半（书本姿态，半开；或带物理铰链的双屏
///   设备）。阅读器按两页排、折痕落在两页之间。
/// - [tabletop]：**横向**折痕把屏幕分成上下两半（桌面姿态，半开平放）。播放器把
///   画面放上半屏、控件放下半屏。
enum FushiFoldPosture { flat, book, tabletop }

/// 当前窗口的折叠状态：姿态 + 折痕矩形。
///
/// **坐标空间**：[hinge] 与读取处 [MediaQuery] 的 `size` 同一坐标空间——界面缩放层
/// （[FushiAppUiScale] / [FushiAppUiScaleNeutralizer]）换算 MediaQuery 时连
/// `displayFeatures` 一起等比换算，所以在任意缩放层下 [hinge] 都能直接与
/// `MediaQuery.sizeOf(context)` 及其推出的宽度 / 中线比较。要落到某个 RenderBox 的
/// 本地坐标（区域不铺满窗口、上方有标题栏等）用 [fushiFoldRectToLocal]。
@immutable
class FushiFoldState {
  const FushiFoldState({required this.posture, this.hinge});

  static const FushiFoldState flat = FushiFoldState(
    posture: FushiFoldPosture.flat,
  );

  final FushiFoldPosture posture;

  /// 折痕矩形（MediaQuery 坐标空间的逻辑像素，见类注释）。普通折叠屏的折痕宽度为 0（一条线），带物理
  /// 铰链的双屏设备有实际宽度；[posture] 为 [FushiFoldPosture.flat] 时为 null。
  final Rect? hinge;

  bool get isBook => posture == FushiFoldPosture.book;
  bool get isTabletop => posture == FushiFoldPosture.tabletop;

  /// 读取 [context] 所在 MediaQuery 的折叠状态。只依赖 `displayFeatures` 与尺寸，
  /// 姿态变化时 MediaQuery 通知依赖方重建。
  static FushiFoldState of(BuildContext context) => resolveFushiFoldState(
    displayFeatures: MediaQuery.displayFeaturesOf(context),
    windowSize: MediaQuery.sizeOf(context),
  );

  @override
  bool operator ==(Object other) =>
      other is FushiFoldState &&
      other.posture == posture &&
      other.hinge == hinge;

  @override
  int get hashCode => Object.hash(posture, hinge);

  @override
  String toString() => 'FushiFoldState($posture, $hinge)';
}

/// 由窗口的 [displayFeatures] 推出折叠状态（纯函数，单测直接喂 [DisplayFeature]）。
///
/// 判据与 Jetpack WindowManager `FoldingFeature.isSeparating` 同义：
/// - 物理铰链（[DisplayFeatureType.hinge]）恒分隔内容；
/// - 柔性折痕（[DisplayFeatureType.fold]）只在半开（[DisplayFeatureState.postureHalfOpened]）
///   时分隔——完全展开的大屏折痕不遮挡，按普通平板排版，不强行双页；
/// - 挖孔（cutout）与本功能无关，忽略。
///
/// 折痕必须**横贯整个窗口**才算把窗口分成两半（分屏 / 自由窗口只盖住折痕一部分时
/// Android 不会上报，这里再按窗口边界复核一次，防止把只碰到窗口一角的折痕当分隔）。
/// 竖向折痕 → [FushiFoldPosture.book]，横向折痕 → [FushiFoldPosture.tabletop]。
FushiFoldState resolveFushiFoldState({
  required List<DisplayFeature> displayFeatures,
  required Size windowSize,
}) {
  if (windowSize.isEmpty) return FushiFoldState.flat;
  for (final DisplayFeature feature in displayFeatures) {
    final bool separating = switch (feature.type) {
      DisplayFeatureType.hinge => true,
      DisplayFeatureType.fold =>
        feature.state == DisplayFeatureState.postureHalfOpened,
      _ => false,
    };
    if (!separating) continue;
    final Rect bounds = feature.bounds;
    // 按条带长边判方向：宽 < 高 = 竖向折痕，否则按横向处理。
    final bool vertical = bounds.width < bounds.height;
    const double slack = 1;
    if (vertical) {
      final bool spans =
          bounds.top <= slack && bounds.bottom >= windowSize.height - slack;
      final bool inside = bounds.left > 0 && bounds.right < windowSize.width;
      if (spans && inside) {
        return FushiFoldState(posture: FushiFoldPosture.book, hinge: bounds);
      }
    } else {
      final bool spans =
          bounds.left <= slack && bounds.right >= windowSize.width - slack;
      final bool inside = bounds.top > 0 && bounds.bottom < windowSize.height;
      if (spans && inside) {
        return FushiFoldState(
          posture: FushiFoldPosture.tabletop,
          hinge: bounds,
        );
      }
    }
  }
  return FushiFoldState.flat;
}

/// 书本姿态下，左右两页之间至少要留多宽的缝（逻辑像素），内容才不会落在折痕 /
/// 铰链下面——对齐指南「内容放在铰链两侧、不放在铰链下」（`occlusionType == FULL`
/// 的物理铰链会真的遮住像素）。
///
/// 两页之间的缝以 [contentCenterX]（窗口坐标）为中线对称展开。缝要盖住整条铰链，
/// 所以 = 铰链宽 + 2 × |铰链中线 − 内容中线|：铰链不在内容正中（左右页边距不等、
/// 铰链偏心）时，缝向两边多放出偏差量。非书本姿态返回 0；宽度为 0 的柔性折痕且中线
/// 已对齐时也是 0（折痕本来就落在缝正中，不必加宽）。
double fushiHingeGutterPx({
  required FushiFoldState fold,
  required double contentCenterX,
}) {
  final Rect? hinge = fold.hinge;
  if (!fold.isBook || hinge == null) return 0;
  final double offset = (hinge.center.dx - contentCenterX).abs();
  return hinge.width + 2 * offset;
}

/// 把 [FushiFoldState.of] 给出的 MediaQuery 坐标空间矩形（如 [FushiFoldState.hinge]）
/// 换算成 [box] 的本地坐标。
///
/// 先按 [FushiAppUiScale.mediaQueryToWindowFactorOf] 还原到窗口逻辑坐标（Flutter
/// global 坐标），再经 `globalToLocal` 走 [box] 到根的完整变换链——区域偏移、界面
/// 缩放、嵌套缩放层一并算进去，调用方不必知道自己在哪个缩放层下。[context] 必须是
/// 读 [rect] 时用的那个 context（或同一 MediaQuery 下的后代）；[box] 必须已布局并挂载
/// （一般在帧后回调里调）。
Rect fushiFoldRectToLocal({
  required BuildContext context,
  required RenderBox box,
  required Rect rect,
}) {
  final double toWindow = FushiAppUiScale.mediaQueryToWindowFactorOf(context);
  final Offset topLeft = box.globalToLocal(rect.topLeft * toWindow);
  final Offset bottomRight = box.globalToLocal(rect.bottomRight * toWindow);
  return Rect.fromPoints(topLeft, bottomRight);
}
