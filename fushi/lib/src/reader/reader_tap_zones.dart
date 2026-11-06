/// 小说阅读器「点击翻页区域」模板（用户反馈 indZkg2A0I：微信读书式点左侧翻下一页 /
/// 静读天下式多模板）。
///
/// ## 与查词的优先级
///
/// 点到文字一律查词（`selectText` 命中词 → `onTextSelected`），模板**只**作用在
/// 「这一下没有点到文字」的点击上：选词脚本判空白后回传的 `onTapEmpty`，以及
/// 「点按查词」关闭 / 挤压态栏收起时不查词的 `onTap`。所以开了模板也不会把点词
/// 截成翻页；代价是正文排得很满时，能点到的空白主要是页边距与行间。
///
/// ## 几何
///
/// 视口按三等分切：两侧（或上下）各三分之一是翻页区，**中间三分之一永远留给原来的
/// 空白点击行为**（唤出 / 收起工具栏、清选区），否则开了模板就再也唤不出栏。
/// 坐标是 WebView 视口归一化坐标（0..1，左上原点）。
///
/// ## 三种 view mode 下的含义
///
/// 命中后一律走阅读器唯一的翻页入口 `_paginate(direction)`，方向的具体含义由当前
/// 模式决定：
/// - 翻页（paginated）：上一页 / 下一页，跨章边界与键盘翻页同一条路。
/// - 滚动（continuous）：按一屏滚动（与 PageDown / 音量键相同），到章末进下一章。
/// - 视觉小说（vn）：上一屏 / 下一屏。若同时开了 VN「点击空白前进」，空白点击由
///   VN 专用桥 `onVnBlankTap` 先接走（整片空白都是前进），模板不参与。
///
/// [ReaderTapZoneLayout.leftRight] 是**视觉方位**语义：竖排（vertical-rl，右开本）
/// 的下一页在左边，所以竖排下左右互换；其余模板是「阅读顺序」语义，不随书写方向翻转。
library;

import 'package:fushi/src/reader/reader_pagination_scripts.dart'
    show ReaderNavigationDirection;

/// 点击翻页区域模板。存字符串 [key]：重排枚举不得破坏已落盘的偏好。
enum ReaderTapZoneLayout {
  /// 关闭：空白点击只管工具栏（旧行为，默认）。
  disabled('disabled'),

  /// 左侧上一页、右侧下一页（竖排书左右互换）。
  leftRight('left_right'),

  /// 单手：左右两侧都翻到下一页（微信读书式）。
  allForward('all_forward'),

  /// 上方上一页、下方下一页。
  topBottom('top_bottom');

  const ReaderTapZoneLayout(this.key);

  /// 持久化字符串。
  final String key;

  /// 解析落盘值；未知值回落 [ReaderTapZoneLayout.disabled]。
  static ReaderTapZoneLayout fromKey(String? raw) {
    for (final ReaderTapZoneLayout value in ReaderTapZoneLayout.values) {
      if (value.key == raw) return value;
    }
    return ReaderTapZoneLayout.disabled;
  }
}

/// 翻页区占视口的比例（两侧 / 上下各三分之一，中间三分之一留给工具栏）。
const double kReaderTapZoneEdge = 1 / 3;

/// 一次未命中文字的点击按模板该往哪翻；null = 不翻页，落回原来的空白点击行为。
///
/// [x] / [y] 是 WebView 视口归一化坐标（0..1）。越界或非有限值视为未命中。
/// [rtl] 为竖排（vertical-rl）阅读，只影响 [ReaderTapZoneLayout.leftRight]。
ReaderNavigationDirection? readerTapZoneTurn(
  ReaderTapZoneLayout layout, {
  required double x,
  required double y,
  required bool rtl,
}) {
  if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
    return null;
  }
  const double e = kReaderTapZoneEdge;
  final bool leading = x < e;
  final bool trailing = x >= 2 * e;
  switch (layout) {
    case ReaderTapZoneLayout.disabled:
      return null;
    case ReaderTapZoneLayout.leftRight:
      if (!leading && !trailing) return null;
      // 竖排下一页在左边：左 = 前进。
      final bool forward = leading == rtl;
      return forward
          ? ReaderNavigationDirection.forward
          : ReaderNavigationDirection.backward;
    case ReaderTapZoneLayout.allForward:
      return leading || trailing ? ReaderNavigationDirection.forward : null;
    case ReaderTapZoneLayout.topBottom:
      if (y < e) return ReaderNavigationDirection.backward;
      if (y >= 2 * e) return ReaderNavigationDirection.forward;
      return null;
  }
}

/// 把 JS 回传的视口像素坐标归一化；任一参数缺失或视口尺寸非正时返回 null。
({double x, double y})? normalizeReaderTapPoint({
  required double? x,
  required double? y,
  required double? viewportWidth,
  required double? viewportHeight,
}) {
  if (x == null ||
      y == null ||
      viewportWidth == null ||
      viewportHeight == null) {
    return null;
  }
  if (viewportWidth <= 0 || viewportHeight <= 0) return null;
  return (x: x / viewportWidth, y: y / viewportHeight);
}
