// 复习页悬浮顶栏（默认开，与小说、漫画阅读器同一口径）：
//
// - 默认收起，不占布局；右键 / 点卡面空白在唤出与收起间切换，不自动收起。
// - 没有卡面可点（复习完等）时顶栏常驻，否则连返回键都唤不出来。
// - 「复习选项」里关掉 = 固定页头常驻，右键不再切换。
// - 原生卡面的「点空白」判定（SrsCardGestureRegion）：点在带点击处理的子控件上、被圈出的
//   释义 WebView 上、拖动、取词用掉的点按都不算空白（手势的其余判定见
//   srs_card_gesture_region_test.dart）。
//
// 走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage。数据库读写放 tester.runAsync。

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
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

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 打开复习页；[faces] 收集每次构建的卡面（拿 onCardGesture 模拟页内脚本回报）。
Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  bool apple = false,
  bool? floating,
  List<SrsCardFace>? faces,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
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
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          faces?.add(face);
          return SrsPlainCardFace(face: face);
        }),
        // null = 不覆盖：走 AppModel 的默认值（偏好未装配 = 悬浮）。
        if (floating != null)
          srsReviewChromeFloatingProvider.overrideWithValue(floating),
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
final Finder _bottomBar = find.byKey(
  const ValueKey<String>('srs-review-bottom-bar'),
);

/// 悬浮顶栏（收起后 FushiChromeReveal 把它放进 Offstage，默认 finder 看不到）。
final Finder _floatingBar = find.descendant(
  of: find.byKey(const ValueKey<String>('srs-review-floating-chrome')),
  matching: find.byType(FushiFloatingTopBar),
);

Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _animate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('默认悬浮：顶栏收起；右键唤出、再右键收起', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store);
    await _pumpReview(tester, store: store);

    expect(_surface, findsOneWidget);
    expect(_floatingBar, findsNothing, reason: '默认收起');
    // 不占布局：整面 WebView 卡面不再给页头让位（桌面无状态栏，顶边贴窗口）。
    expect(tester.getTopLeft(_surface).dy, 0);

    await _rightClick(tester, tester.getCenter(_surface));
    expect(_floatingBar, findsOneWidget, reason: '右键唤出');
    // 不自动收起。
    await tester.pump(const Duration(seconds: 5));
    expect(_floatingBar, findsOneWidget);

    await _rightClick(tester, tester.getCenter(_surface));
    expect(_floatingBar, findsNothing, reason: '再右键收起');
    await _unmount(tester);
  });

  testWidgets('卡面回报点空白：切换顶栏', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(tester, store: store, faces: faces);

    final void Function(SrsCardGestureEvent)? onGesture =
        faces.last.onCardGesture;
    expect(onGesture, isNotNull, reason: '复习页要接卡面的空白点按');
    final SrsCardGestureEvent tap = SrsCardGestureEvent(
      SrsCardGestureKind.tap,
      position: tester.getCenter(_surface),
    );
    onGesture!(tap);
    await _animate(tester);
    expect(_floatingBar, findsOneWidget);
    faces.last.onCardGesture!(tap);
    await _animate(tester);
    expect(_floatingBar, findsNothing);
    await _unmount(tester);
  });

  testWidgets('Apple 悬浮：同样默认收起、右键唤出', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store);
    await _pumpReview(tester, store: store, apple: true);

    expect(_floatingBar, findsNothing);
    await _rightClick(tester, tester.getCenter(_surface));
    expect(_floatingBar, findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('原生 Fushi 卡面：点空白切换顶栏', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store);

    expect(_floatingBar, findsNothing);
    // 卡面右下角、底栏上沿以上：正面内容居中，这里是空白。原生卡面铺到底栏背后，
    // 卡面自己的右下角落在底栏那条里（归底栏，见下一条）。
    final Offset blank = Offset(
      tester.getBottomRight(_surface).dx - 24,
      tester.getTopLeft(_bottomBar).dy - 24,
    );
    await tester.tapAt(blank);
    await _animate(tester);
    expect(_floatingBar, findsOneWidget);
    await tester.tapAt(blank);
    await _animate(tester);
    expect(_floatingBar, findsNothing);
    await _unmount(tester);
  });

  testWidgets('原生 Fushi 卡面：点底栏留白（按钮旁 / 底边）不算点卡面空白', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addFushiCard(tester, store);
    await _pumpReview(tester, store: store);

    // 卡面铺到窗口底端、底栏压在它上面：这条里的点按会命中下面的卡面，除非底栏自己认领。
    expect(
      tester.getBottomLeft(_surface).dy,
      tester.getBottomLeft(_bottomBar).dy,
    );
    final Rect bar = tester.getRect(_bottomBar);
    for (final Offset at in <Offset>[
      Offset(bar.left + 4, bar.center.dy), // 左侧页边留白
      Offset(bar.right - 4, bar.center.dy), // 右侧页边留白
      Offset(bar.center.dx, bar.bottom - 2), // 按钮下方留白 / 底部安全区
    ]) {
      await tester.tapAt(at);
      await _animate(tester);
      expect(_floatingBar, findsNothing, reason: '$at');
    }
    await _unmount(tester);
  });

  testWidgets('复习完：没有卡面可点，顶栏常驻', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _pumpReview(tester, store: store);

    expect(
      find.byKey(const ValueKey<String>('srs-review-finished')),
      findsOneWidget,
    );
    expect(_floatingBar, findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('关掉悬浮：固定页头常驻，右键不切换', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store);
    await _pumpReview(tester, store: store, floating: false);

    expect(find.byType(FushiFloatingTopBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('srs-review-floating-chrome')),
      findsNothing,
    );
    await _rightClick(tester, tester.getCenter(_surface));
    expect(find.byType(FushiFloatingTopBar), findsOneWidget);
    await _unmount(tester);
  });

  group('SrsCardGestureRegion：点空白', () {
    Future<List<String>> pumpRegion(WidgetTester tester) async {
      final List<String> calls = <String>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SrsCardGestureRegion(
            onGesture: (SrsCardGestureEvent e) {
              if (e.kind == SrsCardGestureKind.tap) calls.add('empty');
            },
            tapTookLookup: () => false,
            child: Column(
              children: <Widget>[
                GestureDetector(
                  key: const ValueKey<String>('button'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => calls.add('button'),
                  child: const SizedBox(width: 200, height: 100),
                ),
                // ColoredBox 与真卡面的底色一样会被命中（裸 SizedBox 不参与命中测试）。
                SrsCardGestureRegion.excluded(
                  child: const ColoredBox(
                    key: ValueKey<String>('webview'),
                    color: Color(0xFFEEEEEE),
                    child: SizedBox(width: 200, height: 100),
                  ),
                ),
                const ColoredBox(
                  key: ValueKey<String>('blank'),
                  color: Color(0xFFFFFFFF),
                  child: SizedBox(width: 200, height: 100),
                ),
              ],
            ),
          ),
        ),
      );
      return calls;
    }

    testWidgets('空白点按回报；按钮 / 被圈出的子树不算', (WidgetTester tester) async {
      final List<String> calls = await pumpRegion(tester);
      await tester.tap(find.byKey(const ValueKey<String>('blank')));
      expect(calls, <String>['empty']);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey<String>('button')));
      expect(calls, <String>['button']);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey<String>('webview')));
      expect(calls, isEmpty);
    });

    testWidgets('拖动不算点空白', (WidgetTester tester) async {
      final List<String> calls = await pumpRegion(tester);
      await tester.drag(
        find.byKey(const ValueKey<String>('blank')),
        const Offset(0, 60),
      );
      expect(calls, isEmpty);
    });

    testWidgets('取词用掉的点按不算点空白', (WidgetTester tester) async {
      final List<String> calls = <String>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SrsCardGestureRegion(
            onGesture: (SrsCardGestureEvent e) {
              if (e.kind == SrsCardGestureKind.tap) calls.add('empty');
            },
            tapTookLookup: () => true,
            child: const ColoredBox(
              color: Color(0xFFFFFFFF),
              child: SizedBox(width: 200, height: 100),
            ),
          ),
        ),
      );
      await tester.tapAt(const Offset(50, 50));
      expect(calls, isEmpty);
    });
  });
}
