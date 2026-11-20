import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart'
    show FushiFitTitlePainter;
import 'package:material_ui/material_ui.dart';

/// 色块 / 卡片上的标题：普通卡是 [Text]；音乐专辑色块走 W 原型的唱片 / 专辑海报
/// 版式时，标题是装盒大字（[FushiFitTitlePainter] 画的，不是 [Text]）。两种都认。
Finder findCoverBlockTitle(String title) => find.byWidgetPredicate(
  (Widget w) =>
      (w is Text && w.data == title) ||
      (w is CustomPaint &&
          w.painter is FushiFitTitlePainter &&
          (w.painter! as FushiFitTitlePainter).text == title),
);
