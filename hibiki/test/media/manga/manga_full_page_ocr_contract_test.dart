/// 整页/整卷 OCR 的文档契约：后台逐页完成时只热替换该页透明文字层，不重建
/// WebView 文档（重建会打断阅读、丢焦点、抹掉滚动位置）。
///
/// 历史注记：本文件一度以「不得出现框选挂点」的反向断言存在。框选识别是用户明确
/// 要的能力，已在模块化架构上重建（挂点契约见
/// `manga_rescan_overlay_contract_test.dart`），故这里只守整页 OCR 自己的契约，
/// 不再对框选做排他断言——两条 OCR 路径共存，互不排斥。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

void main() {
  test('阅读器文档暴露逐页热替换 OCR 层的入口，且按 data-page 定位', () {
    final String document = mangaWindowDocument(
      <MokuroImage>[
        const MokuroImage(
          url: 'page.jpg',
          size: Size(1000, 1600),
          blocks: <MokuroBlock>[],
        ),
      ],
      <String>['https://manga.local/img/page.jpg'],
      mode: MangaReadingMode.spread,
      spreadDirection: 'rtl',
      inlineSelectionJs: '/* selection */',
    );

    expect(document, contains('window.__mangaReplaceOcr'));
    expect(
      document,
      contains('.manga-page[data-page="\'+pageIndex+\'"]'),
      reason: '热替换必须按整卷页码定位，按数组序会在窗口化 spread 下替换错页',
    );
    // 只移除该页的 .ocr-box，不动图片节点（重建图片 = 闪屏 + 重新解码）。
    expect(document, contains("page.querySelectorAll('.ocr-box')"));
  });
}
