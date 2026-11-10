// 下载整理器认蓝光原盘（BDMV 树）：盘内文件整棵原样落到作品目录下，不改名、
// 不拆进 Extras、不丢非视频文件。修前 `plan()` 只看视频扩展名：最大的
// `BDMV/STREAM/00001.m2ts` 被改名成正片、其余 m2ts 镜像进 `Extras/`，
// `index.bdmv` / MPLS / CLPI / META 原地留下，整张盘被拆散（用户库里的
// 「特別編 響け！ユーフォニアム～アンサンブルコンテスト～ (2023)」）。

import 'dart:io';

import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_organizer.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:test/test.dart';

final String _localRoot = Platform.isWindows
    ? r'C:\Media\Downloads'
    : '/Media/Downloads';

VideoOrganizationPlan _plan(
  List<(String, int)> files, {
  VideoOrganizationKind kind = VideoOrganizationKind.movie,
  String title = 'Show',
  int? year = 2023,
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
    for (int i = 0; i < files.length; i++)
      TorrentFileEntry(
        name: files[i].$1,
        size: files[i].$2,
        progress: 1,
        index: i,
      ),
  ],
);

/// 一张盘的完整文件清单（盘根相对路径），正片 m2ts 最大。
List<(String, int)> _disc(String root) {
  final String prefix = root.isEmpty ? '' : '$root/';
  return <(String, int)>[
    ('${prefix}BDMV/index.bdmv', 1),
    ('${prefix}BDMV/MovieObject.bdmv', 1),
    ('${prefix}BDMV/PLAYLIST/00000.mpls', 1),
    ('${prefix}BDMV/PLAYLIST/00001.mpls', 1),
    ('${prefix}BDMV/CLIPINF/00001.clpi', 1),
    ('${prefix}BDMV/CLIPINF/00002.clpi', 1),
    ('${prefix}BDMV/STREAM/00001.m2ts', 30000),
    ('${prefix}BDMV/STREAM/00002.m2ts', 500),
    ('${prefix}BDMV/META/DL/bdmt_jpn.xml', 1),
    ('${prefix}BDMV/BACKUP/index.bdmv', 1),
    ('${prefix}CERTIFICATE/id.bdmv', 1),
  ];
}

Map<String, String> _targets(VideoOrganizationPlan plan) => <String, String>{
  for (final VideoOrganizationFilePlan file in plan.files)
    file.originalRelativePath: file.targetRelativePath,
};

void main() {
  test('单盘：整棵盘树原样落到「作品/盘目录」下，一个文件都不丢、不改名', () {
    const String release = '『特別編 響け！ユーフォニアム』';
    final List<(String, int)> files = _disc('$release/BD');
    final VideoOrganizationPlan plan = _plan(files);

    expect(plan.files, hasLength(files.length));
    final Map<String, String> targets = _targets(plan);
    for (final (String name, int _) in files) {
      final String inner = name.substring('$release/BD/'.length);
      expect(targets[name], 'Show (2023)/BD/$inner', reason: name);
    }
    for (final VideoOrganizationFilePlan file in plan.files) {
      expect(file.blurayDiscRoot, 'Show (2023)/BD');
      expect(file.targetRelativePath, isNot(contains('Extras')));
      expect(file.episodeNumber, isNull);
    }
    // 正片 m2ts 绝不能被抬成 `作品 (年份).m2ts`。
    expect(targets.values, isNot(contains('Show (2023)/Show (2023).m2ts')));
  });

  test('多卷：每张盘各自一个盘目录，同名盘目录按上级目录区分、互不冲突', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      ..._disc('Pack/DISC1'),
      ..._disc('Pack/DISC2'),
      ..._disc('Pack/S2/DISC1'),
    ], kind: VideoOrganizationKind.episodic);

    expect(plan.kind, VideoOrganizationKind.episodic);
    final Map<String, String> targets = _targets(plan);
    expect(
      targets['Pack/DISC1/BDMV/STREAM/00001.m2ts'],
      'Show (2023)/DISC1/BDMV/STREAM/00001.m2ts',
    );
    expect(
      targets['Pack/DISC2/BDMV/STREAM/00001.m2ts'],
      'Show (2023)/DISC2/BDMV/STREAM/00001.m2ts',
    );
    expect(
      targets['Pack/S2/DISC1/CERTIFICATE/id.bdmv'],
      'Show (2023)/S2/DISC1/CERTIFICATE/id.bdmv',
    );
    expect(
      plan.files.map((VideoOrganizationFilePlan f) => f.blurayDiscRoot).toSet(),
      <String>{
        'Show (2023)/DISC1',
        'Show (2023)/DISC2',
        'Show (2023)/S2/DISC1',
      },
    );
    expect(
      targets.values.toSet(),
      hasLength(plan.files.length),
      reason: '目标路径必须两两不同',
    );
  });

  test('盘就是种子根（BDMV 在最外层）：作品目录本身就是盘根', () {
    final List<(String, int)> files = _disc('');
    final VideoOrganizationPlan plan = _plan(files);
    expect(plan.files, hasLength(files.length));
    final Map<String, String> targets = _targets(plan);
    expect(targets['BDMV/index.bdmv'], 'Show (2023)/BDMV/index.bdmv');
    expect(
      targets['BDMV/STREAM/00001.m2ts'],
      'Show (2023)/BDMV/STREAM/00001.m2ts',
    );
    expect(targets['CERTIFICATE/id.bdmv'], 'Show (2023)/CERTIFICATE/id.bdmv');
    for (final VideoOrganizationFilePlan file in plan.files) {
      expect(file.blurayDiscRoot, 'Show (2023)');
    }
  });

  test('盘根是发布目录本身：保留盘目录名', () {
    final VideoOrganizationPlan plan = _plan(_disc('SHOW_DISC'));
    expect(
      _targets(plan)['SHOW_DISC/BDMV/index.bdmv'],
      'Show (2023)/SHOW_DISC/BDMV/index.bdmv',
    );
    expect(plan.files.first.blurayDiscRoot, 'Show (2023)/SHOW_DISC');
  });

  test('盘与普通 mkv 混装：盘原样落位，散装分集照旧按 Season 排布', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      ..._disc('[G] Show/Vol.1'),
      ('[G] Show/Vol.1/cover.jpg', 1),
      ('[G] Show/[G] Show - 01 [1080p].mkv', 900),
      ('[G] Show/[G] Show - 02 [1080p].mkv', 900),
      ('[G] Show/SPs/[G] Show - NCOP [1080p].mkv', 50),
    ], kind: VideoOrganizationKind.episodic);

    final Map<String, String> targets = _targets(plan);
    expect(
      targets['[G] Show/[G] Show - 01 [1080p].mkv'],
      'Show (2023)/Season 01/Show (2023) - S01E01.mkv',
    );
    expect(
      targets['[G] Show/[G] Show - 02 [1080p].mkv'],
      'Show (2023)/Season 01/Show (2023) - S01E02.mkv',
    );
    expect(
      targets['[G] Show/SPs/[G] Show - NCOP [1080p].mkv'],
      'Show (2023)/Extras/SPs/[G] Show - NCOP [1080p].mkv',
    );
    expect(
      targets['[G] Show/Vol.1/BDMV/STREAM/00001.m2ts'],
      'Show (2023)/Vol.1/BDMV/STREAM/00001.m2ts',
    );
    // 盘目录里的非视频文件随盘走，不留空壳。
    expect(targets['[G] Show/Vol.1/cover.jpg'], 'Show (2023)/Vol.1/cover.jpg');
    final Set<String?> discRoots = <String?>{
      for (final VideoOrganizationFilePlan file in plan.files)
        if (file.originalRelativePath.contains('/Vol.1/')) file.blurayDiscRoot,
    };
    expect(discRoots, <String?>{'Show (2023)/Vol.1'});
    expect(
      plan.files
          .where((VideoOrganizationFilePlan f) => f.episodeNumber != null)
          .map((VideoOrganizationFilePlan f) => f.blurayDiscRoot),
      everyElement(isNull),
    );
  });

  test('电影身份：盘外的 mkv 才是被抬成正片的那个，盘内最大的 m2ts 不参与', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      ..._disc('Movie/BD'),
      ('Movie/Movie.mkv', 20000),
    ]);
    final Map<String, String> targets = _targets(plan);
    expect(targets['Movie/Movie.mkv'], 'Show (2023)/Show (2023).mkv');
    expect(
      targets['Movie/BD/BDMV/STREAM/00001.m2ts'],
      'Show (2023)/BD/BDMV/STREAM/00001.m2ts',
    );
  });

  test('盘根即种子根时，种子根上与盘无关的文件不被盘认领', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      ..._disc(''),
      ('Bonus.mkv', 10),
    ]);
    final VideoOrganizationFilePlan bonus = plan.files.singleWhere(
      (VideoOrganizationFilePlan f) => f.originalRelativePath == 'Bonus.mkv',
    );
    expect(bonus.blurayDiscRoot, isNull);
    expect(bonus.targetRelativePath, 'Show (2023)/Show (2023).mkv');
  });

  test('反斜杠分隔的种子路径（内置引擎 Windows）同样认盘', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      (r'Rel\BD\BDMV\index.bdmv', 1),
      (r'Rel\BD\BDMV\PLAYLIST\00001.mpls', 1),
      (r'Rel\BD\BDMV\STREAM\00001.m2ts', 100),
    ]);
    expect(
      _targets(plan)[r'Rel\BD\BDMV\STREAM\00001.m2ts'],
      'Show (2023)/BD/BDMV/STREAM/00001.m2ts',
    );
  });

  test('只有 STREAM 而没有 index.bdmv / MPLS 的目录不算盘，照旧按视频排布', () {
    final VideoOrganizationPlan plan = _plan(<(String, int)>[
      ('Rel/BDMV/STREAM/00001.m2ts', 100),
    ]);
    expect(plan.files.single.blurayDiscRoot, isNull);
    expect(
      plan.files.single.targetRelativePath,
      'Show (2023)/Show (2023).m2ts',
    );
  });

  test('共享发布根计算不被盘内 m2ts 带偏', () {
    expect(
      videoDownloadSharedRoot(<TorrentFileEntry>[
        const TorrentFileEntry(
          name: 'A/BD/BDMV/index.bdmv',
          size: 1,
          progress: 1,
          index: 0,
        ),
        const TorrentFileEntry(
          name: 'A/BD/BDMV/STREAM/00001.m2ts',
          size: 1,
          progress: 1,
          index: 1,
        ),
        const TorrentFileEntry(
          name: 'B/Show - 01.mkv',
          size: 1,
          progress: 1,
          index: 2,
        ),
      ]),
      'B',
    );
  });
}
