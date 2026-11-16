// 每日上限单位改缺省（卡片数 → 作答次数，拍板台 pr3460）的两项界面跟进，MD3 与 Apple 两套设计系统：
// - 存量牌组的一次性提醒：「保持按卡片数」写 cards、「按作答次数」写 reviews，回应后提醒消失；新装没评过分时不提醒；
// - 分钟单位的牌组到期一格显示今天还剩的复习分钟，不显示没截断的张数。
//
// 内存库 + 确定性假排程内核；数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';
import 'support/srs_write_settle.dart';

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    // 测试时钟（2026-10-01）在改缺省（kSrsLimitUnitDefaultChangedAtMs）之前：这时评的分算「存量牌组」。
    () => openSrsTestStore(clock: SrsTestClock()),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<void> _settle(WidgetTester tester) => srsSettle(tester, minRounds: 16);

Future<void> _pumpDeckList(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
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
          home: const SrsDeckListPage(),
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

/// 默认牌组里加一张卡；[answer] 时（测试时钟在改缺省之前）评一次分。
Future<void> _seedDefaultDeck(
  WidgetTester tester,
  SrsDbStore store, {
  required bool answer,
}) async {
  await _db(tester, () async {
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(store.profileUid, 'Expression'): '聞く',
      },
    );
    if (answer) {
      await store.answer((await store.cardsOfNote(note)).single.id, 3);
    }
  });
}

void main() {
  group('到期一格：分钟单位显示剩余分钟', () {
    test('有可复习的卡时显示剩余分钟；没有（或用满）时照旧 0；其余单位显示张数', () {
      const SrsReviewCell byMinutes = SrsReviewCell(due: 1234, minutesLeft: 25);
      expect(byMinutes.byMinutes, isTrue);
      expect(byMinutes.numbers, t.srs_count_review_minutes_short(n: 25));
      expect(
        byMinutes.label(),
        '${t.srs_count_review} ${t.srs_count_review_minutes_left(n: 25)}',
      );
      const SrsReviewCell emptyMinutes = SrsReviewCell(due: 0, minutesLeft: 0);
      expect(emptyMinutes.byMinutes, isFalse);
      expect(emptyMinutes.numbers, '0');
      expect(emptyMinutes.label(omitZero: true), isNull);
      const SrsReviewCell counts = SrsReviewCell(due: 12);
      expect(counts.numbers, '12');
      expect(counts.label(), '${t.srs_count_review} 12');
      expect(
        srsNavPeekCountsLabel(
          newCount: 0,
          learnCount: 0,
          reviewCount: 800,
          reviewMinutesLeft: 7,
        ),
        '${t.srs_count_review} ${t.srs_count_review_minutes_left(n: 7)}',
      );
    });

    testWidgets('计数三联：分钟单位那一格写剩余分钟，不写张数', (WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            home: const Scaffold(
              body: SrsCountTriple(
                newCount: 3,
                learnCount: 0,
                reviewCount: 4321,
                reviewMinutesLeft: 18,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text(t.srs_count_review_minutes_short(n: 18)),
        findsOneWidget,
      );
      expect(find.text('4321'), findsNothing);
    });
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 牌组列表：存量牌组提醒一次，「保持按卡片数」写 cards 后提醒消失', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _seedDefaultDeck(tester, store, answer: true);
      await _pumpDeckList(tester, store: store, apple: apple);
      final Finder notice = find.byKey(
        const ValueKey<String>('srs-limit-unit-notice'),
      );
      expect(notice, findsOneWidget);
      expect(find.text(t.srs_limit_unit_notice_body(n: 1)), findsOneWidget);

      await srsUntilWritten(
        tester,
        () => tester.tap(
          find.byKey(const ValueKey<String>('srs-limit-unit-keep-cards')),
        ),
        reloads: <ProviderListenable<AsyncValue<Object?>>>[
          srsLimitUnitLegacyCountProvider,
        ],
        until: () => notice.evaluate().isEmpty,
      );
      expect(notice, findsNothing);
      final SrsDeckTree tree = await _db(tester, store.deckTree);
      expect(tree[store.defaultDeckId]!.limitUnit, SrsLimitUnit.cards);
      expect(tree[store.defaultDeckId]!.limitUnitSet, isTrue);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表：「按作答次数」写 reviews 后提醒消失', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _seedDefaultDeck(tester, store, answer: true);
      await _pumpDeckList(tester, store: store, apple: apple);
      final Finder notice = find.byKey(
        const ValueKey<String>('srs-limit-unit-notice'),
      );
      expect(notice, findsOneWidget);
      await srsUntilWritten(
        tester,
        () => tester.tap(
          find.byKey(const ValueKey<String>('srs-limit-unit-accept')),
        ),
        reloads: <ProviderListenable<AsyncValue<Object?>>>[
          srsLimitUnitLegacyCountProvider,
        ],
        until: () => notice.evaluate().isEmpty,
      );
      expect(notice, findsNothing);
      final SrsDeckTree tree = await _db(tester, store.deckTree);
      expect(tree[store.defaultDeckId]!.limitUnit, SrsLimitUnit.reviews);
      expect(tree[store.defaultDeckId]!.limitUnitSet, isTrue);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表：没评过分的新库不提醒', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _seedDefaultDeck(tester, store, answer: false);
      await _pumpDeckList(tester, store: store, apple: apple);
      expect(
        find.byKey(const ValueKey<String>('srs-limit-unit-notice')),
        findsNothing,
      );
      await _unmount(tester);
    });
  }
}
