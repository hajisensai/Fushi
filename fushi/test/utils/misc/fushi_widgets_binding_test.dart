import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/diagnostics/fushi_binding.dart';

/// 集成测试 / widget 测试先建自己的 binding 再调 `app.main()`：主入口的
/// [FushiWidgetsFlutterBinding.ensureInitialized] 必须沿用它，不能再构造第二个 binding
/// （BindingBase 断言失败 → 主入口中止、不 runApp → app_smoke 90 秒等不到 Scaffold）。
void main() {
  final TestWidgetsFlutterBinding testBinding =
      TestWidgetsFlutterBinding.ensureInitialized();

  test('已有 binding 时沿用它，不构造第二个', () {
    final WidgetsBinding binding =
        FushiWidgetsFlutterBinding.ensureInitialized();
    expect(identical(binding, testBinding), isTrue);
    expect(binding, isNot(isA<FushiWidgetsFlutterBinding>()));
    // 再调一次仍是同一个（幂等）。
    expect(
      identical(FushiWidgetsFlutterBinding.ensureInitialized(), testBinding),
      isTrue,
    );
  });
}
