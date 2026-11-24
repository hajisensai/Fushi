import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show PrefCodec;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/page_backdrop_layer.dart';

/// 拍板台 xxbbL0j15l：背景按「全局 → 模块 → 页面」分层，复习答题页默认继承复习模块
/// （牌组总览），可单独换图或关掉。
void main() {
  tearDown(() {
    pageBackdropSettings.value = const PageBackdropSettings();
    pageBackdropModuleOverrides.value =
        const <HomeTab, PageBackdropModuleOverride>{};
    pageBackdropPageOverrides.value =
        const <PageBackdropPage, PageBackdropModuleOverride>{};
    homeShellTabNotifier.value = HomeTab.home;
  });

  const PageBackdropSettings global = PageBackdropSettings(
    preset: PageBackdropPreset.custom,
    landscapeImagePath: 'global.png',
    blur: PageBackdropBlur.heavy,
    scrim: 0.3,
  );

  group('分层解析', () {
    test('复习答题页没单独设：继承复习模块；模块也没设就是全局', () {
      pageBackdropSettings.value = global;
      expect(
        pageBackdropSettingsFor(null, page: PageBackdropPage.srsReview),
        global,
      );

      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.srs: PageBackdropModuleOverride(
              preset: PageBackdropPreset.custom,
              landscapeImagePath: 'srs.png',
            ),
          };
      expect(
        pageBackdropSettingsFor(null, page: PageBackdropPage.srsReview),
        pageBackdropSettingsFor(HomeTab.srs),
      );
      expect(
        pageBackdropSettingsFor(
          null,
          page: PageBackdropPage.srsReview,
        ).landscapeImagePath,
        'srs.png',
      );
    });

    test('页面总按所属模块继承，与从哪个 tab 打开无关', () {
      pageBackdropSettings.value = global;
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.home: PageBackdropModuleOverride(
              preset: PageBackdropPreset.wave,
            ),
          };
      expect(
        pageBackdropSettingsFor(HomeTab.home, page: PageBackdropPage.srsReview),
        global,
      );
    });

    test('页面单独设：换图只换预设与图片，模糊 / 遮罩沿用全局；选纯色 = 关掉', () {
      pageBackdropSettings.value = global;
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.srs: PageBackdropModuleOverride(
              preset: PageBackdropPreset.custom,
              landscapeImagePath: 'srs.png',
            ),
          };
      pageBackdropPageOverrides.value =
          const <PageBackdropPage, PageBackdropModuleOverride>{
            PageBackdropPage.srsReview: PageBackdropModuleOverride(
              preset: PageBackdropPreset.custom,
              landscapeImagePath: 'review.png',
            ),
          };
      final PageBackdropSettings review = pageBackdropSettingsFor(
        null,
        page: PageBackdropPage.srsReview,
      );
      expect(review.landscapeImagePath, 'review.png');
      expect(review.blur, PageBackdropBlur.heavy);
      expect(review.scrim, 0.3);
      expect(
        pageBackdropSettingsFor(HomeTab.srs).landscapeImagePath,
        'srs.png',
        reason: '总览页不受答题页设置影响',
      );

      pageBackdropPageOverrides.value =
          const <PageBackdropPage, PageBackdropModuleOverride>{
            PageBackdropPage.srsReview: PageBackdropModuleOverride(
              preset: PageBackdropPreset.plain,
            ),
          };
      final PageBackdropSettings off = pageBackdropSettingsFor(
        null,
        page: PageBackdropPage.srsReview,
      );
      expect(off.effectivePreset, PageBackdropPreset.plain);
      expect(off.hasCustomImage, isFalse);
    });

    test('页面选了自定义图片但图不在 → 退回所属模块', () {
      pageBackdropSettings.value = global;
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.srs: PageBackdropModuleOverride(
              preset: PageBackdropPreset.wave,
            ),
          };
      pageBackdropPageOverrides.value =
          const <PageBackdropPage, PageBackdropModuleOverride>{
            PageBackdropPage.srsReview: PageBackdropModuleOverride(
              preset: PageBackdropPreset.custom,
            ),
          };
      expect(
        pageBackdropSettingsFor(null, page: PageBackdropPage.srsReview),
        pageBackdropSettingsFor(HomeTab.srs),
      );
    });
  });

  group('偏好编解码（两层共用一对键）', () {
    test('页面 wire 往返，且不与任何模块 wire 重名', () {
      final Set<String> modules = <String>{
        for (final HomeTab tab in HomeTab.values) pageBackdropModuleWire(tab),
      };
      for (final PageBackdropPage page in PageBackdropPage.values) {
        expect(PageBackdropPage.fromWire(page.wire), page);
        expect(modules, isNot(contains(page.wire)));
      }
      expect(PageBackdropPage.srsReview.wire, 'srs_review', reason: 'wire 冻结');
      expect(PageBackdropPage.fromWire('srs'), isNull);
    });

    test('同一份 JSON 里模块与页面各取各的，整体往返两层都在', () {
      const String presets =
          '{"srs":"wave","srs_review":"plain","alien":"mesh"}';
      expect(
        decodePageBackdropModulePresets(presets),
        <HomeTab, PageBackdropPreset>{HomeTab.srs: PageBackdropPreset.wave},
      );
      expect(
        decodePageBackdropPagePresets(presets),
        <PageBackdropPage, PageBackdropPreset>{
          PageBackdropPage.srsReview: PageBackdropPreset.plain,
        },
      );
      final Map<String, PageBackdropPreset> scoped =
          decodePageBackdropScopedPresets(presets);
      // 认不出的层级 wire（别的版本 / 设备写的）在整键读改写里原样保留，不被本机抹掉。
      expect(
        scoped.keys,
        unorderedEquals(<String>['srs', 'srs_review', 'alien']),
      );
      expect(
        decodePageBackdropScopedPresets(
          encodePageBackdropScopedPresets(scoped),
        ),
        scoped,
      );

      const String images =
          '{"srs":{"landscape":"s.png"},"srs_review":{"landscape":"r.png",'
          '"portrait":"rp.png"}}';
      expect(decodePageBackdropModuleImages(images).keys, <HomeTab>[
        HomeTab.srs,
      ]);
      expect(decodePageBackdropPageImages(images)[PageBackdropPage.srsReview], (
        landscape: 'r.png',
        portrait: 'rp.png',
      ));
      expect(
        decodePageBackdropScopedImages(
          encodePageBackdropScopedImages(
            decodePageBackdropScopedImages(images),
          ),
        ),
        decodePageBackdropScopedImages(images),
      );
    });

    test('认不出的层级 wire 的图同样算被引用、同样改写存量绝对路径', () {
      final String images = jsonEncode(<String, Object>{
        'future_page': <String, String>{'landscape': r'C:\old\next.png'},
      });
      expect(
        pageBackdropReferencedImagePaths(<String, String>{
          kPageBackdropModuleImagesPrefKey: PrefCodec.encode(images),
        }),
        contains(r'C:\old\next.png'),
      );
      final String? healed = healPageBackdropModuleImagesValue(
        images,
        inDirectory: (String name) => name == 'next.png',
      );
      expect(decodePageBackdropScopedImages(healed)['future_page'], (
        landscape: 'next.png',
        portrait: null,
      ));
    });

    test('页面的图算作被引用（换图清扫不误删），存量绝对路径一并改写', () {
      final String images = jsonEncode(<String, Object>{
        'srs_review': <String, String>{'landscape': r'C:\old\review.png'},
      });
      expect(
        pageBackdropReferencedImagePaths(<String, String>{
          kPageBackdropModuleImagesPrefKey: PrefCodec.encode(images),
        }),
        contains(r'C:\old\review.png'),
      );
      final String? healed = healPageBackdropModuleImagesValue(
        images,
        inDirectory: (String name) => name == 'review.png',
      );
      expect(decodePageBackdropPageImages(healed)[PageBackdropPage.srsReview], (
        landscape: 'review.png',
        portrait: null,
      ));
    });
  });

  group('路由层按页面画背景', () {
    ThemeData theme() => ThemeData(
      extensions: const <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: false),
        FushiEinkTheme(false),
      ],
    );

    // 被盖住的总览页是 Offstage，也要数进来。
    Finder layer() => find.byType(PageBackdropLayer, skipOffstage: false);

    testWidgets('FushiBackdropPage 登记后按页面设置画：总览画、答题页关掉', (
      WidgetTester tester,
    ) async {
      pageBackdropSettings.value = const PageBackdropSettings(
        preset: PageBackdropPreset.plain,
      );
      pageBackdropModuleOverrides.value =
          const <HomeTab, PageBackdropModuleOverride>{
            HomeTab.srs: PageBackdropModuleOverride(
              preset: PageBackdropPreset.wave,
            ),
          };
      homeShellTabNotifier.value = HomeTab.srs;
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: theme().copyWith(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: <TargetPlatform, PageTransitionsBuilder>{
                TargetPlatform.android: FushiBackdropPageTransitionsBuilder(
                  ZoomPageTransitionsBuilder(),
                ),
              },
            ),
          ),
          home: const SizedBox.expand(),
        ),
      );
      expect(layer(), findsOneWidget, reason: '复习模块的总览页画波浪');

      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => const FushiBackdropPage(
              page: PageBackdropPage.srsReview,
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 没单独设：继承模块，两页都画。
      expect(layer(), findsNWidgets(2));

      pageBackdropPageOverrides.value =
          const <PageBackdropPage, PageBackdropModuleOverride>{
            PageBackdropPage.srsReview: PageBackdropModuleOverride(
              preset: PageBackdropPreset.plain,
            ),
          };
      await tester.pump();
      expect(layer(), findsOneWidget, reason: '答题页关掉，总览页照画');

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(layer(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
