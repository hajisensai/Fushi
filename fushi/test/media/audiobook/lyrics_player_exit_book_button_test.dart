import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
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

ThemeData _appleTheme() => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glass: FushiGlassMaterial.frosted,
  glassDesign: true,
).copyWith(platform: TargetPlatform.windows);

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

  Widget app({
    required bool withExit,
    bool apple = false,
    LyricsControlsStyle style = LyricsControlsStyle.modern,
    LyricsControlLayout? compactControls,
  }) => MaterialApp(
    theme: apple ? _appleTheme() : null,
    themeAnimationDuration: Duration.zero,
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) {
          // 前提：确实走的是要测的那套设计系统。
          expect(isGlassDesign(context), apple);
          return ReaderLyricsPlayerOverlay(
            lyricsView: const SizedBox.expand(),
            data: LyricsPlayerData(
              title: 'book',
              cover: null,
              isPlaying: false,
              speed: 1,
              lyricsMasked: false,
              clock: _Clock(),
              controlsStyle: style,
              compactControls: compactControls,
            ),
            callbacks: callbacks(withExit: withExit),
            onHtmlThemeChanged: (_) {},
          );
        },
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

  // 2026-11-10 用户：窄屏左上角返回键改成与宽屏同款的「书籍模式」键，和 ×
  // 一起放在右上角。MD3 / Apple × 新版 / 经典四种窄屏都钉一遍；窄屏布局
  // 用出厂宽屏布局（顶部区摆着 bookMode，等同用户把它拖进了窄屏布局），
  // 钉住布局按钮在窄屏不再渲染第二颗书籍模式键。
  for (final bool apple in <bool>[false, true]) {
    for (final LyricsControlsStyle style in LyricsControlsStyle.values) {
      final String name = '${apple ? 'apple' : 'md3'} ${style.name}';

      testWidgets('narrow $name: one book-mode button left of × in the '
          'top-right, no top-left back', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpWidget(
          app(
            withExit: true,
            apple: apple,
            style: style,
            compactControls: LyricsControlLayout.defaults,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.byKey(const ValueKey<String>('lyrics_player_back')),
          findsNothing,
        );
        expect(book, findsOneWidget);
        final Rect bookRect = tester.getRect(book);
        final Rect closeRect = tester.getRect(close);
        expect(bookRect.right, lessThanOrEqualTo(closeRect.left));
        expect(
          bookRect.center.dy,
          moreOrLessEquals(closeRect.center.dy, epsilon: 1),
        );
        expect(bookRect.left, greaterThan(390 / 2));
        await tester.tap(book);
        await tester.tap(close);
        expect(calls, <String>['book', 'exit']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('narrow $name without onExitBook: × alone returns to text', (
        WidgetTester tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpWidget(
          app(
            withExit: false,
            apple: apple,
            style: style,
            compactControls: LyricsControlLayout.defaults,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(book, findsNothing);
        await tester.tap(close);
        expect(calls, <String>['book']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

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
