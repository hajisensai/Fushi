import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/manga_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/manga_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/reader_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/video_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

/// S5 info cards on the Now panels: rows from cached data are shown, rows
/// without data are hidden (never invented), and everything fits the
/// 470 x 540 dp bottom screen.

Map<String, Object?> _reader({bool withInfo = true}) => <String, Object?>{
  ReaderCompanionKeys.title: 'こころ',
  ReaderCompanionKeys.author: '夏目漱石',
  ReaderCompanionKeys.chapterTitle: '上 先生と私',
  ReaderCompanionKeys.chapterIndex: 11,
  ReaderCompanionKeys.chapterCount: 110,
  ReaderCompanionKeys.percent: 34.0,
  ReaderCompanionKeys.hasAudio: false,
  ReaderCompanionKeys.playing: false,
  ReaderCompanionKeys.bookmarksEnabled: true,
  ReaderCompanionKeys.bookmarks: <Map<String, Object?>>[
    <String, Object?>{'id': 4, 'label': '先生と鎌倉で出会う', 'chapter': 2},
  ],
  if (withInfo) ...<String, Object?>{
    ReaderCompanionKeys.bookmarkCount: 120,
    ReaderCompanionKeys.series: '漱石全集',
    ReaderCompanionKeys.seriesIndex: 3,
  },
  ReaderCompanionKeys.stats: <String, Object?>{
    ReaderCompanionKeys.todayMs: 38 * 60000,
    ReaderCompanionKeys.todayChars: 9420,
    ReaderCompanionKeys.todayLookups: 14,
    ReaderCompanionKeys.todayCards: 1,
    if (withInfo) ...<String, Object?>{
      ReaderCompanionKeys.allMs: 5 * 3600000,
      ReaderCompanionKeys.allChars: 123456,
    },
  },
};

Map<String, Object?> _video(Map<String, Object?> info) => <String, Object?>{
  VideoCompanionKeys.title: 'Episode 3',
  VideoCompanionKeys.episodeIndex: -1,
  VideoCompanionKeys.episodeCount: 0,
  VideoCompanionKeys.playing: false,
  VideoCompanionKeys.positionMs: 0,
  VideoCompanionKeys.durationMs: 1000,
  VideoCompanionKeys.speed: 1.0,
  VideoCompanionKeys.cueStart: -1,
  VideoCompanionKeys.cues: const <Map<String, Object?>>[],
  VideoCompanionKeys.audioTracks: const <Map<String, Object?>>[],
  VideoCompanionKeys.subtitleTracks: const <Map<String, Object?>>[],
  VideoCompanionKeys.subtitlesOff: true,
  if (info.isNotEmpty) VideoCompanionKeys.info: info,
};

const Map<String, Object?> _fullVideoInfo = <String, Object?>{
  VideoCompanionKeys.workTitle: 'Series title',
  VideoCompanionKeys.rating: 8.43,
  VideoCompanionKeys.votes: 1234,
  VideoCompanionKeys.year: 2001,
  VideoCompanionKeys.studios: <String>['Studio Ghibli'],
  VideoCompanionKeys.genres: <String>['Fantasy', 'Adventure'],
  VideoCompanionKeys.overview: 'Series overview text.',
  VideoCompanionKeys.cast: <Map<String, Object?>>[
    <String, Object?>{
      VideoCompanionKeys.personName: 'Rumi Hiiragi',
      VideoCompanionKeys.personRole: 'Chihiro',
    },
    <String, Object?>{VideoCompanionKeys.personName: 'Miyu Irino'},
  ],
  VideoCompanionKeys.staff: <Map<String, Object?>>[
    <String, Object?>{
      VideoCompanionKeys.personName: 'Hayao Miyazaki',
      VideoCompanionKeys.staffKind: 'director',
    },
    <String, Object?>{
      VideoCompanionKeys.personName: 'Someone Else',
      VideoCompanionKeys.staffKind: 'writer',
      VideoCompanionKeys.staffJob: 'Screenplay',
    },
  ],
};

Map<String, Object?> _manga({bool rated = true}) => <String, Object?>{
  MangaCompanionKeys.title: 'Series',
  MangaCompanionKeys.author: 'Author',
  MangaCompanionKeys.genres: <String>['Comedy'],
  if (rated) ...<String, Object?>{
    MangaCompanionKeys.rating: 7.84,
    MangaCompanionKeys.votes: 1234,
  },
  MangaCompanionKeys.page: 36,
  MangaCompanionKeys.pageCount: 182,
  MangaCompanionKeys.rtl: true,
  MangaCompanionKeys.ocr: 'idle',
};

Future<void> _openVideoInfo(WidgetTester tester) async {
  final Finder f = companionButton(t.second_screen_video_info);
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  late RecordingCompanionSession rec;

  setUp(() => rec = RecordingCompanionSession());

  group('companionRatingLabel', () {
    test('one decimal, votes only when known', () {
      expect(companionRatingLabel(8.43), '★ 8.4');
      expect(companionRatingLabel(7, votes: 0), '★ 7.0');
      expect(
        companionRatingLabel(7.84, votes: 1234),
        '★ 7.8 · ${t.second_screen_video_votes(n: 1234)}',
      );
    });
  });

  group('reader', () {
    testWidgets('book card: series, all-time reading, bookmark count', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, _reader());
      await pumpCompanionPanel(
        tester,
        rec.session,
        ReaderCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      final Finder card = find.byKey(const ValueKey<String>('reader-info'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      expect(find.text(t.second_screen_info_book), findsOneWidget);
      expect(find.text(t.second_screen_info_series), findsOneWidget);
      expect(find.text('漱石全集 · #3'), findsOneWidget);
      expect(find.text(t.second_screen_info_total_time), findsOneWidget);
      expect(find.text(t.second_screen_info_total_chars), findsOneWidget);
      expect(find.text('123,456'), findsOneWidget);
      final Finder count = find.byKey(
        const ValueKey<String>('reader-bookmark-count'),
      );
      await tester.ensureVisible(count);
      expect(tester.widget<Text>(count).data, '120');
      expect(tester.takeException(), isNull);
    });

    testWidgets('no series and no totals: no book card', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, _reader(withInfo: false));
      await pumpCompanionPanel(
        tester,
        rec.session,
        ReaderCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('reader-info')), findsNothing);
      expect(find.text(t.second_screen_info_series), findsNothing);
      // An old snapshot without the count falls back to the list length.
      final Finder count = find.byKey(
        const ValueKey<String>('reader-bookmark-count'),
      );
      await tester.ensureVisible(count);
      expect(tester.widget<Text>(count).data, '1');
    });
  });

  group('video', () {
    testWidgets('info page: year, studio, genres, cast and staff', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.video, _video(_fullVideoInfo));
      await pumpCompanionPanel(
        tester,
        rec.session,
        VideoCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      await _openVideoInfo(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(t.second_screen_info_year), findsOneWidget);
      expect(find.text('2001'), findsOneWidget);
      expect(find.text(t.second_screen_info_studio), findsOneWidget);
      expect(find.text('Studio Ghibli'), findsOneWidget);
      expect(find.text('Fantasy'), findsOneWidget);
      expect(find.text('Adventure'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Someone Else'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(t.second_screen_info_cast), findsOneWidget);
      expect(find.text('Rumi Hiiragi'), findsOneWidget);
      expect(find.text('Chihiro'), findsOneWidget);
      expect(find.text('Miyu Irino'), findsOneWidget);
      expect(find.text(t.second_screen_info_staff), findsOneWidget);
      expect(find.text('Hayao Miyazaki'), findsOneWidget);
      expect(find.text(t.second_screen_info_director), findsOneWidget);
      // The cached job wins over the kind label.
      expect(find.text('Screenplay'), findsOneWidget);
      expect(find.text(t.second_screen_info_writer), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'cast alone is enough for the Info button; missing rows hidden',
      (WidgetTester tester) async {
        rec.show(
          CompanionContextKind.video,
          _video(const <String, Object?>{
            VideoCompanionKeys.cast: <Map<String, Object?>>[
              <String, Object?>{VideoCompanionKeys.personName: 'Rumi Hiiragi'},
            ],
          }),
        );
        await pumpCompanionPanel(
          tester,
          rec.session,
          VideoCompanionPanel(session: rec.session),
        );
        expect(companionButton(t.second_screen_video_info), findsOneWidget);
        await _openVideoInfo(tester);
        expect(find.text('Rumi Hiiragi'), findsOneWidget);
        expect(find.text(t.second_screen_info_year), findsNothing);
        expect(find.text(t.second_screen_info_studio), findsNothing);
        expect(find.text(t.second_screen_info_staff), findsNothing);
        expect(find.textContaining('★'), findsNothing);
      },
    );

    testWidgets('no cached info: no Info button', (WidgetTester tester) async {
      rec.show(CompanionContextKind.video, _video(const <String, Object?>{}));
      await pumpCompanionPanel(
        tester,
        rec.session,
        VideoCompanionPanel(session: rec.session),
      );
      expect(companionButton(t.second_screen_video_info), findsNothing);
    });
  });

  group('manga', () {
    testWidgets('rating chip with votes next to the genres', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.manga, _manga());
      await pumpCompanionPanel(
        tester,
        rec.session,
        MangaCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.text('★ 7.8 · ${t.second_screen_video_votes(n: 1234)}'),
        findsOneWidget,
      );
      expect(find.text('Comedy'), findsOneWidget);
      expect(find.text('Author'), findsOneWidget);
    });

    testWidgets('no rating cached: no rating chip', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.manga, _manga(rated: false));
      await pumpCompanionPanel(
        tester,
        rec.session,
        MangaCompanionPanel(session: rec.session),
      );
      expect(find.textContaining('★'), findsNothing);
      expect(find.text('Comedy'), findsOneWidget);
    });
  });

  group('CompanionInfoCard', () {
    Future<void> pumpCard(WidgetTester tester, Widget card) =>
        pumpCompanionPanel(
          tester,
          rec.session,
          SingleChildScrollView(padding: const EdgeInsets.all(16), child: card),
        );

    testWidgets('long description collapses with More / Less', (
      WidgetTester tester,
    ) async {
      final String long = List<String>.filled(
        60,
        'A long description.',
      ).join(' ');
      await pumpCard(
        tester,
        CompanionInfoCard(
          facts: const <CompanionInfoFact>[
            CompanionInfoFact(label: 'Year', value: '2001'),
          ],
          description: long,
        ),
      );
      expect(tester.takeException(), isNull);
      final Text collapsed = tester.widget<Text>(find.text(long));
      expect(collapsed.maxLines, 3);
      await tester.tap(find.text(t.second_screen_info_more));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
      expect(find.text(t.second_screen_info_less), findsOneWidget);
      final Size button = tester.getSize(
        find.ancestor(
          of: find.text(t.second_screen_info_less),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        ),
      );
      expect(button.height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(find.text(t.second_screen_info_less));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.second_screen_info_less));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text(long)).maxLines, 3);
    });

    testWidgets('short description: no More button', (
      WidgetTester tester,
    ) async {
      await pumpCard(tester, const CompanionInfoCard(description: 'Short.'));
      expect(find.text('Short.'), findsOneWidget);
      expect(find.text(t.second_screen_info_more), findsNothing);
    });

    test('empty without chips, facts or description', () {
      expect(const CompanionInfoCard(description: '  ').isEmpty, isTrue);
      expect(const CompanionInfoCard(chips: <String>['x']).isEmpty, isFalse);
    });
  });
}
