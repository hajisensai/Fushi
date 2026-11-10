// 标题认不出的 BD 整包靠种子文件列表证成整包；「Show Special」这类一集特典不能
// 被误判成全集（反馈 rCT8Ms0AIe，BUG-4246 / BUG-4243 遗留）。
import 'package:test/test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_release_scope_evidence.dart';

const String _garupa =
    '[喵萌Production&LoliHouse] BanG Dream! 少女乐团派对!☆PICO～大盛～ / '
    'Garupa☆PICO～OHMORI～ [BDRip 1080p HEVC-10bit FLAC]';
const String _mujica =
    '[Moozzi2] BanG Dream! Ave Mujica (BD 1920x1080 x.264 FLAC) - TV + SP';
const String _special = '[Grp] Show Special [1080p]';

List<String> _episodes(String prefix, int count, {String suffix = '.mkv'}) =>
    <String>[
      for (int i = 1; i <= count; i++)
        '$prefix${i.toString().padLeft(2, '0')}$suffix',
    ];

class _Resource extends VideoResourceCandidate {
  _Resource(String id, String title, {int? sizeBytes, String? resolution})
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'site',
        providerPriority: 100,
        remoteId: id,
        title: title,
        sizeBytes: sizeBytes,
        resolution: resolution,
      );
}

const int _gib = 1024 * 1024 * 1024;

void main() {
  group('judgeVideoReleaseScope', () {
    test('反馈里的两条 BD 整包：标题判不出，需要文件列表', () {
      for (final String title in <String>[_garupa, _mujica, _special]) {
        expect(videoReleaseNeedsManifest(title), isTrue, reason: title);
        final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
          title,
        );
        expect(evidence.scope, VideoReleaseScope.undetermined, reason: title);
        expect(evidence.isSeasonPack, isFalse, reason: title);
      }
    });

    test('标题证据照旧：写明合集 → 整包；带集号 → 单条；不需要文件列表', () {
      final VideoReleaseScopeEvidence batch = judgeVideoReleaseScope(
        '[Grp] Show (01-12) [1080p] Batch',
      );
      expect(batch.scope, VideoReleaseScope.seasonPack);
      expect(batch.basis, VideoReleaseScopeBasis.title);
      final VideoReleaseScopeEvidence single = judgeVideoReleaseScope(
        '[Grp] Show - 05 [1080p]',
        manifest: VideoReleaseManifest(_episodes('Show - ', 12)),
      );
      expect(single.scope, VideoReleaseScope.singleRelease);
      expect(single.basis, VideoReleaseScopeBasis.title);
      expect(videoReleaseNeedsManifest('[Grp] Show - 05 [1080p]'), isFalse);
      expect(
        videoReleaseNeedsManifest('[Grp] Show (01-12) [1080p] Batch'),
        isFalse,
      );
    });

    test('喵萌 Garupa☆PICO 大盛 BD 包：文件列表里 26 集正片 → 整包', () {
      final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
        _garupa,
        manifest: VideoReleaseManifest(<String>[
          ..._episodes(
            '[LoliHouse] Garupa Pico Oomori/[LoliHouse] Garupa Pico Oomori - ',
            26,
            suffix: ' [BDRip 1080p HEVC-10bit FLAC].mkv',
          ),
          '[LoliHouse] Garupa Pico Oomori/Fonts/A-OTF-ShinGoPro.otf',
        ]),
      );
      expect(evidence.scope, VideoReleaseScope.seasonPack);
      expect(evidence.basis, VideoReleaseScopeBasis.fileList);
      expect(evidence.episodes, <int>{for (int i = 1; i <= 26; i++) i});
    });

    test('Moozzi2 Ave Mujica TV + SP：特典目录与 SP 文件不算集号，正片 13 集 → 整包', () {
      const String root = '[Moozzi2] BanG Dream! Ave Mujica';
      final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
        _mujica,
        manifest: VideoReleaseManifest(<String>[
          ..._episodes(
            '$root/$root - ',
            13,
            suffix: ' (BD 1920x1080 x.264 Flac).mkv',
          ),
          '$root/$root - SP01 (BD 1920x1080 x.264 Flac).mkv',
          '$root/SPs/$root - NCOP (BD 1920x1080 x.264 Flac).mkv',
          '$root/SPs/$root - NCED (BD 1920x1080 x.264 Flac).mkv',
          '$root/Scans/01.png',
        ]),
      );
      expect(evidence.scope, VideoReleaseScope.seasonPack);
      expect(evidence.episodes, <int>{for (int i = 1; i <= 13; i++) i});
    });

    test('反例：「Show Special」种子里只有一个视频 → 单条，不是全集', () {
      final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
        _special,
        manifest: VideoReleaseManifest(<String>[
          '[Grp] Show Special [1080p].mkv',
          '[Grp] Show Special [1080p].ass',
        ]),
      );
      expect(evidence.scope, VideoReleaseScope.singleRelease);
      expect(evidence.isSeasonPack, isFalse);
    });

    test('反例：两集特典（SP01 / SP02、Special 1 / 2）带序号也不算整包', () {
      for (final List<String> files in <List<String>>[
        <String>['Show - SP01 [1080p].mkv', 'Show - SP02 [1080p].mkv'],
        <String>['Show Special 1 [1080p].mkv', 'Show Special 2 [1080p].mkv'],
        <String>['Show OVA 01.mkv', 'Show OVA 02.mkv'],
      ]) {
        final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
          _special,
          manifest: VideoReleaseManifest(files),
        );
        expect(evidence.isSeasonPack, isFalse, reason: files.join(', '));
      }
    });

    test('反例：正片 + 两段 Bonus（剧场版形态）不算整包', () {
      final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
        '[Grp] Show The Movie [BDRip 1080p]',
        manifest: VideoReleaseManifest(<String>[
          'Show The Movie [BDRip 1080p].mkv',
          'Show The Movie - Bonus 01.mkv',
          'Show The Movie - Bonus 02.mkv',
        ]),
      );
      // 带集号的 2 条不占多数（另有 1 条无集号正片）。
      expect(evidence.isSeasonPack, isFalse);
    });

    test('原盘（BDMV）：.m2ts 序号不是集号，仍判不出', () {
      final VideoReleaseScopeEvidence evidence = judgeVideoReleaseScope(
        _garupa,
        manifest: VideoReleaseManifest(<String>[
          'DISC1/BDMV/index.bdmv',
          'DISC1/BDMV/MovieObject.bdmv',
          'DISC1/BDMV/STREAM/00001.m2ts',
          'DISC1/BDMV/STREAM/00002.m2ts',
          'DISC1/BDMV/STREAM/00003.m2ts',
        ]),
      );
      expect(evidence.scope, VideoReleaseScope.undetermined);
    });
  });

  group('videoReleaseManifestTargets', () {
    test('只挑标题判不出的发布，按输入次序，总量封顶', () {
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _Resource('batch', '[Grp] Show (01-12) [1080p] Batch'),
        _Resource('ep', '[Grp] Show - 01 [1080p]'),
        _Resource('a', '[A] Show [BDRip 1080p]'),
        _Resource('b', '[B] Show [BDRip 1080p]'),
        _Resource('c', '[C] Show [BDRip 1080p]'),
        _Resource('d', '[D] Show [BDRip 1080p]'),
      ];
      expect(
        videoReleaseManifestTargets(
          items,
          sizeReference: items,
          inspected: <String>{},
        ).map((VideoResourceCandidate c) => c.remoteId),
        <String>['a', 'b', 'c'],
      );
      // 已取过的计入总量、不再取。
      expect(
        videoReleaseManifestTargets(
          items,
          sizeReference: items,
          inspected: <String>{items[2].identityKey, items[3].identityKey},
        ).map((VideoResourceCandidate c) => c.remoteId),
        <String>['c'],
      );
    });

    test('体积反证：不到同清晰度单集参考体积 1.5 倍的不取；缺体积 / 缺参考照取', () {
      final List<VideoResourceCandidate> items = <VideoResourceCandidate>[
        _Resource('e1', '[Grp] Show - 01 [1080p]', sizeBytes: _gib),
        _Resource('e2', '[Grp] Show - 02 [1080p]', sizeBytes: _gib),
        _Resource('sp', '[Grp] Show Special [1080p]', sizeBytes: _gib),
        _Resource('bd', '[Grp] Show [BDRip 1080p]', sizeBytes: 14 * _gib),
        _Resource('nosize', '[Grp2] Show [BDRip 1080p]'),
        _Resource('720', '[Grp] Show [BDRip 720p]', sizeBytes: _gib),
      ];
      expect(
        videoReleaseManifestTargets(
          items,
          sizeReference: items,
          inspected: <String>{},
        ).map((VideoResourceCandidate c) => c.remoteId),
        <String>['bd', 'nosize', '720'],
      );
    });
  });
}
