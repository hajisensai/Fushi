/// 整页/整卷 OCR 的文档契约：后台逐页完成时只热替换该页透明文字层，不重建
/// WebView 文档（重建会打断阅读、丢焦点、抹掉滚动位置）。
///
/// 历史注记：阅读器内的 OCR 入口（整卷按钮 / 点击即识别 / 框选重识别）已于
/// 2026-09-12 按产品决策整体移除，OCR 只在阅读器外触发；本文件守的是保留面——
/// 外部任务逐页完成时阅读器的热替换契约（`__mangaReplaceOcr` / `.ocr-box`）。
library;


import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

void main() {
  test('阅读器文档暴露逐页热替换 OCR 层的入口，且按 data-page 定位', () {
    final String document = mangaWindowDocument(
      <MokuroImage>[
        const MokuroImage(
          url: 'page.jpg',
          size: MokuroSize(1000, 1600),
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
