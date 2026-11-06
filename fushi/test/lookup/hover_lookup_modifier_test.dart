import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/hover_lookup_modifier.dart';

/// 设置「悬停查词按键」：偏好值 ↔ 枚举，坏值回到 Shift；下发给 WebView 的那行 JS 与
/// 页面脚本读的全局名（`e[window.__fushiHoverKey]`、`KeyboardEvent.key`）一致。
void main() {
  test('偏好值往返，未知 / 缺省回到 Shift', () {
    for (final HoverLookupModifier m in HoverLookupModifier.values) {
      expect(HoverLookupModifier.fromStorage(m.storageKey), m);
    }
    expect(HoverLookupModifier.fromStorage(null), HoverLookupModifier.shift);
    expect(HoverLookupModifier.fromStorage('meta'), HoverLookupModifier.shift);
  });

  test('JS 侧字段名是 MouseEvent 上真有的修饰键布尔', () {
    expect(HoverLookupModifier.shift.jsEventFlag, 'shiftKey');
    expect(HoverLookupModifier.ctrl.jsEventFlag, 'ctrlKey');
    expect(HoverLookupModifier.alt.jsEventFlag, 'altKey');
    expect(HoverLookupModifier.ctrl.jsKeyName, 'Control');
    expect(
      hoverLookupModifierJs(HoverLookupModifier.alt),
      "window.__fushiHoverKey='altKey';window.__fushiHoverKeyName='Alt';",
    );
  });
}
