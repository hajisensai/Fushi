// 反馈 gvyN7EzzDD：评分后退出复习页、再进来，「撤销」不可用（Anki 可以）。
//
// 根因：撤销栈是 `_SrsReviewPageState` 的字段，页面 dispose 整栈即丢。现在挂在 store 上
// （srs_review_undo.dart）。走真实复习页 + 内存库：评一张 → 卸掉复习页 → 用同一个 store
// 重新挂一个复习页 → 撤销键在、按下后评分日志被撤、回到那张卡。数据库读写放 tester.runAsync。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_undo.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
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
  for (final String word in <String>['試合', '練習']) {
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
            glassDesign: false,
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

final Finder _undoButton = find.byKey(
  const ValueKey<String>('srs_review_undo'),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('rate → leave the review page → re-enter: undo is still '
      'available and reverts the rating', (WidgetTester tester) async {
    final SrsDbStore store = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(tester, store: store, faces: faces);
    expect(_undoButton, findsNothing, reason: '还没评过：没有撤销键');

    final String rated = faces.last.cardId;
    await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
    await _settle(tester, rounds: 24);
    expect(faces.last.cardId, isNot(rated), reason: '评分后换到下一张');
    expect(
      (await tester.runAsync(() => store.history(rated)))!.lastEffective,
      isNotNull,
    );

    // 退出复习页（State dispose），再用同一个 store 进来。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    faces.clear();
    await _pumpReview(tester, store: store, faces: faces);

    expect(_undoButton, findsOneWidget, reason: '重新进入后仍可撤销上一次评分');
    await tester.tap(_undoButton);
    await _settle(tester, rounds: 24);
    final SrsCardHistory after = (await tester.runAsync(
      () => store.history(rated),
    ))!;
    expect(after.lastEffective, isNull, reason: '评分已撤销');
    expect(faces.last.cardId, rated, reason: '撤销带回被撤的那张');
    expect(_undoButton, findsNothing, reason: '栈空了');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  test('undo stack belongs to one store instance and is bounded', () async {
    final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore();
    final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore();
    addTearDown(dbA.close);
    addTearDown(dbB.close);
    final SrsReviewUndoStack stackA = SrsReviewUndoStack.of(a);
    expect(identical(stackA, SrsReviewUndoStack.of(a)), isTrue);
    for (int i = 0; i < kSrsReviewUndoLimit + 5; i++) {
      stackA.push(SrsReviewUndoStep(cardId: 'c$i', logId: 'l$i'));
    }
    expect(stackA.length, kSrsReviewUndoLimit);
    expect(stackA.pop()!.cardId, 'c${kSrsReviewUndoLimit + 4}');
    // 切 profile 换了 store：新 store 不继承旧栈，撤不到别的库上。
    expect(SrsReviewUndoStack.of(b).isEmpty, isTrue);
  });
}
