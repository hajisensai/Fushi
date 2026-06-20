import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 守卫：两处构造 ReaderHibikiPage 的地方都必须用 HibikiAppUiScaleNeutralizer 包裹，
/// 否则全局界面缩放会把阅读器 WebView 正文/弹窗光栅放大致糊（统一走字号方案）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('reader_hibiki_source wraps ReaderHibikiPage with neutralizer', () {
    final String src = read('lib/src/media/sources/reader_hibiki_source.dart');
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: 'reader_hibiki_source.dart 必须用中和器包裹 ReaderHibikiPage');
  });

  test('history page wraps pushed ReaderHibikiPage with neutralizer', () {
    final String src = readReaderHistorySource();
    expect(src.contains('HibikiAppUiScaleNeutralizer'), isTrue,
        reason: '书架 push 阅读器路由必须用中和器包裹 ReaderHibikiPage');
  });
}
