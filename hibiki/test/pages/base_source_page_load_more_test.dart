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

/// TODO-962: the reader / audiobook (base_source_page) dictionary popup used to
/// hard-code `allLoaded: true` and never wired `onScrolledToBottom`, so the
/// popup was stuck on the first page (`maximumTerms`). Because `maximumTerms`
/// budgets by glossary **lines**, a single high-frequency headword's glossary
/// could eat the whole budget, leaving just 1 headword — while the home tab and
/// the video popup paged correctly (the only difference was this flag + the
/// load-more wiring).
///
/// These tests assert, via the `debugPopupStack` hook + the public
/// `loadMoreForLayer` entry point (the real [DictionaryPopupWebView] cannot be
/// instantiated in the unit-test harness), that:
///   (a) a truncated first page reports `allLoaded == false`;
///   (b) `loadMoreForLayer` grows the headword count;
///   (c) reaching the real end flips `allLoaded` back to true.
/// A source-scan guard locks the `onScrolledToBottom` wiring rendering can't.

/// Builds [count] distinct term entries (one headword each).
List<DictionaryEntry> _buildEntries(int count) {
  return List<DictionaryEntry>.generate(
    count,
    (int i) => DictionaryEntry(
      dictionaryName: 'dict',
      word: 'word$i',
      reading: 'reading$i',
      // A multi-line glossary mimics a high-frequency headword whose many
      // gloss lines eat the line-budget — the very shape that left only 1
      // headword before the fix. (The page only counts entries, so the line
      // count here is illustrative, not load-bearing for the assertions.)
      meaning: 'line a\nline b\nline c',
    ),
  );
}

class LoadMoreTestAppModel extends AppModel {
  LoadMoreTestAppModel({required this.totalAvailable})
      : super(testPlatformServices());

  /// Total headwords the (fake) dictionary can return for the query. A request
  /// with `overrideMaximumTerms < totalAvailable` is truncated (allLoaded
  /// false); once the cap reaches/exceeds it the full set returns (allLoaded
  /// true), exactly like the real FFI lookup honoring the cap.
  final int totalAvailable;

  int lastOverrideMaximumTerms = 0;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  // autoReadOnLookup defaults true; with non-empty results the lookup auto-reads
  // the first entry, which resolves audio via [audioSourceConfigs] → prefsRepo
  // (not wired in this fake). Return no sources so the auto-read resolves to no
  // audio instead of NPE-ing on prefsRepo — load-more behaviour is unaffected.
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

  @override
  bool get lowMemoryMode => false;

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
    final int cap = overrideMaximumTerms ?? maximumTerms;
    lastOverrideMaximumTerms = cap;
    final int n = cap < totalAvailable ? cap : totalAvailable;
    return DictionarySearchResult(
      searchTerm: searchTerm,
      entries: _buildEntries(n),
    );
  }
}

class LoadMoreHostPage extends BaseSourcePage {
  const LoadMoreHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<LoadMoreHostPage> createState() =>
      LoadMoreHostPageState();
}

class LoadMoreHostPageState extends BaseSourcePageState<LoadMoreHostPage> {
  Future<void> search(String term) {
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  // Does NOT render buildDictionary(): the warm slot would mount a real
  // DictionaryPopupWebView the harness cannot instantiate. The popup-stack
  // lifecycle is asserted via debugPopupStack + loadMoreForLayer.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _buildApp({
  required AppModel appModel,
  required GlobalKey<LoadMoreHostPageState> hostKey,
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
          body: LoadMoreHostPage(key: hostKey),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'truncated first page reports allLoaded=false (not hard-coded true)',
      (WidgetTester tester) async {
    // 25 available, cap 10 → first page is truncated.
    final appModel = LoadMoreTestAppModel(totalAvailable: 25);
    final hostKey = GlobalKey<LoadMoreHostPageState>();

    await tester.pumpWidget(_buildApp(appModel: appModel, hostKey: hostKey));
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.search('高');
    final stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(1));
    expect(stack.single.entryCount, 10);
    expect(stack.single.allLoaded, isFalse,
        reason: 'a truncated first page must keep load-more open');
  });

  testWidgets('full first page reports allLoaded=true',
      (WidgetTester tester) async {
    // Only 4 available, cap 10 → full set fits the first page.
    final appModel = LoadMoreTestAppModel(totalAvailable: 4);
    final hostKey = GlobalKey<LoadMoreHostPageState>();

    await tester.pumpWidget(_buildApp(appModel: appModel, hostKey: hostKey));
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.search('稀');
    final stack = hostKey.currentState!.debugPopupStack;
    expect(stack.single.entryCount, 4);
    expect(stack.single.allLoaded, isTrue,
        reason: 'a non-truncated first page must close load-more');
  });

  testWidgets('loadMoreForLayer grows the headword count and ends correctly',
      (WidgetTester tester) async {
    // 25 available: page 1 = 10, page 2 = 20, page 3 = 25 (then allLoaded).
    final appModel = LoadMoreTestAppModel(totalAvailable: 25);
    final hostKey = GlobalKey<LoadMoreHostPageState>();

    await tester.pumpWidget(_buildApp(appModel: appModel, hostKey: hostKey));
    await tester.pump();
    await tester.pump();

    final state = hostKey.currentState!;
    await state.search('高');
    expect(state.debugPopupStack.single.entryCount, 10);
    expect(state.debugPopupStack.single.allLoaded, isFalse);

    // Simulate the popup scrolling to the bottom (onScrolledToBottom →
    // loadMoreForLayer) — the headword count must grow, not stay stuck at 1/10.
    await state.loadMoreForLayer(0);
    expect(state.debugPopupStack.single.entryCount, 20);
    expect(state.debugPopupStack.single.allLoaded, isFalse);

    await state.loadMoreForLayer(0);
    expect(state.debugPopupStack.single.entryCount, 25);
    expect(state.debugPopupStack.single.allLoaded, isTrue,
        reason: 'reaching the real end must flip allLoaded true');

    // A further load-more is a no-op once allLoaded.
    await state.loadMoreForLayer(0);
    expect(state.debugPopupStack.single.entryCount, 25);
  });

  test('source guard: base_source_page wires onScrolledToBottom to load-more',
      () {
    final base = File('lib/src/pages/base_source_page.dart').readAsStringSync();

    // allLoaded is computed from the real truncation, no longer hard-coded true.
    expect(
        base.contains(
            'allLoaded: dictionaryResult.entries.length < overrideMaximumTerms'),
        isTrue,
        reason: 'allLoaded must reflect real truncation, not be hard-coded');
    // The popup layer receives a non-null onScrolledToBottom when not allLoaded.
    expect(
        base.contains('item.allLoaded ? null : () => loadMoreForLayer(index)'),
        isTrue,
        reason:
            'the popup layer must wire onScrolledToBottom to loadMoreForLayer');
    // load-more re-queries with a grown cap and refills the same layer.
    expect(base.contains('Future<void> loadMoreForLayer(int index)'), isTrue,
        reason: 'a loadMoreForLayer entry point must exist');
    expect(
        base.contains('current.entries.length + appModel.maximumTerms'), isTrue,
        reason:
            'load-more must grow the cap by maximumTerms from current size');
  });
}
