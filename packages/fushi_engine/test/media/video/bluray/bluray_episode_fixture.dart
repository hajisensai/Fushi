// 在磁盘上铺一张「只有全部播放、没有逐集播放列表」的蓝光剧集盘，形状照
// 《魔女の旅々》BD 实测：`00001.mpls` 串着几集（每集一个整段用满的 m2ts），外加
// 一条菜单背景循环 `00008.mpls` 和一条短特典 `00002.mpls`。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

/// 片段时间轴的起点（m2ts 首个 PTS 几乎从不为 0）。
const int kFixtureClipStartTicks = 45000 * 4;

/// 一个整段用满 [seconds] 秒片段的 PlayItem。
FixturePlayItem wholeClipItem(String clipId, int seconds) => FixturePlayItem(
  clipId: clipId,
  inTimeTicks: kFixtureClipStartTicks,
  outTimeTicks: kFixtureClipStartTicks + 45000 * seconds,
);

void _writeClip(String root, String clipId, int seconds) {
  File(p.join(root, 'BDMV', 'CLIPINF', '$clipId.clpi')).writeAsBytesSync(
    buildClpiFixture(
      presentationStartTicks: kFixtureClipStartTicks,
      presentationEndTicks: kFixtureClipStartTicks + 45000 * seconds,
    ),
  );
  File(
    p.join(root, 'BDMV', 'STREAM', '$clipId.m2ts'),
  ).writeAsBytesSync(Uint8List(4096));
}

/// 写一条播放列表及它用到的片段；[items] 是 `(片段号, 秒数)`，每段开头一个章节点。
void writeFixturePlaylist(
  String root,
  String playlistId,
  List<(String, int)> items,
) {
  for (final String dir in <String>['PLAYLIST', 'CLIPINF', 'STREAM']) {
    Directory(p.join(root, 'BDMV', dir)).createSync(recursive: true);
  }
  File(p.join(root, 'BDMV', 'PLAYLIST', '$playlistId.mpls')).writeAsBytesSync(
    buildMplsFixture(
      playItems: <FixturePlayItem>[
        for (final (String clip, int seconds) in items)
          wholeClipItem(clip, seconds),
      ],
      marks: <FixtureMark>[
        for (int i = 0; i < items.length; i++) ...<FixtureMark>[
          FixtureMark(playItemIndex: i, timestampTicks: kFixtureClipStartTicks),
          FixtureMark(
            playItemIndex: i,
            timestampTicks: kFixtureClipStartTicks + 45000 * 90,
          ),
        ],
      ],
    ),
  );
  for (final (String clip, int seconds) in items) {
    _writeClip(root, clip, seconds);
  }
}

/// 铺一张剧集盘：`00001` 串着 [episodes] 集（每集 24 分钟上下），`00008` 是菜单循环，
/// `00002` 是 90 秒的特典。[discName] 写进 `BDMV/META`（盘内标题）。
void writeEpisodicDisc(String root, {required int episodes, String? discName}) {
  writeFixturePlaylist(root, '00001', <(String, int)>[
    for (int i = 0; i < episodes; i++)
      ((i + 3).toString().padLeft(5, '0'), i.isEven ? 1442 : 1422),
  ]);
  writeFixturePlaylist(root, '00002', const <(String, int)>[('00040', 90)]);
  writeFixturePlaylist(root, '00008', <(String, int)>[
    for (int i = 0; i < 12; i++) (i.isEven ? '00050' : '00051', 216),
    for (int i = 0; i < 40; i++) ('00050', 216),
  ]);
  if (discName != null) {
    final Directory meta = Directory(p.join(root, 'BDMV', 'META', 'DL'))
      ..createSync(recursive: true);
    File(p.join(meta.path, 'bdmt_jpn.xml')).writeAsStringSync(
      '<?xml version="1.0" encoding="utf-8"?><disclib><di:discinfo>'
      '<di:title><di:name>$discName</di:name></di:title>'
      '</di:discinfo></disclib>',
    );
  }
}

/// [root] 这张盘上 `00001` 的第 [playItem]（1 起）集的成员路径。
String episodePath(String root, int playItem) => p.join(
  root,
  'BDMV',
  'PLAYLIST',
  '00001.p${playItem.toString().padLeft(2, '0')}.mpls',
);
