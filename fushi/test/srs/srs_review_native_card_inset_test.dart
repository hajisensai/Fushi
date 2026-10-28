// BUG-3562：复习页把「状态栏 + 浮动页头」的让位交给谁。
//
// - MD3（悬浮页头、正文铺到页头底下）+ 原生 Fushi 卡面：卡面本身从顶端画起，让位高度
//   只作卡面滚动内边距（SrsFushiCardView.topInset），页头收起后不留空带。
// - MD3 + 整面 WebView 卡面（Lapis 等）：WebView 滚不到页头底下，整张卡面仍整体让位。
// - Apple：页头不悬浮（FushiPageScaffold 竖排），正文拿到的顶部 padding 为 0，卡面不加
//   滚动内边距。
//
// 走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage。数据库读写放 tester.runAsync。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
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
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices());
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
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
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
    await _unmount(tester);

    final SrsDbStore lapis = await _openStore(tester);
    await _addLapis(tester, lapis);
    await _pumpReview(tester, store: lapis, apple: false);
    // 整面 WebView 滚不到底栏下面：卡面底边正好在底栏上沿。
    expect(tester.getBottomLeft(_surface).dy, tester.getTopLeft(bar).dy);
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
