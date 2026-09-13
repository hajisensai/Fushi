import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_text.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:html/parser.dart' as html_parser;

EpubBook _book(List<String> bodies) => EpubBook(
  title: 'Lyrics regression',
  chapters: <EpubChapter>[
    for (int i = 0; i < bodies.length; i++)
      EpubChapter(
        id: '$i',
        href: '$i.xhtml',
        mediaType: 'application/xhtml+xml',
        html: '<html><body>${bodies[i]}</body></html>',
      ),
  ],
);

AudioCue _cue(int start, int end, {int section = 0, String text = 'ASR'}) =>
    AudioCue()
      ..id = 42
      ..bookKey = 'book'
      ..chapterHref = '$section.xhtml'
      ..sentenceIndex = 7
      ..textFragmentId = SubtitleRematchCodec.encodeHit(
        sectionIndex: section,
        normCharStart: start,
        normCharEnd: end,
      )
      ..text = text
      ..startMs = 1234
      ..endMs = 5678
      ..audioFileIndex = 2;

String _html(List<AudioCue> cues, {EpubBook? book}) => LyricsModeHtml.generate(
  cues: cues,
  book: book,
  currentIndex: 0,
  backgroundColor: '#fff',
  textColor: '#000',
  accentColor: '#f08',
  fontSize: 24,
);

void main() {
  test('matched lyrics preserve screenshot kanji instead of ASR spellings', () {
    const List<(String, String)> pairs = <(String, String)>[
      ('牛の餌', 'うしの餌'),
      ('僕の痴れ者', '僕の知れもの'),
      ('運命の出会いなんかに憧れた僕が馬鹿だった', '運命の出会いなんかに憧れた僕がバカだった'),
      ('一攫千金ならぬ一攫美少女なんて夢のまた夢だった', '一獲千金ならぬ一カク美少女なんて夢のまた夢だった'),
    ];
    for (final (String original, String transcript) in pairs) {
      final EpubBook book = _book(<String>[original]);
      final AudioCue cue = _cue(
        0,
        AudioTextNormalizer.normalize(original).length,
        text: transcript,
      );
      expect(LyricsCueTextResolver(book).textForCue(cue), original);
      expect(
        html_parser
            .parse(_html(<AudioCue>[cue], book: book))
            .querySelector('.cue')!
            .text,
        original,
      );
    }
  });

  test(
    'ruby annotations are excluded and internal punctuation and glyphs retained',
    () {
      final EpubBook book = _book(<String>[
        '「<ruby>馬鹿<rp>（</rp><rt>ばか</rt><rp>）</rp><rtc>BAKA</rtc></ruby>、ＡＢＣ！カナ。」',
      ]);
      expect(LyricsCueTextResolver(book).textForCue(_cue(0, 7)), '馬鹿、ＡＢＣ！カナ');
    },
  );

  test(
    'fragment addresses the specified chapter and span rather than searching ASR',
    () {
      final EpubBook book = _book(<String>['猫だ。', '前。犬だ。後']);
      expect(
        LyricsCueTextResolver(
          book,
        ).textForCue(_cue(1, 3, section: 1, text: '猫だ')),
        '犬だ',
      );
    },
  );

  test(
    'cross-chapter cue preserves intervening punctuation through empty chapters',
    () {
      final EpubBook book = _book(<String>['前。猫、', '', '！', '犬だ。後']);
      expect(LyricsCueTextResolver(book).textForCue(_cue(1, 5)), '猫、！犬だ。後');
      expect(LyricsCueTextResolver(book).textForCue(_cue(1, 4)), '猫、！犬だ');
    },
  );

  test('unmatched and non-rematch fragments retain transcript', () {
    final LyricsCueTextResolver resolver = LyricsCueTextResolver(
      _book(<String>['猫だ']),
    );
    for (final String fragment in <String>[
      '',
      'srt://1',
      '#line1',
      'fushi-cue://s=0',
    ]) {
      final AudioCue cue = _cue(0, 2)..textFragmentId = fragment;
      expect(resolver.textForCue(cue), 'ASR');
    }
  });

  test('invalid ranges fall back without clamping or partial chapter text', () {
    final LyricsCueTextResolver resolver = LyricsCueTextResolver(
      _book(<String>['猫だ', '犬だ']),
    );
    for (final AudioCue cue in <AudioCue>[
      _cue(-1, 1),
      _cue(1, 1),
      _cue(2, 1),
      _cue(2, 3),
      _cue(0, 5),
      _cue(0, 1, section: -1),
      _cue(0, 1, section: 2),
    ]) {
      expect(resolver.textForCue(cue), 'ASR', reason: cue.textFragmentId);
    }
    expect(
      LyricsCueTextResolver(_book(<String>[''])).textForCue(_cue(0, 1)),
      'ASR',
    );
  });

  test('astral CJK uses UTF-16 ranges and rejects split surrogate pairs', () {
    final LyricsCueTextResolver resolver = LyricsCueTextResolver(
      _book(<String>['𠮷野。犬']),
    );
    expect(resolver.textForCue(_cue(0, 2)), '𠮷');
    expect(resolver.textForCue(_cue(0, 3)), '𠮷野');
    expect(resolver.textForCue(_cue(0, 1)), 'ASR');
    expect(resolver.textForCue(_cue(1, 3)), 'ASR');
    final LyricsCueTextResolver across = LyricsCueTextResolver(
      _book(<String>['猫', '𠮷野']),
    );
    expect(across.textForCue(_cue(0, 2)), 'ASR');
    expect(across.textForCue(_cue(0, 3)), '猫𠮷');
  });

  test(
    'HTML displays escaped original text and preserves cue metadata and timing',
    () {
      final EpubBook book = _book(<String>['猫&lt;犬&amp;鳥&gt;牛']);
      final AudioCue cue = _cue(0, 4, text: 'ねこいぬとりうし');
      final String fragment = cue.textFragmentId;
      final CueTokenTiming timing = CueTokenTiming(
        tokens: <String>['ねこ'],
        offsetsMs: <int>[100],
      );
      cue.tokenTiming = timing;
      final List<AudioCue> cues = <AudioCue>[cue];
      final String html = _html(cues, book: book);
      final element = html_parser.parse(html).querySelector('.cue')!;
      expect(element.text, '猫<犬&鳥>牛');
      expect(element.children, isEmpty);
      expect(element.attributes['data-text-fragment-id'], fragment);
      expect(element.attributes['data-cue-index'], '0');
      expect(cues.single, same(cue));
      expect(cue.text, 'ねこいぬとりうし');
      expect(cue.textFragmentId, fragment);
      expect(cue.id, 42);
      expect(cue.sentenceIndex, 7);
      expect((cue.startMs, cue.endMs, cue.audioFileIndex), (1234, 5678, 2));
      expect(cue.tokenTiming, same(timing));
    },
  );

  test('HTML without EPUB context keeps existing transcript rendering', () {
    expect(
      html_parser
          .parse(_html(<AudioCue>[_cue(0, 2, text: '犬＆猫')]))
          .querySelector('.cue')!
          .text,
      '犬＆猫',
    );
  });

  test(
    'reader supplies EPUB to lyrics and resolves mining cue text only in lyrics mode',
    () {
      final String lyrics = File(
        'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
      ).readAsStringSync();
      final int generateStart = lyrics.indexOf('LyricsModeHtml.generate(');
      final String generate = lyrics.substring(
        generateStart,
        lyrics.indexOf('\n    );', generateStart),
      );
      expect(generate, contains('book: _book'));
      final String audio = File(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      ).readAsStringSync();
      final int syncStart = audio.indexOf('void _syncCueSentence()');
      final String sync = audio.substring(
        syncStart,
        audio.indexOf('\n  ///', syncStart),
      );
      expect(sync, contains('_lyricsMode && book != null'));
      // 解析器按 _book 持有（自带章缓存），不能每次查词 new 一个——那等于每次
      // 查词整章重解析 DOM。
      expect(sync, contains('_lyricsCueTextResolverFor(book).textForCue(cue)'));
      expect(sync, isNot(contains('LyricsCueTextResolver(book)')));
      final int forStart = audio.indexOf(
        'LyricsCueTextResolver _lyricsCueTextResolverFor(EpubBook book)',
      );
      expect(forStart, greaterThan(-1));
      final String resolverFor = audio.substring(
        forStart,
        audio.indexOf('\n  }', forStart),
      );
      expect(resolverFor, contains('identical(cached.book, book)'));
      expect(sync, contains('setCurrentCueSentence('));
      expect(sync, contains('FushiTextSelection(text: cueText)'));
    },
  );
}
