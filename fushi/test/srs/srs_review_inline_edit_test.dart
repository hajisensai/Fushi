// 复习时编辑（反馈 cbzyXZlK-t / yrXhexdOaR）：开关开着时答案面多一排编辑键；卡面上选中文字 → 加粗 /
// 清除写回对应字段（修改记录），撤销改回原值；开关关着时没有编辑键、卡面不上报选区。
//
// 走真实复习页 + 内存库；widget 测试里没有 WebView，卡面换成纯文本实现并记下每次的 face，选区经
// face.onEditSelection 注入（与页内 selectionchange 脚本 / 原生 SelectionArea 上报的是同一个回调）。
// 数据库读写一律放 tester.runAsync。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_edit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

String get _defField => srsLapisFieldId(kSrsTestProfile, 'MainDefinition');

/// 不出声的宿主音频（测试里不碰真播放器）。
class _SilentAudio implements SrsCardAudioOutput {
  @override
  Future<String?> resolve(String name) => Future<String?>.value(null);

  @override
  Future<bool> playToEnd(String path) => Future<bool>.value(true);

  @override
  Future<void> stop() async {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<(SrsDbStore, String)> _seed(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  final String noteId = (await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '試合',
        _defField: 'a formal match',
      },
    ),
  ))!;
  return (store, noteId);
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required List<SrsCardFace> faces,
  required bool inlineEdit,
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
        srsReviewInlineEditProvider.overrideWithValue(inlineEdit),
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

Future<void> _showAnswer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
  await _settle(tester);
}

Future<String> _definition(
  WidgetTester tester,
  SrsDbStore store,
  String noteId,
) async => (await tester.runAsync(() => store.note(noteId)))!.field(_defField);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('selection on the card back → bold / clear written to the '
      'field, undo restores it', (WidgetTester tester) async {
    final (SrsDbStore store, String noteId) = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(tester, store: store, faces: faces, inlineEdit: true);
    await _showAnswer(tester);

    final Finder bold = find.byKey(
      const ValueKey<String>('srs-review-edit-bold'),
    );
    expect(bold, findsOneWidget);
    expect(faces.last.showingAnswer, isTrue);
    expect(faces.last.onEditSelection, isNotNull);

    // 没选中文字：格式键不可按，字段不变。
    await tester.tap(bold);
    await _settle(tester);
    expect(await _definition(tester, store, noteId), 'a formal match');

    faces.last.onEditSelection!(const SrsCardSelection('formal'));
    await tester.pump();
    await tester.tap(bold);
    await _settle(tester, rounds: 20);
    expect(await _definition(tester, store, noteId), 'a <b>formal</b> match');
    // 原地刷新：仍在答案面。
    expect(faces.last.showingAnswer, isTrue);

    faces.last.onEditSelection!(const SrsCardSelection('formal match'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-review-edit-clear')),
    );
    await _settle(tester, rounds: 20);
    expect(await _definition(tester, store, noteId), 'a formal match');

    // 撤销两步：先回到加粗，再回到原值。
    await tester.tap(find.byKey(const ValueKey<String>('srs_review_undo')));
    await _settle(tester, rounds: 20);
    expect(await _definition(tester, store, noteId), 'a <b>formal</b> match');
    await tester.tap(find.byKey(const ValueKey<String>('srs_review_undo')));
    await _settle(tester, rounds: 20);
    expect(await _definition(tester, store, noteId), 'a formal match');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('switch off: no edit keys and the card face does not report '
      'selections', (WidgetTester tester) async {
    final (SrsDbStore store, _) = await _seed(tester);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    await _pumpReview(tester, store: store, faces: faces, inlineEdit: false);
    await _showAnswer(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-review-edit-bar')),
      findsNothing,
    );
    expect(faces.last.onEditSelection, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
