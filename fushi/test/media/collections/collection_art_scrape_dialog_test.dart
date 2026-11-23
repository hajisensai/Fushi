import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_art_scrape.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5287：非日文版的系列在结果面板里按系列选「保留书里的封面 / 用 MangaBaka 封面」。
void main() {
  BookArtRunResult resultWith({required bool original}) => BookArtRunResult(
    dryRun: false,
    snapshots: const <BookArtSnapshot>[],
    series: <BookArtSeriesPlan>[
      BookArtSeriesPlan(
        seriesKey: 'bakemonogatari|lang:zh',
        seriesTitle: '化物語',
        decision: BookArtDecision.accepted,
        source: BookArtSource.mangabaka,
        seriesId: '100',
        matchedTitle: 'Bakemonogatari',
        edition: 'zh',
        originalEditionVolumes: 2,
        originalEditionCovers: original,
        books: const <BookArtBookPlan>[],
      ),
    ],
  );

  testWidgets('缺本语言封面的卷：默认保留书里的封面，按钮切换选择并只重跑这一组', (WidgetTester tester) async {
    final List<BookArtRerun> calls = <BookArtRerun>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CollectionArtScrapeDialog(
          run: (BookArtRerun rerun) async {
            calls.add(rerun);
            final bool original =
                rerun.originalEditionCovers['bakemonogatari|lang:zh'] ?? false;
            return resultWith(original: original);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls.single.isEmpty, isTrue);
    expect(
      find.text(t.collection_art_scrape_original_edition_available(count: 2)),
      findsOneWidget,
    );
    final Finder toggle = find.byKey(
      const ValueKey<String>(
        'collection_art_scrape_original_edition_bakemonogatari|lang:zh',
      ),
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.text(t.collection_art_scrape_original_edition_use),
      ),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(calls.last.originalEditionCovers, <String, bool>{
      'bakemonogatari|lang:zh': true,
    });
    expect(calls.last.covers('bakemonogatari|lang:zh'), isTrue);
    expect(
      find.text(t.collection_art_scrape_original_edition_in_use(count: 2)),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(calls.last.originalEditionCovers, <String, bool>{
      'bakemonogatari|lang:zh': false,
    });
    expect(
      find.text(t.collection_art_scrape_original_edition_available(count: 2)),
      findsOneWidget,
    );
  });
}
