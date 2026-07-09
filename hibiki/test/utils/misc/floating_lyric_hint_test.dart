import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/floating_lyric_hint.dart';

/// TODO-1227：悬浮窗权限被 ColorOS 风控拒授时，OPPO 系（oppo/realme/oneplus）
/// 机型换上带解法的引导提示；其余平台/厂商保持原提示。钉死 manufacturer 分支
/// 到 i18n key 的纯函数映射。
void main() {
  group('isColorOsManufacturer', () {
    test('oppo/realme/oneplus 命中（大小写不敏感 + 去空白）', () {
      expect(isColorOsManufacturer('OPPO'), isTrue);
      expect(isColorOsManufacturer('oppo'), isTrue);
      expect(isColorOsManufacturer('realme'), isTrue);
      expect(isColorOsManufacturer('Realme'), isTrue);
      expect(isColorOsManufacturer('OnePlus'), isTrue);
      expect(isColorOsManufacturer('ONEPLUS'), isTrue);
      expect(isColorOsManufacturer(' OPPO '), isTrue);
    });

    test('其它厂商 / null 不命中', () {
      expect(isColorOsManufacturer(null), isFalse);
      expect(isColorOsManufacturer(''), isFalse);
      expect(isColorOsManufacturer('Xiaomi'), isFalse);
      expect(isColorOsManufacturer('samsung'), isFalse);
      expect(isColorOsManufacturer('Google'), isFalse);
      // 不做子串匹配：带尾巴的值不算命中，避免误伤。
      expect(isColorOsManufacturer('oppo-clone'), isFalse);
    });
  });

  group('floatingLyricFailureHint', () {
    test('非 Android：一律通用不可用提示（与 manufacturer 无关）', () {
      expect(
        floatingLyricFailureHint(isAndroid: false, manufacturer: null),
        t.floating_lyric_unavailable_hint,
      );
      expect(
        floatingLyricFailureHint(isAndroid: false, manufacturer: 'OPPO'),
        t.floating_lyric_unavailable_hint,
      );
    });

    test('Android + ColorOS 厂商：带解法的引导提示', () {
      for (final String maker in <String>['OPPO', 'realme', 'OnePlus']) {
        expect(
          floatingLyricFailureHint(isAndroid: true, manufacturer: maker),
          t.floating_lyric_permission_hint_coloros,
        );
      }
    });

    test('Android + 其它厂商 / 未知厂商：原权限提示', () {
      expect(
        floatingLyricFailureHint(isAndroid: true, manufacturer: 'Xiaomi'),
        t.floating_lyric_permission_hint,
      );
      expect(
        floatingLyricFailureHint(isAndroid: true, manufacturer: null),
        t.floating_lyric_permission_hint,
      );
    });

    test('两条 Android 提示文案确实不同（key 没接错）', () {
      expect(
        t.floating_lyric_permission_hint_coloros,
        isNot(t.floating_lyric_permission_hint),
      );
    });
  });
}
