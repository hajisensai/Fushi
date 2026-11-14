import 'package:fushi_engine/media/audiobook/book_audiobook_pairing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final p.Context _posix = p.Context(style: p.Style.posix);

BookAudiobookPairingPlan _pair({
  required List<String> books,
  List<String> paired = const <String>[],
  required List<String> audio,
  List<String> subtitles = const <String>[],
}) => pairBooksWithAudiobooks(
  unpairedBookPaths: books,
  pairedBookPaths: paired,
  unclaimedAudioPaths: audio,
  subtitlePaths: subtitles,
  subtitleLangCode: 'ja',
  context: _posix,
);

void main() {
  group('isAudiobookDiscFolderName', () {
    test('truth table', () {
      for (final String yes in <String>[
        'CD1',
        'cd 2',
        'Disc 2',
        'disc_03',
        'Disk-4',
        'Part 1',
        'PART10',
      ]) {
        expect(isAudiobookDiscFolderName(yes), isTrue, reason: yes);
      }
      for (final String no in <String>[
        'CD',
        'Disc',
        'Bonus',
        'CD1 extra',
        'Part One',
        'Vol 1',
        '01',
        'mycd1',
      ]) {
        expect(isAudiobookDiscFolderName(no), isFalse, reason: no);
      }
    });
  });

  group('pairBooksWithAudiobooks', () {
    test('R2: X.epub + X/ subfolder with CD1/CD2 discs merged in order', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/lib/X.epub'],
        audio: <String>[
          '/lib/X/CD2/01.mp3',
          '/lib/X/CD1/02.mp3',
          '/lib/X/CD1/01.mp3',
          '/lib/X/CD10/01.mp3',
        ],
        subtitles: <String>['/lib/X/X.srt'],
      );
      final BookAudiobookPairing pairing = plan.byBook['/lib/X.epub']!;
      expect(pairing.rule, BookAudiobookPairRule.subFolder);
      expect(pairing.audioPaths, <String>[
        '/lib/X/CD1/01.mp3',
        '/lib/X/CD1/02.mp3',
        '/lib/X/CD2/01.mp3',
        '/lib/X/CD10/01.mp3',
      ]);
      expect(pairing.subtitlePath, '/lib/X/X.srt');
      expect(plan.ambiguousBookPaths, isEmpty);
    });

    test('R2 matches by folded title (case, width, punctuation)', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/lib/Ｆate・Stay Night.epub'],
        audio: <String>['/lib/fate stay night/track 1.mp3'],
        subtitles: <String>['/lib/Ｆate・Stay Night.ja.srt'],
      );
      final BookAudiobookPairing pairing =
          plan.byBook['/lib/Ｆate・Stay Night.epub']!;
      expect(pairing.rule, BookAudiobookPairRule.subFolder);
      expect(pairing.subtitlePath, '/lib/Ｆate・Stay Night.ja.srt');
    });

    test(
      'R2 beats R4: sole book with same-name folder takes the folder only',
      () {
        final BookAudiobookPairingPlan plan = _pair(
          books: <String>['/lib/X.epub'],
          audio: <String>['/lib/X/01.mp3', '/lib/bgm.mp3'],
        );
        final BookAudiobookPairing pairing = plan.byBook['/lib/X.epub']!;
        expect(pairing.rule, BookAudiobookPairRule.subFolder);
        expect(pairing.audioPaths, <String>['/lib/X/01.mp3']);
        expect(pairing.subtitlePath, isNull);
      },
    );

    test('R3: volume folders and series-named loose files pair one-to-one', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>[
          '/s/安達としまむら 1.epub',
          '/s/安達としまむら 2.epub',
          '/s/安達としまむら 3.epub',
        ],
        audio: <String>[
          '/s/Vol.1/01.mp3',
          '/s/Vol.1/02.mp3',
          '/s/第2巻/01.mp3',
          '/s/安達としまむら 03.m4b',
        ],
        subtitles: <String>['/s/Vol.1/vol1.srt'],
      );
      expect(plan.ambiguousBookPaths, isEmpty);
      final BookAudiobookPairing v1 = plan.byBook['/s/安達としまむら 1.epub']!;
      expect(v1.rule, BookAudiobookPairRule.volume);
      expect(v1.audioPaths, <String>['/s/Vol.1/01.mp3', '/s/Vol.1/02.mp3']);
      expect(v1.subtitlePath, '/s/Vol.1/vol1.srt');
      expect(plan.byBook['/s/安達としまむら 2.epub']!.audioPaths, <String>[
        '/s/第2巻/01.mp3',
      ]);
      expect(plan.byBook['/s/安達としまむら 3.epub']!.audioPaths, <String>[
        '/s/安達としまむら 03.m4b',
      ]);
    });

    test('R3: a unit volume without a book gives up the whole group', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/s/Book 1.epub', '/s/Book 2.epub'],
        audio: <String>['/s/Vol 1/a.mp3', '/s/Vol 2/a.mp3', '/s/Vol 3/a.mp3'],
      );
      expect(plan.byBook, isEmpty);
      expect(plan.ambiguousBookPaths, <String>[
        '/s/Book 1.epub',
        '/s/Book 2.epub',
      ]);
    });

    test('R3: bare numbered loose tracks are not volumes (sole book → R4)', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/b/Book 1.epub'],
        audio: <String>['/b/01.mp3', '/b/02.mp3', '/b/03.mp3'],
      );
      final BookAudiobookPairing pairing = plan.byBook['/b/Book 1.epub']!;
      expect(pairing.rule, BookAudiobookPairRule.soleBook);
      expect(pairing.audioPaths, <String>[
        '/b/01.mp3',
        '/b/02.mp3',
        '/b/03.mp3',
      ]);
    });

    test('R4: sole book takes loose + disc audio of its folder', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/b/Book.epub'],
        audio: <String>[
          '/b/CD2/01.mp3',
          '/b/CD1/01.mp3',
          '/b/intro.mp3',
          '/b/other/x.mp3',
        ],
        subtitles: <String>['/b/Book.srt', '/b/unrelated.srt'],
      );
      final BookAudiobookPairing pairing = plan.byBook['/b/Book.epub']!;
      expect(pairing.rule, BookAudiobookPairRule.soleBook);
      expect(pairing.audioPaths, <String>[
        '/b/intro.mp3',
        '/b/CD1/01.mp3',
        '/b/CD2/01.mp3',
      ]);
      expect(pairing.subtitlePath, '/b/Book.srt');
      // 无关子目录不归 R4，留给 R5。
      expect(
        plan.unclaimedUnits.map((AudiobookUnit u) => u.path),
        contains('/b/other'),
      );
    });

    test('R4 does not fire when the folder has another (R1-paired) book', () {
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/b/B.epub'],
        paired: <String>['/b/A.epub'],
        audio: <String>['/b/bonus.mp3'],
      );
      expect(plan.byBook, isEmpty);
      expect(plan.ambiguousBookPaths, isEmpty);
    });

    test('★ two books claiming the same audio both stay unpaired', () {
      // 父目录的 X.epub 经 R2 认领 X/，X/ 里唯一的书经 R4 认领 X/ 这一层的音频：
      // 同一批音频两本书抢，宁可漏配。
      final BookAudiobookPairingPlan plan = _pair(
        books: <String>['/lib/X.epub', '/lib/X/Extra.epub'],
        audio: <String>['/lib/X/01.mp3', '/lib/X/02.mp3'],
      );
      expect(plan.byBook, isEmpty);
      expect(plan.ambiguousBookPaths, <String>[
        '/lib/X.epub',
        '/lib/X/Extra.epub',
      ]);
      // 有争议的音频不留给 R5。
      expect(plan.unclaimedUnits, isEmpty);
    });

    test('result does not depend on input order', () {
      final List<String> books = <String>[
        '/s/Book 1.epub',
        '/s/Book 2.epub',
        '/lib/X.epub',
        '/one/Only.epub',
      ];
      final List<String> audio = <String>[
        '/s/Vol 1/a.mp3',
        '/s/Vol 2/a.mp3',
        '/lib/X/CD1/1.mp3',
        '/one/a.mp3',
        '/one/b.mp3',
      ];
      final BookAudiobookPairingPlan a = _pair(books: books, audio: audio);
      final BookAudiobookPairingPlan b = _pair(
        books: books.reversed.toList(),
        audio: audio.reversed.toList(),
      );
      expect(a.byBook, b.byBook);
      expect(a.byBook.length, 4);
      expect(a.ambiguousBookPaths, b.ambiguousBookPaths);
      expect(
        a.unclaimedUnits.map((AudiobookUnit u) => u.path).toList(),
        b.unclaimedUnits.map((AudiobookUnit u) => u.path).toList(),
      );
    });

    test('posix context keeps forward-slash URL paths verbatim', () {
      final BookAudiobookPairingPlan plan = pairBooksWithAudiobooks(
        unpairedBookPaths: <String>['https://dav.example/lib/X.epub'],
        unclaimedAudioPaths: <String>['https://dav.example/lib/X/CD1/01.mp3'],
        subtitlePaths: <String>['https://dav.example/lib/X/X.srt'],
        subtitleLangCode: 'ja',
        context: p.url,
      );
      final BookAudiobookPairing pairing =
          plan.byBook['https://dav.example/lib/X.epub']!;
      expect(pairing.audioPaths, <String>[
        'https://dav.example/lib/X/CD1/01.mp3',
      ]);
      expect(pairing.subtitlePath, 'https://dav.example/lib/X/X.srt');
    });
  });

  group('pairByBookTitles (R5)', () {
    List<AudiobookUnit> unitsFor(List<String> audio) =>
        _pair(books: const <String>[], audio: audio).unclaimedUnits;

    test('pairs by folded metadata title within the same folder', () {
      final Map<String, BookAudiobookPairing> out = pairByBookTitles(
        titleByBookPath: <String, String>{'/lib/vol01.epub': '春の物語'},
        unclaimed: unitsFor(<String>[
          '/lib/春の物語/01.mp3',
          '/elsewhere/春の物語/01.mp3',
        ]),
        subtitleLangCode: 'ja',
        context: _posix,
      );
      expect(out['/lib/vol01.epub']!.rule, BookAudiobookPairRule.metadata);
      expect(out['/lib/vol01.epub']!.audioPaths, <String>['/lib/春の物語/01.mp3']);
    });

    test('batch conflict: two books with the same title both give up', () {
      final List<AudiobookUnit> units = unitsFor(<String>['/lib/Story/01.mp3']);
      final Map<String, BookAudiobookPairing> out = pairByBookTitles(
        titleByBookPath: <String, String>{
          '/lib/a.epub': 'Story',
          '/lib/b.epub': 'story',
        },
        unclaimed: units,
        subtitleLangCode: 'ja',
        context: _posix,
      );
      expect(out, isEmpty);
    });

    test('order independent', () {
      final List<AudiobookUnit> units = unitsFor(<String>[
        '/lib/Story/01.mp3',
        '/lib/Other/01.mp3',
      ]);
      final Map<String, String> titles = <String, String>{
        '/lib/a.epub': 'Story',
        '/lib/b.epub': 'Other',
      };
      final Map<String, BookAudiobookPairing> forward = pairByBookTitles(
        titleByBookPath: titles,
        unclaimed: units,
        subtitleLangCode: 'ja',
        context: _posix,
      );
      final Map<String, BookAudiobookPairing> backward = pairByBookTitles(
        titleByBookPath: Map<String, String>.fromEntries(
          titles.entries.toList().reversed,
        ),
        unclaimed: units.reversed.toList(),
        subtitleLangCode: 'ja',
        context: _posix,
      );
      expect(forward, backward);
      expect(forward.length, 2);
    });
  });
}
