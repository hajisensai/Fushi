import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-914 + BUG-913）。
///
/// BUG-914：查词/弹窗热路径此前散落着发布版也不会被剥离的裸计时探针
/// （`[dict-perf]` / `[popup-perf]` / `[video-lookup]` / `[hibiki-autoread]`
/// 的 `debugPrint` + `Stopwatch`）。这些每次查词/每帧渲染都打点，是 release
/// 噪声与微小开销。移除后用源码文本断言防回归（探针散在私有 State / FFI 热
/// 路径，无法用 widget 测试直接触达）。
///
/// BUG-913：`base_source_page.dart` 的 `_isSearchingNotifier`（ValueNotifier）
/// 创建了却没在 `dispose()` 释放，泄漏监听器。断言 dispose 已补 dispose 调用。
void main() {
  String read(String path) => File(path).readAsStringSync();

  // hibiki 包内相对路径（flutter test 以包根为 cwd）。
  const String repositoryPath = 'lib/src/models/dictionary_repository.dart';
  const String baseSourcePagePath = 'lib/src/pages/base_source_page.dart';
  const String mixinPath =
      'lib/src/pages/implementations/dictionary_page_mixin.dart';
  const String popupPagePath =
      'lib/src/pages/implementations/popup_dictionary_page.dart';
  const String lookupFavoritePath =
      'lib/src/pages/implementations/video_hibiki/lookup_favorite.part.dart';
  const String lookupAudioPath =
      'lib/src/utils/misc/lookup_audio_playback.dart';
  // 词典 FFI 引擎在同工作区的兄弟包。
  const String fushidictsPath =
      '../packages/fushi_dictionary/lib/src/engine/fushidicts.dart';

  // (文件, 该文件不应再出现的探针标记)。
  const Map<String, List<String>> probeMarkers = <String, List<String>>{
    repositoryPath: <String>['[dict-perf]'],
    baseSourcePagePath: <String>['[dict-perf]', '[hibiki-autoread]'],
    mixinPath: <String>['[dict-perf]'],
    popupPagePath: <String>['[popup-perf]'],
    lookupFavoritePath: <String>['[video-lookup]'],
    lookupAudioPath: <String>['[hibiki-autoread]'],
    fushidictsPath: <String>['[dict-perf]'],
  };

  probeMarkers.forEach((String path, List<String> markers) {
    test('BUG-914：$path 不再含热路径计时探针', () {
      final String src = read(path);
      for (final String marker in markers) {
        expect(
          src.contains(marker),
          isFalse,
          reason: '$path 不应再有 $marker 探针（release 噪声 + 微开销，BUG-914）',
        );
      }
    });
  });

  test('BUG-913：base_source_page.dispose 释放 _isSearchingNotifier', () {
    final String src = read(baseSourcePagePath);
    expect(
      src.contains('_isSearchingNotifier.dispose()'),
      isTrue,
      reason: '$baseSourcePagePath 的 dispose() 必须释放 _isSearchingNotifier，'
          '否则 ValueNotifier 监听器泄漏（BUG-913）',
    );
  });
}
