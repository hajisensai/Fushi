import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';

// BUG-3309：`auto` 下五平台统一 MD3（M3E）。Fushi 包装层曾有直通 SDK `X.adaptive`
// 的 `.adaptive` 构造器，后者按 ThemeData.platform 选外观——iOS 上于是出绿色
// Cupertino 开关（不跟主题色）、菊花、Cupertino 对话框。隐藏的 Cupertino 设计
// 系统删掉后，开关 / 滑块 / 勾选 / 单选 / 对话框包装层已没有 `.adaptive` 构造器
// （写不出来）；用户可见的「Cupertino」（玻璃设计）走 isGlassDesign 分支。

const Color _iosGreen = Color(0xFF34C759); // CupertinoColors.systemGreen（浅色）

ThemeData _theme({required TargetPlatform platform}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glass: FushiGlassMaterial.off,
  glassDesign: false,
).copyWith(platform: platform);

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(child: SizedBox(width: 360, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('MD3 on iOS renders Material, not Cupertino', () {
    testWidgets('FushiSwitch does not paint the iOS green track', (
      WidgetTester tester,
    ) async {
      final ThemeData theme = _theme(platform: TargetPlatform.iOS);
      // 正对照：同一主题下裸 Switch.adaptive 确实画 iOS 绿，证明匹配器能区分。
      await _pump(
        tester,
        theme,
        Switch.adaptive(value: true, onChanged: (_) {}),
      );
      expect(find.byType(Switch), paints..rrect(color: _iosGreen));

      await _pump(tester, theme, FushiSwitch(value: true, onChanged: (_) {}));
      expect(find.byType(Switch), isNot(paints..rrect(color: _iosGreen)));
      expect(
        find.byType(Switch),
        paints..rrect(color: theme.colorScheme.primary),
      );
    });

    testWidgets(
      'FushiCircularProgressIndicator.adaptive is the M3E wavy ring',
      (WidgetTester tester) async {
        await _pump(
          tester,
          _theme(platform: TargetPlatform.iOS),
          const FushiCircularProgressIndicator.adaptive(),
        );
        expect(find.byType(CupertinoActivityIndicator), findsNothing);
        expect(find.byType(FushiWavyCircularProgress), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    testWidgets('FushiAlertDialog is a Material AlertDialog', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _theme(platform: TargetPlatform.iOS),
        const FushiAlertDialog(title: Text('t'), content: Text('c')),
      );
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  group('MD3 on macOS renders Material', () {
    testWidgets('FushiSwitch / progress on macOS are Material', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _theme(platform: TargetPlatform.macOS),
        Column(
          children: <Widget>[
            FushiSwitch(value: true, onChanged: (_) {}),
            const FushiCircularProgressIndicator.adaptive(),
          ],
        ),
      );
      expect(find.byType(Switch), isNot(paints..rrect(color: _iosGreen)));
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  // 源码层的守卫（SDK `X.adaptive(` / `showAdaptiveDialog` 等平台分派入口、手写的
  // 平台 → Cupertino 分派，只减不增）在 sdk_platform_dispatch_ratchet_test.dart。
}
