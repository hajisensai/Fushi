import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_theme.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// MD3 主题收敛：全应用只有一个「ColorScheme → ThemeData」工厂
/// [buildFushiThemeData]。主 app、书内查词弹窗、数据库就绪前的兜底界面都经它
/// 成型——以前悬浮词典 / 查词弹窗 / 8 处兜底各自拼一份只有 colorScheme 的裸
/// ThemeData，组件主题（卡片圆角、浮动 snackbar、chip 形状…）全退回 Flutter 默认，
/// 悬浮词典更是写死默认种子色、无视用户主题。
void main() {
  final TextTheme appText = FushiTypeScale.buildTextTheme(
    const TextStyle(fontFamily: 'FushiTestFont'),
  );

  group('源码守卫：lib 里只有工厂能构造 ThemeData', () {
    // 不吃标识符前缀：`CardThemeData(` / `MaterialVideoControlsThemeData(` 不算。
    final RegExp ctor = RegExp(
      r'(?<![A-Za-z0-9_])ThemeData(\.(light|dark))?\(',
    );
    final RegExp seedShortcut = RegExp(r'colorSchemeSeed\s*:');
    const String factoryFile = 'lib/src/models/theme_notifier.dart';

    test('除 $factoryFile 外不得手写 ThemeData( / colorSchemeSeed', () {
      final List<String> offenders = <String>[];
      int scanned = 0;
      for (final FileSystemEntity e in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('.g.dart')) continue;
        final String path = e.path.replaceAll(r'\', '/');
        scanned++;
        final List<String> lines = e.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final String code = lines[i].split('//').first;
          if (seedShortcut.hasMatch(code) ||
              (path != factoryFile && ctor.hasMatch(code))) {
            offenders.add('$path:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(scanned, greaterThan(500), reason: '扫描面不能空转');
      expect(
        offenders,
        isEmpty,
        reason:
            '改用 buildFushiThemeData / buildFushiFallbackTheme / '
            'ThemeNotifier.buildThemeDataFor，组件主题才与主 app 同源',
      );
    });

    test('悬浮词典入口跟随用户主题（与 popup_main 同一口径）', () {
      final String src = File('lib/floating_dict_main.dart').readAsStringSync();
      expect(
        src,
        contains('appModel.overrideDictionaryTheme ?? appModel.theme'),
      );
      expect(src, contains('appModel.darkTheme'));
      expect(src, contains('appModel.themeMode'));
    });
  });

  group('兜底主题', () {
    for (final Brightness b in Brightness.values) {
      test('$b：默认种子色 + 与主 app 同一套组件主题', () {
        final ThemeData theme = buildFushiFallbackTheme(b);
        final ColorScheme expected = buildFushiColorScheme(
          seedColor: kFushiDefaultSeed,
          brightness: b,
        );
        expect(theme.colorScheme, expected);
        expect(theme.useMaterial3, isTrue);
        expect(theme.cardTheme.color, expected.surfaceContainerLow);
        expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
        expect(theme.chipTheme.showCheckmark, isFalse);
        expect(theme.bottomSheetTheme.showDragHandle, isTrue);
        expect(theme.dividerTheme.color, expected.outlineVariant);
        expect(theme.extension<FushiEinkTheme>()?.einkMode, isFalse);
        expect(
          theme.textTheme.titleLarge?.fontSize,
          FushiTypeScale.titleLarge.size,
        );
      });
    }
  });

  group('书内查词弹窗主题', () {
    const Color paperBg = Color(0xFFF5EFE0);
    const Color paperFg = Color(0xFF3B3229);

    DictionaryPopupTheme resolve({required bool eink}) =>
        resolveDictionaryPopupTheme(
          eink: eink,
          einkDark: false,
          readerBackground: paperBg,
          readerForeground: paperFg,
          readerDark: false,
          buildColorScheme: eink
              ? buildEinkColorScheme
              : (Brightness b) => buildFushiColorScheme(
                  seedColor: kFushiDefaultSeed,
                  brightness: b,
                ),
          textTheme: appText,
          designSystem: FushiDesignSystem.material,
        );

    test('组件主题与字号阶梯同源，中性表面换成纸色', () {
      final ThemeData theme = resolve(eink: false).theme;
      final ThemeData reference = buildFushiThemeData(
        scheme: theme.colorScheme,
        textTheme: appText,
        designSystem: FushiDesignSystem.material,
      );
      expect(theme.colorScheme.surface, isNot(Colors.white));
      expect(theme.colorScheme.onSurface, paperFg);
      expect(theme.cardTheme, reference.cardTheme);
      expect(theme.chipTheme, reference.chipTheme);
      expect(theme.dialogTheme, reference.dialogTheme);
      expect(theme.snackBarTheme, reference.snackBarTheme);
      expect(theme.cardTheme.color, theme.colorScheme.surfaceContainerLow);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'FushiTestFont');
      expect(
        theme.extension<FushiDesignSystemTheme>()?.designSystem,
        FushiDesignSystem.material,
      );
    });

    test('墨水屏扩展仍由纯函数自己挂上', () {
      expect(
        resolve(eink: true).theme.extension<FushiEinkTheme>()?.einkMode,
        isTrue,
      );
      expect(
        resolve(eink: false).theme.extension<FushiEinkTheme>()?.einkMode,
        isFalse,
      );
    });
  });
}
