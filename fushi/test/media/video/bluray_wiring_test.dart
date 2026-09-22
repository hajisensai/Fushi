import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/media/video/video_local_files.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

SourceFileEntry _file(String path) =>
    SourceFileEntry(name: p.basename(path), path: path, isDirectory: false);

VideoBookRow _row({required String videoPath}) => VideoBookRow(
  bookUid: 'video/x',
  title: 'x',
  videoPath: videoPath,
  currentEpisode: 0,
  lastPositionMs: 0,
  delayMs: 0,
  importedAt: 0,
);

void main() {
  group('扫描规划认盘', () {
    // 一张最小的盘：一条播放列表 + 被它切碎的三段码流 + 一个菜单片。
    final List<SourceFileEntry> discFiles = <SourceFileEntry>[
      _file('/lib/Movie/BDMV/index.bdmv'),
      _file('/lib/Movie/BDMV/PLAYLIST/00001.mpls'),
      _file('/lib/Movie/BDMV/PLAYLIST/00800.mpls'),
      _file('/lib/Movie/BDMV/CLIPINF/00001.clpi'),
      _file('/lib/Movie/BDMV/STREAM/00001.m2ts'),
      _file('/lib/Movie/BDMV/STREAM/00002.m2ts'),
      _file('/lib/Movie/BDMV/STREAM/00003.m2ts'),
      _file('/lib/Movie/BDMV/BACKUP/PLAYLIST/00001.mpls'),
      _file('/lib/Movie/CERTIFICATE/id.bdmv'),
    ];

    test('盘被认出来，盘内 m2ts 不再各自成为散装视频条目', () {
      final ScanPlan plan = planScanFromFileList(
        discFiles,
        detectBlurayDiscs: true,
      );

      expect(
        plan.blurayDiscs.map((ScanBlurayDiscItem d) => d.discRootPath),
        <String>[p.normalize('/lib/Movie')],
      );
      // 不摘的话用户会同时拿到「正片」和一屏叫 00001~00003 的碎片。
      expect(plan.videos, isEmpty);
    });

    test('关掉盘识别时，m2ts 退回散装视频（网络来源走的就是这条）', () {
      final ScanPlan plan = planScanFromFileList(discFiles);

      expect(plan.blurayDiscs, isEmpty);
      expect(
        plan.videos.map((ScanVideoItem v) => p.basename(v.videoPath)),
        <String>['00001.m2ts', '00002.m2ts', '00003.m2ts'],
      );
    });

    test('盘外的视频照常进散装表', () {
      final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
        ...discFiles,
        _file('/lib/别的片子.mkv'),
        _file('/lib/Movie/特典.mkv'),
      ], detectBlurayDiscs: true);

      expect(
        plan.videos.map((ScanVideoItem v) => p.basename(v.videoPath)),
        <String>['别的片子.mkv', '特典.mkv'],
      );
      expect(plan.blurayDiscs, hasLength(1));
    });

    test('只有 BDMV 目录名但没有播放列表：不算盘，也不吃掉里面的文件', () {
      final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
        _file('/lib/伪盘/BDMV/STREAM/00001.m2ts'),
      ], detectBlurayDiscs: true);

      expect(plan.blurayDiscs, isEmpty);
      expect(plan.videos, hasLength(1));
    });

    test('多张盘各自成条', () {
      final ScanPlan plan = planScanFromFileList(<SourceFileEntry>[
        _file('/lib/Vol1/BDMV/PLAYLIST/00001.mpls'),
        _file('/lib/Vol1/BDMV/STREAM/00001.m2ts'),
        _file('/lib/Vol2/BDMV/PLAYLIST/00001.mpls'),
        _file('/lib/Vol2/BDMV/STREAM/00001.m2ts'),
      ], detectBlurayDiscs: true);

      expect(
        plan.blurayDiscs.map((ScanBlurayDiscItem d) => d.discRootPath),
        <String>[p.normalize('/lib/Vol1'), p.normalize('/lib/Vol2')],
      );
      expect(plan.videos, isEmpty);
    });
  });

  group('删除条目不得动盘结构', () {
    test('蓝光标题不给出任何「可删的本地文件」', () {
      const String mpls = '/lib/Movie/BDMV/PLAYLIST/00001.mpls';

      // 删掉 .mpls 等于把盘拆坏：码流还在 STREAM 下，盘却再也说不出该怎么播；
      // 一张盘上多条标题还共用同一批码流。
      expect(localVideoFileCandidates(videoPath: mpls), isEmpty);
      expect(videoBookHasLocalFiles(_row(videoPath: mpls)), isFalse);
    });

    test('普通本地视频不受影响', () {
      const String mkv = '/lib/普通片子.mkv';
      expect(localVideoFileCandidates(videoPath: mkv), <String>[mkv]);
      expect(videoBookHasLocalFiles(_row(videoPath: mkv)), isTrue);
    });
  });

  group('blurayPlaylistFacts', () {
    test('时长/编码/高度/帧率/语言全从 MPLS 出，不跑 ffprobe', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 45000 * 10,
            outTimeTicks: 45000 * 3610,
          ),
        ],
        streams: const <FixtureStream>[
          FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
          FixtureStream.audio(codingType: 0x83, language: 'jpn'),
          FixtureStream.audio(codingType: 0x81, language: 'eng'),
          FixtureStream.subtitle(codingType: 0x90, language: 'chi'),
        ],
      );
      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      final VideoProbeFacts facts = blurayPlaylistFacts(
        playlist,
        streamBytes: 21474836480,
      );

      expect(facts.durationMs, const Duration(hours: 1).inMilliseconds);
      expect(facts.fileSizeBytes, 21474836480);
      // 用 ffprobe 的拼写，好让下游的编码名映射表原样查得到。
      expect(facts.video!.codec, 'h264');
      expect(facts.video!.height, 1080);
      expect(facts.video!.frameRateMilli, 23976);
      // 宽度不猜：BD 规范允许 1080 行同时对应 1920 与 1440。
      expect(facts.video!.width, isNull);
      expect(facts.audioTracks.map((AudioTrackFacts a) => a.codec), <String>[
        'truehd',
        'ac3',
      ]);
      expect(facts.audioLanguages, <String>['jpn', 'eng']);
      expect(facts.subtitleTracks.single.codec, 'hdmv_pgs_subtitle');
      expect(facts.subtitleTracks.single.codecLabel, 'PGS');
      expect(facts.isEmpty, isFalse);
      expect(facts.isUnavailable, isFalse);
    });

    test('多段正片的时长是各段之和，不是某一段的', () {
      final Uint8List bytes = buildMplsFixture(
        playItems: const <FixturePlayItem>[
          FixturePlayItem(
            clipId: '00001',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 2400,
          ),
          FixturePlayItem(
            clipId: '00002',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 2400,
          ),
          FixturePlayItem(
            clipId: '00003',
            inTimeTicks: 0,
            outTimeTicks: 45000 * 2400,
          ),
        ],
      );
      final BlurayPlaylist playlist = parseBlurayPlaylist(bytes, id: '00001')!;

      expect(
        blurayPlaylistFacts(playlist).durationMs,
        const Duration(hours: 2).inMilliseconds,
      );
    });
  });
}
