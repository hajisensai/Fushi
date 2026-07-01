import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// BUG-094: the video player seeds one persistent hidden warm popup slot and
/// reuses it for every lookup (via [DictionaryPageMixin.pushNestedPopup] with
/// `reuseWarmSlot: true`), so the popup WebView is never cold-loaded per lookup.
/// These tests exercise the shared mixin reuse contract directly (the real
/// VideoHibikiPage needs media_kit, which is unavailable in the test harness).
class MixinTestAppModel extends AppModel {
  MixinTestAppModel({this.results = const <DictionaryEntry>[]})
      : super(testPlatformServices());

  final List<DictionaryEntry> results;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  // TODO-108: popupBottomDocked 读 prefsRepo（本 fake 未 wire），与现有
  // popupMaxWidth/Height 同属弹窗布局路径，照例覆写避免 prefsRepo 空指针。
  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm, entries: results);
  }
}

class MixinHostPage extends ConsumerStatefulWidget {
  const MixinHostPage({super.key});

  @override
  ConsumerState<MixinHostPage> createState() => MixinHostPageState();
}

class MixinHostPageState extends ConsumerState<MixinHostPage>
    with DictionaryPageMixin {
  final DictionaryPopupController controller =
      DictionaryPopupController(lowMemory: false);

  @override
  AppModel get mixinAppModel => ref.read(appProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  /// Mirror VideoHibikiPage._seedWarmPopup.
  void seedWarmSlot() {
    setState(() => controller.seedWarmSlot());
  }

  Future<void> lookup(String term) => pushNestedPopup(
        query: term,
        selectionRect: const Rect.fromLTWH(20, 20, 4, 4),
        controller: controller,
        replaceStack: true,
        reuseWarmSlot: true,
        autoRead: false,
      );

  void pushChild(String term) => pushNestedPopup(
        query: term,
        selectionRect: const Rect.fromLTWH(30, 30, 4, 4),
        controller: controller,
        autoRead: false,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: <Widget>[
            for (int i = 0; i < controller.entries.length; i++)
              buildNestedPopupLayer(
                index: i,
                screen: screen,
                controller: controller,
                onPush: (text, rect) {},
                onPop: (index) {},
              ),
          ],
        );
      },
    );
  }
}

Widget wrap(AppModel appModel, GlobalKey<MixinHostPageState> key) {
  return ProviderScope(
    overrides: [appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: MixinHostPage(key: key)),
      ),
    ),
  );
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('reuseWarmSlot reuses the seeded warm slot (same webViewKey)',
      (WidgetTester tester) async {
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(wrap(MixinTestAppModel(), key));
    key.currentState!.seedWarmSlot();
    await tester.pump();

    final state = key.currentState!;
    expect(state.controller.entries, hasLength(1));
    expect(state.controller.entries.single.isWarmSlot, isTrue);
    expect(state.controller.entries.single.visible, isFalse);
    final warmKey = state.controller.entries.single.webViewKey;

    await state.lookup('一');
    await tester.pump();

    // Same warm slot object/key reused (not a fresh entry) and now visible.
    expect(state.controller.entries, hasLength(1));
    expect(state.controller.entries.single.webViewKey, same(warmKey));
    expect(state.controller.entries.single.isWarmSlot, isTrue);
    expect(state.controller.entries.single.visible, isTrue);

    await state.lookup('二');
    await tester.pump();
    expect(state.controller.entries, hasLength(1));
    expect(state.controller.entries.single.webViewKey, same(warmKey));
  });

  testWidgets(
      'reuseWarmSlot with entries waits for popupRendered before reveal',
      (WidgetTester tester) async {
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(
      wrap(
        MixinTestAppModel(
          results: <DictionaryEntry>[
            DictionaryEntry(word: '語', reading: 'ご', meaning: 'word'),
          ],
        ),
        key,
      ),
    );
    key.currentState!.seedWarmSlot();
    await tester.pump();

    final state = key.currentState!;
    final warmKey = state.controller.entries.single.webViewKey;

    await state.lookup('語');
    await tester.pump();

    final entry = state.controller.entries.single;
    expect(entry.webViewKey, same(warmKey));
    expect(entry.isWarmSlot, isTrue);
    expect(entry.visible, isFalse,
        reason: 'Renderable warm-slot results must wait for popupRendered '
            'instead of exposing a possibly stale hidden WebView.');
    expect(entry.revealOnRender, isTrue);
    expect(state.controller.isSearchingUi, isTrue,
        reason: 'The lightweight placeholder stays up while the WebView '
            'renders off-screen.');

    expect(state.controller.revealRendered(entry), isTrue);
    state.controller.endSearchUi();
    await tester.pump();

    expect(entry.visible, isTrue);
    expect(entry.revealOnRender, isFalse);
    expect(state.controller.isSearchingUi, isFalse);
  });

  testWidgets('reuseWarmSlot drops nested children but keeps the warm WebView',
      (WidgetTester tester) async {
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(wrap(MixinTestAppModel(), key));
    key.currentState!.seedWarmSlot();
    await tester.pump();

    final state = key.currentState!;
    await state.lookup('親');
    await tester.pump();
    final warmKey = state.controller.entries.first.webViewKey;

    state.pushChild('子');
    await tester.pump();
    expect(state.controller.entries.length, greaterThan(1));

    await state.lookup('新');
    await tester.pump();
    // Children dropped, warm slot (same key) survives.
    expect(state.controller.entries, hasLength(1));
    expect(state.controller.entries.single.webViewKey, same(warmKey));
    expect(state.controller.entries.single.visible, isTrue);
  });

  testWidgets('without a warm slot, reuseWarmSlot falls back to a fresh entry',
      (WidgetTester tester) async {
    // Mirrors low-memory mode (no seed): a fresh entry is created each lookup.
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(wrap(MixinTestAppModel(), key));
    await tester.pump();

    final state = key.currentState!;
    expect(state.controller.entries, isEmpty);
    await state.lookup('語');
    await tester.pump();
    expect(state.controller.entries, hasLength(1));
    expect(state.controller.entries.single.isWarmSlot, isFalse);
  });
}
