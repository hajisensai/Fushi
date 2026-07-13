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

    test('resolveOverlayResizeFromWindow — 覆盖窗拖角倒推 + 解锁真值', () {
      // 正向：cardW = overlayLogicalW × uiScale，窗口物理宽 = cardW × dpr。
      // 取 overlayLogicalW=600, uiScale=1.25, dpr=1.5 → 物理宽 = 600×1.25×1.5 = 1125。
      final LookupSize size = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 1125,
        windowPhysicalHeight: 900, // 480×1.25×1.5 = 900 → 逻辑高 480
        dpr: 1.5,
        uiScale: 1.25,
      );
      expect(size, const LookupSize(600, 480));
    });

    test('resolveOverlayResizeFromWindow — dpr/uiScale 非正按 1 兜底（不除零）', () {
      final LookupSize size = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 800,
        windowPhysicalHeight: 600,
        dpr: 0,
        uiScale: -1,
      );
      expect(size, const LookupSize(800, 600));
    });

    test('resolveOverlayResizeFromWindow — 下取整到整逻辑像素', () {
      // 900.9 / 1 / 1 = 900.9 → floor 900；700.2 → 700。
      final LookupSize size = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 900.9,
        windowPhysicalHeight: 700.2,
        dpr: 1,
        uiScale: 1,
      );
      expect(size, const LookupSize(900, 700));
    });

    test('resolveOverlayResizeFromWindow — clamp 到滑杆同源 min/max', () {
      // 过小 → 夹到 (250,200)；过大 → 夹到 (2000,1600)。
      final LookupSize tiny = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 10,
        windowPhysicalHeight: 10,
        dpr: 1,
        uiScale: 1,
      );
      expect(
          tiny, const LookupSize(kLookupPopupMinWidth, kLookupPopupMinHeight));
      final LookupSize huge = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 99999,
        windowPhysicalHeight: 99999,
        dpr: 1,
        uiScale: 1,
      );
      expect(
          huge, const LookupSize(kLookupPopupMaxWidth, kLookupPopupMaxHeight));
    });

    test('resolveOverlayResizeFromWindow — 拖出的尺寸即解锁独立键的写入值', () {
      // 语义验证：倒推值直接作为 overlayLookupMaxWidth/Height 写入，effective 在
      // independent=true 下即读它——拖拽与滑杆写同一真值。
      final LookupSize dragged = resolveOverlayResizeFromWindow(
        windowPhysicalWidth: 1400,
        windowPhysicalHeight: 1000,
        dpr: 2,
        uiScale: 1,
      );
      expect(dragged, const LookupSize(700, 500));
      final LookupSize effective = effectiveLookupSize(
        independent: true,
        sceneWidth: dragged.width,
        sceneHeight: dragged.height,
        sharedWidth: 400,
        sharedHeight: 360,
      );
      expect(effective, const LookupSize(700, 500));
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

  group('resolveExtensionPopupSize（Phase D — 扩展拖角回写 clamp）', () {
    test('范围内尺寸原样透传', () {
      expect(resolveExtensionPopupSize(maxWidth: 640, maxHeight: 520),
          const LookupSize(640, 520));
    });

    test('超上界夹到 2000×1600（4K 屏视口空间远超上界）', () {
      // 扩展侧只按视口可用空间夹（可远超上界），app 侧必须再兜底夹到滑杆同款上界。
      expect(resolveExtensionPopupSize(maxWidth: 5000, maxHeight: 4000),
          const LookupSize(kLookupPopupMaxWidth, kLookupPopupMaxHeight));
    });

    test('低于下界夹到 250×200', () {
      expect(resolveExtensionPopupSize(maxWidth: 10, maxHeight: 10),
          const LookupSize(kLookupPopupMinWidth, kLookupPopupMinHeight));
    });

    test('非有限值（NaN/Inf）按下限兜底', () {
      expect(
          resolveExtensionPopupSize(
              maxWidth: double.nan, maxHeight: double.infinity),
          const LookupSize(kLookupPopupMinWidth, kLookupPopupMinHeight));
    });

    test('clamp 后即扩展场景独立键的写入值（拖拽与滑杆写同一真值）', () {
      final LookupSize dragged =
          resolveExtensionPopupSize(maxWidth: 720, maxHeight: 600);
      final LookupSize effective = effectiveLookupSize(
        independent: true,
        sceneWidth: dragged.width,
        sceneHeight: dragged.height,
        sharedWidth: 400,
        sharedHeight: 360,
      );
      expect(effective, const LookupSize(720, 600));
    });
  });
}
