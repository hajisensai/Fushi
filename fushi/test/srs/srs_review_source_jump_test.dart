// 设计稿 11-20 #15（方案 A）：复习卡的「回到出处」不再只藏在会自动隐藏的顶栏里——
//
// - 媒体素材左下角常驻一颗胶囊「回到出处 · 定位」（拿不到定位时写来源名）；
// - 没有媒体素材的卡：例句卡右侧一个小 ↩；连例句也没有：词条行尾一个 ↩；
// - 顶栏原来的图标保留。
//
// 卡面上只画一个入口（应用内反馈 unGQ8ykXGJ，BUG-5182）：有胶囊时例句卡不再重复一个 ↩。
// 入口都落到复习页同一个跳转动作（cardSourceOpenerProvider，复习页的 _openSource）。
// 走真实路径：内存库 + 真复习页，MD3 / Apple 两套设计系统各跑一遍。

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/card_source_origin.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_source_jump.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 16×9 的灰图（铺满栏宽的常见比例）。
const String _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAIAAAC0SDtlAAAAEUlEQVR4nGNoIBEwjGoYFBoAGJ/YAfh07lQAAAAASUVORK5CYII=';

final CardSourceLink _link = CardSourceLink.tryMusic(
  trackUid: 'track-1',
  startMs: 754000,
  endMs: 758000,
)!;

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<void> _addCard(
  WidgetTester tester,
  SrsDbStore store, {
  required bool media,
  bool sentence = true,
}) async {
  String id(String field) => srsFushiCardFieldId(kSrsTestProfile, field);
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        id('Term'): 'ベランダ',
        id('TermReading'): 'ベランダ',
        id('MainDefinition'): 'veranda',
        if (sentence) id('Sentence'): '<b>ベランダ</b>をたどっていけば',
        if (media) id('Media'): '<img src="$_png">',
        id('Source'): '<a href="${_link.toUri()}">ゆるゆり</a>',
      },
    ),
  );
}

Future<List<CardSourceLink>> _pumpReview(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices())
    ..shortcutRegistry.loadDefaults(TargetPlatform.windows);
  final List<CardSourceLink> opened = <CardSourceLink>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        // 顶栏固定（不随滚动自动隐藏），顶栏那颗图标才稳定可点。
        srsReviewChromeFloatingProvider.overrideWithValue(false),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        cardSourceOpenerProvider.overrideWithValue(({
          required WidgetRef ref,
          required CardSourceLink link,
        }) async {
          opened.add(link);
        }),
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
  await srsSettle(tester, minRounds: 12);
  // 翻面（空格，焦点驱动）：背面才有媒体与例句卡。
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await srsSettle(tester, minRounds: 12);
  return opened;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('按钮文字：有定位写定位，没有写来源名，都没有只写「回到出处」', () {
    expect(
      cardSourceJumpLabel(locator: 'Ep. 3 · 12:34', title: 'X'),
      '${t.card_source_open} · Ep. 3 · 12:34',
    );
    expect(
      cardSourceJumpLabel(locator: null, title: 'ゆるゆり'),
      '${t.card_source_open} · ゆるゆり',
    );
    expect(cardSourceJumpLabel(), t.card_source_open);
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 有媒体素材：卡面只画媒体胶囊（例句卡不再重复 ↩），与顶栏图标同一个跳转', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _addCard(tester, store, media: true);
      // 宽窗：顶栏动作平铺（手机宽度下 MD3 顶栏把低优先级动作收进「⋯」）。
      final List<CardSourceLink> opened = await _pumpReview(
        tester,
        store: store,
        apple: apple,
        size: const Size(1100, 900),
      );

      final Finder pill = find.byKey(
        const ValueKey<String>('srs-card-source-jump-pill'),
      );
      final Finder button = find.byKey(
        const ValueKey<String>('srs-card-source-jump-button'),
      );
      final Finder topBar = find.byKey(
        const ValueKey<String>('srs_review_open_source'),
      );
      expect(pill, findsOneWidget);
      expect(button, findsNothing, reason: '卡面上只留一个「回到出处」入口：有媒体胶囊时例句卡不画 ↩');
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
        findsOneWidget,
        reason: '例句卡照常显示，只是不带 ↩',
      );
      expect(topBar, findsOneWidget, reason: '顶栏图标保留（快捷入口）');

      // 胶囊压在媒体素材左下角，写明会跳到哪（音乐出处的定位 = 时间点）。
      final Rect media = tester.getRect(
        find.byKey(const ValueKey<String>('srs-fushi-picture')),
      );
      final Rect pillRect = tester.getRect(find.byType(SrsCardSourceJumpPill));
      expect(pillRect.left, moreOrLessEquals(media.left, epsilon: 0.5));
      expect(pillRect.bottom, moreOrLessEquals(media.bottom, epsilon: 0.5));
      expect(
        find.descendant(
          of: pill,
          matching: find.text('${t.card_source_open} · 12:34'),
        ),
        findsOneWidget,
      );
      // 读屏朗读与可见文字一致（不只读「回到出处」）。
      expect(
        tester.getSemantics(pill),
        containsSemantics(
          label: '${t.card_source_open} · 12:34',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(pill);
      await tester.pump();
      await tester.tap(topBar);
      await tester.pump();
      expect(opened, hasLength(2));
      for (final CardSourceLink l in opened) {
        expect(l.toUri(), _link.toUri());
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('[$ds] 没有媒体素材的卡：例句卡 ↩ 照样能回到出处', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addCard(tester, store, media: false);
      final List<CardSourceLink> opened = await _pumpReview(
        tester,
        store: store,
        apple: apple,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-card-source-jump-pill')),
        findsNothing,
      );
      final Finder button = find.byKey(
        const ValueKey<String>('srs-card-source-jump-button'),
      );
      expect(button, findsOneWidget, reason: '卡面上恰好一个入口');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
          matching: button,
        ),
        findsOneWidget,
        reason: '↩ 在例句卡右侧',
      );
      await tester.tap(button);
      await tester.pump();
      expect(opened.single.toUri(), _link.toUri());
      await _unmount(tester);
    });

    testWidgets('[$ds] 既没有媒体也没有例句的卡：↩ 落在词条行尾', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addCard(tester, store, media: false, sentence: false);
      final List<CardSourceLink> opened = await _pumpReview(
        tester,
        store: store,
        apple: apple,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-card-source-jump-pill')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-fushi-sentence-block')),
        findsNothing,
      );
      final Finder button = find.byKey(
        const ValueKey<String>('srs-card-source-jump-button'),
      );
      expect(button, findsOneWidget, reason: '没有句子的卡也有且只有一个入口');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-fushi-header')),
          matching: button,
        ),
        findsOneWidget,
        reason: '↩ 在词条区（词条 + 读音）行尾',
      );
      await tester.tap(button);
      await tester.pump();
      expect(opened.single.toUri(), _link.toUri());
      await _unmount(tester);
    });
  }
}
