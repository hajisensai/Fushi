import 'package:flutter/gestures.dart' show PointerDeviceKind;

/// BUG-2770：「触摸类」指针——手指、触控笔（含笔尾橡皮擦）。查词弹窗滑关的触摸
/// 半边只认这三种；鼠标与触控板（[PointerDeviceKind.trackpad] 与 pan-zoom 事件）
/// 属于 BUG-299 防线的「鼠标半边」，照旧由 `enable_swipe_to_close` 的平台默认值门控。
bool isTouchLikePointer(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.touch ||
    kind == PointerDeviceKind.stylus ||
    kind == PointerDeviceKind.invertedStylus;

/// TODO-407/716 单一真相：查词弹窗"水平滑动关闭"的位移阈值（px）。
///
/// [sensitivity] 越高（越灵敏）阈值越小：0.6（默认）≈ 94px，1.0 → 30px，0 → 190px。
/// 被 `SwipeDismissWrapper`（弹窗顶栏可拖区）与 `base_source_page` 的全屏 barrier
/// （桌面拖正文关一层，TODO-716）共用，避免两份魔法数漂移。
double swipeDismissThreshold(double sensitivity) =>
    30 + (1.0 - sensitivity) * 160;
