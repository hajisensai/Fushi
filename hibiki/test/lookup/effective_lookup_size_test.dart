// 查词弹窗「有效最大宽高」纯函数 + 解锁语义单元测试。
//
// 纯 Dart，不依赖词典 FFI / sqlite native-assets，可 `flutter test` 单独跑过。
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/effective_lookup_size.dart';

void main() {
  group('LookupSize', () {
    test('值相等即相等（可用于 widget rebuild 去重）', () {
      expect(const LookupSize(400, 360), const LookupSize(400, 360));
      expect(const LookupSize(400, 360).hashCode,
          const LookupSize(400, 360).hashCode);
    });

    test('宽或高不同即不相等', () {
      expect(const LookupSize(400, 360) == const LookupSize(401, 360), isFalse);
      expect(const LookupSize(400, 360) == const LookupSize(400, 361), isFalse);
    });
  });

  group('effectiveLookupSize — 解锁语义', () {
    const double sharedW = 400;
    const double sharedH = 360;
    const double sceneW = 900;
    const double sceneH = 1200;

    test('跟随中（independent=false）→ 恒用 app 内共享宽高，忽略自身键', () {
      final LookupSize size = effectiveLookupSize(
        independent: false,
        sceneWidth: sceneW,
        sceneHeight: sceneH,
        sharedWidth: sharedW,
        sharedHeight: sharedH,
      );
      expect(size, const LookupSize(sharedW, sharedH));
    });

    test('解锁后（independent=true）→ 用自身场景宽高，脱钩共享值', () {
      final LookupSize size = effectiveLookupSize(
        independent: true,
        sceneWidth: sceneW,
        sceneHeight: sceneH,
        sharedWidth: sharedW,
        sharedHeight: sharedH,
      );
      expect(size, const LookupSize(sceneW, sceneH));
    });

    test('跟随时改共享值实时联动，自身键此刻无影响', () {
      LookupSize follow(double w, double h) => effectiveLookupSize(
            independent: false,
            sceneWidth: 111,
            sceneHeight: 222,
            sharedWidth: w,
            sharedHeight: h,
          );
      expect(follow(500, 600), const LookupSize(500, 600));
      expect(follow(700, 800), const LookupSize(700, 800));
    });

    test('解锁后改共享值不影响，读的是自身键', () {
      LookupSize independent(double sharedW, double sharedH) =>
          effectiveLookupSize(
            independent: true,
            sceneWidth: 640,
            sceneHeight: 480,
            sharedWidth: sharedW,
            sharedHeight: sharedH,
          );
      expect(independent(400, 360), const LookupSize(640, 480));
      expect(independent(2000, 1600), const LookupSize(640, 480));
    });

    test('默认场景键 == app 内默认（解锁瞬间不跳尺寸）', () {
      // 场景键默认值应等于 app 内默认（400×360），使 independent 从 false→true 的
      // 那一刻有效尺寸不变——这是「一动手才脱钩」好品味的前提。
      const double appDefaultW = 400;
      const double appDefaultH = 360;
      final LookupSize followed = effectiveLookupSize(
        independent: false,
        sceneWidth: appDefaultW,
        sceneHeight: appDefaultH,
        sharedWidth: appDefaultW,
        sharedHeight: appDefaultH,
      );
      final LookupSize unlocked = effectiveLookupSize(
        independent: true,
        sceneWidth: appDefaultW,
        sceneHeight: appDefaultH,
        sharedWidth: appDefaultW,
        sharedHeight: appDefaultH,
      );
      expect(unlocked, followed);
    });
  });
}
