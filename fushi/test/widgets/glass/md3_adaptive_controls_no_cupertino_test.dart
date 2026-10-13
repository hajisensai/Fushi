import 'dart:io';

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

import '../../helpers/source_guard.dart';

// BUG-3309：`auto` 下五平台统一 MD3（M3E）。Fushi 包装层的 `.adaptive` 构造器
// 曾直通 SDK 的 `X.adaptive`，后者按 ThemeData.platform 选外观——iOS 上于是出
// 绿色 Cupertino 开关（不跟主题色）、菊花、Cupertino 对话框。现在只有隐藏的
// `FushiDesignSystem.cupertino` 才交给 SDK 的平台分派；用户可见的「Cupertino」
// （玻璃设计）走 isGlassDesign 分支，不受此判据影响。

const Color _iosGreen = Color(0xFF34C759); // CupertinoColors.systemGreen（浅色）

ThemeData _theme({
  required TargetPlatform platform,
  FushiDesignSystem designSystem = FushiDesignSystem.auto,
}) {
  final ThemeData base = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: false,
  ).copyWith(platform: platform);
  return base.copyWith(
    extensions: List<ThemeExtension<dynamic>>.of(
      base.extensions.values.cast<ThemeExtension<dynamic>>(),
    )..add(FushiDesignSystemTheme(designSystem)),
  );
}

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
    testWidgets('FushiSwitch.adaptive does not paint the iOS green track', (
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

      await _pump(
        tester,
        theme,
        FushiSwitch.adaptive(value: true, onChanged: (_) {}),
      );
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

    testWidgets('FushiAlertDialog.adaptive is a Material AlertDialog', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _theme(platform: TargetPlatform.iOS),
        const FushiAlertDialog.adaptive(title: Text('t'), content: Text('c')),
      );
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  // 「隐藏的 FushiDesignSystem.cupertino」不是用户可见的「Cupertino」——后者是
  // 玻璃设计，走 isGlassDesign 分支，不受 useCupertinoAdaptiveControls 影响。
  group('hidden FushiDesignSystem.cupertino keeps platform dispatch', () {
    testWidgets('switch / progress / dialog stay Cupertino on iOS', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _theme(
          platform: TargetPlatform.iOS,
          designSystem: FushiDesignSystem.cupertino,
        ),
        Column(
          children: <Widget>[
            FushiSwitch.adaptive(value: true, onChanged: (_) {}),
            const FushiCircularProgressIndicator.adaptive(),
          ],
        ),
      );
      expect(find.byType(Switch), paints..rrect(color: _iosGreen));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

      await _pump(
        tester,
        _theme(
          platform: TargetPlatform.iOS,
          designSystem: FushiDesignSystem.cupertino,
        ),
        const FushiAlertDialog.adaptive(title: Text('t'), content: Text('c')),
      );
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    });
  });

  // 隐藏的 macOS 原生设计系统（FushiDesignSystem.macos）同样不是隐藏的
  // FushiDesignSystem.cupertino：修复前它在 macOS 上让 `.adaptive` 出 Cupertino
  // 开关 / 菊花，现在与 MD3 一样渲染 Material 控件。
  group('hidden FushiDesignSystem.macos renders Material', () {
    testWidgets('FushiSwitch.adaptive / progress on macOS are Material', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        _theme(
          platform: TargetPlatform.macOS,
          designSystem: FushiDesignSystem.macos,
        ),
        Column(
          children: <Widget>[
            FushiSwitch.adaptive(value: true, onChanged: (_) {}),
            const FushiCircularProgressIndicator.adaptive(),
          ],
        ),
      );
      expect(find.byType(Switch), isNot(paints..rrect(color: _iosGreen)));
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  // 源码守卫：SDK `X.adaptive(` 只许出现在包装层（及显式 Apple 分支的
  // settings_kit），且包装层每一处都经 useCupertinoAdaptiveControls 判据；不许再
  // 出现直通 `if (_adaptive) {`。
  test(
    'SDK .adaptive constructors are gated by the design-system judgement',
    () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        offenders.addAll(
          _adaptiveGateOffenders(
            entity.path.replaceAll(r'\', '/'),
            entity.readAsStringSync(),
          ),
        );
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    },
  );

  // 守卫自检：注释里的判据 / 注释里的 SDK 调用都不能左右结论（审查 PR #2098：
  // 逐行过滤只认行首注释，挡不住块注释与行尾注释）。
  group('adaptive gate guard self-check', () {
    const String wrapper = '${_glassDir}fushi_glass_toggles.dart';

    test('a gate that only lives in a block comment does not count', () {
      const String source = '''
Widget build(BuildContext context) {
  if (_adaptive /* && useCupertinoAdaptiveControls(context) */) {
    return Switch.adaptive(value: v, onChanged: f);
  }
}
''';
      expect(_adaptiveGateOffenders(wrapper, source), isNotEmpty);
    });

    test('a gate that only lives in a trailing comment does not count', () {
      const String source = '''
Widget build(BuildContext context) {
  final bool g = _adaptive; // useCupertinoAdaptiveControls(context)
  if (g) return Switch.adaptive(value: v, onChanged: f);
}
''';
      expect(_adaptiveGateOffenders(wrapper, source), isNotEmpty);
    });

    test('a real gate passes and commented SDK calls are ignored', () {
      const String source = '''
Widget build(BuildContext context) {
  /* Switch.adaptive( */
  // Slider.adaptive(
  if (_adaptive && useCupertinoAdaptiveControls(context)) {
    return Switch.adaptive(value: v, onChanged: f);
  }
}
''';
      expect(_adaptiveGateOffenders(wrapper, source), isEmpty);
    });

    test('a raw SDK call outside the wrappers is reported', () {
      const String source = 'final Widget w = Switch.adaptive(value: v);';
      expect(
        _adaptiveGateOffenders('lib/src/pages/some_page.dart', source),
        isNotEmpty,
      );
    });
  });
}

final RegExp _sdkAdaptive = RegExp(
  r'\b(Switch|Slider|Checkbox|Radio(<\w+>)?|CheckboxListTile|'
  r'SwitchListTile|RadioListTile(<\w+>)?|AlertDialog|'
  r'CircularProgressIndicator)\.adaptive\(',
);
const String _glassDir = 'lib/src/utils/components/glass/';
const Set<String> _wrappers = <String>{
  '${_glassDir}fushi_glass_toggles.dart',
  '${_glassDir}fushi_glass_overlays.dart',
  '${_glassDir}fushi_glass_feedback.dart',
};
// settings_kit 的那一处在 `if (apple)` 分支里（玻璃 / Apple 设计系统）。
const Set<String> _allowed = <String>{
  ..._wrappers,
  'lib/src/settings/settings_kit.dart',
};

/// 单个文件的违规清单。先整文件词法遮注释（`maskComments`：行注释 / 行尾注释 /
/// 块注释一律换成等长空白），再在遮后的全文上计数——不逐行过滤。
List<String> _adaptiveGateOffenders(String path, String source) {
  final String code = maskComments(source);
  final int raw = _sdkAdaptive.allMatches(code).length;
  if (raw == 0) return const <String>[];
  if (!_allowed.contains(path)) {
    return <String>['$path: $raw raw SDK .adaptive( call(s)'];
  }
  if (!_wrappers.contains(path)) return const <String>[];
  final List<String> offenders = <String>[];
  final int gated = 'useCupertinoAdaptiveControls(context)'
      .allMatches(code)
      .length;
  if (gated < raw) {
    offenders.add('$path: $raw SDK .adaptive( calls but $gated gates');
  }
  if (RegExp(r'if \((widget\.)?_adaptive\) \{').hasMatch(code)) {
    offenders.add('$path: ungated `if (_adaptive) {`');
  }
  return offenders;
}
