import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_album_versions.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi_core/fushi_core.dart' show MusicTrackRow;
import 'package:path/path.dart' as p;

/// 合成一张 [kMusicDiscFaceSampleSize] 见方的扫图样本：[paint] 按归一化半径
/// （内切圆 = 1）与坐标给每个像素的 RGB。
MusicDiscFaceSample _sample(
  List<int> Function(double r, int x, int y) paint, {
  int width = 1000,
  int height = 1000,
}) {
  const int n = kMusicDiscFaceSampleSize;
  final Uint8List px = Uint8List(n * n * 4);
  const double c = (n - 1) / 2;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final double r =
          math.sqrt((x - c) * (x - c) + (y - c) * (y - c)) / (n / 2);
      final List<int> rgb = paint(r, x, y);
      final int i = (y * n + x) * 4;
      px[i] = rgb[0];
      px[i + 1] = rgb[1];
      px[i + 2] = rgb[2];
      px[i + 3] = 255;
    }
  }
  return MusicDiscFaceSample(
    sourceWidth: width,
    sourceHeight: height,
    size: n,
    rgba: px,
  );
}

/// 白底上平放的一张光盘：透明孔、印刷盘面、盘缘。
List<int> _whiteBgDisc(double r, int x, int y) {
  if (r > 0.99 || r < 0.08) return <int>[250, 250, 250];
  if (r < 0.2) return <int>[200, 200, 205];
  return <int>[(x * 3) % 200, 60, (y * 5) % 220];
}

/// 浅色印刷的白盘（樱 Trick 那种）：盘面接近底色，只有盘缘一圈灰边。
List<int> _paleDisc(double r, int x, int y) {
  if (r > 0.99 || r < 0.08) return <int>[252, 252, 252];
  if (r > 0.9) return <int>[170, 170, 170];
  return <int>[235, 225, 230];
}

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

  group('按内容认盘面（BUG-5057）', () {
    test('白底平放的光盘认作盘面，含浅色印刷的白盘', () {
      expect(isMusicDiscFace(_sample(_whiteBgDisc)), isTrue);
      expect(isMusicDiscFace(_sample(_paleDisc)), isTrue);
    });

    test('不是近似正方形的图不认（跨页 / 侧标）', () {
      expect(
        isMusicDiscFace(_sample(_whiteBgDisc, width: 1400, height: 1000)),
        isFalse,
      );
      expect(isMusicDiscFaceAspect(1000, 1040), isTrue);
      expect(isMusicDiscFaceAspect(1000, 1150), isFalse);
    });

    test('满版插画 / 有图案的四角不认', () {
      expect(
        isMusicDiscFace(
          _sample((double r, int x, int y) => <int>[x * 2, y * 2, 128]),
        ),
        isFalse,
      );
    });

    test('中心没有孔（圆形印刷的内页 / 特典卡）不认', () {
      expect(
        isMusicDiscFace(
          _sample(
            (double r, int x, int y) =>
                r > 0.99 ? <int>[250, 250, 250] : <int>[40, 120, 200],
          ),
        ),
        isFalse,
      );
    });

    test('没有盘缘反差（几乎纯色的一页）不认', () {
      expect(
        isMusicDiscFace(
          _sample(
            (double r, int x, int y) =>
                r < 0.5 ? <int>[230, 230, 230] : <int>[250, 250, 250],
          ),
        ),
        isFalse,
      );
    });

    test('候选只收扫图目录里没写明别的部位的图，按自然序', () {
      expect(
        musicDiscFaceCandidates(<String>[
          'cover.jpg',
          '01.flac',
          'Scans/10.webp',
          'Scans/02.webp',
          'Scans/obi.webp',
          'Scans/notes.txt',
          'BK/Scan 120.jpg',
          'BK/Scan 119.jpg',
          'Disc 1/01.jpg',
          'Scans/a/b/deep.jpg',
        ]),
        <String>[
          'BK/Scan 119.jpg',
          'BK/Scan 120.jpg',
          'Scans/02.webp',
          'Scans/10.webp',
        ],
      );
    });

    test('BK 整名是扫图目录，文件名里的 bk 仍是背面', () {
      expect(isMusicScanDirectoryName('BK'), isTrue);
      expect(musicDiscArtScore('BK/cd.jpg'), isNotNull);
      expect(musicDiscArtScore('cd_bk.jpg'), isNull);
    });

    test('自然序：数字段按数值比', () {
      final List<String> names = <String>['Scan 120', 'Scan 2', 'Scan 19']
        ..sort(compareMusicNatural);
      expect(names, <String>['Scan 2', 'Scan 19', 'Scan 120']);
    });
  });

  group('同一张专辑的各版本共用盘面图（BUG-5058）', () {
    const String cds = '/v/Onimai/CDs';
    test('标签不一致被拆开的两个版本：同父目录 + 同名（全角半角不计）借用', () {
      final Map<String, String> out = shareMusicDiscArtAcrossVersions(
        found: <String, String>{'webp': '$cds/A (flac+webp)/Scans/07.webp'},
        albums: <String, ({String title, List<String> trackPaths})>{
          'webp': (
            title: 'ひめごと＊クライシスターズ',
            trackPaths: <String>['$cds/A (flac+webp)/01.flac'],
          ),
          'hires': (
            title: 'ひめごと*クライシスターズ',
            trackPaths: <String>['$cds/A [24bit_48kHz] (flac)/01.flac'],
          ),
        },
      );
      expect(out['hires'], '$cds/A (flac+webp)/Scans/07.webp');
      expect(out['webp'], '$cds/A (flac+webp)/Scans/07.webp');
    });

    test('分碟目录并回版本目录再比父目录', () {
      final Map<String, String> out = shareMusicDiscArtAcrossVersions(
        found: <String, String>{'a': '$cds/X (flac)/Scans/01.jpg'},
        albums: <String, ({String title, List<String> trackPaths})>{
          'a': (title: 'X', trackPaths: <String>['$cds/X (flac)/01.flac']),
          'b': (
            title: 'X',
            trackPaths: <String>['$cds/X [Hi-Res]/Disc 2/01.flac'],
          ),
        },
      );
      expect(out['b'], '$cds/X (flac)/Scans/01.jpg');
    });

    test('不同父目录的同名专辑、同目录的不同名专辑都不借', () {
      final Map<String, String> out = shareMusicDiscArtAcrossVersions(
        found: <String, String>{'a': '$cds/OST/Scans/01.jpg'},
        albums: <String, ({String title, List<String> trackPaths})>{
          'a': (title: 'OST', trackPaths: <String>['$cds/OST/01.flac']),
          'other': (
            title: 'OST',
            trackPaths: <String>['/v/Another/CDs/OST/01.flac'],
          ),
          'single': (
            title: 'Single',
            trackPaths: <String>['$cds/Single/01.flac'],
          ),
        },
      );
      expect(out.keys.toSet(), <String>{'a'});
    });

    test('比较键：全角折半角、空白归一、小写', () {
      expect(musicAlbumTitleKey('  ＡＢ　 ＣＤ！ '), 'ab cd!');
    });
  });

  group('MusicDiscArtIndex', () {
    late Directory tmp;
    final MusicDiscFaceSampler realSampler = MusicDiscArtIndex.instance.sampler;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_disc_art_');
      MusicDiscArtIndex.instance.invalidate();
    });

    tearDown(() {
      MusicDiscArtIndex.instance.invalidate();
      MusicDiscArtIndex.instance.sampler = realSampler;
      tmp.deleteSync(recursive: true);
    });

    test('编号扫图按内容认出第一张光盘；文件名命中的目录不按内容判', () async {
      final Directory numbered = Directory(p.join(tmp.path, 'N'))..createSync();
      Directory(p.join(numbered.path, 'Scans')).createSync();
      for (final String n in <String>['01', '02', '06', '07']) {
        File(
          p.join(numbered.path, 'Scans', '$n.webp'),
        ).writeAsBytesSync(<int>[0]);
      }
      final Directory named = Directory(p.join(tmp.path, 'M'))..createSync();
      Directory(p.join(named.path, 'Scans')).createSync();
      final File namedDisc = File(p.join(named.path, 'Scans', 'disc.jpg'))
        ..writeAsBytesSync(<int>[0]);
      File(p.join(named.path, 'Scans', '01.jpg')).writeAsBytesSync(<int>[0]);

      final List<String> sampled = <String>[];
      MusicDiscArtIndex.instance.sampler = (String path) async {
        sampled.add(p.relative(path, from: tmp.path));
        final String stem = p.basenameWithoutExtension(path);
        // 06、07 是两张盘（VCB 常见：盘面在最后几张），01 是封面。
        return stem == '06' || stem == '07'
            ? _sample(_whiteBgDisc)
            : _sample((double r, int x, int y) => <int>[x * 2, y * 2, 90]);
      };

      final Map<String, String> found = await MusicDiscArtIndex.instance
          .resolve(<String, List<String>>{
            'n': <String>[p.join(numbered.path, '01.flac')],
            'm': <String>[p.join(named.path, '01.flac')],
          });
      expect(found, <String, String>{
        'n': p.join(numbered.path, 'Scans', '06.webp'),
        'm': namedDisc.path,
      });
      // 第一张中即停；文件名已命中的目录一张都不解码。
      expect(sampled, <String>[
        p.join('N', 'Scans', '01.webp'),
        p.join('N', 'Scans', '02.webp'),
        p.join('N', 'Scans', '06.webp'),
      ]);
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
