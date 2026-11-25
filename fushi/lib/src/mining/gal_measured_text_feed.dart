// 游戏内嵌查词「实测排版路线」的中立数据面（attached surface 只认它）。
//
// 能报出「每个字画在游戏客户区哪里」的数据源实现这组接口：TyranoScript DOM 源
// （`tyrano_dom/tyrano_dom_feed.dart`）与 OCR 游戏模式（`gal_ocr_line_source.dart`，
// BUG-5299 ②）。查词扫描面（`lib/src/lookup/`）只 import 本文件，不碰任何 OCR 包
// （`gal_attached_no_ocr_guard_test`）：OCR 识别、行框换算都留在 mining 层，交过来的只有
// 「文本 + 逐字客户区矩形」。
//
// 坐标契约与 runner `attached_measured_layout.h` 相同：原点是游戏顶层窗口客户区左上角，
// 单位是物理像素（[GalMeasuredTextFrame.devicePixelRatio] 只用来推「测量尺寸 vs 真实客户区」的
// 取整容差）。

import 'dart:math' show Rectangle;

/// 一个字形：在 [GalMeasuredTextFrame.text] 里的 UTF-16 区间与客户区物理像素矩形。
abstract interface class GalMeasuredTextGlyph {
  /// 在 [GalMeasuredTextFrame.text] 里的起始下标（UTF-16）。
  int get textStart;

  /// UTF-16 长度（一般为 1，代理对为 2）。
  int get textLength;

  /// 客户区物理像素矩形。
  Rectangle<double> get rect;

  /// 画面上是否已显示（逐字显示动画里还没出墨的字为 false）。
  bool get shown;
}

/// 一帧实测排版。
abstract interface class GalMeasuredTextFrame {
  /// 画面上这一句的正文（进 texthooker 前的原文；消费端按 texthooker 同一收口归一）。
  String get text;

  /// 本句已显示完。逐字显示中的帧不给命中框（点击的本意是跳过打字）。
  bool get complete;

  /// 字形（只需覆盖能命中的字；没有框的字不可点）。
  List<GalMeasuredTextGlyph> get glyphs;

  /// 测量坐标每物理像素对应的设备像素比：DOM 源是页面 dpr，直接量物理像素的源为 1。
  double get devicePixelRatio;

  /// 测量时的客户区物理宽。
  int get clientWidth;

  /// 测量时的客户区物理高。
  int get clientHeight;
}

/// 一个已接上的实测数据源的帧广播。
///
/// 一个 feed 对应数据源的一次连接 / 一次会话；断开 / 停源时关闭并换成 null（或新 feed）。
/// 消费者按对象身份判断「数据源换了」，所以 feed 不复用。
abstract interface class GalMeasuredTextFeed {
  /// runner 白名单里的数据源身份（`attached_measured_layout.h` `IsSupportedSource`）。
  String get measuredSource;

  /// 诊断用的简短描述（不含标题 / 路径 / 台词）。
  String get diagnosticLabel;

  /// 帧广播；feed 关闭时结束。
  Stream<GalMeasuredTextFrame> get frames;

  /// 最近一帧（重发 / 刚订阅时用）。
  GalMeasuredTextFrame? get latest;

  /// feed 是否已关闭。
  bool get isClosed;
}
