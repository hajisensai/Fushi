// 阅读器插图表不在 UI isolate 上建（2026-10-15）源码守卫。
//
// `EpubBook.images` 逐章同步读文件 + html_parser 整章解析。歌词模式自动恢复时
// `_prepareLyricsIllustrations` 与插图册入口 `_openGallery` 曾在 UI isolate 上直接读它，
// 长篇书卡界面上百毫秒到秒级。现在两处都经 `_loadBookImagesOffUiIsolate` 在后台
// isolate 建好、`EpubBook.adoptImages` 回填缓存。
//
// 层级理由：两处入口在挂 WebView 的阅读器页面里，能落地的最强一层是源码扫描；
// `adoptImages` 的行为由 test/epub/epub_image_list_test.dart 跨 isolate 真跑。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test('reader never builds the illustration list on the UI isolate', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ]) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: '${f.absolute.path} not found');
      final String src = maskComments(f.readAsStringSync());
      expect(
        RegExp(r'=\s*book\.images;').hasMatch(src),
        isFalse,
        reason:
            '$path reads book.images synchronously; use '
            '_loadBookImagesOffUiIsolate',
      );
      expect(
        RegExp(r'_loadBookImagesOffUiIsolate\(\s*book,').hasMatch(src),
        isTrue,
        reason: '$path must load the illustration list off the UI isolate',
      );
    }
  });
}
