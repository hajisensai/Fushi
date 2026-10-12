// 蓝光盘特典划分（PR #2058 审查）：旧判据「比最长标题短 50% 以上即特典」会把剧集盘
// 正片误判——50 分钟特别篇 + 24 分钟各集，各集全成特典不刮削；漏网的「全部播放」
// 当锚时同样。现在以正片集合为基准（play-all 串起来的组 / 时长相近的一组 / 电影盘
// 的最长那条），这里用纯函数钉住正负两面。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';

import 'bluray_fixture.dart';

/// 造一条播放列表：[clips] 是 `(片段号, 秒数)` 序列。
BlurayPlaylist _make(String id, List<(String, int)> clips) {
  final Uint8List bytes = buildMplsFixture(
    playItems: clips
        .map(
          ((String, int) clip) => FixturePlayItem(
            clipId: clip.$1,
            inTimeTicks: 45000 * 10,
            outTimeTicks: 45000 * (10 + clip.$2),
          ),
        )
        .toList(),
    marks: const <FixtureMark>[
      FixtureMark(playItemIndex: 0, timestampTicks: 45000 * 10),
    ],
  );
  return parseBlurayPlaylist(bytes, id: id)!;
}

/// 与 [readBlurayDisc] 同一条筛选链拼出一张盘（不碰文件系统）。
BlurayDisc _disc(List<BlurayPlaylist> playlists) {
  const String root = '/discs/X';
  final List<BlurayTitle> titles = selectBlurayTitles(
    playlists,
    discRootPath: root,
    discName: 'X',
  );
  return BlurayDisc(
    rootPath: root,
    name: 'X',
    playlists: playlists,
    titles: titles,
    extras: selectBlurayExtras(
      playlists,
      titles: titles,
      discRootPath: root,
      discName: 'X',
    ),
  );
}

const int _min = 60;

void main() {
  group('电影盘：正片之外远短于正片的都是特典', () {
    test('143 分钟正片 + 31.5 / 28 分钟两条特辑 + 菜单特典', () {
      final BlurayDisc disc = _disc(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 143 * _min)]),
        _make('00002', <(String, int)>[('00002', 31 * _min + 30)]),
        _make('00003', <(String, int)>[('00003', 28 * _min)]),
        _make('00004', <(String, int)>[('00004', 5 * _min)]),
      ]);
      // 两条特辑时长相近（1.1 倍），但合计只有正片的 41%，不能被认成剧集组。
      expect(
        disc.titles.map((BlurayTitle t) => t.playlist.id),
        containsAll(<String>['00001', '00002', '00003']),
      );
      final BlurayDiscExtrasPlan plan = classifyBlurayDiscExtras(disc);
      expect(plan.extraIds, <String>{'00002', '00003', '00004'});
      expect(plan.parentOrder.first, '00001');
    });
  });

  group('剧集盘：正片集合里的各集与更长的特别篇都不是特典', () {
    test('4 集 24 分钟 + 50 分钟特别篇 + 8 分钟制作特辑', () {
      final BlurayDisc disc = _disc(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 24 * _min)]),
        _make('00002', <(String, int)>[('00002', 24 * _min + 20)]),
        _make('00003', <(String, int)>[('00003', 23 * _min + 50)]),
        _make('00004', <(String, int)>[('00004', 24 * _min + 5)]),
        _make('00005', <(String, int)>[('00005', 50 * _min)]),
        _make('00006', <(String, int)>[('00006', 8 * _min)]),
      ]);
      final BlurayDiscExtrasPlan plan = classifyBlurayDiscExtras(disc);
      for (final String ep in <String>[
        '00001',
        '00002',
        '00003',
        '00004',
        '00005',
      ]) {
        expect(plan.extraIds, isNot(contains(ep)), reason: '$ep 是正片');
      }
      expect(plan.extraIds, contains('00006'));
      // 特典挂到剧集组上，而不是挂到最长的特别篇上。
      expect(plan.parentOrder.first, '00001');
    });

    test('只有 2 集 + 50 分钟特别篇（合计 96%）：各集仍是正片', () {
      final BlurayDisc disc = _disc(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 24 * _min)]),
        _make('00002', <(String, int)>[('00002', 24 * _min)]),
        _make('00003', <(String, int)>[('00003', 50 * _min)]),
      ]);
      expect(classifyBlurayDiscExtras(disc).extraIds, isEmpty);
    });

    test('盘上的 play-all 声明了剧集组：2 集 + 70 分钟特别篇仍不误判', () {
      final BlurayDisc disc = _disc(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 24 * _min)]),
        _make('00002', <(String, int)>[('00002', 25 * _min)]),
        _make('00003', <(String, int)>[('00003', 70 * _min)]),
        // 全部播放：恰好串起两集（筛选链把它从标题里丢掉，但它仍在盘上）。
        _make('00009', <(String, int)>[
          ('00001', 24 * _min),
          ('00002', 25 * _min),
        ]),
      ]);
      expect(
        disc.titles.map((BlurayTitle t) => t.playlist.id),
        isNot(contains('00009')),
      );
      final BlurayDiscExtrasPlan plan = classifyBlurayDiscExtras(disc);
      expect(plan.extraIds, isNot(contains('00001')));
      expect(plan.extraIds, isNot(contains('00002')));
      expect(plan.extraIds, isNot(contains('00003')));
    });

    test('漏网的 play-all 成了最长标题：不当基准，各集不被砍成特典', () {
      // play-all 多带一段各集里没有的 NCOP，筛选链的「恰好等于并集」认不出它，
      // 它以 73.5 分钟留在标题里、还是全盘最长。
      final BlurayDisc disc = _disc(<BlurayPlaylist>[
        _make('00001', <(String, int)>[('00001', 24 * _min)]),
        _make('00002', <(String, int)>[('00002', 24 * _min)]),
        _make('00003', <(String, int)>[('00003', 24 * _min)]),
        _make('00009', <(String, int)>[
          ('00001', 24 * _min),
          ('00002', 24 * _min),
          ('00003', 24 * _min),
          ('00010', 90),
        ]),
      ]);
      expect(
        disc.titles.map((BlurayTitle t) => t.playlist.id),
        contains('00009'),
      );
      final BlurayDiscExtrasPlan plan = classifyBlurayDiscExtras(disc);
      for (final String ep in <String>['00001', '00002', '00003']) {
        expect(plan.extraIds, isNot(contains(ep)), reason: '$ep 是正片');
      }
      expect(plan.parentOrder.first, '00001');
    });
  });
}
