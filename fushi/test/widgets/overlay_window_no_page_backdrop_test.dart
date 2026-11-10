import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;

import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';

/// 反馈 jDuyvS-Hly：app 外查词弹窗（popup_main）卡片以外铺了一层页面底色 +
/// 角落 M3E 形状，应当透出背后的 app。根因是透明浮窗的 MaterialApp 直接用用户
/// 主题，主题转场里的 [FushiBackdropPageTransitionsBuilder] 给 `home` 路由垫了
/// [FushiPageBackdrop]。透明浮窗（popup_main / floating_dict_main）一律经
/// [withoutFushiPageBackdrop] 去掉这层。
void main() {
  const Map<TargetPlatform, PageTransitionsBuilder> wrapped =
      <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FushiBackdropPageTransitionsBuilder(
          FadeUpwardsPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: FushiBackdropPageTransitionsBuilder(
          CupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      };
  final ThemeData backdropTheme = ThemeData(
    pageTransitionsTheme: const PageTransitionsTheme(builders: wrapped),
  );

  group('withoutFushiPageBackdrop', () {
    test('unwraps every backdrop builder to its inner builder', () {
      final Map<TargetPlatform, PageTransitionsBuilder> builders =
          withoutFushiPageBackdrop(backdropTheme).pageTransitionsTheme.builders;
      expect(builders.keys, unorderedEquals(wrapped.keys));
      expect(
        builders[TargetPlatform.android],
        isA<FadeUpwardsPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.iOS],
        isA<CupertinoPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.windows],
        isA<ZoomPageTransitionsBuilder>(),
      );
    });

    test('the real fallback theme loses every backdrop builder', () {
      for (final Brightness b in Brightness.values) {
        final Iterable<PageTransitionsBuilder> builders =
            withoutFushiPageBackdrop(
              buildFushiFallbackTheme(b),
            ).pageTransitionsTheme.builders.values;
        expect(
          builders.whereType<FushiBackdropPageTransitionsBuilder>(),
          isEmpty,
        );
      }
    });

    test('rebuilding yields an equal theme (no theme animation churn)', () {
      expect(
        withoutFushiPageBackdrop(backdropTheme),
        withoutFushiPageBackdrop(backdropTheme),
      );
    });

    test('a theme without the backdrop layer is returned as-is', () {
      final ThemeData plain = ThemeData(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: ZoomPageTransitionsBuilder(),
          },
        ),
      );
      expect(identical(withoutFushiPageBackdrop(plain), plain), isTrue);
    });
  });

  testWidgets('overlay-window home route paints no page backdrop', (
    WidgetTester tester,
  ) async {
    Widget app(ThemeData theme) => MaterialApp(
      theme: theme,
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: SizedBox.expand(),
      ),
    );

    // 对照：带背景层的用户主题，home 路由被垫了 FushiPageBackdrop。
    await tester.pumpWidget(app(backdropTheme));
    expect(find.byType(FushiPageBackdrop), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(withoutFushiPageBackdrop(backdropTheme)));
    await tester.pumpAndSettle();
    expect(find.byType(FushiPageBackdrop), findsNothing);
  });

  group('transparent overlay entry points strip the backdrop', () {
    for (final String path in <String>[
      'lib/popup_main.dart',
      'lib/floating_dict_main.dart',
    ]) {
      test(path, () {
        final String src = File(
          path,
        ).readAsStringSync().replaceAll('\r\n', '\n');
        expect(src, contains('withoutFushiPageBackdrop('));
        expect(
          RegExp(r'\btheme:\s*appModel\.').hasMatch(src),
          isFalse,
          reason: 'user theme must go through withoutFushiPageBackdrop',
        );
        expect(
          RegExp(r':\s*appModel\.darkTheme\b').hasMatch(src),
          isFalse,
          reason: 'dark theme must go through withoutFushiPageBackdrop',
        );
        final int fallbackCalls = RegExp(
          r'buildFushiFallbackTheme\(',
        ).allMatches(src).length;
        final int strippedFallbackCalls = RegExp(
          r'withoutFushiPageBackdrop\(\s*buildFushiFallbackTheme\(',
        ).allMatches(src).length;
        expect(fallbackCalls, greaterThan(0));
        expect(strippedFallbackCalls, fallbackCalls);
      });
    }
  });
}
