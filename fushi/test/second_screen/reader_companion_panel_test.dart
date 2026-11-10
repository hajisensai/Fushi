import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_lookup_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/audiobook_companion_panel.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/reader_companion_panel.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const Map<String, Object?> _reader = <String, Object?>{
  ReaderCompanionKeys.title: 'こころ',
  ReaderCompanionKeys.author: '夏目漱石',
  ReaderCompanionKeys.chapterTitle: '上 先生と私',
  ReaderCompanionKeys.chapterIndex: 11,
  ReaderCompanionKeys.chapterCount: 110,
  ReaderCompanionKeys.percent: 34.0,
  ReaderCompanionKeys.toc: <Map<String, Object?>>[
    <String, Object?>{'label': '上 先生と私', 'depth': 0},
    <String, Object?>{'label': '一', 'depth': 1},
    <String, Object?>{'label': '二', 'depth': 1},
  ],
  ReaderCompanionKeys.tocCurrent: 1,
  ReaderCompanionKeys.hasAudio: false,
  ReaderCompanionKeys.playing: false,
  ReaderCompanionKeys.bookmarksEnabled: true,
  ReaderCompanionKeys.bookmarks: <Map<String, Object?>>[
    <String, Object?>{'id': 4, 'label': '先生と鎌倉で出会う', 'chapter': 2},
    <String, Object?>{'id': 9, 'label': '雑司ヶ谷の墓地', 'chapter': 5},
  ],
  ReaderCompanionKeys.stats: <String, Object?>{
    ReaderCompanionKeys.todayMs: 38 * 60000,
    ReaderCompanionKeys.todayChars: 9420,
    ReaderCompanionKeys.todayLookups: 14,
    ReaderCompanionKeys.todayCards: 1,
  },
};

const Map<String, Object?> _audiobook = <String, Object?>{
  AudiobookCompanionKeys.title: 'こころ',
  AudiobookCompanionKeys.author: '夏目漱石',
  AudiobookCompanionKeys.chapterTitle: '上 先生と私',
  AudiobookCompanionKeys.chapterIndex: 11,
  AudiobookCompanionKeys.chapterCount: 110,
  AudiobookCompanionKeys.playing: true,
  AudiobookCompanionKeys.speed: 1.0,
  AudiobookCompanionKeys.positionMs: 8045000,
  AudiobookCompanionKeys.durationMs: 35310000,
  AudiobookCompanionKeys.current: 1,
  AudiobookCompanionKeys.lines: <Map<String, Object?>>[
    <String, Object?>{'index': 0, 'text': '私が先生と知り合いになったのは鎌倉である。'},
    <String, Object?>{'index': 1, 'text': 'その時私はまだ若々しい書生であった。'},
    <String, Object?>{'index': 2, 'text': '私は金の工面に二、三日を費やした。'},
  ],
};

List<String> _sent(RecordingCompanionSession rec) => <String>[
  for (final CompanionCommandMessage c in rec.commands) '${c.action} ${c.args}',
];

List<String> _fmt(List<(String, Map<String, Object?>)> expected) => <String>[
  for (final (String, Map<String, Object?>) e in expected) '${e.$1} ${e.$2}',
];

void main() {
  late RecordingCompanionSession rec;

  setUp(() => rec = RecordingCompanionSession());

  group('ReaderCompanionPanel', () {
    testWidgets('book info, progress, stats and bookmarks at 470x540', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, _reader, title: 'こころ');
      await pumpCompanionPanel(
        tester,
        rec.session,
        ReaderCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(t.second_screen_reader_header), findsOneWidget);
      expect(
        find.text(t.second_screen_reader_chapter(current: 12, total: 110)),
        findsOneWidget,
      );
      expect(find.text('こころ'), findsOneWidget);
      expect(find.text('夏目漱石 · 上 先生と私'), findsOneWidget);
      expect(find.text('34%'), findsOneWidget);
      expect(find.text('9,420'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('雑司ヶ谷の墓地'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(t.second_screen_reader_bookmark_chapter(n: 5)),
        findsOneWidget,
      );
      // No audiobook: no play button.
      expect(find.byKey(const ValueKey<String>('reader-play')), findsNothing);
    });

    testWidgets('controls send their commands; bookmark tap jumps', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, _reader);
      await pumpCompanionPanel(
        tester,
        rec.session,
        ReaderCompanionPanel(session: rec.session),
      );
      await tester.tap(companionButton(t.second_screen_reader_next_page));
      await tester.tap(companionButton(t.second_screen_reader_prev_page));
      await tester.tap(companionButton(t.second_screen_reader_add_bookmark));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('先生と鎌倉で出会う'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('先生と鎌倉で出会う'));
      await tester.pump();
      expect(
        _sent(rec),
        _fmt(<(String, Map<String, Object?>)>[
          (
            ReaderCompanionActions.turnPage,
            <String, Object?>{ReaderCompanionActions.forward: true},
          ),
          (
            ReaderCompanionActions.turnPage,
            <String, Object?>{ReaderCompanionActions.forward: false},
          ),
          (ReaderCompanionActions.addBookmark, <String, Object?>{}),
          (
            ReaderCompanionActions.jumpToBookmark,
            <String, Object?>{ReaderCompanionActions.id: 4},
          ),
        ]),
      );
      expect(
        rec.commands.every(
          (CompanionCommandMessage c) => c.kind == CompanionContextKind.reader,
        ),
        isTrue,
      );
    });

    testWidgets('contents page: current entry selected, tap jumps and pops', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, _reader);
      await pumpCompanionPanel(
        tester,
        rec.session,
        Navigator(
          onGenerateRoute: (RouteSettings s) => MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                ReaderCompanionPanel(session: rec.session),
          ),
        ),
      );
      await tester.tap(companionButton(t.second_screen_reader_contents));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderCompanionContentsPage), findsOneWidget);
      await tester.tap(find.text('二'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderCompanionContentsPage), findsNothing);
      expect(rec.commands.last.action, ReaderCompanionActions.goToToc);
      expect(rec.commands.last.args, <String, Object?>{
        ReaderCompanionActions.index: 2,
      });
    });

    testWidgets('missing data hides rows: no author, stats, bookmarks', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.reader, const <String, Object?>{
        ReaderCompanionKeys.title: 'Untitled',
        ReaderCompanionKeys.chapterCount: 0,
        ReaderCompanionKeys.hasAudio: true,
        ReaderCompanionKeys.playing: true,
      });
      await pumpCompanionPanel(
        tester,
        rec.session,
        ReaderCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Untitled'), findsOneWidget);
      expect(find.text('--'), findsOneWidget);
      expect(find.text(t.second_screen_reader_bookmarks), findsNothing);
      expect(find.text(t.second_screen_reader_read_today), findsNothing);
      expect(
        companionButton(t.second_screen_reader_add_bookmark),
        findsNothing,
      );
      await tester.tap(companionButton(t.pause));
      await tester.pump();
      expect(rec.commands.single.action, ReaderCompanionActions.playPause);
    });
  });

  group('AudiobookCompanionPanel', () {
    testWidgets('transcript, position and transport at 470x540', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.audiobook, _audiobook);
      await pumpCompanionPanel(
        tester,
        rec.session,
        AudiobookCompanionPanel(session: rec.session),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('2:14:05 / 9:48:30'), findsOneWidget);
      expect(
        find.text(
          t.second_screen_audiobook_chapter_listened(n: 12, percent: 23),
        ),
        findsOneWidget,
      );
      expect(find.text('その時私はまだ若々しい書生であった。'), findsOneWidget);

      await tester.tap(companionButton(t.pause));
      await tester.tap(companionButton(t.second_screen_video_back_10));
      await tester.tap(companionButton(t.second_screen_audiobook_next_chapter));
      await tester.tap(find.byKey(const ValueKey<String>('audiobook-speed')));
      await tester.tap(find.text('私は金の工面に二、三日を費やした。'));
      await tester.pump();
      expect(
        _sent(rec),
        _fmt(<(String, Map<String, Object?>)>[
          (AudiobookCompanionActions.playPause, <String, Object?>{}),
          (
            AudiobookCompanionActions.seekRelative,
            <String, Object?>{AudiobookCompanionActions.seconds: -10},
          ),
          (AudiobookCompanionActions.nextChapter, <String, Object?>{}),
          (
            AudiobookCompanionActions.setSpeed,
            <String, Object?>{AudiobookCompanionActions.speed: 1.25},
          ),
          (
            AudiobookCompanionActions.seekLine,
            <String, Object?>{AudiobookCompanionActions.index: 2},
          ),
        ]),
      );
    });

    testWidgets('long-press a line looks it up on the panel', (
      WidgetTester tester,
    ) async {
      rec.show(CompanionContextKind.audiobook, _audiobook);
      await pumpCompanionPanel(
        tester,
        rec.session,
        AudiobookCompanionPanel(session: rec.session),
      );
      await tester.longPress(find.text('その時私はまだ若々しい書生であった。'));
      await tester.pump();
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AudiobookCompanionPanel)),
      );
      final CompanionLookupEntry? entry = container
          .read(companionLookupControllerProvider)
          .current;
      expect(entry?.text, 'その時私はまだ若々しい書生であった。');
      expect(entry?.sentence, 'その時私はまだ若々しい書生であった。');
      expect(rec.commands, isEmpty);
    });

    test('speed button cycles', () {
      expect(nextAudiobookSpeed(1.0), 1.25);
      expect(nextAudiobookSpeed(2.0), 0.75);
      expect(nextAudiobookSpeed(1.1), 1.25);
    });
  });
}
