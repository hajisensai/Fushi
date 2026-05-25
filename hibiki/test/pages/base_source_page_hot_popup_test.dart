import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

class HotPopupTestAppModel extends AppModel {
  HotPopupTestAppModel({this.lowMemory = false});

  final bool lowMemory;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

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
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class HotPopupHostPage extends BaseSourcePage {
  const HotPopupHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<HotPopupHostPage> createState() =>
      HotPopupHostPageState();
}

class HotPopupHostPageState extends BaseSourcePageState<HotPopupHostPage> {
  int backgroundTapCount = 0;

  Future<void> search(String term) {
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => backgroundTapCount++,
            child: const SizedBox.expand(),
          ),
        ),
        buildDictionary(),
      ],
    );
  }
}

Widget buildHotPopupTestApp({
  required AppModel appModel,
  required GlobalKey<HotPopupHostPageState> hostKey,
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
          body: HotPopupHostPage(key: hostKey),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('top-level popup is hidden and reused after close', (
    WidgetTester tester,
  ) async {
    final appModel = HotPopupTestAppModel();
    final hostKey = GlobalKey<HotPopupHostPageState>();

    await tester.pumpWidget(
      buildHotPopupTestApp(appModel: appModel, hostKey: hostKey),
    );

    await hostKey.currentState!.search('first');
    await tester.pump();

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);

    final DictionaryPopupLayer firstLayer =
        tester.widget(find.byType(DictionaryPopupLayer));

    hostKey.currentState!.clearDictionaryResult();
    await tester.pump();

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);
    expect(hostKey.currentState!.dictionaryPopupShown, isFalse);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(hostKey.currentState!.backgroundTapCount, 1);

    await hostKey.currentState!.search('second');
    await tester.pump();

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);
    expect(hostKey.currentState!.dictionaryPopupShown, isTrue);

    final DictionaryPopupLayer secondLayer =
        tester.widget(find.byType(DictionaryPopupLayer));
    expect(secondLayer.webViewKey, same(firstLayer.webViewKey));
  });

  testWidgets('low memory mode disposes top-level popup on close', (
    WidgetTester tester,
  ) async {
    final appModel = HotPopupTestAppModel(lowMemory: true);
    final hostKey = GlobalKey<HotPopupHostPageState>();

    await tester.pumpWidget(
      buildHotPopupTestApp(appModel: appModel, hostKey: hostKey),
    );

    await hostKey.currentState!.search('first');
    await tester.pump();

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);

    hostKey.currentState!.clearDictionaryResult();
    await tester.pump();

    expect(find.byType(DictionaryPopupLayer), findsNothing);
    expect(hostKey.currentState!.dictionaryPopupShown, isFalse);
  });
}
