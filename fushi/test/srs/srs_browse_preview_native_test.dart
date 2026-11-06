// 浏览页卡片预览与复习页同一个卡面：内置 Fushi 卡片走原生 + 释义 WebView 的混合卡面
// （复习页的判据 [SrsRenderedCard.fushiCardDefinitions]），其余笔记类型整面 WebView。
// 以前预览一律整面 WebView，Fushi 卡片在预览里与复习时长得不一样（反馈 satv-DI70B）。
//
// 走真实路径：内存库 → SrsDbStore.renderCard → SrsBrowsePreview。数据库读写放 tester.runAsync。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
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

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<SrsDbStore> openStore(WidgetTester tester) async {
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    return store;
  }

  Future<String> cardOf(
    WidgetTester tester,
    SrsDbStore store,
    String noteTypeId,
    Map<String, String> fieldsById,
  ) async {
    final String note = (await tester.runAsync(
      () => store.createNote(noteTypeId: noteTypeId, fieldsById: fieldsById),
    ))!;
    return (await tester.runAsync(() => store.cardsOfNote(note)))!.first.id;
  }

  Future<List<SrsCardFace>> pump(
    WidgetTester tester,
    SrsDbStore store,
    String cardId, {
    required bool showAnswer,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<SrsCardFace> webFaces = <SrsCardFace>[];
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
            webFaces.add(face);
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
            home: Scaffold(
              body: SrsBrowsePreview(
                cardId: cardId,
                revision: 0,
                showAnswer: showAnswer,
                onCommand: (_) {},
                onEdit: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    return webFaces;
  }

  for (final bool answer in <bool>[false, true]) {
    final String side = answer ? '背面' : '正面';

    testWidgets('Fushi 卡片$side：预览走与复习页同一个原生卡面', (WidgetTester tester) async {
      final SrsDbStore store = await openStore(tester);
      final String card = await cardOf(
        tester,
        store,
        store.fushiCardNoteTypeId,
        <String, String>{
          srsFushiCardFieldId(kSrsTestProfile, 'Expression'): 'キャッチ',
          srsFushiCardFieldId(kSrsTestProfile, 'MainDefinition'): 'catch',
          srsFushiCardFieldId(kSrsTestProfile, 'Sentence'): 'アタシが<b>キャッチ</b>。',
        },
      );
      final SrsRenderedCard? rendered = await tester.runAsync<SrsRenderedCard?>(
        () => store.renderCard(card),
      );
      // 前提：复习页对这张卡走原生（判据非 null）。
      expect(rendered?.fushiCardDefinitions, isNotNull);
      final List<SrsCardFace> webFaces = await pump(
        tester,
        store,
        card,
        showAnswer: answer,
      );
      final Finder native = find.byKey(
        const ValueKey<String>('srs-browse-preview-native'),
      );
      expect(native, findsOneWidget);
      final SrsFushiCardView view = tester.widget<SrsFushiCardView>(native);
      expect(view.face.showingAnswer, answer);
      expect(view.definitionsHtml, rendered!.fushiCardDefinitions);
      // 整面 WebView 不再画整张卡（只剩原生卡面里的释义区，不是整面 HTML）。
      expect(
        webFaces.where(
          (SrsCardFace f) =>
              f.bodyHtml == (answer ? rendered.answer : rendered.question),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('其他笔记类型（Lapis）：照旧整面 WebView', (WidgetTester tester) async {
    final SrsDbStore store = await openStore(tester);
    final String card =
        await cardOf(tester, store, store.lapisNoteTypeId, <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '図書館',
          srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
        });
    final List<SrsCardFace> webFaces = await pump(
      tester,
      store,
      card,
      showAnswer: false,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-browse-preview-native')),
      findsNothing,
    );
    expect(find.byType(SrsFushiCardView), findsNothing);
    expect(webFaces, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
