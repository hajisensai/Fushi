import 'dart:io';

import 'package:test/test.dart';

/// 首页外壳的源码守卫：共享选中真值是 [HomeTab] 而不是 int 下标，外部入口
/// （ctl 路由）写 `homeShellTabNotifier` 后走同一条 `_selectTab` 路径；MD3 桌面
/// rail 不带 Apple 式侧栏分隔线。HomePage 无法单独 pump（需要整套 AppModel），
/// 照其它 home_page `*_static_test` 的惯例断言结构契约。
void main() {
  final String home = File(
    'lib/src/pages/implementations/home_page.dart',
  ).readAsStringSync();
  // 共享选中真值的声明已移到 models/home_tab.dart（路由层页面背景读它，不反向
  // import 整个首页实现，反馈 DYI1IOZxSM）。
  final String homeTab = File(
    'lib/src/models/home_tab.dart',
  ).readAsStringSync();

  test('tab selection is unified through homeShellTabNotifier (HomeTab)', () {
    expect(
      homeTab,
      contains('ValueNotifier<HomeTab> homeShellTabNotifier'),
      reason:
          'the shared shell selection is a HomeTab notifier, not an int '
          'index (Approach C: enum identity survives conditional tabs).',
    );
    expect(
      home,
      contains('homeShellTabNotifier.addListener(_onShellTabRequested)'),
      reason:
          'HomePage listens so external writers route selection through '
          'the same _selectTab path (preserving _previousTab / focus reset).',
    );
    expect(
      home,
      contains('homeShellTabNotifier.value = tab'),
      reason:
          '_selectTab writes back so the shared notifier reflects the '
          'current tab whatever entry point switched it.',
    );
  });

  test('MD3 desktop rail has no Apple-style sidebar separator', () {
    final int layoutStart = home.indexOf('Widget _buildDesktopLayout(');
    final int layoutEnd = home.indexOf(
      'Widget _bodyWithMiniBar()',
      layoutStart,
    );
    expect(layoutStart, isNonNegative);
    expect(layoutEnd, greaterThan(layoutStart));
    final String body = home.substring(layoutStart, layoutEnd);
    expect(
      body,
      isNot(contains('VerticalDivider')),
      reason:
          'The MD3 rail and content surface must not be split by the '
          'leftover macOS/Cupertino-style sidebar border.',
    );
  });
}
