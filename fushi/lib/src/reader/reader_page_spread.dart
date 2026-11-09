/// 小说阅读器「单双页」：设置值域与「本次排版到底是一页还是两页」的唯一判据。
///
/// 旧设置是「每页列数」0–4（CSS multicol 的 column-count），横排是左右并排 N 栏、竖排
/// 却是上下叠 N 段，同一个设置在两种排版下是两回事，3、4 栏也几乎没法读。2026-11-07
/// 改成三档：自动 / 单页 / 双页——
///
/// - 横排双页 = 一屏两栏左右并排（multicol `column-count: 2`）；
/// - 竖排双页 = 对开：一屏右页 + 左页（multicol `column-wrap`，见
///   `ReaderContentStyles.verticalSpreadCss`），不再上下分段；
/// - 「自动」：窗口有竖向折痕（折叠屏书本姿态 / 完全展开的内屏）时双页，中缝对到折痕；
///   否则横排宽屏（横向且宽 ≥ [kReaderAutoSpreadMinWindowWidth]）双页、竖排单页。
///
/// 持久化键沿用 `page_columns`（冻结不改名），值 0 = 自动、1 = 单页、≥ 2 = 双页——
/// 旧版存下的 3、4 栏读出来就是双页，不需要迁移。
library;

import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// 单双页偏好。
enum ReaderPageSpread {
  auto(0),
  single(1),
  double(2);

  const ReaderPageSpread(this.storedValue);

  /// 写进 `page_columns` 偏好的整数。
  final int storedValue;

  /// 解析 `page_columns` 的存量值：≤ 0 自动、1 单页、≥ 2 双页（旧 3、4 栏归双页）。
  static ReaderPageSpread fromStored(int value) {
    if (value <= 0) return ReaderPageSpread.auto;
    if (value == 1) return ReaderPageSpread.single;
    return ReaderPageSpread.double;
  }
}

/// 「自动」下横排排成双页的最小窗口宽（逻辑像素）：平板横屏 / 桌面窗口双页，手机横屏
/// （约 800–930）仍单页——两页各自只剩十几个字一行时双页反而难读。
const double kReaderAutoSpreadMinWindowWidth = 960;

/// 本次排版实际生效的一屏几页。
@immutable
class ReaderSpreadLayout {
  const ReaderSpreadLayout._({
    required this.columns,
    required this.verticalSpread,
  });

  /// 一屏一页。
  static const ReaderSpreadLayout single = ReaderSpreadLayout._(
    columns: 1,
    verticalSpread: false,
  );

  /// 横排双页：一屏两栏。
  static const ReaderSpreadLayout horizontalDouble = ReaderSpreadLayout._(
    columns: 2,
    verticalSpread: false,
  );

  /// 竖排对开：一屏右页 + 左页。
  static const ReaderSpreadLayout verticalDouble = ReaderSpreadLayout._(
    columns: 1,
    verticalSpread: true,
  );

  /// 横排 multicol 的列数（1 或 2）；竖排恒为 1（竖排的两页走 [verticalSpread]）。
  final int columns;

  /// 竖排对开。只在 WebView 支持 `column-wrap` 时真正排成两页（CSS 包在
  /// `@supports` 里），不支持时退回单页竖排。
  final bool verticalSpread;

  /// 是否一屏两页。
  bool get isDouble => columns == 2 || verticalSpread;

  @override
  bool operator ==(Object other) =>
      other is ReaderSpreadLayout &&
      other.columns == columns &&
      other.verticalSpread == verticalSpread;

  @override
  int get hashCode => Object.hash(columns, verticalSpread);

  @override
  String toString() =>
      'ReaderSpreadLayout(columns: $columns, verticalSpread: $verticalSpread)';
}

/// 由偏好与当前窗口推出本次排版的单双页（纯函数，判据只此一份：正文 CSS、中缝折痕、
/// 铰链缝、卷页纸面、设置页显隐都调它）。
///
/// - 只有翻页（`paginated`）有「页」：滚动 / VN 恒单页。
/// - [hasFoldSpine]：窗口有竖向折痕（`FushiFoldState.hasSpine`，书本姿态或完全展开的
///   折叠屏内屏）。
/// - [window]：阅读器所在窗口的逻辑尺寸（MediaQuery 坐标空间）。
ReaderSpreadLayout resolveReaderSpreadLayout({
  required ReaderPageSpread preference,
  required String viewMode,
  required String writingMode,
  required bool hasFoldSpine,
  required Size window,
}) {
  if (viewMode == 'vn' || viewMode == 'continuous') {
    return ReaderSpreadLayout.single;
  }
  final bool vertical = writingMode.startsWith('vertical');
  final bool double = switch (preference) {
    ReaderPageSpread.single => false,
    ReaderPageSpread.double => true,
    ReaderPageSpread.auto =>
      hasFoldSpine ||
          (!vertical &&
              window.width >= kReaderAutoSpreadMinWindowWidth &&
              window.width > window.height),
  };
  if (!double) return ReaderSpreadLayout.single;
  return vertical
      ? ReaderSpreadLayout.verticalDouble
      : ReaderSpreadLayout.horizontalDouble;
}
