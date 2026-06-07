import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 守卫：竖排查词避让的接线不被回退。
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  test('calcPopupPosition has a verticalWriting branch', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(RegExp(r'bool\s+verticalWriting').hasMatch(src), isTrue,
        reason: 'calcPopupPosition 必须有 verticalWriting 参数');
    expect(src.contains('if (verticalWriting)'), isTrue, reason: '必须保留竖排放置分支');
  });

  test('base_source_page exposes popupVerticalWriting and threads it', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    expect(src.contains('bool get popupVerticalWriting'), isTrue);
    expect(src.contains('verticalWriting: popupVerticalWriting'), isTrue,
        reason: '_calculatePopupPosition 必须把写排方向透传给 calcPopupPosition');
  });

  test('reader overrides popupVerticalWriting from writingMode', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(
        RegExp(r'popupVerticalWriting\s*=>[\s\S]{0,80}writingMode')
            .hasMatch(src),
        isTrue,
        reason: 'reader 必须用 _settings.writingMode 决定竖排避让');
    expect(src.contains('_lyricsMode'), isTrue);
    // getter 必须用 !_lyricsMode 门控，歌词模式（横排渲染）不套竖排避让
    expect(RegExp(r'popupVerticalWriting\s*=>\s*!_lyricsMode').hasMatch(src),
        isTrue,
        reason: '歌词模式恒横排，popupVerticalWriting 必须 !_lyricsMode 门控');
  });
}
