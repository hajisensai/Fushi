import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/popup_mining_target_overrides.dart';

/// 反馈 K9YPrjtZE1：Android 平板（668×1070 逻辑像素）上 app 外查词浮卡近乎全屏。
/// 根因：`PopupDictionaryPage` 卡片高度写死 `(可用高) × 0.72` 且固定，不读「最大高度」
/// 设置；宽读 app 内 popupMaxWidth 而非 overlayLookupEffectiveSize。
class _SizedPopupAppModel extends AppModel {
  _SizedPopupAppModel({this.overlaySize}) : super(testPlatformServices());

  /// 非 null 时模拟「已初始化 + 用户设了 app 外最大宽高」。
  final LookupSize? overlaySize;

  @override
  bool get isInitialised => overlaySize != null;

  @override
  LookupSize get overlayLookupEffectiveSize => overlaySize!;

  @override
  bool get lowMemoryMode => false;

  @override
  int get maximumTerms => 10;

  @override
  double get dictionaryFontSize => 16;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

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

Widget _wrap(AppModel appModel, Widget home) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      ...popupMiningTargetTestOverrides(),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (context, child) => child ?? const SizedBox.shrink(),
        home: home,
      ),
    ),
  );
}

Future<Size> _pumpCard(
  WidgetTester tester, {
  required Size logicalScreen,
  LookupSize? overlaySize,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalScreen;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _wrap(
      _SizedPopupAppModel(overlaySize: overlaySize),
      const PopupDictionaryPage(searchTerm: 'neko', autoSearchOnOpen: false),
    ),
  );
  await tester.pump();
  // 外层浮卡是树里第一个 FushiPopupSurface（层内面板在它之下）。
  return tester.getSize(find.byType(FushiPopupSurface).first);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('resolveExternalPopupCardBounds', () {
    test('tablet portrait: capped by the max size setting, not 72% of '
        'the screen', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 652,
        availableHeight: 1054,
        maxSize: const LookupSize(480, 480),
      );
      expect(bounds, const LookupSize(480, 480));
    });

    test('phone landscape: available space still caps the setting', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 834,
        availableHeight: 376,
        maxSize: const LookupSize(480, 480),
      );
      expect(bounds.width, 480);
      expect(bounds.height, 376 * kExternalPopupMaxHeightFraction);
    });

    test('narrow phone: width falls back to the available width', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 344,
        availableHeight: 800,
        maxSize: const LookupSize(480, 1600),
      );
      expect(bounds.width, 344);
      expect(bounds.height, 800 * kExternalPopupMaxHeightFraction);
    });
  });

  group('resolveExternalPopupCardHeight', () {
    test('unmeasured (null) takes the bound', () {
      expect(
        resolveExternalPopupCardHeight(maxHeight: 480, fitHeight: null),
        480,
      );
    });
    test('short content shrinks the shell', () {
      expect(
        resolveExternalPopupCardHeight(maxHeight: 480, fitHeight: 260),
        260,
      );
    });
    test('tall content never exceeds the bound', () {
      expect(
        resolveExternalPopupCardHeight(maxHeight: 480, fitHeight: 900),
        480,
      );
    });
  });

  testWidgets('K9YPrjtZE1: tablet card is bounded by the default max size, '
      'not ~72% of the screen height', (WidgetTester tester) async {
    final Size card = await _pumpCard(
      tester,
      logicalScreen: const Size(668, 1070),
    );
    expect(card.width, kLookupPopupDefaultWidth);
    expect(card.height, kLookupPopupDefaultHeight);
  });

  testWidgets('K9YPrjtZE1: tablet card follows the overlay max size setting', (
    WidgetTester tester,
  ) async {
    final Size card = await _pumpCard(
      tester,
      logicalScreen: const Size(668, 1070),
      overlaySize: const LookupSize(360, 320),
    );
    expect(card, const Size(360, 320));
  });

  testWidgets('phone portrait never gets larger than before the fix', (
    WidgetTester tester,
  ) async {
    const Size screen = Size(392, 850);
    final Size card = await _pumpCard(tester, logicalScreen: screen);
    expect(card.width, lessThanOrEqualTo(screen.width));
    expect(card.height, kLookupPopupDefaultHeight);
    expect(
      card.height,
      lessThanOrEqualTo(screen.height * kExternalPopupMaxHeightFraction),
    );
  });

  testWidgets('phone landscape keeps the old screen-fraction ceiling', (
    WidgetTester tester,
  ) async {
    const Size screen = Size(850, 392);
    final Size card = await _pumpCard(tester, logicalScreen: screen);
    expect(card.width, kLookupPopupDefaultWidth);
    expect(card.height, lessThan(kLookupPopupDefaultHeight));
    expect(
      card.height,
      lessThanOrEqualTo(screen.height * kExternalPopupMaxHeightFraction),
    );
  });
}
