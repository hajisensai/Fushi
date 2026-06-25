import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/app_icon_preferences.dart';

void main() {
  group('windowIconAssetForPreset', () {
    test('返回三套预设各自的 asset', () {
      expect(windowIconAssetForPreset('default'),
          'assets/meta/launcher_icon_minimal.png');
      expect(windowIconAssetForPreset('hibiki_full'),
          'assets/meta/launcher_icon_full.png');
      expect(windowIconAssetForPreset('hibiki_minimal'),
          'assets/meta/launcher_icon_minimal.png');
    });

    test('未知 key 回退到 default 的 asset', () {
      expect(windowIconAssetForPreset('nope'),
          'assets/meta/launcher_icon_minimal.png');
    });

    test('custom key 没有内置 asset（返回 null）', () {
      expect(windowIconAssetForPreset('custom'), isNull);
    });
  });

  group('isPresetKey', () {
    test('三套预设是合法 preset，custom 与未知不是', () {
      expect(isPresetKey('default'), isTrue);
      expect(isPresetKey('hibiki_full'), isTrue);
      expect(isPresetKey('hibiki_minimal'), isTrue);
      expect(isPresetKey('custom'), isFalse);
      expect(isPresetKey('nope'), isFalse);
    });
  });
}
