import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

/// 造一条播放列表：[clips] 是 `(片段号, 秒数)` 序列。
BlurayPlaylist _make(
  String id,
  List<(String, int)> clips, {
  int playbackType = 1,
  int chapterCount = 1,
  bool withVideo = true,
}) {
  final Uint8List bytes = buildMplsFixture(
    playbackType: playbackType,
    playItems: clips
        .map(
          ((String, int) clip) => FixturePlayItem(
            clipId: clip.$1,
            inTimeTicks: 45000 * 10,
            outTimeTicks: 45000 * (10 + clip.$2),
          ),
        )
        .toList(),
    streams: withVideo
        ? const <FixtureStream>[
            FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
          ]
        : const <FixtureStream>[
            FixtureStream.audio(codingType: 0x80, language: 'jpn'),
          ],
    marks: List<FixtureMark>.generate(
      chapterCount,
      (int i) =>
          FixtureMark(playItemIndex: 0, timestampTicks: 45000 * (10 + i * 5)),
    ),
  );
  return parseBlurayPlaylist(bytes, id: id)!;
}

void main() {
  const String root = '/discs/Show';

  List<BlurayTitle> select(
    List<BlurayPlaylist> playlists, {
    Set<String>? present,
  }) => selectBlurayTitles(
    playlists,
    discRootPath: root,
    discName: 'Show',
    presentClipIds: present,
  );

  group('selectBlurayTitles 的筛选链', () {
    test('电影盘：只留正片，花絮被相对时长下限挡掉', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 7200)]), // 正片 2h
        _make('00002', <(String, int)>[('00002', 180)]), // 预告 3min
        _make('00003', <(String, int)>[('00003', 240)]), // 花絮 4min
      ]);

      expect(titles, hasLength(1));
      expect(titles.single.name, 'Show');
      expect(titles.single.isMainFeature, isTrue);
      expect(titles.single.duration, const Duration(hours: 2));
    });

    test('MV 盘：各曲时长相近，整批留下并按编号顺序编号', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 260)]),
        _make('00002', <(String, int)>[('00002', 240)]),
        _make('00003', <(String, int)>[('00003', 300)]),
      ]);

      expect(titles.map((BlurayTitle t) => t.name), <String>[
        'Show - 01',
        'Show - 02',
        'Show - 03',
      ]);
      // 最长的那条是主标题，但顺序仍按盘上的编号。
      expect(titles[2].isMainFeature, isTrue);
      expect(titles[0].isMainFeature, isFalse);
    });

    test('剧集盘：丢掉「全部播放」，保住各集', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        // 全部播放：把三集串起来
        _make('00001', <(String, int)>[
          ('00011', 1440),
          ('00012', 1440),
          ('00013', 1440),
        ]),
        _make('00002', <(String, int)>[('00011', 1440)]),
        _make('00003', <(String, int)>[('00012', 1440)]),
        _make('00004', <(String, int)>[('00013', 1440)]),
      ]);

      expect(titles.map((BlurayTitle t) => t.playlist.id), <String>[
        '00002',
        '00003',
        '00004',
      ]);
    });

    test('play-all 多含一段各集里没有的过场时 ⑤ 漏网：⑥ 不能拿它当锚砍掉各集', () {
      // 8 集 × 24 min，play-all 把 8 集 + 一段 90 s 的 NCOP 串起来；NCOP 没有自己的
      // 播放列表。⑤ 的「恰好等于并集」放过 play-all；若 ⑥ 以它（3.2 h）为锚，
      // 0.15 × 3.2 h = 29 min > 24 min，8 集全部出局、库里只剩 play-all。
      final List<BlurayPlaylist> playlists = <BlurayPlaylist>[
        _make('00001', <(String, int)>[
          for (int i = 11; i < 19; i++) ('000$i', 1440),
          ('00030', 90),
        ]),
        for (int i = 11; i < 19; i++)
          _make('000${i + 40}', <(String, int)>[('000$i', 1440)]),
      ];

      final List<BlurayTitle> titles = select(playlists);

      final List<String> ids = titles
          .map((BlurayTitle t) => t.playlist.id)
          .toList(growable: false);
      expect(
        ids,
        containsAll(<String>[for (int i = 51; i < 59; i++) '000$i']),
        reason: '各集必须保住',
      );
      expect(
        titles
            .where((BlurayTitle t) => t.isMainFeature)
            .map((BlurayTitle t) => t.playlist.id),
        isNot(contains('00001')),
        reason: '锚是单集，不是 play-all',
      );
      expect(
        ids.contains('00001'),
        isTrue,
        reason: '漏网的 play-all 本身照旧按下限判，不额外删',
      );
    });

    test('多段正片不会被误判成「全部播放」', () {
      // 正片被切成三段，但盘上没有对应的单段播放列表。
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[
          ('00011', 2400),
          ('00012', 2400),
          ('00013', 2400),
        ]),
      ]);

      expect(titles, hasLength(1));
      expect(titles.single.duration, const Duration(hours: 2));
    });

    test('顺序被打乱的诱饵播放列表与正片同签名，合并成一条', () {
      // 某些发行盘放几十条时长相同、只是片段顺序不同的播放列表来干扰自动选片。
      final List<(String, int)> chunks = <(String, int)>[
        ('00011', 1200),
        ('00012', 1200),
        ('00013', 1200),
      ];
      final List<BlurayPlaylist> playlists = <BlurayPlaylist>[
        // 真正的正片：章节齐全
        _make('00001', chunks, chapterCount: 12),
        // 诱饵：同样的片段、同样的总时长，顺序打乱，只有一个章节点
        _make('00042', chunks.reversed.toList()),
        _make('00043', <(String, int)>[chunks[1], chunks[2], chunks[0]]),
        _make('00044', <(String, int)>[chunks[2], chunks[0], chunks[1]]),
      ];

      final List<BlurayTitle> titles = select(playlists);

      expect(titles, hasLength(1));
      expect(titles.single.playlist.id, '00001');
      expect(titles.single.playlist.chapters, hasLength(12));
    });

    test('随机/洗牌播放列表不是标题', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 3600)]),
        _make('00002', <(String, int)>[('00002', 3600)], playbackType: 2),
        _make('00003', <(String, int)>[('00003', 3600)], playbackType: 3),
      ]);

      expect(titles.map((BlurayTitle t) => t.playlist.id), <String>['00001']);
    });

    test('太短的（厂标、警告画面）被绝对下限挡掉', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 600)]),
        _make('00002', <(String, int)>[('00002', 12)]),
        _make('00003', <(String, int)>[('00003', 59)]),
      ]);

      expect(titles.map((BlurayTitle t) => t.playlist.id), <String>['00001']);
    });

    test('没有视频轨的（纯音轨播放列表）不是标题', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 3600)]),
        _make('00002', <(String, int)>[('00002', 3600)], withVideo: false),
      ]);

      expect(titles.map((BlurayTitle t) => t.playlist.id), <String>['00001']);
    });

    test('引用的片段不在盘上就不是可播放的标题', () {
      final List<BlurayTitle> titles = select(
        <BlurayPlaylist>[
          _make('00001', <(String, int)>[('00001', 3600)]),
          _make('00002', <(String, int)>[('00009', 3600)]),
        ],
        present: <String>{'00001'},
      );

      expect(titles.map((BlurayTitle t) => t.playlist.id), <String>['00001']);
    });

    test('一条都选不出来时返回空表而不是抛', () {
      expect(select(const <BlurayPlaylist>[]), isEmpty);
      expect(
        select(<BlurayPlaylist>[
          _make('00001', <(String, int)>[('00001', 5)]),
        ]),
        isEmpty,
      );
    });

    test('标题路径指向它自己的 mpls', () {
      final List<BlurayTitle> titles = select(<BlurayPlaylist>[
        _make('00007', <(String, int)>[('00001', 3600)]),
      ]);

      expect(
        titles.single.playlistPath,
        p.join(root, 'BDMV', 'PLAYLIST', '00007.mpls'),
      );
    });
  });

  group('blurayDiscRootForFile', () {
    test('认盘内三个内容目录和 index.bdmv', () {
      const String expected = '/a/Movie';
      for (final String path in <String>[
        '/a/Movie/BDMV/PLAYLIST/00001.mpls',
        '/a/Movie/BDMV/STREAM/00001.m2ts',
        '/a/Movie/BDMV/CLIPINF/00001.clpi',
        '/a/Movie/BDMV/index.bdmv',
        '/a/Movie/BDMV/MovieObject.bdmv',
      ]) {
        expect(
          blurayDiscRootForFile(path),
          p.normalize(expected),
          reason: path,
        );
      }
    });

    test('BACKUP 下的副本不算盘根', () {
      expect(
        blurayDiscRootForFile('/a/Movie/BDMV/BACKUP/PLAYLIST/00001.mpls'),
        isNull,
      );
      expect(blurayDiscRootForFile('/a/Movie/BDMV/BACKUP/index.bdmv'), isNull);
    });

    test('盘外的同名文件不算', () {
      expect(blurayDiscRootForFile('/a/STREAM/00001.m2ts'), isNull);
      expect(blurayDiscRootForFile('/a/Movie/00001.m2ts'), isNull);
      expect(blurayDiscRootForFile('00001.m2ts'), isNull);
    });

    test('目录名按精确大小写认：小写 bdmv/ 不是盘（与 IO 层同一口径）', () {
      // 规划层若宽松认了，IO 层却开不出 `BDMV/`：m2ts 被摘、盘又读不出，整张盘一条
      // 都不剩。不认它至少还能当散装 m2ts 播。
      expect(blurayDiscRootForFile('/a/Movie/bdmv/stream/00001.m2ts'), isNull);
      expect(blurayDiscRootForFile('/a/Movie/BDMV/stream/00001.m2ts'), isNull);
      expect(
        isInsideBlurayDisc('/a/Movie/bdmv/STREAM/00001.m2ts', <String>{
          p.normalize('/a/Movie'),
        }),
        isFalse,
      );
      // 文件名照旧不分大小写。
      expect(
        blurayDiscRootForFile('/a/Movie/BDMV/Index.BDMV'),
        p.normalize('/a/Movie'),
      );
    });
  });

  group('parseBlurayMetaTitle', () {
    test('合集名候选序列：盘名 → 带上级目录名 → 再加序号', () {
      expect(
        blurayCollectionNameCandidates('DISC1', '/lib/S2/DISC1').take(4),
        <String>['DISC1', 'DISC1 (S2)', 'DISC1 (S2) (2)', 'DISC1 (S2) (3)'],
      );
      // 上级目录名与盘名相同（`Movie/Movie/BDMV`）时不重复带。
      expect(
        blurayCollectionNameCandidates('Movie', '/lib/Movie/Movie').take(3),
        <String>['Movie', 'Movie (2)', 'Movie (3)'],
      );
    });

    test('取出盘内标题并反转义', () {
      expect(
        parseBlurayMetaTitle(
          '<?xml version="1.0"?><disclib xmlns:di="urn:BDA:bdmv;discinfo">'
          '<di:discinfo><di:title><di:name>Fate &amp; Stay</di:name>'
          '</di:title></di:discinfo></disclib>',
        ),
        'Fate & Stay',
      );
    });

    test('没有标题时返回 null', () {
      expect(parseBlurayMetaTitle('<disclib></disclib>'), isNull);
      expect(parseBlurayMetaTitle('not xml at all'), isNull);
    });
  });
}
