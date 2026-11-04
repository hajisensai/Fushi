// 同步设备区 / 冲突差异块走设计系统（PR #2830 审查）：本机行的「点按改名」提示用 FushiTooltip（不写裸 Tooltip），
// 差异块底色取设计令牌的嵌套面板色（MD3 / Apple 各自分派），不在页面里自选 MD3 色调。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_devices_section.dart';
import 'package:fushi/src/pages/implementations/srs/srs_value_diff.dart';
import 'package:fushi/src/srs/srs_device_view.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(ThemeData theme, Widget child) => MaterialApp(
  theme: theme,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

BoxDecoration _diffDecoration(WidgetTester tester) {
  final Container box = tester.widget<Container>(
    find.byKey(const ValueKey<String>('srs-conflict-diff')),
  );
  return box.decoration! as BoxDecoration;
}

FushiDesignTokens _tokensAt(WidgetTester tester) => FushiDesignTokens.of(
  tester.element(find.byKey(const ValueKey<String>('srs-conflict-diff'))),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('差异块（MD3）：底色 = 设计令牌的嵌套面板色，圆角 = 卡内小件档', (
    WidgetTester tester,
  ) async {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC)),
    );
    await tester.pumpWidget(
      _host(theme, const SrsValueDiff(from: '今日は雨', to: '今日は晴れ')),
    );
    final BoxDecoration deco = _diffDecoration(tester);
    final FushiDesignTokens tokens = _tokensAt(tester);
    expect(deco.color, tokens.surfaces.card);
    expect(deco.borderRadius, tokens.radii.cardRadius);
    expect(
      deco.color,
      isNot(theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
    );
  });

  testWidgets('差异块（Apple）：底色走 Apple 分组嵌套色，不漏出 MD3 色调', (
    WidgetTester tester,
  ) async {
    final FushiAppleColors apple = FushiAppleColors.of(
      Brightness.light,
      const Color(0xFF007AFF),
    );
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF007AFF)),
      extensions: <ThemeExtension<dynamic>>[apple],
    );
    await tester.pumpWidget(
      _host(theme, const SrsValueDiff(from: 'abc', to: 'abd')),
    );
    final BoxDecoration deco = _diffDecoration(tester);
    expect(deco.color, apple.tertiaryGroupedBackground);
    expect(deco.color, isNot(theme.colorScheme.surfaceContainerHighest));
  });

  testWidgets('本机设备行：改名提示用 FushiTooltip，消息是改名提示文案', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ThemeData(),
        SrsSyncDevicesSection(
          devices: const <SrsDeviceView>[
            SrsDeviceView(id: 'self-device', self: true, name: 'Wight 的电脑'),
          ],
          syncing: false,
          enabled: true,
          onRename: (SrsDeviceView _) {},
          onRetire: (SrsDeviceView _) {},
          onUnretire: (SrsDeviceView _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder tip = find.byKey(
      const ValueKey<String>('srs_device_rename_self-device'),
    );
    expect(tip, findsOneWidget);
    final FushiTooltip widget = tester.widget<FushiTooltip>(tip);
    expect(widget.message, t.srs_device_rename_tooltip);
    expect(find.byType(FushiTooltip), findsOneWidget);
  });
}
