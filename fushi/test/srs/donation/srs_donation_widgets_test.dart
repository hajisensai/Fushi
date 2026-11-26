import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/srs/donation/srs_donation_banner.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/donation/srs_donation_providers.dart';
import 'package:fushi/src/srs/donation/srs_donation_words_page.dart';
import 'package:fushi/src/srs/srs_home_stats.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

Widget _app({
  required bool apple,
  required Widget home,
  List<Override> overrides = const <Override>[],
}) => ProviderScope(
  overrides: <Override>[
    appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
    ...overrides,
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
      home: home,
    ),
  ),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('词表搜索：词头或读音包含即命中', () {
    const List<SrsDonationWord> words = <SrsDonationWord>[
      SrsDonationWord(noteId: 'a', headword: '漢字', reading: 'かんじ'),
      SrsDonationWord(noteId: 'b', headword: '言葉', reading: 'ことば'),
      SrsDonationWord(noteId: 'c', headword: 'ゲーム'),
    ];
    expect(srsDonationFilterWords(words, ''), words);
    expect(
      srsDonationFilterWords(words, 'かん').map((SrsDonationWord w) => w.noteId),
      <String>['a'],
    );
    expect(
      srsDonationFilterWords(words, '葉').map((SrsDonationWord w) => w.noteId),
      <String>['b'],
    );
    expect(srsDonationFilterWords(words, 'ゲ').single.noteId, 'c');
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'M3E';

    testWidgets('[$ds] 横幅：首次与更新两种文案、三个按钮', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final SrsHomeStats stats = SrsHomeStats(
        doneToday: 0,
        averageMsPerCard: 0,
        streak: 0,
        today: 40,
        countsByDay: const <int, int>{10: 1500, 39: 1700},
      );
      for (final SrsDonationPromptKind kind in SrsDonationPromptKind.values) {
        await tester.pumpWidget(
          _app(
            apple: apple,
            overrides: <Override>[
              srsHomeStatsProvider.overrideWith((Ref ref) async => stats),
              srsDonationPrefsProvider.overrideWithValue(
                SrsDonationPrefsState(
                  lastAt: kind == SrsDonationPromptKind.update
                      ? DateTime(2026)
                      : null,
                  lastReviews: kind == SrsDonationPromptKind.update ? 1200 : 0,
                ),
              ),
            ],
            home: FushiPageHost(child: SrsDonationBanner(kind: kind)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('srs-donation-banner')),
          findsOneWidget,
        );
        expect(
          find.text(
            kind == SrsDonationPromptKind.donate
                ? t.srs_donation_banner_body(n: 3200)
                : t.srs_donation_banner_update_body(n: 2000),
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            kind == SrsDonationPromptKind.donate
                ? t.srs_donation_learn_more
                : t.srs_donation_update,
          ),
          findsOneWidget,
        );
        expect(find.text(t.srs_donation_later), findsOneWidget);
        expect(find.text(t.srs_donation_never), findsOneWidget);
      }
    });

    testWidgets('[$ds] 词表页：搜索过滤、逐词排除回调', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<Set<String>> changes = <Set<String>>[];
      await tester.pumpWidget(
        _app(
          apple: apple,
          home: SrsDonationWordsPage(
            words: const <SrsDonationWord>[
              SrsDonationWord(noteId: 'a', headword: '漢字', reading: 'かんじ'),
              SrsDonationWord(noteId: 'b', headword: '言葉', reading: 'ことば'),
            ],
            excluded: const <String>{'b'},
            onChanged: changes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.srs_donation_words_summary(n: 2, excluded: 1)),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-donation-word-a')),
      );
      await tester.pumpAndSettle();
      expect(changes.last, <String>{'a', 'b'});
      expect(
        find.text(t.srs_donation_words_summary(n: 2, excluded: 2)),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('srs-donation-words-search')),
        'ことば',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('srs-donation-word-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-donation-word-b')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-donation-word-b')),
      );
      await tester.pumpAndSettle();
      expect(changes.last, <String>{'a'});
    });
  }
}

/// 横幅放进一个带 Material 祖先的页面里。
class FushiPageHost extends StatelessWidget {
  const FushiPageHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: child,
    ),
  );
}
