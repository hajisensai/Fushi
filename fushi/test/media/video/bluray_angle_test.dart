import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_angle.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:path/path.dart' as p;

import 'bluray_fixture.dart';

/// 伪造的多角度 title：第 1 段单角度，第 2 段三个角度（00011 / 00021 / 00031）。
const List<FixturePlayItem> _multiAngleItems = <FixturePlayItem>[
  FixturePlayItem(
    clipId: '00010',
    inTimeTicks: 45000,
    outTimeTicks: 45000 * 61,
  ),
  FixturePlayItem(
    clipId: '00011',
    inTimeTicks: 90000,
    outTimeTicks: 45000 * 32,
    angleClipIds: <String>['00021', '00031'],
  ),
];

void main() {
  group('角度成员路径', () {
    test('拼与拆往返，角度号 1 起、只写第 2 个角度起', () {
      final String member = p.join(
        'D:',
        'Disc',
        'BDMV',
        'PLAYLIST',
        '00001.mpls',
      );
      expect(blurayAnglePath(member, 0), member);
      final String angle2 = blurayAnglePath(member, 1);
      expect(p.basename(angle2), '00001.a2.mpls');
      final BlurayAngleRef ref = parseBlurayAnglePath(angle2)!;
      expect(ref.memberPath, member);
      expect(ref.angleIndex, 1);
      expect(blurayAngleBaseMemberPath(angle2), member);
      expect(parseBlurayAnglePath(member), isNull);
      // 已带角度的再按别的角度拼：先去掉旧角度。
      expect(p.basename(blurayAnglePath(angle2, 8)), '00001.a9.mpls');
      expect(blurayAnglePath(angle2, 0), member);
    });

    test('分集路径也能带角度，背后的真实文件是整卷 .mpls', () {
      const String episode = '/d/Disc/BDMV/PLAYLIST/00001.p03.mpls';
      final String angle = blurayAnglePath(episode, 2);
      expect(angle, '/d/Disc/BDMV/PLAYLIST/00001.p03.a3.mpls');
      expect(parseBlurayAnglePath(angle)!.memberPath, episode);
      expect(
        blurayMemberBackingPlaylistPath(angle),
        '/d/Disc/BDMV/PLAYLIST/00001.mpls',
      );
      expect(
        discMemberBackingFilePath(angle),
        '/d/Disc/BDMV/PLAYLIST/00001.mpls',
      );
      // 仍是蓝光成员：盘根照样反推得出。
      expect(isBlurayPlaylistPath(angle), isTrue);
      expect(discRootForMemberPath(angle), p.normalize('/d/Disc'));
    });

    test('Windows 分隔符照样认；a1 / a10 / 非 .mpls 不是角度路径', () {
      expect(
        parseBlurayAnglePath(
          r'C:\Disc\BDMV\PLAYLIST\00002.a4.MPLS',
        )!.memberPath,
        r'C:\Disc\BDMV\PLAYLIST\00002.MPLS',
      );
      expect(parseBlurayAnglePath('/d/BDMV/PLAYLIST/00001.a1.mpls'), isNull);
      expect(parseBlurayAnglePath('/d/BDMV/PLAYLIST/00001.a10.mpls'), isNull);
      expect(parseBlurayAnglePath('/d/movie.a2.mkv'), isNull);
    });

    test('越界角度与非 .mpls 成员拒绝拼', () {
      expect(
        () => blurayAnglePath('/d/BDMV/PLAYLIST/00001.mpls', 9),
        throwsRangeError,
      );
      expect(
        () => blurayAnglePath('/d/BDMV/PLAYLIST/00001.mpls', -1),
        throwsRangeError,
      );
      expect(() => blurayAnglePath('/d/movie.mkv', 1), throwsArgumentError);
    });
  });

  group('blurayPlaylistForAngle', () {
    test('多角度段换片段、IN/OUT 与总时长不变，单角度段不动', () {
      final BlurayPlaylist playlist = parseBlurayPlaylist(
        buildMplsFixture(playItems: _multiAngleItems),
        id: '00001',
      )!;
      final BlurayPlaylist angle = blurayPlaylistForAngle(playlist, 2);
      expect(angle.id, '00001.a3');
      expect(angle.clipIds, <String>['00010', '00031']);
      for (int i = 0; i < playlist.clips.length; i++) {
        expect(angle.clips[i].inTimeTicks, playlist.clips[i].inTimeTicks);
        expect(angle.clips[i].outTimeTicks, playlist.clips[i].outTimeTicks);
      }
      expect(angle.durationTicks, playlist.durationTicks);
      expect(angle.chapters, playlist.chapters);
      expect(identical(blurayPlaylistForAngle(playlist, 0), playlist), isTrue);
      // 超出所有段角度数的角度：每段都回到第 1 个角度（libbluray 同口径）。
      expect(blurayPlaylistForAngle(playlist, 5).clipIds, playlist.clipIds);
    });
  });

  group('按角度读盘上的成员', () {
    late Directory disc;
    late String member;
    setUp(() async {
      disc = await Directory.systemTemp.createTemp('bluray-angle-');
      final Directory list = await Directory(
        p.join(disc.path, 'BDMV', 'PLAYLIST'),
      ).create(recursive: true);
      final Directory streams = await Directory(
        p.join(disc.path, 'BDMV', 'STREAM'),
      ).create();
      for (final String id in <String>['00010', '00011', '00021', '00031']) {
        await File(p.join(streams.path, '$id.m2ts')).writeAsBytes(<int>[0]);
      }
      member = p.join(list.path, '00001.mpls');
      await File(
        member,
      ).writeAsBytes(buildMplsFixture(playItems: _multiAngleItems));
    });
    tearDown(() async => disc.delete(recursive: true));

    test('readBlurayMemberPlaylist 读出该角度的片段', () async {
      final BlurayPlaylist? angle = await readBlurayMemberPlaylist(
        blurayAnglePath(member, 1),
      );
      expect(angle, isNotNull);
      expect(angle!.clipIds, <String>['00010', '00021']);
      final BlurayPlaylist? base = await readBlurayMemberPlaylist(member);
      expect(base!.clipIds, <String>['00010', '00011']);
      expect(angle.durationTicks, base.durationTicks);
    });

    test('resolveBluraySource 的物理片段是该角度的', () async {
      final BluraySource? source = await resolveBluraySource(
        blurayAnglePath(member, 2),
      );
      expect(source, isNotNull);
      expect(source!.streamPaths.map(p.basename), <String>[
        '00010.m2ts',
        '00031.m2ts',
      ]);
    });

    test('角度成员按背后的 .mpls 判本机媒体，自身不是文件', () async {
      final String angle = blurayAnglePath(member, 1);
      expect(await hasLocalMediaFile(angle), isTrue);
      expect(hasLocalMediaFileSync(angle), isTrue);
      expect(await videoMemberExists(angle), isTrue);
      expect(await videoPathFileExists(angle), isFalse);
      expect(await hasLocalSingleMediaFile(angle), isFalse);
      await File(member).delete();
      expect(await hasLocalMediaFile(angle), isFalse);
    });
  });
}
