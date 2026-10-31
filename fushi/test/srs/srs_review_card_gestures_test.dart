// 复习页卡面手势：映射 → 复习页现成动作（与按钮 / 快捷键同一条实现）。
//
// - WebView 卡面：页内脚本回报的事件（这里直接调 [SrsCardFace.onCardGesture] 模拟）按落点
//   分区、按松手位移判滑动；
// - 原生 Fushi 卡面：真实指针（tapAt / 触屏拖动）经 [SrsCardGestureRegion]；还能滚动时竖直
//   滑动是滚动；
// - 两面分开、「只留重来 / 良好」屏蔽困难 / 简单、识别器开关随面下发；
// - 滑动反馈：跟手位移 + 动作提示，作废后撤掉，减弱动态效果下不移动。
//
// 走真实路径：内存库 + 确定性假排程内核 → SrsReviewPage。数据库读写放 tester.runAsync。

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
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

Future<String> _addLapis(WidgetTester tester, SrsDbStore store) async =>
    (await tester.runAsync(
      () => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '図書館',
          srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
        },
      ),
    ))!;

Future<String> _addFushiCard(
  WidgetTester tester,
  SrsDbStore store, {
  String? sentence,
}) async => (await tester.runAsync(
  () => store.createNote(
    noteTypeId: store.fushiCardNoteTypeId,
    fieldsById: <String, String>{
      srsFushiCardFieldId(kSrsTestProfile, 'Expression'): '図書館',
      srsFushiCardFieldId(kSrsTestProfile, 'ExpressionReading'): 'としょかん',
      srsFushiCardFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
      if (sentence != null)
        srsFushiCardFieldId(kSrsTestProfile, 'Sentence'): sentence,
    },
  ),
))!;

/// 这条笔记的卡有没有被评过分（评分落一条日志）。
Future<bool> _rated(
  WidgetTester tester,
  SrsDbStore store,
  String noteId,
) async {
  final List<SrsCardCacheRow> cards = (await tester.runAsync(
    () => store.cardsOfNote(noteId),
  ))!;
  return cards.any((SrsCardCacheRow c) => c.lastLogId != null);
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
  required SrsReviewGestureMap gestures,
  bool hideHardEasy = false,
  bool apple = false,
  bool disableAnimations = false,
  Size size = const Size(1100, 900),
  List<SrsCardFace>? faces,
}) async {
  tester.view.physicalSize = size;
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
        srsReviewGesturesProvider.overrideWithValue(gestures),
        srsReviewHideHardEasyProvider.overrideWithValue(hideHardEasy),
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
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: disableAnimations),
            child: FushiGlassScope(child: child!),
          ),
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
final Finder _showAnswer = find.byKey(
  const ValueKey<String>('srs-show-answer'),
);
final Finder _floatingBar = find.descendant(
  of: find.byKey(const ValueKey<String>('srs-review-floating-chrome')),
  matching: find.byType(FushiFloatingTopBar),
);

/// 卡面区域里横向第 [third] 个三分之一（0 / 1 / 2）的中心、纵向 [dy]。
Offset _inThird(WidgetTester tester, int third, double dy) {
  final Rect r = tester.getRect(_surface);
  return Offset(r.left + r.width * (third + 0.5) / 3, dy);
}

Future<void> _animate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 提示清空后卡面弹回：一帧起动画、再走完。
Future<void> _springBack(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _touchSwipe(WidgetTester tester, Offset from, Offset by) async {
  final TestGesture g = await tester.startGesture(from);
  for (int i = 1; i <= 10; i++) {
    await g.moveTo(from + by * (i / 10));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
}

SrsReviewGestureMap _map(
  List<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)> bindings,
) {
  SrsReviewGestureMap m = SrsReviewGestureMap.defaults;
  for (final (SrsReviewSide side, SrsReviewGesture g, SrsReviewGestureAction a)
      in bindings) {
    m = m.withBinding(side, g, a);
  }
  return m;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('WebView 卡面（页内脚本回报）', () {
    testWidgets('单击按落点分区执行：左 = 显示答案，中间仍是默认的切换顶栏', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addLapis(tester, store);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(
        tester,
        store: store,
        faces: faces,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.front,
                SrsReviewGesture.tapLeft,
                SrsReviewGestureAction.showAnswer,
              ),
            ]),
      );
      expect(faces.last.gestureArming, SrsCardGestureArming.none);
      final double y = tester.getCenter(_surface).dy;

      faces.last.onCardGesture!(
        SrsCardGestureEvent(
          SrsCardGestureKind.tap,
          position: _inThird(tester, 1, y),
        ),
      );
      await _animate(tester);
      expect(_showAnswer, findsOneWidget, reason: '中间：没改，仍是切换顶栏');
      expect(_floatingBar, findsOneWidget);

      faces.last.onCardGesture!(
        SrsCardGestureEvent(
          SrsCardGestureKind.tap,
          position: _inThird(tester, 0, y),
        ),
      );
      await _animate(tester);
      expect(_showAnswer, findsNothing, reason: '左：显示答案');
      expect(faces.last.showingAnswer, isTrue);
      await _unmount(tester);
    });

    testWidgets('答案面：松手位移够远才按映射评分；问题面同一手势不评分', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String note = await _addLapis(tester, store);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(
        tester,
        store: store,
        faces: faces,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.back,
                SrsReviewGesture.swipeLeft,
                SrsReviewGestureAction.rateGood,
              ),
            ]),
      );
      const SrsCardGestureEvent far = SrsCardGestureEvent(
        SrsCardGestureKind.release,
        delta: Offset(-200, 4),
      );
      expect(faces.last.gestureArming, SrsCardGestureArming.none);
      faces.last.onCardGesture!(far);
      await _settle(tester, rounds: 4);
      expect(await _rated(tester, store, note), isFalse, reason: '问题面没绑');

      await tester.tap(_showAnswer);
      await _animate(tester);
      expect(
        faces.last.gestureArming,
        const SrsCardGestureArming(swipeHorizontal: true),
        reason: '识别器随面下发',
      );
      faces.last.onCardGesture!(
        const SrsCardGestureEvent(
          SrsCardGestureKind.release,
          delta: Offset(-40, 0),
        ),
      );
      await _settle(tester, rounds: 4);
      expect(await _rated(tester, store, note), isFalse, reason: '不够远');

      faces.last.onCardGesture!(far);
      await _settle(tester);
      expect(await _rated(tester, store, note), isTrue);
      await _unmount(tester);
    });

    testWidgets('「只留重来 / 良好」：绑在困难上的滑动不评分、也不开识别器', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String note = await _addLapis(tester, store);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(
        tester,
        store: store,
        faces: faces,
        hideHardEasy: true,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.back,
                SrsReviewGesture.swipeLeft,
                SrsReviewGestureAction.rateHard,
              ),
            ]),
      );
      await tester.tap(_showAnswer);
      await _animate(tester);
      expect(faces.last.gestureArming, SrsCardGestureArming.none);
      faces.last.onCardGesture!(
        const SrsCardGestureEvent(
          SrsCardGestureKind.release,
          delta: Offset(-200, 0),
        ),
      );
      await _settle(tester);
      expect(await _rated(tester, store, note), isFalse);
      await _unmount(tester);
    });

    for (final bool apple in <bool>[false, true]) {
      testWidgets('[${apple ? 'Apple' : 'MD3'}] 滑动反馈：跟手位移 + 动作提示，作废后撤掉', (
        WidgetTester tester,
      ) async {
        final SrsDbStore store = await _openStore(tester);
        await _addLapis(tester, store);
        final List<SrsCardFace> faces = <SrsCardFace>[];
        await _pumpReview(
          tester,
          store: store,
          faces: faces,
          apple: apple,
          gestures:
              _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
                (
                  SrsReviewSide.back,
                  SrsReviewGesture.swipeLeft,
                  SrsReviewGestureAction.rateAgain,
                ),
              ]),
        );
        await tester.tap(_showAnswer);
        await _animate(tester);
        final Finder follow = find.byKey(
          const ValueKey<String>('srs-swipe-follow'),
        );
        double dx() =>
            tester.widget<Transform>(follow).transform.getTranslation().x;
        expect(dx(), 0);

        faces.last.onCardGesture!(
          const SrsCardGestureEvent(
            SrsCardGestureKind.drag,
            delta: Offset(-120, 3),
          ),
        );
        await tester.pump();
        expect(dx(), closeTo(-120 * SrsSwipeFollow.kFollow, 0.01));
        expect(
          find.byKey(const ValueKey<String>('srs-swipe-hint-rate_again')),
          findsOneWidget,
        );
        expect(find.text(t.srs_rating_again), findsWidgets);

        // 朝没绑动作的方向拖：不跟手。
        faces.last.onCardGesture!(
          const SrsCardGestureEvent(
            SrsCardGestureKind.drag,
            delta: Offset(120, 0),
          ),
        );
        await _springBack(tester);
        expect(dx(), 0);

        faces.last.onCardGesture!(
          const SrsCardGestureEvent(
            SrsCardGestureKind.drag,
            delta: Offset(-60, 0),
          ),
        );
        await tester.pump();
        faces.last.onCardGesture!(
          const SrsCardGestureEvent(SrsCardGestureKind.cancel),
        );
        await _springBack(tester);
        expect(dx(), 0, reason: '作废后弹回');
        expect(
          tester
              .widget<AnimatedOpacity>(
                find
                    .ancestor(
                      of: find.byKey(
                        const ValueKey<String>('srs-swipe-hint-rate_again'),
                      ),
                      matching: find.byType(AnimatedOpacity),
                    )
                    .first,
              )
              .opacity,
          0,
        );
        await _unmount(tester);
      });
    }

    testWidgets('减弱动态效果：滑动途中卡面不移动，提示照常', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addLapis(tester, store);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(
        tester,
        store: store,
        faces: faces,
        disableAnimations: true,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.back,
                SrsReviewGesture.swipeLeft,
                SrsReviewGestureAction.undo,
              ),
            ]),
      );
      await tester.tap(_showAnswer);
      await _animate(tester);
      faces.last.onCardGesture!(
        const SrsCardGestureEvent(
          SrsCardGestureKind.drag,
          delta: Offset(-120, 0),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<Transform>(
              find.byKey(const ValueKey<String>('srs-swipe-follow')),
            )
            .transform
            .getTranslation()
            .x,
        0,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-swipe-hint-undo')),
        findsOneWidget,
      );
      await _unmount(tester);
    });
  });

  group('原生 Fushi 卡面（真实指针）', () {
    testWidgets('单击空白按分区：右 = 显示答案，左 = 默认切换顶栏', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addFushiCard(tester, store);
      await _pumpReview(
        tester,
        store: store,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.front,
                SrsReviewGesture.tapRight,
                SrsReviewGestureAction.showAnswer,
              ),
            ]),
      );
      // 正面内容居中：底栏上沿以上靠左 / 靠右都是空白。
      final double y = tester.getTopLeft(_bottomBar).dy - 24;
      final Rect surface = tester.getRect(_surface);
      await tester.tapAt(Offset(surface.left + 24, y));
      await _animate(tester);
      expect(_floatingBar, findsOneWidget, reason: '左：切换顶栏');
      expect(_showAnswer, findsOneWidget);

      await tester.tapAt(Offset(surface.right - 24, y));
      await _animate(tester);
      expect(_showAnswer, findsNothing, reason: '右：显示答案');
      await _unmount(tester);
    });

    testWidgets('答案面：触屏横滑空白按映射评分；鼠标拖不算', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String note = await _addFushiCard(tester, store);
      await _pumpReview(
        tester,
        store: store,
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.back,
                SrsReviewGesture.swipeRight,
                SrsReviewGestureAction.rateAgain,
              ),
            ]),
      );
      await tester.tap(_showAnswer);
      await _animate(tester);
      // 卡面左缘中部的页边空白。
      final Offset start = Offset(
        tester.getTopLeft(_surface).dx + 8,
        tester.getCenter(_surface).dy,
      );
      final TestGesture mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      for (int i = 1; i <= 10; i++) {
        await mouse.moveTo(start + Offset(20.0 * i, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await mouse.up();
      await _settle(tester, rounds: 4);
      expect(await _rated(tester, store, note), isFalse, reason: '鼠标拖是拖选');

      await _touchSwipe(tester, start, const Offset(220, 0));
      await _settle(tester);
      expect(await _rated(tester, store, note), isTrue);
      await _unmount(tester);
    });

    testWidgets('答案面内容还能往上滚时：竖直上划是滚动，不评分', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String note = await _addFushiCard(
        tester,
        store,
        // 例句是原生排版（释义在 WebView 里，那里的滑动归页内脚本），撑高背面。
        sentence: List<String>.filled(40, '図書館で本を読んだ。').join('<br>'),
      );
      await _pumpReview(
        tester,
        store: store,
        size: const Size(390, 640),
        gestures:
            _map(<(SrsReviewSide, SrsReviewGesture, SrsReviewGestureAction)>[
              (
                SrsReviewSide.back,
                SrsReviewGesture.swipeUp,
                SrsReviewGestureAction.rateAgain,
              ),
            ]),
      );
      await tester.tap(_showAnswer);
      await _animate(tester);
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey<String>('srs-fushi-card-view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(200),
        reason: '前提：背面内容比视口高',
      );
      final Offset start = Offset(
        tester.getTopLeft(_surface).dx + 6,
        tester.getCenter(_surface).dy,
      );
      await _touchSwipe(tester, start, const Offset(0, -180));
      await _settle(tester, rounds: 4);
      expect(scrollable.position.pixels, greaterThan(0), reason: '滚了');
      expect(await _rated(tester, store, note), isFalse, reason: '滚动不是滑动');
      await _unmount(tester);
    });
  });
}
