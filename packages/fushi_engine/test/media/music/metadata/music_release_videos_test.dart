import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_release_videos.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show videoDownloadJobReleaseAudioPaths;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

int _id = 0;

VideoDownloadJobFileRow _row(
  String rel, {
  String kind = 'other',
  String status = VideoDownloadJobFileStatus.downloaded,
  String? finalPath,
  int? size,
  bool selected = true,
}) => VideoDownloadJobFileRow(
  id: ++_id,
  jobId: 'job',
  originalRelativePath: rel,
  currentRelativePath: rel,
  finalAbsolutePath: finalPath,
  kind: kind,
  sizeBytes: size,
  selected: selected,
  status: status,
  createdAt: 0,
  updatedAt: 0,
);

const int _mb = 1024 * 1024;

MusicRelease? _release(List<VideoDownloadJobFileRow> rows) =>
    musicReleaseOfDownloadJob(
      rows,
      minDiscBytes: 20 * _mb,
      maxDiscBytes: 6 * 1024 * _mb,
      discStreamLimit: 2,
    );

/// 用户库实况：VCB 发布的 CD 留在原发布目录，NCOP / NCED / PV 整理进
/// `<作品 (年)>/Extras/SPs`，整个来源后来又被搬到 NAS 映射盘。
void main() {
  final p.Context win = p.Context(style: p.Style.windows);
  const String cd =
      r'[SweetSub&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]\CDs\[230125] OP\01.flac';
  const String ncop =
      'お兄ちゃんはおしまい！ (2023)/Extras/SPs/[SweetSub&VCB-Studio] Oniichan ha Oshimai! [NCOP][Ma10p_1080p].mkv';

  group('musicReleaseOfDownloadJob', () {
    test('纯音频目录 + 片头片尾 / PV 特典；菜单、正片、扫图不算候选', () {
      final MusicRelease r = _release(<VideoDownloadJobFileRow>[
        _row(cd),
        _row(
          r'[SweetSub&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]\Scans\01.webp',
        ),
        _row(ncop, kind: 'extra', status: VideoDownloadJobFileStatus.organized),
        _row(
          'お兄ちゃんはおしまい！ (2023)/Extras/SPs/[Grp] Title [PV01].mkv',
          kind: 'extra',
        ),
        _row(
          'お兄ちゃんはおしまい！ (2023)/Extras/SPs/[Grp] Title [Menu01].mkv',
          kind: 'extra',
        ),
        _row(
          'お兄ちゃんはおしまい！ (2023)/Season 01/お兄ちゃんはおしまい！ (2023) - S01E01.mkv',
          kind: 'video',
        ),
      ])!;
      expect(r.audioDirs, <String>{
        '[SweetSub&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]/CDs/[230125] OP',
      });
      expect(
        r.videos.map(
          (MusicReleaseVideoRef v) => p.posix.basename(v.relativePath),
        ),
        <String>[
          '[SweetSub&VCB-Studio] Oniichan ha Oshimai! [NCOP][Ma10p_1080p].mkv',
          '[Grp] Title [PV01].mkv',
        ],
      );
    });

    test('原盘流按大小筛、每张盘只取最大的几条', () {
      const String disc = 'ぼっち・ざ・ろっく！ [BDMV] (2022)/VOL1/BDMV/STREAM';
      final MusicRelease r = _release(<VideoDownloadJobFileRow>[
        _row(r'ぼっち・ざ・ろっく！\vol.1\CD\01.flac'),
        _row('$disc/00001.m2ts', size: 5 * _mb), // 菜单背景
        _row('$disc/00002.m2ts', size: 300 * _mb),
        _row('$disc/00003.m2ts', size: 200 * _mb),
        _row('$disc/00004.m2ts', size: 100 * _mb),
        _row('$disc/00005.m2ts', size: 8 * 1024 * _mb), // 整片
      ])!;
      expect(
        r.videos.map(
          (MusicReleaseVideoRef v) => p.posix.basename(v.relativePath),
        ),
        <String>['00002.m2ts', '00003.m2ts'],
      );
      expect(r.videos.every((MusicReleaseVideoRef v) => v.discStream), isTrue);
    });

    test('没有纯音频或没有候选视频的任务不是发布', () {
      expect(
        _release(<VideoDownloadJobFileRow>[_row(ncop, kind: 'extra')]),
        isNull,
      );
      expect(_release(<VideoDownloadJobFileRow>[_row(cd)]), isNull);
      expect(
        _release(<VideoDownloadJobFileRow>[
          _row(cd, status: VideoDownloadJobFileStatus.skipped),
          _row(ncop, kind: 'extra'),
        ]),
        isNull,
        reason: '跳过没下的 CD 不算',
      );
    });
  });

  group('musicReleaseVideosForDir', () {
    final MusicRelease release = _release(<VideoDownloadJobFileRow>[
      _row(cd),
      _row(
        ncop,
        kind: 'extra',
        finalPath: r'D:\video\播放列表合集\お兄ちゃんはおしまい！ (2023)\Extras\SPs\x.mkv',
      ),
    ])!;

    test('来源根没动：候选 = 来源根 + 相对路径，其后是任务记下的路径', () {
      final List<MusicReleaseVideoCandidate> c = musicReleaseVideosForDir(
        r'D:\video\播放列表合集\[SweetSub&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]\CDs\[230125] OP',
        <MusicRelease>[release],
        context: win,
      );
      expect(
        c.single.alternatives.first,
        win.joinAll(<String>[r'D:\video\播放列表合集', ...ncop.split('/')]),
      );
      expect(c.single.alternatives.last, endsWith(r'SPs\x.mkv'));
      expect(c.single.discStream, isFalse);
    });

    test('整个来源搬到 V:（大小写不同也认）：按曲目路径反推现在的来源根', () {
      final List<MusicReleaseVideoCandidate> c = musicReleaseVideosForDir(
        r'V:\[SWEETSUB&VCB-Studio] Oniichan ha Oshimai! [Ma10p_1080p]\cds\[230125] OP',
        <MusicRelease>[release],
        context: win,
      );
      expect(
        c.single.alternatives.first,
        startsWith(r'V:\お兄ちゃんはおしまい！ (2023)\Extras'),
      );
    });

    test('不属于任何发布的目录没有候选', () {
      expect(
        musicReleaseVideosForDir(r'D:\音乐\K-ON!! OST', <MusicRelease>[
          release,
        ], context: win),
        isEmpty,
      );
      expect(
        musicReleaseVideosForDir(r'D:\other\[230125] OP', <MusicRelease>[
          release,
        ], context: win),
        isEmpty,
        reason: '只尾段同名不算，要整条 CD 相对目录对上',
      );
    });
  });

  group('videoDownloadJobReleaseAudioPaths', () {
    test('取选中、没跳过的纯音频，拼在来源根下；视频 / 盘内 / 越界路径不算', () {
      final List<String> paths = videoDownloadJobReleaseAudioPaths(
        sourceRoot: p.join(p.current, 'src'),
        files: <VideoDownloadJobFileRow>[
          _row(cd),
          _row(r'Show\CD\02.flac', status: VideoDownloadJobFileStatus.skipped),
          _row(r'Show\CD\03.flac', selected: false),
          _row(r'Show\ep01.mkv', kind: 'video'),
          _row(r'..\escape\04.flac'),
        ],
      );
      expect(paths, hasLength(1));
      expect(paths.single, endsWith('01.flac'));
      expect(p.isWithin(p.join(p.current, 'src'), paths.single), isTrue);
    });
  });
}
