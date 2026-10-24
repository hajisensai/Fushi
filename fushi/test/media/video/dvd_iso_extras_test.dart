// DVD 第二轮缺口：`.iso` 镜像整盘读取、特典划分、成员路径的存在性入口。
// 盘与镜像全部由 `dvd_fixture.dart` / `dvd_iso_fixture.dart` 合成。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/strm_file.dart';
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:path/path.dart' as p;

import 'dvd_fixture.dart';
import 'dvd_iso_fixture.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dvd_iso_extras_');
    debugClearBlurayDiscExtrasCache();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('.iso 镜像形态的 DVD', () {
    test('读出与文件夹形态同样的 title；成员路径挂在 iso 下；盘身份一致', () async {
      final String folder = p.join(tmp.path, 'folder', 'Show');
      writeTvDvdFixture(folder);
      final String iso = p.join(tmp.path, 'Show.iso');
      writeIsoFromFolderDisc(folder, iso);

      final DvdDisc disc = (await readDvdDisc(iso))!;
      expect(disc.rootPath, p.normalize(iso));
      expect(disc.name, 'Show');
      expect(disc.volumeLabel, 'DVD_VIDEO');
      expect(disc.titles.map((DvdTitle t) => t.titleNumber), <int>[2, 3, 4, 5]);
      expect(
        disc.titles.first.titlePath,
        p.join(p.normalize(iso), 'VIDEO_TS', 'TITLE_02.dvdtitle'),
      );
      // 同一份 IFO 字节：镜像与文件夹算出的 DVDDiscID 必须一样（libdvdread 两种形态
      // 都走同一个 DVDDiscID）。
      expect(disc.discId, (await readDvdDisc(folder))!.discId);

      final String member = disc.titles.first.titlePath;
      expect(discRootForMemberPath(member), p.normalize(iso));
      expect(dvdPlaybackUriForTitlePath(member), 'dvd://1/${p.normalize(iso)}');
      expect(discMemberBackingFilePath(member), p.normalize(iso));
      expect(await readDiscFormatAtRoot(iso), DiscFormat.dvd);
    });

    test('镜像里没有 VIDEO_TS（数据盘 / BD 镜像 / 坏文件）返回 null，不抛', () async {
      final String junk = p.join(tmp.path, 'junk.iso');
      File(junk).writeAsBytesSync(Uint8List(300000));
      expect(await readDvdDisc(junk), isNull);
      final String data = p.join(tmp.path, 'data.iso');
      File(data).writeAsBytesSync(
        buildVideoTsIsoImage(<String, List<int>>{
          'README.TXT': <int>[1],
        }),
      );
      expect(await readDvdDisc(data), isNull);
    });
  });

  group('特典', () {
    test('电影盘：制作特辑是特典，预告（< 1 分钟）与菜单循环不是', () async {
      final String root = p.join(tmp.path, 'Movie');
      writeMovieWithExtrasDvdFixture(root);
      final DvdDisc disc = (await readDvdDisc(root))!;
      expect(disc.titles.map((DvdTitle t) => t.titleNumber), <int>[1]);
      expect(disc.extras.map((DvdTitle t) => t.titleNumber), <int>[2]);
      expect(disc.extras.single.name, 'Movie - T02');
      expect(disc.extras.single.isMainFeature, isFalse);
    });

    test('索引口径：特典挂到同盘正片下（文件夹与镜像同一判据）', () async {
      final String root = p.join(tmp.path, 'Movie');
      writeMovieWithExtrasDvdFixture(root);
      final String iso = p.join(tmp.path, 'iso', 'Movie.iso');
      writeIsoFromFolderDisc(root, iso);
      for (final String discRoot in <String>[root, iso]) {
        final String main = dvdTitlePath(discRoot, 1);
        final String extra = dvdTitlePath(discRoot, 2);
        final Map<String, String> extras = await discMemberExtras(<String>[
          main,
          extra,
        ]);
        expect(extras.length, 1, reason: discRoot);
        expect(extras.values.single, main, reason: discRoot);
      }
    });
  });

  group('成员路径的存在性入口', () {
    test('「这一条还在不在」：DVD title 按 VIDEO_TS.IFO / iso 判', () {
      final String root = p.join(tmp.path, 'Show');
      writeTvDvdFixture(root);
      final String member = dvdTitlePath(root, 2);
      expect(File(member).existsSync(), isFalse, reason: '前提：成员路径是虚拟的');
      expect(videoMemberExistsSync(member), isTrue);
      File(p.join(root, 'VIDEO_TS', 'VIDEO_TS.IFO')).deleteSync();
      expect(videoMemberExistsSync(member), isFalse);

      final String iso = p.join(tmp.path, 'Other.iso');
      File(iso).writeAsBytesSync(Uint8List(16));
      expect(videoMemberExistsSync(dvdTitlePath(iso, 1)), isTrue);
    });

    test('「有没有可读的媒体文件」：DVD title 没有（不碰文件系统），普通文件看磁盘', () async {
      final String root = p.join(tmp.path, 'Show');
      writeTvDvdFixture(root);
      final String member = dvdTitlePath(root, 2);
      expect(lacksLocalMediaFile(member), isTrue);
      expect(hasLocalMediaFileSync(member), isFalse);
      expect(await hasLocalMediaFile(member), isFalse);

      final String plain = p.join(tmp.path, 'a.mkv');
      expect(hasLocalMediaFileSync(plain), isFalse);
      File(plain).writeAsBytesSync(<int>[1]);
      expect(hasLocalMediaFileSync(plain), isTrue);
      expect(await videoMemberExists(plain), isTrue);
    });
  });
}
