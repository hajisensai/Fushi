import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_album_versions.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi_core/fushi_core.dart' show MusicTrackRow;
import 'package:path/path.dart' as p;

MusicTrackRow _row(String uid, String path, {int? disc, int? ms}) =>
    MusicTrackRow(
      trackUid: uid,
      path: path,
      title: uid,
      discNo: disc,
      durationMs: ms,
      isLossless: true,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );

void main() {
  group('musicDiscArtScore 识别规则', () {
    test('专辑根下的盘面图认、其它扫图部位不认', () {
      for (final String name in <String>[
        'disc.jpg',
        'CD.png',
        'cdart.png',
        'discart.webp',
        'Disc 1.jpg',
        'cd1.jpeg',
        'disc_01.jpg',
        'label.jpg',
        '05 - Disc.jpg',
        '盘面.jpg',
        'ディスク.png',
      ]) {
        expect(musicDiscArtScore(name), isNotNull, reason: name);
      }
      for (final String name in <String>[
        'cover.jpg',
        'folder.jpg',
        'front.jpg',
        'cdcover.jpg',
        'cd_back.jpg',
        'disc tray.jpg',
        'CD Booklet 01.jpg',
        'obi.jpg',
        'disc.txt',
        'disc.flac',
        '封面.jpg',
      ]) {
        expect(musicDiscArtScore(name), isNull, reason: name);
      }
    });

    test('扫图收纳目录里认，最多下探一层子目录；其它子目录不认', () {
      expect(musicDiscArtScore('Scans/CD.jpg'), isNotNull);
      expect(musicDiscArtScore(r'Artwork\disc1.png'), isNotNull);
      expect(musicDiscArtScore('Scans/Disc/01.jpg'), isNotNull);
      expect(musicDiscArtScore('Covers/disc.jpg'), isNotNull);
      expect(musicDiscArtScore('扫图/盘面.jpg'), isNotNull);
      expect(musicDiscArtScore('Scans/Booklet/01.jpg'), isNull);
      expect(musicDiscArtScore('Scans/Disc/Back/01.jpg'), isNull);
      // 分碟目录（音频目录）里的图由那个目录自己作根时再认。
      expect(musicDiscArtScore('Disc 1/folder.jpg'), isNull);
      expect(musicDiscArtScore('Bonus/disc.jpg'), isNull);
    });

    test('根下优先于扫图目录，第一张盘优先于后面的', () {
      expect(
        pickMusicDiscArt(<String>['Scans/disc.jpg', 'disc.jpg']),
        'disc.jpg',
      );
      expect(pickMusicDiscArt(<String>['cd2.jpg', 'cd1.jpg']), 'cd1.jpg');
      expect(pickMusicDiscArt(<String>['cover.jpg', 'back.jpg']), isNull);
      expect(pickMusicDiscArt(<String>['label.jpg', 'cdart.png']), 'cdart.png');
    });
  });

  group('分碟目录与版本目录', () {
    test('分碟目录名', () {
      for (final String name in <String>[
        'Disc 1',
        'CD2',
        'DISC-01 Original',
        'disk_3',
        '第2盘',
        '2枚目',
      ]) {
        expect(isMusicDiscSubdirectoryName(name), isTrue, reason: name);
      }
      for (final String name in <String>['Scans', 'Discography', 'CDs']) {
        expect(isMusicDiscSubdirectoryName(name), isFalse, reason: name);
      }
    });

    test('找盘面图的根：版本目录在前，分碟目录随后；远程地址不收', () {
      final String root = p.join(p.current, 'lib_root', 'Album');
      final List<String> roots = musicAlbumDiscArtRoots(<String>[
        p.join(root, 'Disc 1', '01.flac'),
        p.join(root, 'Disc 2', '01.flac'),
        'sftp://host/music/Album/01.flac',
      ]);
      expect(roots, <String>[
        root,
        p.join(root, 'Disc 1'),
        p.join(root, 'Disc 2'),
      ]);
    });

    test('同一专辑两个目录按版本切开、各自按碟分组', () {
      final String base = p.join(p.current, 'lib_root');
      final List<MusicAlbumVersion> versions = musicAlbumVersions(
        <MusicTrackRow>[
          _row('a1', p.join(base, 'Album [FLAC]', 'CD1', '01.flac'), disc: 1),
          _row('a2', p.join(base, 'Album [FLAC]', 'CD2', '01.flac'), disc: 2),
          _row('b1', p.join(base, 'Album [MP3]', '01.mp3'), disc: 1, ms: 1000),
          _row('b2', p.join(base, 'Album [MP3]', '02.mp3'), disc: 1, ms: 2000),
        ],
      );
      expect(versions.map((MusicAlbumVersion v) => v.label), <String>[
        'Album [FLAC]',
        'Album [MP3]',
      ]);
      expect(versions.first.discs.keys, <int?>[1, 2]);
      expect(versions.last.discs.keys, <int?>[null]);
      expect(versions.last.totalDurationMs, 3000);
    });
  });

  group('MusicDiscArtIndex', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_disc_art_');
      MusicDiscArtIndex.instance.invalidate();
    });

    tearDown(() {
      MusicDiscArtIndex.instance.invalidate();
      tmp.deleteSync(recursive: true);
    });

    test('读专辑目录与扫图目录，没有盘面图的专辑不在结果里', () async {
      final Directory withScan = Directory(p.join(tmp.path, 'A'))..createSync();
      File(p.join(withScan.path, 'cover.jpg')).writeAsBytesSync(<int>[0]);
      Directory(p.join(withScan.path, 'Scans')).createSync();
      final File disc = File(p.join(withScan.path, 'Scans', 'CD.jpg'))
        ..writeAsBytesSync(<int>[0]);
      final Directory plain = Directory(p.join(tmp.path, 'B'))..createSync();
      File(p.join(plain.path, 'folder.jpg')).writeAsBytesSync(<int>[0]);

      final Map<String, String> found = await MusicDiscArtIndex.instance
          .resolve(<String, List<String>>{
            'a': <String>[p.join(withScan.path, '01.flac')],
            'b': <String>[p.join(plain.path, '01.flac')],
            'missing': <String>[p.join(tmp.path, 'gone', '01.flac')],
          });
      expect(found, <String, String>{'a': disc.path});
    });

    test('按目录缓存，invalidate 后重新识别', () async {
      final Directory album = Directory(p.join(tmp.path, 'C'))..createSync();
      final Map<String, List<String>> tracks = <String, List<String>>{
        'c': <String>[p.join(album.path, '01.flac')],
      };
      expect(await MusicDiscArtIndex.instance.resolve(tracks), isEmpty);
      final File disc = File(p.join(album.path, 'disc.png'))
        ..writeAsBytesSync(<int>[0]);
      expect(await MusicDiscArtIndex.instance.resolve(tracks), isEmpty);
      MusicDiscArtIndex.instance.invalidate();
      expect(await MusicDiscArtIndex.instance.resolve(tracks), <String, String>{
        'c': disc.path,
      });
    });
  });
}
