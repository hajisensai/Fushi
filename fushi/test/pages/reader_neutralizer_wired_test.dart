import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 守卫：阅读器页面的统一 launch source 必须用 FushiAppUiScaleNeutralizer 包裹；
/// 书架/历史页不得直接 push ReaderFushiPage，必须走 ReaderFushiSource -> AppModel
/// 的媒体入口，否则会绕开 source 层中和器和 currentMediaSource 注册。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('reader_fushi_source wraps ReaderFushiPage with neutralizer', () {
    final String src = read('lib/src/media/sources/reader_fushi_source.dart');
    expect(src.contains('FushiAppUiScaleNeutralizer'), isTrue,
        reason: 'reader_fushi_source.dart 必须用中和器包裹 ReaderFushiPage');
  });

  test('history page opens books through ReaderFushiSource', () {
    final String src = readReaderHistorySource();
    expect(src.contains('appModel.openMedia('), isTrue,
        reason: '书架打开阅读器必须走 AppModel.openMedia 注册媒体源');
    expect(src.contains('mediaSource: ReaderFushiSource.instance'), isTrue,
        reason: '书架入口必须走 ReaderFushiSource，由 source 层包裹中和器');
    expect(src.contains('ReaderFushiPage('), isFalse,
        reason: '书架/历史页不得直接构造 ReaderFushiPage');
  });
}
