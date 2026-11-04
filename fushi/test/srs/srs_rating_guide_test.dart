// 复习页「评分按钮怎么选」首次说明（反馈 qQA11YJLQF）：
// - 第一次翻到答案面：评分按钮上方出说明，每颗按钮一行，与按钮同序；正面不出；
// - 只留「重来 / 良好」时只解释这两颗；
// - 点「知道了」立即收起并落偏好，下次打开复习页不再出现；
// - 偏好层没装好时不出（记不住「已看过」）。
//
// 走真实路径：内存库 + 真偏好库 → SrsReviewPage。数据库读写放 tester.runAsync。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rating_guide.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart'
    show SrsRatingTone;
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

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

final Finder _guide = find.byKey(const ValueKey<String>('srs-rating-guide'));
final Finder _showAnswer = find.byKey(
  const ValueKey<String>('srs-show-answer'),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  late FushiDatabase mainDb;
  late PreferencesRepository prefs;
  late Directory dir;

  Future<SrsDbStore> openStore(WidgetTester tester) async {
    final SrsDbStore store = (await tester.runAsync(() async {
      mainDb = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(mainDb);
      await prefs.loadFromDb();
      dir = Directory.systemTemp.createTempSync('fushi_rating_guide');
      final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
      addTearDown(
        () => tester.runAsync(() async {
          await db.close();
          await mainDb.close();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }),
      );
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '図書館',
          srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
        },
      );
      return store;
    }))!;
    return store;
  }

  Future<void> pumpReview(
    WidgetTester tester,
    SrsDbStore store, {
    bool prefsReady = true,
    bool hideHardEasy = false,
  }) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppModel app = AppModel(testPlatformServices());
    if (prefsReady) {
      app.wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          srsStoreProvider.overrideWith((Ref ref) async => store),
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => null as SrsMediaStore?,
          ),
          srsCardFaceBuilderProvider.overrideWithValue(
            (BuildContext context, SrsCardFace face) =>
                SrsPlainCardFace(face: face),
          ),
          srsReviewHideHardEasyProvider.overrideWithValue(hideHardEasy),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: SrsReviewPage(
              deckId: store.defaultDeckId,
              deckName: 'Default',
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> flip(WidgetTester tester) async {
    await tester.tap(_showAnswer);
    await _settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  List<String> rows(WidgetTester tester) => <String>[
    for (final SrsRatingTone tone in SrsRatingTone.values)
      if (find
          .byKey(ValueKey<String>('srs-rating-guide-${tone.name}'))
          .evaluate()
          .isNotEmpty)
        tone.name,
  ];

  testWidgets('第一次翻到答案面：四颗按钮各一行说明；点「知道了」收起并不再出现', (WidgetTester tester) async {
    final SrsDbStore store = await openStore(tester);
    await pumpReview(tester, store);
    expect(_guide, findsNothing, reason: '问题面不出说明');
    await flip(tester);
    expect(_guide, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(rows(tester), <String>['again', 'hard', 'good', 'easy']);
    expect(find.text(t.srs_rating_guide_good), findsOneWidget);
    // 说明在评分按钮上方。
    expect(
      tester.getRect(_guide).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey<String>('srs-rate-3'))).top,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-rating-guide-dismiss')),
    );
    await _settle(tester);
    expect(_guide, findsNothing);
    expect(
      prefs.getPref(kSrsRatingGuideDismissedPrefKey, defaultValue: false),
      isTrue,
    );
    await unmount(tester);

    // 重新打开复习页（新的 AppModel + 从数据库重读的偏好库，上一个随 AppModel 释放了）：
    // 偏好记着，不再出现。
    await tester.runAsync(() async {
      prefs = PreferencesRepository(mainDb);
      await prefs.loadFromDb();
    });
    expect(
      prefs.getPref(kSrsRatingGuideDismissedPrefKey, defaultValue: false),
      isTrue,
      reason: '「知道了」写进了数据库',
    );
    await pumpReview(tester, store);
    await flip(tester);
    expect(_guide, findsNothing);
    expect(find.byKey(const ValueKey<String>('srs-rate-3')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('只留「重来 / 良好」：只解释这两颗', (WidgetTester tester) async {
    final SrsDbStore store = await openStore(tester);
    await pumpReview(tester, store, hideHardEasy: true);
    await flip(tester);
    expect(rows(tester), <String>['again', 'good']);
    await unmount(tester);
  });

  testWidgets('偏好层没装好：不出说明（记不住已看过）', (WidgetTester tester) async {
    final SrsDbStore store = await openStore(tester);
    await pumpReview(tester, store, prefsReady: false);
    await flip(tester);
    expect(_guide, findsNothing);
    expect(find.byKey(const ValueKey<String>('srs-rate-1')), findsOneWidget);
    await unmount(tester);
  });
}
