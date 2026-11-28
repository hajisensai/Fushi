// 反馈 wJmcCQBVn1：复习页查词弹窗开着时，「关闭词典」/「返回上一级」只关一层，不退出复习。
//
// 此前复习页只认写死的 Esc：键盘闸（SrsCardLookupController.guardKey）与卡面键盘桥闸
// （guardBridgeToken）都不看注册表，复习页也没有可绑的「关闭词典」动作；弹窗挂在根 Overlay、
// 不是路由，根上的「返回上一级」/ Android 系统返回走 Navigator.maybePop，连页带弹窗一起退出。
//
// 走真实路径：内存库 + SrsReviewPage（压在一条根路由之上），弹窗经卡面的 SrsCardLookupScope 打开；
// 键盘用 sendKeyEvent，卡面键盘桥用 SrsCardFace.onBridgeKey，系统返回用 handlePopRoute。

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/popup_mining_target_overrides.dart';
import 'srs_test_support.dart';

/// 复习页 + 查词弹窗要读的 app 设置（与 srs_card_lookup_test 的 `_LookupApp` 同口径），快捷键按
/// Windows 默认表装载（[SrsTestAppModel]）。
class _App extends SrsTestAppModel {
  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  bool get lowMemoryMode => false;
  @override
  SrsCardAppearance get srsCardAppearance => const SrsCardAppearance();
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}
}

Future<DictionarySearchResult> _fakeSearch(String term, int max) async =>
    DictionarySearchResult(
      searchTerm: term,
      bestLength: term.length,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: term, reading: 'よみ', meaning: 'm'),
      ],
    );

/// 打开好的复习页：卡面拿到的查词控制器、最近一次卡面输入（键盘桥回调）、app。
typedef _Review = ({
  SrsCardLookupController Function() lookup,
  SrsCardFace Function() face,
  _App app,
});

final Finder _reviewPage = find.byType(SrsReviewPage);

Future<_Review> _pumpReview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '図書館',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'library',
      },
    ),
  );
  final _App app = _App();
  SrsCardLookupController? lookup;
  SrsCardFace? lastFace;
  final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        ...popupMiningTargetTestOverrides(),
        srsCardLookupSearchProvider.overrideWithValue(_fakeSearch),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          lastFace = face;
          return Builder(
            builder: (BuildContext context) {
              lookup = SrsCardLookupScope.of(context) ?? lookup;
              return SrsPlainCardFace(face: face);
            },
          );
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: nav,
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    ),
  );
  nav.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
    ),
  );
  await srsSettle(tester);
  expect(_reviewPage, findsOneWidget);
  expect(lookup, isNotNull, reason: '卡面应在 SrsCardLookupScope 里');
  return (lookup: () => lookup!, face: () => lastFace!, app: app);
}

Future<void> _openPopup(WidgetTester tester, SrsCardLookupController c) async {
  await c.pushNested('図書館', const Rect.fromLTWH(200, 200, 40, 20));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 2));
  expect(c.isOpen, isTrue);
}

Future<void> _settleClose(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('系统返回 / 根上的「返回上一级」（maybePop）：弹窗开着先关一层，再按才退出复习', (
    WidgetTester tester,
  ) async {
    final _Review r = await _pumpReview(tester);
    await _openPopup(tester, r.lookup());

    await tester.binding.handlePopRoute();
    await _settleClose(tester);
    expect(r.lookup().isOpen, isFalse, reason: '弹窗应关掉');
    expect(_reviewPage, findsOneWidget, reason: '弹窗开着时返回不该退出复习页');

    await tester.binding.handlePopRoute();
    await srsSettle(tester);
    expect(_reviewPage, findsNothing, reason: '弹窗关了之后返回照常退出');
  });

  testWidgets('自绑的「关闭词典」键：弹窗开着关一层；没开时不做别的', (WidgetTester tester) async {
    final _Review r = await _pumpReview(tester);
    r.app.shortcutRegistry.updateBinding(
      ShortcutAction.srsReviewDismissDict,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyQ),
        ],
      ),
    );
    await _openPopup(tester, r.lookup());

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await _settleClose(tester);
    expect(r.lookup().isOpen, isFalse);
    expect(_reviewPage, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await _settleClose(tester);
    expect(_reviewPage, findsOneWidget);
  });

  testWidgets('卡面键盘桥：改绑的「返回上一级」/「关闭词典」token 在弹窗开着时关一层', (
    WidgetTester tester,
  ) async {
    final _Review r = await _pumpReview(tester);
    r.app.shortcutRegistry.updateBinding(
      ShortcutAction.srsReviewDismissDict,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyQ),
        ],
      ),
    );
    // 默认「返回上一级」= Esc / Alt+←；用 Alt+← 的 token（不是写死的 'Escape'）。
    final String altLeft = const InputBinding(
      key: LogicalKeyboardKey.arrowLeft,
      modifiers: <ModifierKey>{ModifierKey.alt},
    ).bridgeToken;
    expect(altLeft, isNot('Escape'));
    expect(srsReviewBridgeTokens(r.app.shortcutRegistry), contains(altLeft));

    await _openPopup(tester, r.lookup());
    r.face().onBridgeKey(altLeft);
    await _settleClose(tester);
    expect(r.lookup().isOpen, isFalse, reason: 'Alt+← 应关一层');
    expect(_reviewPage, findsOneWidget);

    await _openPopup(tester, r.lookup());
    final String q = const InputBinding(
      key: LogicalKeyboardKey.keyQ,
    ).bridgeToken;
    expect(srsReviewBridgeTokens(r.app.shortcutRegistry), contains(q));
    r.face().onBridgeKey(q);
    await _settleClose(tester);
    expect(r.lookup().isOpen, isFalse, reason: '「关闭词典」键应关一层');
    expect(_reviewPage, findsOneWidget);
  });
}
