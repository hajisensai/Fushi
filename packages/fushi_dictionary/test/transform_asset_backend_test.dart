import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// `fushidicts.dart` 的变形表读取经 `if (dart.library.ui)` 条件 import 分流：Flutter
/// 宿主必须选中 rootBundle 分支，否则 app 启动时 `FushiDicts.preloadTransforms()` 静默
/// 落到「不支持」，去屈折规则表全空、查「食べた」查不到「食べる」。纯 Dart 宿主那一端
/// 由 packages/fushi_server/test/dictionary_host_test.dart 钉成 `'none'`。
void main() {
  test('Flutter 宿主选中 rootBundle 读变形表', () {
    expect(FushiDicts.transformAssetBackend, 'rootBundle');
  });

  test('preloadTransformsFrom 用注入的读取函数装载 manifest 里列出的每种语言', () async {
    final List<String> asked = <String>[];
    await FushiDicts.preloadTransformsFrom((String key) async {
      asked.add(key);
      if (key.endsWith('manifest.json')) return '["ja","en"]';
      return '{}';
    });
    expect(asked, <String>[
      'assets/transforms/manifest.json',
      'assets/transforms/ja.json',
      'assets/transforms/en.json',
    ]);
    expect(FushiDicts.loadedTransformCount, 2);
  });
}
