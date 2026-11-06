import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/source_guard.dart';

/// 反馈 QvYpZODImz：歌词模式右上角的 × 原本只回正文；用户要一颗单独的「书籍
/// 模式」键承接回正文，× 改成直接退书回书架（这样这本书记住的仍是歌词模式，重开
/// 还是歌词模式）。
class _Clock implements LyricsPlayerClock {
  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

void main() {
  late List<String> calls;

  LyricsPlayerCallbacks callbacks({required bool withExit}) =>
      LyricsPlayerCallbacks(
        onClose: () => calls.add('book'),
        onExitBook: withExit ? () => calls.add('exit') : null,
        onPlayPause: () {},
        onPreviousCue: () {},
        onNextCue: () {},
        onSeek: (_) {},
        onToggleMask: () {},
        onOpenStatistics: () {},
        onSpeedChanged: (_) {},
        onMore: (_) {},
        onTapBackground: () {},
      );

  Widget app({required bool withExit}) => MaterialApp(
    home: Scaffold(
      body: ReaderLyricsPlayerOverlay(
        lyricsView: const SizedBox.expand(),
        data: LyricsPlayerData(
          title: 'book',
          cover: null,
          isPlaying: false,
          speed: 1,
          lyricsMasked: false,
          clock: _Clock(),
        ),
        callbacks: callbacks(withExit: withExit),
        onHtmlThemeChanged: (_) {},
      ),
    ),
  );

  final Finder close = find.byKey(
    const ValueKey<String>('lyrics_close_button'),
  );
  final Finder book = find.byKey(
    const ValueKey<String>('lyrics_return_to_book_button'),
  );

  setUp(() => calls = <String>[]);

  testWidgets('wide: × exits the book, book-mode button returns to text', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pumpWidget(app(withExit: true));
    await tester.pump(const Duration(milliseconds: 50));

    expect(book, findsOneWidget);
    await tester.tap(book);
    await tester.tap(close);
    expect(calls, <String>['book', 'exit']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wide without onExitBook keeps × as return-to-text', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pumpWidget(app(withExit: false));
    await tester.pump(const Duration(milliseconds: 50));

    expect(book, findsNothing);
    await tester.tap(close);
    expect(calls, <String>['book']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow: back returns to text, × exits the book', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(app(withExit: true));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey<String>('lyrics_player_back')));
    await tester.tap(close);
    expect(calls, <String>['book', 'exit']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('reader wires × to the explicit exit-book funnel', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      ).readAsStringSync(),
    );
    expect(src, contains('onExitBook: () => unawaited(_exitReaderBook())'));
    expect(src, contains('onClose: () => unawaited(_toggleLyricsMode())'));
  });
}
