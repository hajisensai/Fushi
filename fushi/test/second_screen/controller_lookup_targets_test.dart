import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_controller_cursor_scripts.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart'
    show
        mangaControllerBlockText,
        mangaControllerFirstTextBlock,
        mangaControllerNextTextBlock;
import 'package:fushi/src/media/shared/controller_lookup_steps.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart'
    show musicControllerNextTextLine;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerControllerLineAction;
import 'package:fushi/src/shortcuts/reader_caret_router.dart' show CaretAction;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_music/fushi_music.dart';

/// Deterministic tokenizer: words are separated by `|` in the test input,
/// which is stripped before tokenizing.
List<String> Function(String) _words(String marked) {
  final List<String> words = marked.split('|');
  return (String text) {
    expect(text, words.join());
    return words;
  };
}

MokuroBlock _block(List<String> lines) => MokuroBlock(
  rectangle: MokuroRect.zero,
  isVertical: true,
  fontSize: 10,
  zIndex: 0,
  lines: lines,
);

LyricLine _line(String text) => LyricLine(
  startMs: 0,
  endMs: 1000,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: 0, endMs: 1000),
  ],
);

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('controller lookup steps', () {
    test('character steps are grapheme-safe and clamp at the ends', () {
      const String text = 'a😀b';
      expect(controllerLookupCharStep(text, 0, 1), 1);
      expect(controllerLookupCharStep(text, 1, 1), 3, reason: 'skips pair');
      expect(controllerLookupCharStep(text, 3, 1), 3, reason: 'clamped');
      expect(controllerLookupCharStep(text, 3, -1), 1);
      expect(controllerLookupCharStep(text, 0, -1), 0);
      expect(controllerLookupCharStep('', 0, 1), 0);
    });

    test('word steps go to word starts, back from inside a word to its '
        'start, null at the ends', () {
      final List<String> Function(String) tok = _words('私は|先生と|呼んだ');
      const String text = '私は先生と呼んだ';
      expect(controllerLookupWordStep(text, 0, 1, tokenize: tok), 2);
      expect(controllerLookupWordStep(text, 2, 1, tokenize: tok), 5);
      expect(controllerLookupWordStep(text, 5, 1, tokenize: tok), isNull);
      expect(controllerLookupWordStep(text, 3, -1, tokenize: tok), 2);
      expect(controllerLookupWordStep(text, 2, -1, tokenize: tok), 0);
      expect(controllerLookupWordStep(text, 0, -1, tokenize: tok), isNull);
      expect(controllerLookupWordStep('', 0, 1), isNull);
    });

    test('subtitle word entry: same cue only, -1 at the ends, null to fall '
        'back to characters', () {
      final Object cueA = Object();
      final Object cueB = Object();
      // Registry: cue A 'あいう' (3 chars) then cue B 'あいう'.
      final List<ControllerLookupSubtitleChar> entries =
          <ControllerLookupSubtitleChar>[
            for (int i = 0; i < 3; i++)
              (sentence: 'あいう', graphemeIndex: i, cue: cueA),
            for (int i = 0; i < 3; i++)
              (sentence: 'あいう', graphemeIndex: i, cue: cueB),
          ];
      int? step(int current, int dir) => controllerLookupSubtitleWordEntry(
        current: current,
        dir: dir,
        entryCount: entries.length,
        charAt: (int i) => entries[i],
        tokenize: _words('あ|いう'),
      );
      expect(step(0, 1), 1);
      expect(step(1, 1), -1, reason: 'last word of the cue');
      expect(step(2, -1), 1, reason: 'back to the start of its word');
      expect(step(4, -1), 3, reason: 'stays in cue B');
      expect(step(3, -1), -1);
      expect(
        controllerLookupSubtitleWordEntry(
          current: 0,
          dir: 1,
          entryCount: 0,
          charAt: (int _) => null,
        ),
        isNull,
      );
    });
  });

  group('reader', () {
    test('line steps use the physical direction of the writing mode', () {
      expect(
        readerControllerLineAction(1, vertical: true),
        CaretAction.moveLeft,
      );
      expect(
        readerControllerLineAction(-1, vertical: true),
        CaretAction.moveRight,
      );
      expect(
        readerControllerLineAction(1, vertical: false),
        CaretAction.moveDown,
      );
      expect(
        readerControllerLineAction(-1, vertical: false),
        CaretAction.moveUp,
      );
    });
  });

  group('manga', () {
    test('blocks with text in reading order; empty blocks are skipped', () {
      final List<MokuroBlock> blocks = <MokuroBlock>[
        _block(const <String>[' ']),
        _block(const <String>['大丈夫', 'だよな']),
        _block(const <String>[]),
        _block(const <String>['?']),
      ];
      expect(mangaControllerFirstTextBlock(blocks), 1);
      expect(mangaControllerNextTextBlock(blocks, 1, 1), 3);
      expect(mangaControllerNextTextBlock(blocks, 3, 1), -1);
      expect(mangaControllerNextTextBlock(blocks, 3, -1), 1);
      expect(mangaControllerNextTextBlock(blocks, 1, -1), -1);
      expect(mangaControllerBlockText(blocks[1]), '大丈夫だよな');
      expect(mangaControllerFirstTextBlock(const <MokuroBlock>[]), -1);
    });

    test('cursor scripts target the page / block / offset and use the '
        "document's own selection path", () {
      final String place = MangaControllerCursorScripts.place(
        page: 4,
        block: 2,
        utf16: 7,
        color: 'rgba(1,2,3,0.95)',
      );
      expect(place, endsWith('(4,2,7,"rgba(1,2,3,0.95)",false)'));
      expect(place, contains('.manga-page[data-page="'));
      expect(place, contains("querySelectorAll('.ocr-box')[block]"));
      expect(place, contains('data-utf16-start'));
      final String lookup = MangaControllerCursorScripts.place(
        page: 0,
        block: 0,
        utf16: 0,
        color: 'red',
        lookup: true,
      );
      expect(lookup, endsWith(',true)'));
      expect(lookup, contains('selection.clearSelection()'));
      expect(lookup, contains('selection.selectFromPosition(node, offset, 40'));
      expect(
        MangaControllerCursorScripts.clear(),
        endsWith('(-1,0,0,"",false)'),
      );
    });
  });

  group('music', () {
    test('line steps skip empty lyric lines', () {
      final LyricTimeline t = LyricTimeline(
        format: 'lrc',
        timingQuality: LyricTimingQuality.line,
        lines: <LyricLine>[_line('一'), _line(' '), _line('二')],
      );
      expect(musicControllerNextTextLine(t, -1, 1), 0);
      expect(musicControllerNextTextLine(t, 0, 1), 2);
      expect(musicControllerNextTextLine(t, 2, 1), -1);
      expect(musicControllerNextTextLine(t, 2, -1), 0);
    });
  });

  group('page wiring (source)', () {
    const String reader =
        'lib/src/pages/implementations/reader_fushi_page.dart';
    const String video = 'lib/src/pages/implementations/video_fushi_page.dart';
    const String manga = 'lib/src/media/manga/reader/manga_fushi_page.dart';
    const String music =
        'lib/src/pages/implementations/music/music_lyrics_page.dart';

    test('every page attaches its target in initState and detaches it in '
        'dispose', () {
      for (final String page in <String>[reader, video, manga]) {
        final String src = _read(page);
        expect(src, contains('_attachControllerLookup();'), reason: page);
        expect(src, contains('_detachControllerLookup();'), reason: page);
      }
      final String src = _read(music);
      expect(
        src,
        contains(
          'ControllerLookupMode.instance.attach(_controllerLookupTarget)',
        ),
      );
      expect(
        src,
        contains(
          'ControllerLookupMode.instance.detach(_controllerLookupTarget)',
        ),
      );
      expect(src, contains('cursor: _lookupCursor'));
    });

    test('companion claims count lookups with the page counter', () {
      expect(
        _read(
          'lib/src/second_screen/companion/modules/reader_companion_hook.dart',
        ),
        contains('onLookupCounted: _page.countLookup'),
      );
      expect(
        _read('lib/src/media/manga/reader/manga_companion_hook.dart'),
        contains('onLookupCounted: _reader.countLookup'),
      );
      expect(_read(music), contains('onLookupCounted: recordCompanionLookup'));
      for (final String part in <String>[
        'lib/src/pages/implementations/reader_fushi/companion.part.dart',
        'lib/src/media/manga/reader/manga_fushi/companion.part.dart',
      ]) {
        expect(
          _read(part),
          contains('_state.recordCompanionLookup()'),
          reason: part,
        );
      }
    });

    test('targets stay out of focus requests and the gamepad channel', () {
      for (final String part in <String>[
        'lib/src/pages/implementations/reader_fushi/controller_lookup.part.dart',
        'lib/src/pages/implementations/video_fushi/controller_lookup.part.dart',
        'lib/src/media/manga/reader/manga_fushi/controller_lookup.part.dart',
        'lib/src/pages/implementations/music/music_lyrics_controller_lookup.part.dart',
      ]) {
        final String src = _read(part);
        expect(src, isNot(contains('requestFocus')), reason: part);
        expect(src, isNot(contains('resolveGamepad')), reason: part);
        expect(src, isNot(contains('GamepadButtonIntent')), reason: part);
      }
    });
  });
}
