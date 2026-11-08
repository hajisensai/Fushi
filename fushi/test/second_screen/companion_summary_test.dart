import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/second_screen/companion/companion_main_services.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_now_tab.dart'
    show kCompanionReviewLink;
import 'package:fushi_engine/stats/stat_facts.dart';

StatFact _fact(String kind, String day, int minutes, {String format = ''}) =>
    StatFact(
      mediaKind: kind,
      mediaKey: 'k',
      title: 't',
      format: format,
      dateKey: day,
      hour: -1,
      ms: minutes * 60000,
      chars: 0,
      pages: 0,
      lastActiveMs: 0,
    );

CompanionContinueCandidate _candidate(String title, int recentAt) =>
    CompanionContinueCandidate(
      item: CompanionContinueItem(
        kind: CompanionContinueKind.book,
        title: title,
        link: 'fushi://widget/continue?kind=book&id=$title',
      ),
      recentAt: recentAt,
    );

void main() {
  test("today's time per category, other days and reviews left out", () {
    final CompanionDailySummary summary = buildCompanionDailySummary(
      todayKey: '2026-11-07',
      daily: <StatFact>[
        _fact('book', '2026-11-07', 30),
        _fact('book', '2026-11-07', 22, format: 'manga'),
        _fact('video', '2026-11-07', 24),
        _fact('music', '2026-11-07', 18),
        _fact('game', '2026-11-07', 3),
        _fact(kStatMediaReview, '2026-11-07', 40),
        _fact('book', '2026-11-06', 100),
      ],
    );
    expect(summary.dayKey, '2026-11-07');
    expect(summary.readingMs, 52 * 60000);
    expect(summary.watchingMs, 24 * 60000);
    expect(summary.listeningMs, 18 * 60000);
    expect(summary.gamesMs, 3 * 60000);
    expect(summary.srsDue, isNull);
    expect(summary.continueItem, isNull);
  });

  test('no data: zeros, nothing invented', () {
    final CompanionDailySummary summary = buildCompanionDailySummary(
      todayKey: '2026-11-07',
      daily: const <StatFact>[],
    );
    expect(summary, const CompanionDailySummary(dayKey: '2026-11-07'));
  });

  test('the most recent candidate is the one to continue', () {
    expect(pickCompanionContinue(const <CompanionContinueCandidate>[]), isNull);
    expect(
      pickCompanionContinue(<CompanionContinueCandidate>[
        _candidate('old', 10),
        _candidate('new', 30),
        _candidate('mid', 20),
      ])!.item.title,
      'new',
    );
  });

  test('the review link opens the built-in review on the main screen', () {
    expect(WidgetLink.tryParse(kCompanionReviewLink), isA<WidgetSrsLink>());
  });
}
