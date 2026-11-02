// 服务器字幕的推荐规则（流式建书自动挂上 / 下载单集随附 / 选择框排序共用）：
// 书与单集的归属判据、同主干内按学习语言与格式挑、所有有声书字幕格式都认、
// 挑不准时返回 null 交给用户。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_subtitle_match.dart';

Map<String, Object?> _file(String ino, String name) => <String, Object?>{
  'ino': ino,
  'fileType': 'unknown',
  'metadata': <String, Object?>{'filename': name, 'size': 100},
};

AudiobookshelfItemDetail _book(
  List<String> files, {
  List<String> tracks = const <String>['part1.mp3'],
  String title = 'Fables',
}) => AudiobookshelfItemDetail.parse(<String, Object?>{
  'id': 'item_1',
  'mediaType': 'book',
  'media': <String, Object?>{
    'metadata': <String, Object?>{'title': title},
    'tracks': <Object?>[
      for (int i = 0; i < tracks.length; i++)
        <String, Object?>{
          'index': i + 1,
          'ino': '${10 + i}',
          'duration': 1,
          'startOffset': i,
          'metadata': <String, Object?>{'filename': tracks[i]},
        },
    ],
  },
  'libraryFiles': <Object?>[
    for (int i = 0; i < files.length; i++) _file('${30 + i}', files[i]),
  ],
})!;

AudiobookshelfItemDetail _podcast(List<String> files) =>
    AudiobookshelfItemDetail.parse(<String, Object?>{
      'id': 'pod_1',
      'mediaType': 'podcast',
      'media': <String, Object?>{
        'metadata': <String, Object?>{'title': 'Show'},
        'episodes': <Object?>[
          for (final String ep in <String>['e1', 'e2'])
            <String, Object?>{
              'id': 'ep_$ep',
              'title': 'Episode $ep',
              'audioFile': <String, Object?>{
                'ino': 'a_$ep',
                'duration': 4,
                'metadata': <String, Object?>{'filename': '$ep.mp3'},
              },
            },
        ],
      },
      'libraryFiles': <Object?>[
        for (int i = 0; i < files.length; i++) _file('${30 + i}', files[i]),
      ],
    })!;

String? _bookPick(List<String> files, {List<String>? tracks}) =>
    matchAudiobookshelfSubtitle(
      tracks == null ? _book(files) : _book(files, tracks: tracks),
      langCode: 'ja',
    )?.filename;

String? _episodePick(List<String> files, {String episode = 'ep_e1'}) {
  final AudiobookshelfItemDetail detail = _podcast(files);
  return matchAudiobookshelfSubtitle(
    detail,
    episode: detail.episodes.firstWhere(
      (AudiobookshelfEpisode e) => e.id == episode,
    ),
    langCode: 'ja',
  )?.filename;
}

void main() {
  group('书', () {
    test('每种有声书字幕格式都认', () {
      for (final String ext in kAudiobookSubtitleExtensions) {
        expect(_bookPick(<String>['part1.$ext']), 'part1.$ext', reason: ext);
        expect(_bookPick(<String>['WHATEVER.${ext.toUpperCase()}']), isNotNull);
      }
    });

    test('与音轨同名的优先于与标题同名的', () {
      expect(_bookPick(<String>['Fables.srt', 'part1.vtt']), 'part1.vtt');
    });

    test('其次与标题同名；再其次全部字幕同一主干', () {
      expect(_bookPick(<String>['x.srt', 'Fables.lrc']), 'Fables.lrc');
      expect(_bookPick(<String>['story.en.srt', 'story.ass']), 'story.ass');
    });

    test('同一主干多种格式：srt > vtt > ass > ssa > lrc（与本机同名字幕扫描同序）', () {
      expect(
        _bookPick(<String>['part1.lrc', 'part1.ssa', 'part1.vtt']),
        'part1.vtt',
      );
      expect(_bookPick(<String>['part1.lrc', 'part1.ssa']), 'part1.ssa');
      expect(_bookPick(<String>['part1.lrc', 'part1.srt']), 'part1.srt');
    });

    test('学习语言标记 > 无标记 > 别的语言（别的语言不自动挂）', () {
      expect(
        _bookPick(<String>['part1.srt', 'part1.ja.vtt', 'part1.en.srt']),
        'part1.ja.vtt',
      );
      expect(_bookPick(<String>['part1.en.srt', 'part1.srt']), 'part1.srt');
      expect(_bookPick(<String>['part1.en.srt']), isNull);
      expect(_bookPick(<String>['part1.ja-JP.srt']), 'part1.ja-JP.srt');
      // 常见的日语别名：jpn / jp 也算学习语言。
      expect(
        _bookPick(<String>['part1.en.srt', 'part1.jpn.srt']),
        'part1.jpn.srt',
      );
      expect(_bookPick(<String>['part1.jp.ass']), 'part1.jp.ass');
    });

    test('分属不同主干 → null（每个音轨一份 / 互不相干的文件）', () {
      expect(
        _bookPick(
          <String>['part1.srt', 'part2.srt'],
          tracks: <String>['part1.mp3', 'part2.mp3'],
        ),
        isNull,
      );
      expect(_bookPick(<String>['a.srt', 'b.srt']), isNull);
    });

    test('没有字幕 → null；非字幕文件不算', () {
      expect(_bookPick(<String>[]), isNull);
      expect(_bookPick(<String>['cover.jpg', 'part1.txt']), isNull);
    });
  });

  group('播客单集', () {
    test('只认与这一集音频同主干的；文件夹里只有别集的字幕 → null', () {
      expect(_episodePick(<String>['e1.srt', 'e2.srt']), 'e1.srt');
      expect(_episodePick(<String>['e2.srt']), isNull);
      expect(_episodePick(<String>['Show.srt']), isNull);
    });

    test('同主干里按语言与格式挑', () {
      expect(
        _episodePick(<String>['e1.en.srt', 'E1.ja.lrc', 'e1.vtt']),
        'E1.ja.lrc',
      );
      expect(_episodePick(<String>['e1.lrc', 'e1.ass']), 'e1.ass');
    });
  });
}
