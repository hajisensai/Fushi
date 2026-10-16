import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3485：Android 原生层的两条焦点契约（Java 侧无单测宿主，只能源码守卫）。
///
/// 1. 触摸模式下窗口没有任何聚焦 view 时，手柄键到不了 FlutterView，系统按
///    `Generic.kcm` 把 BUTTON_B 兜底成 BACK——绕过快捷键注册表直接退页面。
///    `dispatchKeyEvent` 必须在交给 super 之前把焦点交给 FlutterView。
/// 2. `setDefaultFocusHighlightEnabled` 是**逐 view** 属性，只设 decorView 管不到
///    真正持焦的全屏 FlutterView（屏幕最外缘那圈淡框）。必须设在 FlutterView 与
///    后续获焦的 view 上。
void main() {
  final String src = File(
    'android/app/src/main/java/app/fushi/reader/MainActivity.java',
  ).readAsStringSync();

  String bodyOf(String signature) {
    final int start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');
    int depth = 0;
    for (int i = src.indexOf('{', start); i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(start, i + 1);
      }
    }
    fail('$signature 的方法体没有闭合');
  }

  test('dispatchKeyEvent gives FlutterView focus before dispatching', () {
    final String body = bodyOf(
      'public boolean dispatchKeyEvent(KeyEvent event)',
    );
    final int ensure = body.indexOf('ensureKeyFocusTarget();');
    final int superCall = body.lastIndexOf('super.dispatchKeyEvent(event)');
    expect(
      ensure,
      isNonNegative,
      reason: 'dispatchKeyEvent 必须调用 ensureKeyFocusTarget()（BUG-3485）',
    );
    expect(
      ensure,
      lessThan(superCall),
      reason: '必须在 super.dispatchKeyEvent 之前补焦点，否则这一下 B 已被兜底成 BACK',
    );
  });

  test(
    'ensureKeyFocusTarget focuses the FlutterView only when nothing has focus',
    () {
      final String body = bodyOf('private void ensureKeyFocusTarget()');
      expect(
        body.contains('getCurrentFocus() != null'),
        isTrue,
        reason: '已有聚焦 view（如 WebView 平台视图）时不得抢焦点',
      );
      expect(body.contains('findViewById(FLUTTER_VIEW_ID)'), isTrue);
      expect(body.contains('requestFocus()'), isTrue);
    },
  );

  test(
    'system focus highlight is disabled on the FlutterView, not only decor',
    () {
      final String body = bodyOf('private void disableSystemFocusHighlight()');
      expect(
        body.contains('findViewById(FLUTTER_VIEW_ID)'),
        isTrue,
        reason: '必须对全屏 FlutterView 关系统焦点框（屏幕外缘淡框）',
      );
      expect(
        body.contains('addOnGlobalFocusChangeListener'),
        isTrue,
        reason: '之后获焦的 view（平台视图等）也要关系统焦点框',
      );
      expect(
        RegExp(
          r'flutterView\.setDefaultFocusHighlightEnabled\(false\)',
        ).hasMatch(body),
        isTrue,
      );
    },
  );
}
