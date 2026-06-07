import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-094: the video player seeds one persistent hidden warm popup slot and
/// reuses it for every lookup (via [DictionaryPageMixin.pushNestedPopup] with
/// `reuseWarmSlot: true`), so the popup WebView is never cold-loaded per lookup.
/// These tests exercise the shared mixin reuse contract directly (the real
/// VideoHibikiPage needs media_kit, which is unavailable in the test harness).
class MixinTestAppModel extends AppModel {
  MixinTestAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class MixinHostPage extends ConsumerStatefulWidget {
  const MixinHostPage({super.key});

  @override
  ConsumerState<MixinHostPage> createState() => MixinHostPageState();
}

class MixinHostPageState extends ConsumerState<MixinHostPage>
    with DictionaryPageMixin {
  final List<DictionaryPopupEntry> stack = <DictionaryPopupEntry>[];

  @override
  AppModel get mixinAppModel => ref.read(appProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  /// Mirror VideoHibikiPage._seedWarmPopup.
  void seedWarmSlot() {
    final DictionaryPopupEntry warm = DictionaryPopupEntry(
      searchTerm: '',
      selectionRect: Rect.zero,
      visible: false,
      isWarmSlot: true,
    )..isSearching = false;
    setState(() => stack.add(warm));
  }

  Future<void> lookup(String term) => pushNestedPopup(
        query: term,
        selectionRect: const Rect.fromLTWH(20, 20, 4, 4),
        popupStack: stack,
        replaceStack: true,
        reuseWarmSlot: true,
        autoRead: false,
      );

  void pushChild(String term) => pushNestedPopup(
        query: term,
        selectionRect: const Rect.fromLTWH(30, 30, 4, 4),
        popupStack: stack,
        autoRead: false,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: <Widget>[
            for (int i = 0; i < stack.length; i++)
              buildNestedPopupLayer(
                index: i,
                screen: screen,
                popupStack: stack,
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
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('reuseWarmSlot reuses the seeded warm slot (same webViewKey)',
      (WidgetTester tester) async {
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(wrap(MixinTestAppModel(), key));
    key.currentState!.seedWarmSlot();
    await tester.pump();

    final state = key.currentState!;
    expect(state.stack, hasLength(1));
    expect(state.stack.single.isWarmSlot, isTrue);
    expect(state.stack.single.visible, isFalse);
    final warmKey = state.stack.single.webViewKey;

    await state.lookup('一');
    await tester.pump();

    // Same warm slot object/key reused (not a fresh entry) and now visible.
    expect(state.stack, hasLength(1));
    expect(state.stack.single.webViewKey, same(warmKey));
    expect(state.stack.single.isWarmSlot, isTrue);
    expect(state.stack.single.visible, isTrue);

    await state.lookup('二');
    await tester.pump();
    expect(state.stack, hasLength(1));
    expect(state.stack.single.webViewKey, same(warmKey));
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
    final warmKey = state.stack.first.webViewKey;

    state.pushChild('子');
    await tester.pump();
    expect(state.stack.length, greaterThan(1));

    await state.lookup('新');
    await tester.pump();
    // Children dropped, warm slot (same key) survives.
    expect(state.stack, hasLength(1));
    expect(state.stack.single.webViewKey, same(warmKey));
    expect(state.stack.single.visible, isTrue);
  });

  testWidgets('without a warm slot, reuseWarmSlot falls back to a fresh entry',
      (WidgetTester tester) async {
    // Mirrors low-memory mode (no seed): a fresh entry is created each lookup.
    final key = GlobalKey<MixinHostPageState>();
    await tester.pumpWidget(wrap(MixinTestAppModel(), key));
    await tester.pump();

    final state = key.currentState!;
    expect(state.stack, isEmpty);
    await state.lookup('語');
    await tester.pump();
    expect(state.stack, hasLength(1));
    expect(state.stack.single.isWarmSlot, isFalse);
  });
}
