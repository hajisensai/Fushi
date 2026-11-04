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

Future<void> _answer(WidgetTester tester, int rating) async {
  await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
  await _settle(tester);
  await tester.tap(find.byKey(ValueKey<String>('srs-rate-$rating')));
  await _settle(tester, rounds: 24);
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
      await tester.tap(find.byKey(const ValueKey<String>('srs-rate-1')));
      await _settle(tester, rounds: 24);
      expect(_chip(1), findsOneWidget);
      expect(_chip(3), findsNothing);

      // 撤销：提示收起。
      await tester.tap(find.byKey(const ValueKey<String>('srs_review_undo')));
      await _settle(tester, rounds: 24);
      expect(_chip(1), findsNothing, reason: '撤销后不再声称已评');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
