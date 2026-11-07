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
  _SizedPopupAppModel({this.overlaySize, this.uiScale = 1.0})
    : super(testPlatformServices());

  /// 非 null 时模拟「已初始化 + 用户设了 app 外最大宽高」。
  final LookupSize? overlaySize;

  /// 模拟「界面大小」（平板竖屏自动约 1.11，用户可手动调大）。
  final double uiScale;

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
  double get appUiScale => uiScale;

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
  double uiScale = 1.0,
  Rect? anchorRect,
  bool autoSearchOnOpen = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalScreen;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _wrap(
      _SizedPopupAppModel(overlaySize: overlaySize, uiScale: uiScale),
      PopupDictionaryPage(
        searchTerm: 'neko',
        autoSearchOnOpen: autoSearchOnOpen,
        anchorRect: anchorRect,
      ),
    ),
  );
  await tester.pump();
  // 自动查词（假词典立即返回空结果）要再走几帧才落成「未找到」空态。
  if (autoSearchOnOpen) {
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
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
        uiScale: 1.0,
      );
      expect(bounds, const LookupSize(480, 480));
    });

    test('phone landscape: available space still caps the setting', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 834,
        availableHeight: 376,
        maxSize: const LookupSize(480, 480),
        uiScale: 1.0,
      );
      expect(bounds.width, 480);
      expect(bounds.height, 376 * kExternalPopupMaxHeightFraction);
    });

    test('narrow phone: width falls back to the available width', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 344,
        availableHeight: 800,
        maxSize: const LookupSize(480, 1600),
        uiScale: 1.0,
      );
      expect(bounds.width, 344);
      expect(bounds.height, 800 * kExternalPopupMaxHeightFraction);
    });

    test('UI scale multiplies the base setting before the space cap', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 652,
        availableHeight: 1054,
        maxSize: const LookupSize(480, 480),
        uiScale: 1.25,
      );
      expect(bounds, const LookupSize(600, 600));
    });

    test('UI scale never pushes past the available space', () {
      final LookupSize bounds = resolveExternalPopupCardBounds(
        availableWidth: 500,
        availableHeight: 600,
        maxSize: const LookupSize(480, 480),
        uiScale: 1.5,
      );
      expect(bounds.width, 500);
      expect(bounds.height, 600 * kExternalPopupMaxHeightFraction);
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

  group('UI scale (界面大小) multiplies the base max size', () {
    testWidgets('tablet: the setting is scaled like the in-app popup', (
      WidgetTester tester,
    ) async {
      final Size card = await _pumpCard(
        tester,
        logicalScreen: const Size(668, 1070),
        overlaySize: const LookupSize(360, 320),
        uiScale: 1.25,
      );
      expect(card, const Size(450, 400));
    });

    testWidgets('empty ("not found") shell height is scaled too', (
      WidgetTester tester,
    ) async {
      final Size card = await _pumpCard(
        tester,
        logicalScreen: const Size(668, 1070),
        overlaySize: const LookupSize(480, 480),
        uiScale: 1.25,
        autoSearchOnOpen: true,
      );
      expect(card.height, kLookupPopupEmptyHeight * 1.25);
    });
  });

  group('anchored card (floating ball / floating subtitle tap)', () {
    const Rect anchor = Rect.fromLTWH(300, 200, 20, 20);

    testWidgets('tablet: default max size, not ~72% of the screen', (
      WidgetTester tester,
    ) async {
      final Size card = await _pumpCard(
        tester,
        logicalScreen: const Size(668, 1070),
        anchorRect: anchor,
      );
      expect(
        card,
        const Size(kLookupPopupDefaultWidth, kLookupPopupDefaultHeight),
      );
    });

    testWidgets('tablet: follows the overlay max size setting', (
      WidgetTester tester,
    ) async {
      final Size card = await _pumpCard(
        tester,
        logicalScreen: const Size(668, 1070),
        overlaySize: const LookupSize(360, 320),
        anchorRect: anchor,
      );
      expect(card, const Size(360, 320));
    });

    testWidgets('tablet: UI scale multiplies the setting', (
      WidgetTester tester,
    ) async {
      final Size card = await _pumpCard(
        tester,
        logicalScreen: const Size(668, 1070),
        overlaySize: const LookupSize(360, 320),
        uiScale: 1.25,
        anchorRect: anchor,
      );
      expect(card, const Size(450, 400));
    });

    testWidgets('phone landscape keeps the screen-fraction ceiling', (
      WidgetTester tester,
    ) async {
      const Size screen = Size(850, 392);
      final Size card = await _pumpCard(
        tester,
        logicalScreen: screen,
        anchorRect: const Rect.fromLTWH(400, 40, 20, 20),
      );
      expect(card.width, kLookupPopupDefaultWidth);
      expect(
        card.height,
        lessThanOrEqualTo(screen.height * kExternalPopupMaxHeightFraction),
      );
    });
  });
}
