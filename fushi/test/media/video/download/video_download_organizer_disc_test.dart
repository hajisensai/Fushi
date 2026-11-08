// BUG-4245：下载整理器认原盘（BDMV / VIDEO_TS / .iso），整盘平移、不拆。
import 'dart:io';

import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_disc_payload.dart';
import 'package:fushi_engine/media/video/download/video_download_organizer.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:test/test.dart';

final String _localRoot = Platform.isWindows
    ? r'C:\Media\Downloads'
    : '/Media/Downloads';

VideoOrganizationPlan _plan(
  List<String> names, {
  VideoOrganizationKind kind = VideoOrganizationKind.episodic,
  String title = "BanG Dream! It's MyGO!!!!!",
  int? year = 2023,
  Map<String, int> sizes = const <String, int>{},
}) => const VideoDownloadOrganizer().plan(
  VideoOrganizationRequest(
    torrentId: 'hash',
    title: title,
    year: year,
    kind: kind,
    sourceRoot: _localRoot,
    pathMapping: VideoDownloadPathMapping(
      remoteRoot: '/library',
      localRoot: _localRoot,
    ),
  ),
  <TorrentFileEntry>[
    for (int i = 0; i < names.length; i++)
      TorrentFileEntry(
        name: names[i],
        size: sizes[names[i]] ?? 1000,
        progress: 1,
        index: i,
      ),
  ],
);

/// 一张蓝光盘的典型文件（盘根 [root]，可为空串 = 种子顶层）。
List<String> _bdmv(String root, {int clips = 3}) {
  final String prefix = root.isEmpty ? '' : '$root/';
  return <String>[
    '${prefix}BDMV/index.bdmv',
    '${prefix}BDMV/MovieObject.bdmv',
    for (int i = 1; i <= clips; i++) ...<String>[
      '${prefix}BDMV/PLAYLIST/0000$i.mpls',
      '${prefix}BDMV/CLIPINF/0000$i.clpi',
      '${prefix}BDMV/STREAM/0000$i.m2ts',
    ],
    '${prefix}BDMV/BACKUP/index.bdmv',
    '${prefix}BDMV/BACKUP/PLAYLIST/00001.mpls',
    '${prefix}CERTIFICATE/id.bdmv',
  ];
}

Map<String, String> _targets(VideoOrganizationPlan plan) => <String, String>{
  for (final VideoOrganizationFilePlan f in plan.files)
    f.originalRelativePath: f.targetRelativePath,
};

void main() {
  const String display = "BanG Dream! It's MyGO!!!!! (2023)";

  test('多卷 BDMV 的 TV 任务：每卷整盘平移，盘内结构与文件名一字不改', () {
    final List<String> names = <String>[
      ..._bdmv('MyGO BD/MYGO_1'),
      ..._bdmv('MyGO BD/MYGO_2'),
      'MyGO BD/scan/booklet.jpg',
    ];
    final VideoOrganizationPlan plan = _plan(names);

    // 修前：parseVideoFilename('00001.m2ts') 解不出集号 → 抛
    // 'unable to determine episode number'，任务进 needsAttention。
    expect(plan.kind, VideoOrganizationKind.episodic);
    expect(
      plan.discs.map((VideoOrganizationDiscPlan d) => d.targetRootRelativePath),
      <String>['$display/MYGO_1', '$display/MYGO_2'],
    );
    expect(plan.discs.first.format, DownloadDiscFormat.bluray);
    final Map<String, String> targets = _targets(plan);
    // 盘内每个文件（含 index.bdmv / mpls / clpi / BACKUP / CERTIFICATE）都在计划里，
    // 且只平移盘根前缀。
    for (final String name in names.where((String n) => !n.contains('scan'))) {
      final String inner = name.substring('MyGO BD/'.length);
      expect(targets[name], '$display/$inner', reason: name);
    }
    // 盘外的非视频文件不归盘、不进计划（与以前一样随 moveStorage 原路径走）。
    expect(targets.containsKey('MyGO BD/scan/booklet.jpg'), isFalse);
    // 没有任何 m2ts 被改名成 SxxEyy / 正片 / 进 Extras。
    for (final VideoOrganizationFilePlan f in plan.files) {
      expect(f.targetRelativePath, isNot(contains('Season ')));
      expect(f.targetRelativePath, isNot(contains('/Extras/')));
      expect(f.episodeNumber, isNull);
      expect(f.disc, isNotNull);
    }
    expect(plan.discs.first.finalLocalRootPath, endsWith('MYGO_1'));
  });

  test('多卷 BDMV 的电影任务：不抬最大 m2ts 当正片，不把其余 m2ts 当并列正片', () {
    final List<String> names = <String>[
      ..._bdmv('Movie/DISC1'),
      ..._bdmv('Movie/DISC2'),
    ];
    final VideoOrganizationPlan plan = _plan(
      names,
      kind: VideoOrganizationKind.movie,
      title: 'Some Movie',
      year: 2020,
      sizes: const <String, int>{'Movie/DISC1/BDMV/STREAM/00001.m2ts': 900000},
    );
    expect(plan.kind, VideoOrganizationKind.movie);
    final Map<String, String> targets = _targets(plan);
    expect(
      targets['Movie/DISC1/BDMV/STREAM/00001.m2ts'],
      'Some Movie (2020)/DISC1/BDMV/STREAM/00001.m2ts',
    );
    expect(
      targets['Movie/DISC2/BDMV/PLAYLIST/00002.mpls'],
      'Some Movie (2020)/DISC2/BDMV/PLAYLIST/00002.mpls',
    );
    expect(targets.length, names.length);
  });

  test('单盘种子：盘根就是发布根，盘直接落在作品目录下；顶层就是 BDMV 也认', () {
    final VideoOrganizationPlan rooted = _plan(_bdmv('[Group] MyGO Vol.1'));
    expect(
      _targets(rooted)['[Group] MyGO Vol.1/BDMV/STREAM/00002.m2ts'],
      '$display/BDMV/STREAM/00002.m2ts',
    );
    final VideoOrganizationPlan top = _plan(_bdmv(''));
    expect(top.discs.single.originalRootRelativePath, '');
    expect(
      _targets(top)['BDMV/PLAYLIST/00001.mpls'],
      '$display/BDMV/PLAYLIST/00001.mpls',
    );
  });

  test('VIDEO_TS 与 .iso 不再报 no supported video files，整盘 / 整个镜像平移', () {
    final VideoOrganizationPlan dvd = _plan(<String>[
      'Show DVD/VIDEO_TS/VIDEO_TS.IFO',
      'Show DVD/VIDEO_TS/VIDEO_TS.BUP',
      'Show DVD/VIDEO_TS/VTS_01_0.IFO',
      'Show DVD/VIDEO_TS/VTS_01_1.VOB',
      'Show DVD/AUDIO_TS/.keep',
    ]);
    expect(dvd.discs.single.format, DownloadDiscFormat.dvd);
    expect(
      _targets(dvd)['Show DVD/VIDEO_TS/VTS_01_1.VOB'],
      '$display/VIDEO_TS/VTS_01_1.VOB',
    );
    expect(_targets(dvd)['Show DVD/AUDIO_TS/.keep'], '$display/AUDIO_TS/.keep');

    final VideoOrganizationPlan iso = _plan(<String>['MyGO Vol.1.ISO']);
    expect(iso.discs.single.format, DownloadDiscFormat.image);
    expect(iso.files.single.targetRelativePath, '$display/MyGO Vol.1.iso');
    expect(iso.discs.single.finalLocalRootPath, endsWith('MyGO Vol.1.iso'));
  });

  test('BDMV + 零散 mkv：mkv 按原规则，特典目录里的 mkv 不被改名成 S01E01', () {
    final VideoOrganizationPlan plan = _plan(<String>[
      ..._bdmv('MyGO/DISC1'),
      'MyGO/Extra/Making - 01.mkv',
      'MyGO/MyGO - 13.mkv',
    ]);
    final Map<String, String> targets = _targets(plan);
    // 修前：第二趟（不分特典）把 m2ts 塞进 Extras、把真特典改名成第 1 集。
    expect(
      targets['MyGO/Extra/Making - 01.mkv'],
      '$display/Extras/Extra/Making - 01.mkv',
    );
    expect(
      targets['MyGO/MyGO - 13.mkv'],
      '$display/Season 01/$display - S01E13.mkv',
    );
    expect(
      targets['MyGO/DISC1/BDMV/STREAM/00001.m2ts'],
      '$display/DISC1/BDMV/STREAM/00001.m2ts',
    );
  });

  test('只有盘 + 特典目录里的 mkv（没有分集）：不硬失败，mkv 进 Extras', () {
    final VideoOrganizationPlan plan = _plan(<String>[
      ..._bdmv('MyGO/DISC1'),
      'MyGO/Extra/Making - 01.mkv',
    ]);
    expect(
      _targets(plan)['MyGO/Extra/Making - 01.mkv'],
      '$display/Extras/Extra/Making - 01.mkv',
    );
  });

  test('特典目录里的盘整盘处理：保留 SP 段、不进 Extras、不拆', () {
    final VideoOrganizationPlan plan = _plan(<String>[
      ..._bdmv('MyGO/DISC1'),
      ..._bdmv('MyGO/SP/BONUS'),
    ]);
    final Map<String, String> targets = _targets(plan);
    expect(
      targets['MyGO/SP/BONUS/BDMV/STREAM/00003.m2ts'],
      '$display/SP/BONUS/BDMV/STREAM/00003.m2ts',
    );
    expect(
      targets['MyGO/SP/BONUS/BDMV/index.bdmv'],
      '$display/SP/BONUS/BDMV/index.bdmv',
    );
  });

  test('下载时跳过特典按整盘判：特典目录里的盘整张跳过，正片盘一个文件都不跳', () {
    final List<String> names = <String>[
      ..._bdmv('MyGO/DISC1'),
      ..._bdmv('MyGO/SP/BONUS'),
      'MyGO/SP/scan.jpg',
    ];
    final List<TorrentFileEntry> files = <TorrentFileEntry>[
      for (int i = 0; i < names.length; i++)
        TorrentFileEntry(name: names[i], size: 1, progress: 0, index: i),
    ];
    final Set<int> skipped = videoDownloadSkippableExtraIndexes(files);
    for (final TorrentFileEntry file in files) {
      expect(
        skipped.contains(file.index),
        file.name.startsWith('MyGO/SP/'),
        reason: file.name,
      );
    }
    // 整个种子只有特典盘：一个都不跳。
    final List<TorrentFileEntry> onlyBonus = <TorrentFileEntry>[
      for (final (int i, String name) in _bdmv('MyGO/SP/BONUS').indexed)
        TorrentFileEntry(name: name, size: 1, progress: 0, index: i),
    ];
    expect(videoDownloadSkippableExtraIndexes(onlyBonus), isEmpty);
  });

  test('手动选择扩成整盘：选了盘里任何一个文件就选整张盘', () {
    final List<String> names = <String>[
      ..._bdmv('MyGO/DISC1'),
      ..._bdmv('MyGO/DISC2'),
      'MyGO/MyGO - 13.mkv',
    ];
    final Map<int, String> byIndex = <int, String>{
      for (int i = 0; i < names.length; i++) i: names[i],
    };
    final int pick = names.indexOf('MyGO/DISC2/BDMV/STREAM/00002.m2ts');
    final int mkv = names.indexOf('MyGO/MyGO - 13.mkv');
    final Set<int> expanded = expandDownloadSelectionToWholeDiscs(<int>{
      pick,
      mkv,
    }, byIndex);
    expect(
      <String>{for (final int i in expanded) names[i]},
      <String>{..._bdmv('MyGO/DISC2'), 'MyGO/MyGO - 13.mkv'},
    );
  });

  test('认盘判据：小写 bdmv 不认（与扫描器同口径），反斜杠路径照认', () {
    expect(
      planDownloadDiscRoots(<String>['x/bdmv/PLAYLIST/00001.mpls']),
      isEmpty,
    );
    final List<DownloadDiscRoot> roots = planDownloadDiscRoots(<String>[
      r'Show\DISC1\BDMV\PLAYLIST\00001.mpls',
    ]);
    expect(roots.single.path, 'Show/DISC1');
    expect(
      downloadDiscRootOf(r'Show\DISC1\BDMV\STREAM\00001.m2ts', roots),
      roots.single,
    );
    expect(downloadDiscRootOf('Show/DISC1/scan.jpg', roots), isNull);
  });
}
