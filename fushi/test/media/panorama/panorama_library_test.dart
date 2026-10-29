// 媒体库全景数据层的纯函数：词抽取（内部编号回退字段）、作品归并（播放列表 / 去集号同名）、
// 挂词（出处优先、标签空格写成 _）、均匀抽样上限。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/panorama/panorama_library.dart';

void main() {
  group('panoramaNoteWord', () {
    test('uses sort_field when it is a real word', () {
      expect(panoramaNoteWord('<b>食べる</b>', const <String>[]), '食べる');
    });

    test('falls back to the first Japanese-looking field for internal ids', () {
      expect(
        panoramaNoteWord('1700000012345', const <String>[
          '1700000012345',
          'to eat',
          '[sound:a.mp3]',
          '食べる',
          '飲む',
        ]),
        '食べる',
      );
      expect(
        panoramaNoteWord('a1b2-c3d4', const <String>['abc', 'x9']),
        isNull,
      );
    });

    test('internal id / japanese word predicates', () {
      expect(panoramaLooksLikeInternalId('12345'), isTrue);
      expect(panoramaLooksLikeInternalId('id_00f3'), isTrue);
      expect(panoramaLooksLikeInternalId('hello'), isFalse);
      expect(panoramaLooksLikeInternalId('猫'), isFalse);
      expect(panoramaLooksLikeJapaneseWord('ネコ'), isTrue);
      expect(panoramaLooksLikeJapaneseWord('cat'), isFalse);
      expect(panoramaLooksLikeJapaneseWord('これはとても長い文章ですけれども'), isFalse);
    });
  });

  test('panoramaSampleEvenly keeps order and respects the cap', () {
    final List<int> xs = List<int>.generate(100, (int i) => i);
    final List<int> s = panoramaSampleEvenly(xs, 40);
    expect(s, hasLength(40));
    expect(s.first, 0);
    expect(s, orderedEquals(List<int>.of(s)..sort()));
    expect(panoramaSampleEvenly(<int>[1, 2], 40), <int>[1, 2]);
  });

  group('panoramaGroupVideos', () {
    test(
      'playlist members collapse into one work; leftovers group by series',
      () {
        final List<PanoramaWork> works = panoramaGroupVideos(
          const <PanoramaVideoInput>[
            PanoramaVideoInput(
              bookUid: 'a1',
              title: '[Sub] Frieren - 01',
              coverPath: null,
            ),
            PanoramaVideoInput(
              bookUid: 'a2',
              title: '[Sub] Frieren - 02',
              coverPath: '/c/a2.jpg',
              lastPlayedAt: 9,
            ),
            PanoramaVideoInput(
              bookUid: 'b1',
              title: 'Bocchi the Rock 01',
              coverPath: null,
            ),
            PanoramaVideoInput(
              bookUid: 'b2',
              title: 'Bocchi the Rock 02',
              coverPath: '/c/b2.jpg',
            ),
          ],
          const <PanoramaPlaylistInput>[
            PanoramaPlaylistInput(
              id: 7,
              name: 'Bocchi',
              coverPath: null,
              memberUids: <String>['b1', 'b2'],
            ),
          ],
        );
        expect(works, hasLength(2));
        final PanoramaWork bocchi = works.first;
        expect(bocchi.title, 'Bocchi');
        expect(bocchi.playlistCollectionId, 7);
        expect(bocchi.memberKeys, <String>['b1', 'b2']);
        expect(bocchi.coverPath, '/c/b2.jpg');
        final PanoramaWork frieren = works.last;
        expect(frieren.memberKeys, <String>['a1', 'a2']);
        expect(frieren.key, 'a2', reason: 'most recently played episode opens');
        expect(frieren.coverPath, '/c/a2.jpg');
      },
    );
  });

  group('panoramaAssignWords', () {
    const List<PanoramaWork> works = <PanoramaWork>[
      PanoramaWork(
        kind: PanoramaWorkKind.book,
        key: 'book-key',
        title: 'ぼっち ざ ろっく',
        coverPath: null,
        memberKeys: <String>['book-key', 'book_uid_1'],
      ),
      PanoramaWork(
        kind: PanoramaWorkKind.video,
        key: 'v1',
        title: 'Frieren',
        coverPath: null,
      ),
    ];

    test('source bookKey wins over tags; tags match with underscores', () {
      final List<PanoramaWord> words = panoramaAssignWords(
        works,
        const <PanoramaNoteInput>[
          PanoramaNoteInput(
            sortField: '弾く',
            tags: <String>['frieren'],
            sourceKeys: <String>['book-key'],
          ),
          PanoramaNoteInput(sortField: '魔法', tags: <String>['Frieren']),
          PanoramaNoteInput(sortField: '陰キャ', tags: <String>['ぼっち_ざ_ろっく']),
          PanoramaNoteInput(sortField: '無主', tags: <String>['other']),
        ],
      );
      String? ownerOf(String w) => <int, String>{
        -1: 'loose',
        0: 'book',
        1: 'video',
      }[words.firstWhere((PanoramaWord x) => x.text == w).work];
      expect(ownerOf('弾く'), 'book');
      expect(ownerOf('魔法'), 'video');
      expect(ownerOf('陰キャ'), 'book');
      expect(ownerOf('無主'), 'loose');
    });

    test('caps 40 per work and 1800 loose', () {
      final List<PanoramaNoteInput> notes = <PanoramaNoteInput>[
        for (int i = 0; i < 100; i++)
          PanoramaNoteInput(sortField: '語$i', tags: const <String>['frieren']),
        for (int i = 0; i < 2000; i++)
          PanoramaNoteInput(sortField: '散$i', tags: const <String>[]),
      ];
      final List<PanoramaWord> words = panoramaAssignWords(works, notes);
      expect(
        words.where((PanoramaWord w) => w.work == 1),
        hasLength(kPanoramaWordsPerWork),
      );
      expect(
        words.where((PanoramaWord w) => w.work == -1),
        hasLength(kPanoramaLooseWords),
      );
    });

    test('sampling picks at most 1.5x the caps per owner, in order', () {
      final List<PanoramaNoteInput> notes = <PanoramaNoteInput>[
        for (int i = 0; i < 200; i++)
          PanoramaNoteInput(sortField: '語$i', tags: const <String>['frieren']),
        for (int i = 0; i < 3000; i++)
          PanoramaNoteInput(sortField: 'id-$i', tags: const <String>[]),
        const PanoramaNoteInput(
          sortField: '弾く',
          tags: <String>[],
          sourceKeys: <String>['book_uid_1'],
        ),
      ];
      final List<int> picked = panoramaSampleNoteIndices(works, notes);
      expect(picked, orderedEquals(List<int>.of(picked)..sort()));
      expect(picked.where((int i) => i < 200), hasLength(60));
      expect(
        picked.where((int i) => i >= 200 && i < 3200),
        hasLength((kPanoramaLooseWords * 1.5).ceil()),
      );
      expect(picked, contains(3200), reason: 'source-owned note kept');
    });
  });
}
