import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// Tests BUG-092: the reader/video/audiobook (base_source_page) dictionary popup
/// keeps ONE persistent warm WebView seeded on open and reused for every lookup,
/// so there is no per-lookup WebView cold-load (the white flash). The reader's
/// pre-lookup `prunePopupStack(0)` must preserve that warm slot rather than
/// discard it.
///
/// The real [DictionaryPopupWebView] cannot instantiate its platform WebView in
/// the unit-test harness, so these tests assert the popup-stack lifecycle via
/// the `debugPopupStack` hook (the host page does not render `buildDictionary`).
/// A source-scan guard locks the WebView-mount wiring that rendering can't.
class WarmPopupTestAppModel extends AppModel {
  WarmPopupTestAppModel({this.lowMemory = false})
      : super(testPlatformServices());

  final bool lowMemory;

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
  bool get lowMemoryMode => lowMemory;

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

class WarmPopupHostPage extends BaseSourcePage {
  const WarmPopupHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<WarmPopupHostPage> createState() =>
      WarmPopupHostPageState();
}

class WarmPopupHostPageState extends BaseSourcePageState<WarmPopupHostPage> {
  Future<void> search(String term) {
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  /// Mimics the reader's text-selection lookup, which clears any prior popups
  /// via prunePopupStack(0) before searching.
  Future<void> resetThenSearch(String term) async {
    prunePopupStack(0);
    await search(term);
  }

  // Intentionally does NOT render buildDictionary(): the warm slot would mount
  // a real DictionaryPopupWebView, which the unit-test harness cannot
  // instantiate. The popup-stack lifecycle is asserted via debugPopupStack.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget buildWarmPopupTestApp({
  required AppModel appModel,
  required GlobalKey<WarmPopupHostPageState> hostKey,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: WarmPopupHostPage(key: hostKey),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('warm popup slot is seeded on open (hidden) before any lookup',
      (WidgetTester tester) async {
    final appModel = WarmPopupTestAppModel();
    final hostKey = GlobalKey<WarmPopupHostPageState>();

    await tester.pumpWidget(
      buildWarmPopupTestApp(appModel: appModel, hostKey: hostKey),
    );
    // First pump runs the post-frame seed; second settles the notifier rebuild.
    await tester.pump();
    await tester.pump();

    final stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(1));
    expect(stack.single.isWarmSlot, isTrue);
    expect(stack.single.visible, isFalse);
    expect(hostKey.currentState!.dictionaryPopupShown, isFalse);
  });

  testWidgets(
      'reader-style lookup reuses the warm slot key across prunePopupStack(0)',
      (WidgetTester tester) async {
    final appModel = WarmPopupTestAppModel();
    final hostKey = GlobalKey<WarmPopupHostPageState>();

    await tester.pumpWidget(
      buildWarmPopupTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.resetThenSearch('first');
    final firstStack = hostKey.currentState!.debugPopupStack;
    expect(firstStack, hasLength(1));
    expect(firstStack.single.visible, isTrue);
    final firstKey = firstStack.single.webViewKey;

    // A fresh reader lookup prunes to 0 first; the warm slot (and its loaded
    // WebView) must survive so the second lookup reuses the SAME webViewKey
    // rather than cold-loading a new WebView (the white flash).
    await hostKey.currentState!.resetThenSearch('second');
    final secondStack = hostKey.currentState!.debugPopupStack;
    expect(secondStack, hasLength(1));
    expect(secondStack.single.visible, isTrue);
    expect(secondStack.single.webViewKey, same(firstKey));
  });

  testWidgets('low memory mode seeds no warm slot and clears on prune',
      (WidgetTester tester) async {
    final appModel = WarmPopupTestAppModel(lowMemory: true);
    final hostKey = GlobalKey<WarmPopupHostPageState>();

    await tester.pumpWidget(
      buildWarmPopupTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    expect(hostKey.currentState!.debugPopupStack, isEmpty);

    await hostKey.currentState!.search('first');
    expect(hostKey.currentState!.debugPopupStack, hasLength(1));
    expect(hostKey.currentState!.debugPopupStack.single.isWarmSlot, isFalse);

    // ignore: invalid_use_of_protected_member  — 测试直接驱动受保护的清栈逻辑
    hostKey.currentState!.prunePopupStack(0);
    expect(hostKey.currentState!.debugPopupStack, isEmpty);
  });

  test('source guard: warm slot wiring keeps the WebView mounted and preserved',
      () {
    final base = File('lib/src/pages/base_source_page.dart').readAsStringSync();
    final layer =
        File('lib/src/pages/implementations/dictionary_popup_layer.dart')
            .readAsStringSync();

    // base_source_page passes the warm flag to the popup layer.
    expect(base.contains('keepWebViewWarm: item.isWarmSlot'), isTrue,
        reason: 'warm slot must request a persistently mounted WebView');
    // base_source_page seeds the warm slot on open via the shared controller.
    expect(base.contains('_popup.seedWarmSlot('), isTrue,
        reason: 'a persistent warm slot must be seeded via the controller');
    // prunePopupStack preserves the warm slot instead of discarding it
    // (delegated to the controller's pruneToWarmSlot).
    expect(base.contains('pruneToWarmSlot()'), isTrue,
        reason: 'prunePopupStack(0) must preserve the warm slot');
    expect(base.contains('first.isWarmSlot'), isTrue,
        reason: 'warm-slot reuse condition keys off isWarmSlot');
    // The popup layer mounts the WebView for the empty seed warm slot, while a
    // completed real empty lookup can fall through to the Flutter no-results
    // placeholder instead of exposing a blank warm WebView shell.
    expect(
        layer.contains('final bool isSeedWarmSlot = keepWebViewWarm'), isTrue,
        reason:
            'keepWebViewWarm must only force the WebView for the seed slot');
    expect(
        layer.contains('hasRenderableResults || isSearching || isSeedWarmSlot'),
        isTrue,
        reason:
            'WebView mounting must be keyed to real content, searching, or seed prewarm');
  });
}
