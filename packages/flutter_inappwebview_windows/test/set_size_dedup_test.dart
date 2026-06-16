import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';

/// TODO-428/420：setSize 去抖判定测试。
///
/// 验证 _setSize 的去重逻辑（提取为 SetSizeDedup 纯状态机）只在「首次 / 尺寸真变」
/// 时放行下发，对「与上次完全相等」的重复一律拦截——这正是掐断 WGC 帧池 churn 的守卫。
void main() {
  group('SetSizeDedup', () {
    test('首次调用必放行（尚无记录）', () {
      final dedup = SetSizeDedup();
      expect(dedup.shouldDispatch(800, 600, 1.0), isTrue);
    });

    test('同尺寸重复调用只放行一次', () {
      final dedup = SetSizeDedup();
      expect(dedup.shouldDispatch(800, 600, 1.0), isTrue, reason: '首次必下发');
      expect(dedup.shouldDispatch(800, 600, 1.0), isFalse,
          reason: '完全相等的重复必须拦掉');
      expect(dedup.shouldDispatch(800, 600, 1.0), isFalse, reason: '连续相同仍拦掉');
    });

    test('宽度变化重新放行', () {
      final dedup = SetSizeDedup();
      dedup.shouldDispatch(800, 600, 1.0);
      expect(dedup.shouldDispatch(801, 600, 1.0), isTrue);
    });

    test('高度变化重新放行', () {
      final dedup = SetSizeDedup();
      dedup.shouldDispatch(800, 600, 1.0);
      expect(dedup.shouldDispatch(800, 599, 1.0), isTrue);
    });

    test('scaleFactor 变化重新放行（DPI 改变）', () {
      final dedup = SetSizeDedup();
      dedup.shouldDispatch(800, 600, 1.0);
      expect(dedup.shouldDispatch(800, 600, 1.5), isTrue);
    });

    test('尺寸在两个值间抖动：每次真变都放行，原值回归也放行，但同值重复被拦', () {
      final dedup = SetSizeDedup();
      // 滚动条出现/消失导致宽度在 800 / 783 间抖。
      expect(dedup.shouldDispatch(800, 600, 1.0), isTrue); // 首次
      expect(dedup.shouldDispatch(800, 600, 1.0), isFalse); // 重复拦
      expect(dedup.shouldDispatch(783, 600, 1.0), isTrue); // 变窄放行
      expect(dedup.shouldDispatch(783, 600, 1.0), isFalse); // 重复拦
      expect(dedup.shouldDispatch(800, 600, 1.0), isTrue); // 变回原宽放行
      expect(dedup.shouldDispatch(800, 600, 1.0), isFalse); // 重复拦
    });

    test('放行后内部状态更新为最新尺寸（变更后再重复同样被拦）', () {
      final dedup = SetSizeDedup();
      dedup.shouldDispatch(800, 600, 1.0);
      expect(dedup.shouldDispatch(1024, 768, 2.0), isTrue, reason: '尺寸变');
      expect(dedup.shouldDispatch(1024, 768, 2.0), isFalse,
          reason: '变更后再发同尺寸应被拦');
    });
  });
}
