/// 「点一下没识别的对话框就地识别并查词」的 JS 契约。
///
/// Dart 侧唯一能验证的 JS 行为面。这条链有三个环节，缺一个整条路径就静默失效
/// （而且是那种「点了没反应、也没有任何报错」的失效）：
/// 1. 空白点击必须**带上落页信息**回传，否则 Dart 不知道该识别哪一页；
/// 2. payload 必须带 `hasOcr`，否则已识别页面上点气泡间隙也会被当成「缺 OCR」
///    而反复触发识别；
/// 3. 必须暴露回放入口，否则识别完成后用户还得自己再点一次——那这条路径就白做了。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

const List<MokuroImage> _pages = <MokuroImage>[
  MokuroImage(url: 'p001.jpg', size: Size(1000, 1600), blocks: <MokuroBlock>[]),
  MokuroImage(url: 'p002.jpg', size: Size(1000, 1600), blocks: <MokuroBlock>[]),
];

String _document({MangaReadingMode mode = MangaReadingMode.spread}) {
  return mangaWindowDocument(
    _pages,
    const <String>[
      'https://manga.local/img/p001.jpg',
      'https://manga.local/img/p002.jpg',
    ],
    mode: mode,
    spreadDirection: 'rtl',
    inlineSelectionJs: '/* selection */',
  );
}

void main() {
  test('空白点击带落页 payload 回传（否则 Dart 无从知道该识别哪一页）', () {
    final String document = _document();
    expect(document, contains("callHandler('onTapEmpty', JSON.stringify("));
    for (final String field in <String>['pageIndex:', 'hasOcr:']) {
      expect(document, contains(field));
    }
  });

  test('hasOcr 判据是「该页有没有 .ocr-box」，不是「这一点没命中字」', () {
    final String document = _document();
    // 已识别页面上点气泡间隙本来就该什么都不做。判据一旦写成「没命中字」，
    // 每次点空隙都会重新触发一次整页识别。
    expect(document, contains("querySelector('.ocr-box')"));
  });

  test('暴露 __mangaTapLookupAt 回放入口', () {
    final String document = _document();
    expect(document, contains('window.__mangaTapLookupAt'));
  });

  test('落页换算只有一份实现，框选与点击共用', () {
    final String document = _document();
    expect(document, contains('function _pageAt('));
    // 各写一遍的话，迟早一处在 spread/缩放下算错而另一处没错。
    expect(
      'function _pageAt('.allMatches(document).length,
      1,
      reason: '换算函数被复制成第二份就是下一个坐标 bug 的温床',
    );
  });

  test('点击翻页区仍然优先于按需识别（边缘点是翻页，不是识别）', () {
    final String document = _document();
    final int turnIndex = document.indexOf("callHandler('onMangaTurn', zone)");
    final int emptyIndex = document.indexOf("callHandler('onTapEmpty'");
    expect(turnIndex, greaterThan(0));
    expect(emptyIndex, greaterThan(0));
    expect(turnIndex, lessThan(emptyIndex),
        reason: '翻页区判定必须排在空白回传之前，否则边缘点会触发识别而不是翻页');
  });

  test('webtoon 同样带 payload（长条漫才是最需要按需识别的形态）', () {
    final String document = _document(mode: MangaReadingMode.webtoon);
    expect(document, contains("callHandler('onTapEmpty', JSON.stringify("));
    expect(document, contains('window.__mangaTapLookupAt'));
  });
}
