import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_tab.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';
import 'companion_panel_harness.dart';

/// An AppModel that answers lookups with nothing (no dictionaries / I/O).
class _LookupAppModel extends AppModel {
  _LookupAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 400;

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
  }) async => DictionarySearchResult(searchTerm: searchTerm);
}

/// The real popup page in its embedded (companion) form, as
/// [buildCompanionPopupDictionary] builds it once the AppModel is up.
Widget _embeddedPage(
  BuildContext context,
  CompanionLookupEntry entry,
  int generation,
  CompanionLookupController controller,
) => PopupDictionaryPage(
  searchTerm: entry.text,
  searchGeneration: generation,
  closeInApp: controller.close,
  showSearchBar: false,
  embedded: true,
  autoSearchOnOpen: false,
);

/// The page's card (the standalone-window surface).
Finder get _card => find.byWidgetPredicate(
  (Widget w) => w is FushiPopupSurface && w.standaloneWindow,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('the embedded dictionary card fills the Lookup tab down to the '
      'bottom bar on the ~470x540 dp bottom screen', (
    WidgetTester tester,
  ) async {
    final RecordingCompanionSession rec = RecordingCompanionSession();
    final _LookupAppModel appModel = _LookupAppModel();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(470, 540);
    addTearDown(tester.view.reset);
    rec.push(
      const CompanionSummaryMessage(
        CompanionDailySummary(dayKey: '2026-11-08'),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionPanelSessionProvider.overrideWith((Ref ref) => rec.session),
          appProvider.overrideWith((Ref ref) => appModel),
          ...popupMiningTargetTestOverrides(),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            builder: (BuildContext context, Widget? child) =>
                LegacyDesignCompatibility(
                  child: FushiGlassScope(child: child!),
                ),
            home: const CompanionShell(
              lookupTab: CompanionLookupTab(dictionaryBuilder: _embeddedPage),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    rec.push(const CompanionLookupMessage(text: '猫'));
    await tester.pumpAndSettle();

    expect(_card, findsOneWidget);
    final Rect card = tester.getRect(_card);
    // Top of the bottom bar's first destination: the tab body ends above it
    // (the shell extends its body under the bar and reports the bar height as
    // bottom padding).
    final double barTop = tester
        .getRect(companionButton(t.second_screen_tab_now))
        .top;
    final double gapBelowCard = barTop - card.bottom;
    expect(
      card.bottom,
      lessThanOrEqualTo(barTop),
      reason: 'the card must not run under the bottom bar',
    );
    expect(
      gapBelowCard,
      lessThan(40),
      reason:
          'the card must reach down to the bottom bar (was ~55 % of the '
          'tab: the bar padding was applied twice), gap $gapBelowCard',
    );
    expect(card.height, greaterThan(540 * 0.6));
  });
  testWidgets('the floating popup window keeps its own safe area', (
    WidgetTester tester,
  ) async {
    final _LookupAppModel appModel = _LookupAppModel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((Ref ref) => appModel),
          ...popupMiningTargetTestOverrides(),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            home: PopupDictionaryPage(
              searchTerm: '猫',
              closeInApp: () {},
              autoSearchOnOpen: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.ancestor(of: _card, matching: find.byType(SafeArea)),
      findsWidgets,
    );
  });
}
