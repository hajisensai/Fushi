import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/disc/disc_angle.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_disc_outputs.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show videoSubtitleDiscExportDir;
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:path/path.dart' as p;

import 'dvd_fixture.dart';

void main() {
  group('DVD 角度成员路径', () {
    final String title = dvdTitlePath(p.join(p.separator, 'd', 'Disc'), 3);

    test('拼与拆往返，角度号 1 起、只写第 2 个角度起', () {
      expect(dvdTitleAnglePath(title, 0), title);
      final String angle2 = dvdTitleAnglePath(title, 1);
      expect(p.basename(angle2), 'TITLE_03.a2.dvdtitle');
      final DvdTitleAngleRef ref = parseDvdTitleAnglePath(angle2)!;
      expect(ref.titlePath, title);
      expect(ref.angleIndex, 1);
      expect(dvdTitleAngleBasePath(angle2), title);
      expect(parseDvdTitleAnglePath(title), isNull);
      // 已带角度的再按别的角度拼：先去掉旧角度。
      expect(p.basename(dvdTitleAnglePath(angle2, 8)), 'TITLE_03.a9.dvdtitle');
      expect(dvdTitleAnglePath(angle2, 0), title);
    });

    test('仍是同一张盘的同一条 title：盘根、title 号、背后文件、播放地址不变', () {
      final String angle = dvdTitleAnglePath(title, 2);
      expect(isDvdTitlePath(angle), isTrue);
      expect(dvdTitleNumberForPath(angle), 3);
      expect(dvdDiscRootForTitlePath(angle), dvdDiscRootForTitlePath(title));
      expect(discRootForMemberPath(angle), discRootForMemberPath(title));
      expect(discFormatHintForMemberPath(angle), DiscFormat.dvd);
      expect(
        discMemberBackingFilePath(angle),
        discMemberBackingFilePath(title),
      );
      expect(
        dvdPlaybackUriForTitlePath(angle),
        dvdPlaybackUriForTitlePath(title),
      );
      final String iso = dvdTitlePath(
        p.join(p.separator, 'isos', 'Show.iso'),
        2,
      );
      expect(
        dvdTitleBackingFilePath(dvdTitleAnglePath(iso, 1)),
        p.join(p.separator, 'isos', 'Show.iso'),
      );
    });

    test('Windows 分隔符照样认；a1 / a10 / 非 .dvdtitle 不是角度路径', () {
      expect(
        parseDvdTitleAnglePath(
          r'C:\Disc\VIDEO_TS\TITLE_02.a4.DVDTITLE',
        )!.titlePath,
        r'C:\Disc\VIDEO_TS\TITLE_02.DVDTITLE',
      );
      expect(
        parseDvdTitleAnglePath('/d/VIDEO_TS/TITLE_01.a1.dvdtitle'),
        isNull,
      );
      expect(
        parseDvdTitleAnglePath('/d/VIDEO_TS/TITLE_01.a10.dvdtitle'),
        isNull,
      );
      expect(parseDvdTitleAnglePath('/d/VIDEO_TS/TITLE_01.a2.mpls'), isNull);
      expect(dvdTitleNumberForPath('/d/VIDEO_TS/TITLE_01.a1.dvdtitle'), isNull);
    });

    test('越界角度与非 DVD title 拒绝拼', () {
      expect(() => dvdTitleAnglePath(title, -1), throwsRangeError);
      expect(() => dvdTitleAnglePath(title, kDvdMaxAngles), throwsRangeError);
      expect(
        () => dvdTitleAnglePath('/d/BDMV/PLAYLIST/00001.mpls', 1),
        throwsArgumentError,
      );
    });

    test('盘型通用入口：蓝光与 DVD 同一个形状', () {
      final String angle = discAnglePath(title, 1);
      expect(angle, dvdTitleAnglePath(title, 1));
      expect(parseDiscAnglePath(angle), (memberPath: title, angleIndex: 1));
      expect(discAngleBaseMemberPath(angle), title);
      const String mpls = '/d/Disc/BDMV/PLAYLIST/00001.mpls';
      expect(discAnglePath(mpls, 1), '/d/Disc/BDMV/PLAYLIST/00001.a2.mpls');
      expect(parseDiscAnglePath('/d/Disc/BDMV/PLAYLIST/00001.a2.mpls'), (
        memberPath: mpls,
        angleIndex: 1,
      ));
      expect(discAngleBaseMemberPath('/d/movie.mkv'), '/d/movie.mkv');
      expect(parseDiscAnglePath('/d/movie.mkv'), isNull);
      expect(discMaxAnglesFor(title), kDvdMaxAngles);
      expect(discMaxAnglesFor('/d/movie.mkv'), 0);
      expect(() => discAnglePath('/d/movie.mkv', 0), throwsArgumentError);
    });
  });

  group('落在本机的 DVD', () {
    late Directory disc;

    setUp(() async {
      disc = await Directory.systemTemp.createTemp('dvd-angle-');
      writeTvDvdFixture(disc.path);
    });

    tearDown(() async {
      await disc.delete(recursive: true);
    });

    test('角度成员按盘的 VIDEO_TS.IFO 判本机媒体，自身不是文件', () async {
      final String angle = dvdTitleAnglePath(dvdTitlePath(disc.path, 2), 1);
      expect(await hasLocalMediaFile(angle), isTrue);
      expect(hasLocalMediaFileSync(angle), isTrue);
      expect(await videoPathFileExists(angle), isFalse);
      File(p.join(disc.path, 'VIDEO_TS', 'VIDEO_TS.IFO')).deleteSync();
      expect(await hasLocalMediaFile(angle), isFalse);
    });

    test('disc_out：每个角度一个目录，默认角度仍是 title 自己那个，回收一并删', () async {
      final Directory jobs = Directory(p.join(disc.path, 'jobs'));
      final String member = dvdTitlePath(disc.path, 2);
      final List<Directory> dirs = videoSubtitleDiscOutputDirs(jobs, member);
      expect(dirs, hasLength(kDvdMaxAngles));
      expect(
        dirs.first.path,
        videoSubtitleDiscExportDir(jobs, member)!.path,
        reason: '默认角度的 disc_out 不变，已登记的产物照旧',
      );
      final Directory angleOut = videoSubtitleDiscExportDir(
        jobs,
        dvdTitleAnglePath(member, 1),
      )!;
      expect(angleOut.path, isNot(dirs.first.path));
      expect(dirs.map((Directory d) => d.path), contains(angleOut.path));
      for (final Directory d in <Directory>[dirs.first, angleOut]) {
        d.createSync(recursive: true);
        File(p.join(d.path, 'x.ja.srt')).writeAsStringSync('1');
      }
      final List<(String, Object)> failures =
          await deleteVideoSubtitleDiscOutputs(
            jobsRoot: jobs,
            memberPaths: <String>[member],
          );
      expect(failures, isEmpty);
      expect(dirs.first.existsSync(), isFalse);
      expect(angleOut.existsSync(), isFalse);
    });
  });
}
