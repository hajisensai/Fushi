import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_text.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:html/dom.dart' as html_dom;
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
      // 2026-10-04：句首开括号与句末「。」」随行显示（归一化剥掉的收尾标点补回）。
      expect(
        LyricsCueTextResolver(book).textForCue(_cue(0, 7)),
        '「馬鹿、ＡＢＣ！カナ。」',
      );
    },
  );

  // 用户 2026-10-04 报「歌词模式没有标点」：matcher 的区间是归一化坐标（标点已剥），
  // 按它截正文会丢掉每句末尾的「。」「」」。歌词行显示 cue 命中的**正文原文**，
  // 收尾标点 / 闭括号与句首开括号都要在，但不能吞进下一句的开括号或换行。
  group('lyrics line keeps sentence punctuation from the book', () {
    String line(String body, String sentence) {
      final EpubBook book = _book(<String>[body]);
      final String norm = AudioTextNormalizer.normalize(body);
      final String target = AudioTextNormalizer.normalize(sentence);
      final int start = norm.indexOf(target);
      expect(start, greaterThanOrEqualTo(0), reason: sentence);
      return LyricsCueTextResolver(
        book,
      ).textForCue(_cue(start, start + target.length));
    }

    test('sentence ending with 。', () {
      expect(
        line('月が替わると、体育の種目も変わる。次の授業だ。', '月が替わると体育の種目も変わる'),
        '月が替わると、体育の種目も変わる。',
      );
    });

    test('quoted sentence ending with 」 takes its opening 「 too', () {
      expect(
        line('彼は言った。「月が替わると、体育の種目も変わる」次だ', '月が替わると体育の種目も変わる'),
        '「月が替わると、体育の種目も変わる」',
      );
    });

    test('」 followed by 。 keeps both', () {
      expect(line('「体育の種目も変わる」。<br/>「次の授業だ」', '体育の種目も変わる'), '「体育の種目も変わる」。');
    });

    test(
      "does not swallow the next line's opening bracket or exclamation run",
      () {
        expect(line('本当か！？「次だ」', '本当か'), '本当か！？');
        expect(line('本当か！？「次だ」', '次だ'), '「次だ」');
      },
    );
  });

  test(
    'fragment addresses the specified chapter and span rather than searching ASR',
    () {
      final EpubBook book = _book(<String>['猫だ。', '前。犬だ。後']);
      expect(
        LyricsCueTextResolver(
          book,
        ).textForCue(_cue(1, 3, section: 1, text: '猫だ')),
        '犬だ。',
      );
    },
  );

  test(
    'cross-chapter cue preserves intervening punctuation through empty chapters',
    () {
      final EpubBook book = _book(<String>['前。猫、', '', '！', '犬だ。後']);
      expect(LyricsCueTextResolver(book).textForCue(_cue(1, 5)), '猫、！犬だ。後');
      expect(LyricsCueTextResolver(book).textForCue(_cue(1, 4)), '猫、！犬だ。');
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
    expect(resolver.textForCue(_cue(0, 3)), '𠮷野。');
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
      // 2026-10-04：cue 正文包在行内 `.tx` 里（逐字扫过的渐变载体）；转义正确
      // 时它里面不会再有任何被注入的元素。
      expect(element.children.single.classes, contains('tx'));
      expect(element.children.single.children, isEmpty);
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

  test('ruby in the book comes back as <ruby><rt> furigana in lyrics HTML', () {
    // 正文：艦長は<ruby>共通信号<rt>きょうつうしんごう</rt></ruby>の発信を命じた。
    const String body = '<p>艦長は<ruby>共通信号<rt>きょうつうしんごう</rt></ruby>の発信を命じた。</p>';
    final EpubBook book = _book(<String>[body]);
    // 尾部句号在归一化区间之外；2026-10-04 起 resolver 把句末标点补回（歌词行
    // 显示正文原文、带句号），ruby 区间不受影响。
    const String plain = '艦長は共通信号の発信を命じた。';
    final AudioCue cue = _cue(
      0,
      AudioTextNormalizer.normalize(plain).length,
      text: '艦長は共通信号の発信を命じた',
    );
    final LyricsCueText resolved = LyricsCueTextResolver(
      book,
    ).resolveForCue(cue);
    expect(resolved.text, plain);
    expect(resolved.rubies, hasLength(1));
    expect(resolved.rubies.single.start, 3);
    expect(resolved.rubies.single.end, 7);
    expect(resolved.rubies.single.reading, 'きょうつうしんごう');
    // 纯文本入口不变：查词句子拿基底、不带读音。
    expect(LyricsCueTextResolver(book).textForCue(cue), plain);

    final html_dom.Document doc = html_parser.parse(
      _html(<AudioCue>[cue], book: book),
    );
    final html_dom.Element cueEl = doc.querySelector('.cue')!;
    expect(cueEl.querySelector('ruby')!.text, '共通信号きょうつうしんごう');
    expect(cueEl.querySelector('rt')!.text, 'きょうつうしんごう');
    // 收藏标记按无读音的 data-text 比对（textContent 会把 rt 拼进来）。
    expect(cueEl.attributes['data-text'], plain);
    expect(cueEl.text, isNot(plain));
    expect(
      _html(<AudioCue>[cue], book: book),
      contains('(cues[i].dataset.text || cues[i].textContent)'),
    );
    expect(
      cueEl.innerHtml,
      contains('艦長は<ruby>共通信号<rt>きょうつうしんごう</rt></ruby>の発信を命じた'),
    );
  });

  test('ruby cut by the cue boundary is dropped, not half-rendered', () {
    const String body =
        '<p>停<ruby>船<rt>せん</rt></ruby>せよ。<ruby>艦長<rt>かんちょう</rt></ruby>は命じた。</p>';
    final EpubBook book = _book(<String>[body]);
    // 归一化 停0船1せ2よ3艦4長5：cue 只盖「せよ艦」——「艦長」ruby 被切开 → 丢；
    // 「船」不在区间内。
    final AudioCue cue = _cue(2, 5, text: 'せよかん');
    final LyricsCueText resolved = LyricsCueTextResolver(
      book,
    ).resolveForCue(cue);
    expect(resolved.text, 'せよ。艦');
    expect(resolved.rubies, isEmpty);
    expect(
      html_parser
          .parse(_html(<AudioCue>[cue], book: book))
          .querySelector('.cue ruby'),
      isNull,
    );
  });

  test('cue without EPUB context has no rubies and no ruby markup', () {
    final AudioCue cue = _cue(0, 3, text: 'ざつおん');
    expect(
      html_parser.parse(_html(<AudioCue>[cue])).querySelector('.cue ruby'),
      isNull,
    );
  });

  group('skipped book text between cues (跳读灰显)', () {
    // 用户报的形态：ASR 漏转后半句，合缝也认领不下时缝留在两条 cue 之间。
    // 归一化：あなたが犯人だっていってまわればいいんだ(0-20) それで(20-23)
    // ぎょっとしたやつが犯人(23-34) そして(34-37) 彼は笑った(37-42)。
    const String body =
        '<p>「あなたが犯人だ、っていってまわればいいんだ！　'
        'それで、ぎょっとしたやつが犯人！」そして、彼は笑った。</p>';

    test(
      'text between two same-chapter cues is returned, flush with both lines',
      () {
        final EpubBook book = _book(<String>[body]);
        final LyricsCueTextResolver resolver = LyricsCueTextResolver(book);
        final AudioCue prev = _cue(0, 20);
        final AudioCue next = _cue(34, 37);
        final LyricsCueText? gap = resolver.skippedTextBetween(prev, next);
        expect(gap, isNotNull);
        // 两侧歌词行与灰显行首尾相接、不重不漏（全角空格是行间空白，去掉）。
        expect(resolver.textForCue(prev), '「あなたが犯人だ、っていってまわればいいんだ！');
        expect(gap!.text, 'それで、ぎょっとしたやつが犯人！」');
        expect(resolver.textForCue(next), 'そして、');
      },
    );

    test(
      'no gap: adjacent ranges, overlap, or only punctuation / one char',
      () {
        final EpubBook book = _book(<String>[body]);
        final LyricsCueTextResolver resolver = LyricsCueTextResolver(book);
        expect(resolver.skippedTextBetween(_cue(0, 20), _cue(20, 34)), isNull);
        expect(resolver.skippedTextBetween(_cue(0, 22), _cue(20, 34)), isNull);
        // 乱序（后一条在前一条之前）。
        expect(resolver.skippedTextBetween(_cue(34, 37), _cue(0, 20)), isNull);
        // 缝只有 1 个有读音的字（模糊命中漏掉的词尾）。
        expect(resolver.skippedTextBetween(_cue(0, 20), _cue(21, 34)), isNull);
        expect(
          resolver.skippedTextBetween(_cue(0, 20), _cue(22, 34))!.text,
          'それ',
        );
      },
    );

    test('no gap across chapters, at chapter edges, or for unmatched cues', () {
      final EpubBook book = _book(<String>['あいうえお。', 'かきくけこ。']);
      final LyricsCueTextResolver resolver = LyricsCueTextResolver(book);
      // 跨章：前一章末尾 / 后一章开头的未认领正文都不显示。
      expect(
        resolver.skippedTextBetween(_cue(0, 2), _cue(3, 5, section: 1)),
        isNull,
      );
      final AudioCue unmatched = AudioCue()
        ..bookKey = 'book'
        ..chapterHref = '0.xhtml'
        ..textFragmentId = ''
        ..text = 'ASR';
      expect(resolver.skippedTextBetween(_cue(0, 1), unmatched), isNull);
      expect(resolver.skippedTextBetween(unmatched, _cue(4, 5)), isNull);
    });

    test('ruby inside the skipped text is kept', () {
      final EpubBook book = _book(<String>[
        '<p>停船せよ。<ruby>艦長<rt>かんちょう</rt></ruby>は命じた。出航。</p>',
      ]);
      // 归一化：停船せよ(0-4) 艦長は命じた(4-10) 出航(10-12)。
      final LyricsCueText gap = LyricsCueTextResolver(
        book,
      ).skippedTextBetween(_cue(0, 4), _cue(10, 12))!;
      expect(gap.text, '艦長は命じた。');
      expect(gap.rubies, hasLength(1));
      expect(gap.rubies.single.start, 0);
      expect(gap.rubies.single.end, 2);
      expect(gap.rubies.single.reading, 'かんちょう');
    });

    String page(
      List<AudioCue> cues,
      EpubBook book, {
      int current = 0,
      bool show = true,
    }) => LyricsModeHtml.generate(
      cues: cues,
      book: book,
      currentIndex: current,
      backgroundColor: '#fff',
      textColor: '#000',
      accentColor: '#f08',
      fontSize: 24,
      showSkippedText: show,
    );

    test('lyrics HTML puts a non-cue .ly-gap row between the two lines', () {
      final EpubBook book = _book(<String>[body]);
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 20),
        _cue(34, 37),
        _cue(37, 42),
      ];
      final String html = page(cues, book);
      final html_dom.Document doc = html_parser.parse(html);
      final List<html_dom.Element> rows = doc
          .querySelector('#lc')!
          .children
          .toList();
      expect(rows.map((html_dom.Element e) => e.className).toList(), <String>[
        'cue current',
        'ly-gap near-1',
        'cue near-1',
        'cue near-2',
      ]);
      final html_dom.Element gap = rows[1];
      expect(gap.text, 'それで、ぎょっとしたやつが犯人！」');
      expect(gap.attributes['data-after'], '0');
      // 灰显行没有 cue 身份：不带下标 / fragment / 收藏比对文本，JS 按 .cue 取行
      // 时数不到它，cue 下标与 Dart 侧一一对应不变。
      expect(gap.attributes.containsKey('data-cue-index'), isFalse);
      expect(gap.attributes.containsKey('data-text-fragment-id'), isFalse);
      expect(
        doc
            .querySelectorAll('.cue')
            .map((html_dom.Element e) => e.attributes['data-cue-index'])
            .toList(),
        <String?>['0', '1', '2'],
      );
      // 默认显示；关掉开关只挂 body class，行仍在文档里（热更不重建整页）。
      expect(doc.body!.classes, isNot(contains('ly-hide-skipped')));
      final html_dom.Document hidden = html_parser.parse(
        page(cues, book, show: false),
      );
      expect(hidden.body!.classes, contains('ly-hide-skipped'));
      expect(hidden.querySelectorAll('.ly-gap'), hasLength(1));
      expect(html, contains('body.ly-hide-skipped .ly-gap { display: none; }'));
      expect(html, contains('window.__lyricsSetShowSkipped = function(on)'));
    });

    test(
      'gap opacity step follows the nearer neighbour of the current line',
      () {
        final EpubBook book = _book(<String>[body]);
        final List<AudioCue> cues = <AudioCue>[
          _cue(0, 20),
          _cue(34, 37),
          _cue(37, 42),
        ];
        // 当前句是第 2 行（下标 2）：灰显行夹在 0 与 1 之间，离当前句近的是 1
        // （near-1）→ 灰显行 near-2。
        final html_dom.Element gap = html_parser
            .parse(page(cues, book, current: 2))
            .querySelector('.ly-gap')!;
        expect(gap.className, 'ly-gap near-2');
      },
    );

    test('gap rows never take lookups (no cue context to mine against)', () {
      final String html = page(<AudioCue>[
        _cue(0, 20),
        _cue(34, 37),
      ], _book(<String>[body]));
      final int start = html.indexOf('window.fushiSelection.selectText = ');
      final int gapGuard = html.indexOf("hitEl.closest('.ly-gap')", start);
      final int forward = html.indexOf('origSelectText.apply', start);
      expect(start, isNonNegative);
      expect(gapGuard, greaterThan(start));
      expect(gapGuard, lessThan(forward));
    });

    test('no EPUB context → no gap rows', () {
      final String html = _html(<AudioCue>[_cue(0, 20), _cue(34, 37)]);
      expect(html_parser.parse(html).querySelectorAll('.ly-gap'), isEmpty);
    });
  });
}
