// BUG-3562：复习页把「状态栏 + 浮动页头」的让位交给谁。
//
// - MD3（悬浮页头、正文铺到页头底下）+ 原生 Fushi 卡面：卡面本身从顶端画起，让位高度
//   只作卡面滚动内边距（SrsFushiCardView.topInset），页头收起后不留空带。
// - MD3 + 整面 WebView 卡面（Lapis 等）：WebView 滚不到页头底下，整张卡面仍整体让位。
// - Apple：页头不悬浮（FushiPageScaffold 竖排），正文拿到的顶部 padding 为 0，卡面不加
//   滚动内边距。
//
// 底栏不画底（所有者 2026-11-15 截图「底部怎么没进去」）：卡面透明时底栏祖先链上
// 没有不透明底，页面背景铺到屏幕底边；卡面内容改在底栏上沿裁掉。卡面自己铺底（自定义
// 配色）时才垫同色底板。
//
// 走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage。数据库读写放 tester.runAsync。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:flutter/rendering.dart' show RenderClipRect;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<void> _addFushiCard(WidgetTester tester, SrsDbStore store) async {
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        srsFushiCardFieldId(kSrsTestProfile, 'Expression'): '図書館',
        srsFushiCardFieldId(kSrsTestProfile, 'ExpressionReading'): 'としょかん',
        srsFushiCardFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
      },
    ),
  );
}

Future<void> _addLapis(WidgetTester tester, SrsDbStore store) async {
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '図書館',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
      },
    ),
  );
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  await srsSettle(tester, minRounds: rounds);
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  bool dark = false,
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 复习页按快捷键注册表解析按键（空格翻面）：装出厂默认（真 app 在 initialise 里装）。
  final AppModel app = AppModel(testPlatformServices())
    ..shortcutRegistry.loadDefaults(TargetPlatform.windows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        // 本文件钉的是固定页头的让位；悬浮顶栏（默认）见 srs_review_floating_chrome_test.dart。
        srsReviewChromeFloatingProvider.overrideWithValue(false),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        ...overrides,
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            textTheme: dark
                ? Typography.material2021().white
                : Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

final Finder _surface = find.byKey(const ValueKey<String>('srs-card-surface'));
final Finder _native = find.byType(SrsFushiCardView);

/// 卡面正文实际拿到的顶部让位（FushiPageScaffold 注入的 MediaQuery padding.top）。
double _bodyInset(WidgetTester tester) =>
    MediaQuery.paddingOf(tester.element(_surface)).top;

/// 卡面裁切层实际裁掉的底部高度（0 = 不裁）。
double _underBarCut(WidgetTester tester) {
  final RenderClipRect clip = tester.renderObject<RenderClipRect>(
    find.byKey(const ValueKey<String>('srs-card-under-bar-clip')),
  );
  if (clip.clipBehavior == Clip.none) return 0;
  return clip.size.height - clip.clipper!.getClip(clip.size).bottom;
}

/// 原生卡面里铺满整个卡面的不透明 [ColoredBox]（卡面自己的整面底色）。
List<ColoredBox> _nativeOpaqueFills(WidgetTester tester) {
  final Size face = tester.getSize(_native);
  return tester
      .widgetList<ColoredBox>(
        find.descendant(of: _native, matching: find.byType(ColoredBox)),
      )
      .where((ColoredBox b) => b.color.a > 0)
      .where((ColoredBox b) {
        final Size s = tester.getSize(find.byWidget(b));
        return s.width >= face.width - 1 && s.height >= face.height - 1;
      })
      .toList();
}

/// 底栏里的 [row]（默认「显示答案」那一行；翻面后传评分按钮行）往上直到卡面宿主，
/// 祖先链上画了不透明底的 widget。
List<Widget> _opaqueBarAncestors(
  WidgetTester tester, {
  String row = 'srs-show-answer-row',
}) {
  final List<Widget> opaque = <Widget>[];
  bool paints(Color? c) => c != null && c.a > 0;
  tester.element(find.byKey(ValueKey<String>(row))).visitAncestorElements((
    Element e,
  ) {
    final Widget w = e.widget;
    if (w is SrsCardLookupHost) return false;
    final bool hit = switch (w) {
      ColoredBox(:final Color color) => paints(color),
      DecoratedBox(decoration: final BoxDecoration d) =>
        paints(d.color) ||
            (d.gradient?.colors.any((Color c) => c.a > 0) ?? false),
      Material(:final MaterialType type, :final Color? color) =>
        type != MaterialType.transparency && paints(color),
      _ => false,
    };
    if (hit) opaque.add(w);
    return true;
  });
  return opaque;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('MD3 原生 Fushi 卡面：卡面铺到页头底下，让位只作滚动内边距', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store, apple: false);

    expect(_native, findsOneWidget);
    final double inset = _bodyInset(tester);
    expect(inset, greaterThan(0), reason: '悬浮页头下正文应拿到页头让位');
    // 卡面不再整体让位：从窗口顶端画起。
    expect(tester.getTopLeft(_surface).dy, 0);
    // 让位交给卡面当滚动内边距：开头内容从页头下沿开始。
    expect(tester.widget<SrsFushiCardView>(_native).topInset, inset);
    final Finder front = find.byKey(const ValueKey<String>('srs-fushi-front'));
    expect(front, findsOneWidget);
    final EdgeInsets padding =
        tester.widget<SingleChildScrollView>(front).padding! as EdgeInsets;
    expect(padding.top, greaterThan(inset));
    await _unmount(tester);
  });

  testWidgets('MD3 整面 WebView 卡面：滚不到页头底下，卡面整体让位', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store);
    await _pumpReview(tester, store: store, apple: false);

    expect(_native, findsNothing);
    expect(find.byType(SrsPlainCardFace), findsOneWidget);
    // 外层 Padding 吃掉了整段让位：卡面顶边正好在页头下沿。
    final double surfaceTop = tester.getTopLeft(_surface).dy;
    expect(surfaceTop, greaterThan(0));
    expect(surfaceTop, _bodyInset(tester));
    await _unmount(tester);
  });

  testWidgets('底栏让位：原生卡面铺到底栏背后、底栏高度作滚动内边距；WebView 卡面停在底栏上沿', (
    WidgetTester tester,
  ) async {
    final Finder bar = find.byKey(
      const ValueKey<String>('srs-review-bottom-bar'),
    );
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store, apple: false);

    final double barHeight = tester.getSize(bar).height;
    expect(barHeight, greaterThan(0));
    // 原生卡面画到窗口底端（底栏背后），末尾内容靠滚动内边距让到底栏上沿以上。
    expect(tester.getBottomLeft(_surface).dy, tester.getBottomLeft(bar).dy);
    expect(
      tester.widget<SrsFushiCardView>(_native).bottomInset?.value,
      barHeight,
    );
    final EdgeInsets padding =
        tester
                .widget<SingleChildScrollView>(
                  find.byKey(const ValueKey<String>('srs-fushi-front')),
                )
                .padding!
            as EdgeInsets;
    expect(padding.bottom, greaterThan(barHeight));
    // 跟随 app 配色（卡面透明）：底栏不画底，页面背景铺到底边；滚到底栏背后的内容在
    // 底栏上沿裁掉，不从按钮之间透出来。
    expect(
      find.byKey(const ValueKey<String>('srs-review-bottom-bar-scrim')),
      findsNothing,
    );
    expect(_opaqueBarAncestors(tester), isEmpty);
    expect(_underBarCut(tester), barHeight);
    await _unmount(tester);

    final SrsDbStore lapis = await _openStore(tester);
    await _addLapis(tester, lapis);
    await _pumpReview(tester, store: lapis, apple: false);
    // 整面 WebView 滚不到底栏下面：卡面底边正好在底栏上沿；不需要底板，也不必再裁。
    expect(tester.getBottomLeft(_surface).dy, tester.getTopLeft(bar).dy);
    expect(
      find.byKey(const ValueKey<String>('srs-review-bottom-bar-scrim')),
      findsNothing,
    );
    expect(_opaqueBarAncestors(tester), isEmpty);
    expect(_underBarCut(tester), 0);
    await _unmount(tester);
  });

  for (final bool apple in <bool>[false, true]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets(
        '${apple ? 'Apple' : 'MD3'}${dark ? ' 深色' : ' 浅色'} 底栏不画底：页面背景铺到底边，'
        '卡面在底栏上沿裁掉（显示答案与翻面后的评分行）',
        (WidgetTester tester) async {
          final SrsDbStore store = await _openStore(tester);
          await _addFushiCard(tester, store);
          await _pumpReview(tester, store: store, apple: apple, dark: dark);

          final Finder bar = find.byKey(
            const ValueKey<String>('srs-review-bottom-bar'),
          );
          final double barHeight = tester.getSize(bar).height;
          expect(barHeight, greaterThan(0));
          expect(_opaqueBarAncestors(tester), isEmpty);
          expect(_underBarCut(tester), barHeight);

          // 翻面（空格，焦点驱动）：底栏换成评分按钮行，仍不画底，裁切跟随新底栏高度。
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await _settle(tester);
          expect(
            find.byKey(const ValueKey<String>('srs-answer-bar')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey<String>('srs-review-bottom-bar-scrim')),
            findsNothing,
          );
          expect(_opaqueBarAncestors(tester, row: 'srs-rate-3'), isEmpty);
          expect(_underBarCut(tester), tester.getSize(bar).height);
          await _unmount(tester);
        },
      );
    }
  }

  testWidgets('卡面自定义配色（卡面自己铺底）：底栏同样不画底，卡面在底栏上沿裁掉', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(
      tester,
      store: store,
      apple: false,
      overrides: <Override>[
        srsCardAppearanceProvider.overrideWithValue(
          const SrsCardAppearance(colorSource: SrsCardColorSource.custom),
        ),
      ],
    );

    final Finder bar = find.byKey(
      const ValueKey<String>('srs-review-bottom-bar'),
    );
    // 以前这里垫「透明 → 卡面 surface」的渐变底板；所有者 11-20：底部也不应该有背景。
    expect(
      find.byKey(const ValueKey<String>('srs-review-bottom-bar-scrim')),
      findsNothing,
    );
    expect(_opaqueBarAncestors(tester), isEmpty);
    // 不靠底色挡内容：卡面在底栏上沿裁掉，末尾内容靠底部滚动内边距滚到底栏以上。
    expect(_underBarCut(tester), tester.getSize(bar).height);
    expect(
      tester.widget<SrsFushiCardView>(_native).bottomInset?.value,
      tester.getSize(bar).height,
    );
    // 自定义配色时原生卡面仍铺用户选的 surface（有意为之的卡面底色）。
    expect(_nativeOpaqueFills(tester), isNotEmpty);
    await _unmount(tester);
  });

  testWidgets('跟随 app 配色：原生卡面不铺任何整面底色，透出页面背景', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store, apple: false);
    expect(_nativeOpaqueFills(tester), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-answer-bar')),
      findsOneWidget,
    );
    // 答案面同样不铺。
    expect(_nativeOpaqueFills(tester), isEmpty);
    await _unmount(tester);
  });

  testWidgets('Apple 原生 Fushi 卡面：页头不悬浮，卡面不加滚动内边距', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store, apple: true);

    expect(_native, findsOneWidget);
    expect(tester.widget<SrsFushiCardView>(_native).topInset, 0);
    // 卡面在竖排页头之下，不被盖住。
    expect(tester.getTopLeft(_surface).dy, greaterThan(0));
    await _unmount(tester);
  });
}
