// 反馈 fiTLYrWbDW：复习点评分后界面直接换下一张，没有任何结果提示，看不出点的是哪一档。
//
// 现在：评分后下一张的问题面卡面底部出一枚「已评：良好 · …后到期」胶囊（SrsRatedFeedbackChip），
// 配色与那颗评分按钮同一套（MD3 / Apple 两套各自的色调），翻面 / 撤销时收起。
// 走真实复习页 + 内存库；MD3 与 Apple（glassDesign）两套都跑。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart'
    show SrsRatingTone, srsRatingColors;
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/misc/notice_dwell.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

class _SilentAudio implements SrsCardAudioOutput {
  @override
  Future<String?> resolve(String name) => Future<String?>.value(null);

  @override
  Future<bool> playToEnd(String path) => Future<bool>.value(true);

  @override
  Future<void> stop() async {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 16}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<SrsDbStore> _seed(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  for (final String word in <String>['試合', '練習', '勉強']) {
    await tester.runAsync(
      () => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): word,
          srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'def $word',
        },
      ),
    );
  }
  return store;
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required List<SrsCardFace> faces,
  required bool apple,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith(
          (Ref ref) => Future<SrsDbStore?>.value(store),
        ),
        srsCardAudioOutputProvider.overrideWithValue(_SilentAudio()),
        srsReviewChromeFloatingProvider.overrideWithValue(false),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          faces.add(face);
          return SrsPlainCardFace(face: face);
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
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

Finder _chip(int rating) =>
    find.byKey(ValueKey<String>('srs-rated-chip-$rating'));

/// 一帧帧推进到 [finder] 出现为止（评分后下一张卡异步载入，提示随之出现）；
/// 出现即停，不多推时间——提示本身只停留 [FushiNoticeDwell.flash]。
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget, reason: '评分后提示应出现');
}

Future<void> _rate(WidgetTester tester, int rating) async {
  await tester.tap(find.byKey(ValueKey<String>('srs-rate-$rating')));
  await _pumpUntilFound(tester, _chip(rating));
}

Future<void> _answer(WidgetTester tester, int rating) async {
  await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
  await _settle(tester);
  await _rate(tester, rating);
}

/// 走完退场动画（[FushiMotion.micro]）。
Future<void> _pumpExit(WidgetTester tester) async {
  await tester.pump(FushiMotion.micro);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    testWidgets('apple=$apple: rating shows which grade was picked on the '
        'next card, in that grade\'s colours; flipping hides it', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _seed(tester);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(tester, store: store, faces: faces, apple: apple);
      for (int r = 1; r <= 4; r++) {
        expect(_chip(r), findsNothing, reason: '还没评过：不出提示');
      }

      await _answer(tester, 3);
      expect(_chip(3), findsOneWidget, reason: '评「良好」后出良好提示');
      expect(
        find.descendant(
          of: _chip(3),
          matching: find.textContaining(t.srs_rating_good),
        ),
        findsOneWidget,
      );
      // 配色与「良好」评分按钮同一套。
      final BuildContext ctx = tester.element(_chip(3));
      final ShapeDecoration deco =
          tester.widget<DecoratedBox>(_chip(3)).decoration as ShapeDecoration;
      expect(
        deco.color,
        srsRatingColors(
          SrsRatingTone.good,
          Theme.of(ctx).colorScheme,
          apple: isGlassDesign(ctx),
        ).background,
      );
      expect(isGlassDesign(ctx), apple);

      // 翻面：提示收起（走完退场动画）。
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(_chip(3), findsNothing, reason: '翻面后收起');

      // 再评「重来」：提示换成重来。
      await _rate(tester, 1);
      expect(_chip(1), findsOneWidget);
      expect(_chip(3), findsNothing);

      // 撤销：提示收起。
      await tester.tap(find.byKey(const ValueKey<String>('srs_review_undo')));
      await _settle(tester, rounds: 24);
      expect(_chip(1), findsNothing, reason: '撤销后不再声称已评');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('apple=$apple: the rated chip only flashes — it hides by '
        'itself after FushiNoticeDwell.flash while the question stays up '
        '(feedback vKGS1y9-v2)', (WidgetTester tester) async {
      final SrsDbStore store = await _seed(tester);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await _pumpReview(tester, store: store, faces: faces, apple: apple);

      await _answer(tester, 1);
      expect(_chip(1), findsOneWidget, reason: '评分后先闪出提示');
      expect(
        find.byKey(const ValueKey<String>('srs-show-answer')),
        findsOneWidget,
        reason: '仍停在下一张的问题面（没翻面）',
      );

      // 还没满停留时长：仍在。
      await tester.pump(
        FushiNoticeDwell.flash - const Duration(milliseconds: 200),
      );
      expect(_chip(1), findsOneWidget, reason: '停留未满不收');

      // 停留满 + 退场：自行收起，问题面不动。
      await tester.pump(const Duration(milliseconds: 200));
      await _pumpExit(tester);
      expect(_chip(1), findsNothing, reason: '闪一下就收，不一直挂到翻面');
      expect(
        find.byKey(const ValueKey<String>('srs-show-answer')),
        findsOneWidget,
      );

      // 同一次评分的重建不让它再冒出来；下一次评分重新闪。
      await tester.pump(const Duration(seconds: 2));
      expect(_chip(1), findsNothing);
      await _answer(tester, 4);
      expect(_chip(4), findsOneWidget, reason: '新的一次评分重新闪');
      await tester.pump(FushiNoticeDwell.flash);
      await _pumpExit(tester);
      expect(_chip(4), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
