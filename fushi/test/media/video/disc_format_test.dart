// 原盘规格（BD / UHD / DVD）：成员路径判据、`index.bdmv` 版本判 UHD、按盘根缓存的
// 解析器、多盘汇总，以及 `.iso` 镜像探测（ISO 9660 / UDF 物理分区 / UDF 2.50 元数据
// 分区）。镜像全部在内存里按规范布局合成。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_image_probe.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:path/path.dart' as p;

import 'dvd_fixture.dart';

const int _kSector = 2048;

void _le16(Uint8List b, int at, int v) {
  b[at] = v & 0xFF;
  b[at + 1] = (v >> 8) & 0xFF;
}

void _le32(Uint8List b, int at, int v) {
  for (int i = 0; i < 4; i++) {
    b[at + i] = (v >> (8 * i)) & 0xFF;
  }
}

void _ascii(Uint8List b, int at, String s) {
  for (int i = 0; i < s.length; i++) {
    b[at + i] = s.codeUnitAt(i);
  }
}

DiscImageRead _reader(Uint8List image) => (int offset, int length) {
  if (offset >= image.length) return Uint8List(0);
  final int end = offset + length > image.length
      ? image.length
      : offset + length;
  return Uint8List.sublistView(image, offset, end);
};

// ─────────────── ISO 9660 ───────────────

class _IsoNode {
  _IsoNode.dir(this.name, this.children) : content = null;
  _IsoNode.file(this.name, this.content) : children = const <_IsoNode>[];

  final String name;
  final List<_IsoNode> children;
  final List<int>? content;
  int sector = 0;

  bool get isDir => content == null;
}

Uint8List _buildIso(
  List<_IsoNode> rootChildren, {
  String volumeId = 'TESTDISC',
}) {
  final _IsoNode root = _IsoNode.dir('', rootChildren);
  int next = 20;
  void assign(_IsoNode n) {
    n.sector = next++;
    for (final _IsoNode c in n.children) {
      assign(c);
    }
  }

  assign(root);
  final Uint8List image = Uint8List(next * _kSector);

  void record(int at, String name, _IsoNode n, {int? rawName}) {
    final int nameLen = rawName != null ? 1 : name.length;
    final int len = 33 + nameLen + (nameLen.isEven ? 1 : 0);
    image[at] = len;
    _le32(image, at + 2, n.sector);
    _le32(image, at + 10, n.isDir ? _kSector : n.content!.length);
    image[at + 25] = n.isDir ? 0x02 : 0;
    image[at + 32] = nameLen;
    if (rawName != null) {
      image[at + 33] = rawName;
    } else {
      _ascii(image, at + 33, name);
    }
  }

  int recordLength(String name) =>
      33 + name.length + (name.length.isEven ? 1 : 0);

  void write(_IsoNode n, _IsoNode parent) {
    final int base = n.sector * _kSector;
    if (!n.isDir) {
      image.setRange(base, base + n.content!.length, n.content!);
      return;
    }
    int at = base;
    record(at, '', n, rawName: 0);
    at += 34;
    record(at, '', parent, rawName: 1);
    at += 34;
    for (final _IsoNode c in n.children) {
      final String name = c.isDir ? c.name : '${c.name};1';
      record(at, name, c);
      at += recordLength(name);
      write(c, n);
    }
  }

  write(root, root);
  // PVD + 终止符。
  const int pvd = 16 * _kSector;
  image[pvd] = 1;
  _ascii(image, pvd + 1, 'CD001');
  image[pvd + 6] = 1;
  _ascii(image, pvd + 40, volumeId.padRight(32));
  record(pvd + 156, '', root, rawName: 0);
  const int term = 17 * _kSector;
  image[term] = 255;
  _ascii(image, term + 1, 'CD001');
  return image;
}

// ─────────────── UDF ───────────────

/// 极简 UDF 写入器：物理分区从 [_kPartStart] 扇区起；`metadata` 为真时目录树放进
/// UDF 2.50 元数据分区（元数据文件把元数据块 k 映射到物理块 [_kMetaBase] + k）。
const int _kPartStart = 300;
const int _kMetaBase = 20;

class _Udf {
  _Udf({required this.metadata})
    : image = Uint8List((_kPartStart + 80) * _kSector);

  final bool metadata;
  final Uint8List image;

  int get _ref => metadata ? 1 : 0;

  /// 目录树所在分区的块 → 镜像内字节偏移。
  int _treeOffset(int block) =>
      (_kPartStart + (metadata ? _kMetaBase + block : block)) * _kSector;

  void _fileEntry(
    int block, {
    required int dataLength,
    required List<int> ad,
    int adType = 0,
  }) {
    final int at = _treeOffset(block);
    _le16(image, at, 261);
    _le16(image, at + 34, adType);
    _le32(image, at + 56, dataLength);
    _le32(image, at + 168, 0);
    _le32(image, at + 172, ad.length);
    image.setRange(at + 176, at + 176 + ad.length, ad);
  }

  List<int> _shortAd(int length, int block) {
    final Uint8List b = Uint8List(8);
    _le32(b, 0, length);
    _le32(b, 4, block);
    return b;
  }

  List<int> _fid(
    String? name,
    int icbBlock, {
    required bool dir,
    bool parent = false,
  }) {
    final List<int> encoded = name == null
        ? const <int>[]
        : <int>[8, ...name.codeUnits];
    final int len = (38 + encoded.length + 3) & ~3;
    final Uint8List b = Uint8List(len);
    _le16(b, 0, 257);
    b[18] = (dir ? 0x02 : 0) | (parent ? 0x08 : 0);
    b[19] = encoded.length;
    _le32(b, 20, _kSector);
    _le32(b, 24, icbBlock);
    _le16(b, 28, _ref);
    b.setRange(38, 38 + encoded.length, encoded);
    return b;
  }

  /// 目录：FE 在 [feBlock]，FID 数据在 [dataBlock]。
  void directory(
    int feBlock,
    int dataBlock,
    List<(String, int, bool)> entries,
  ) {
    final List<int> data = <int>[
      ..._fid(null, feBlock, dir: true, parent: true),
      for (final (String name, int icb, bool isDir) in entries)
        ..._fid(name, icb, dir: isDir),
    ];
    image.setRange(
      _treeOffset(dataBlock),
      _treeOffset(dataBlock) + data.length,
      data,
    );
    _fileEntry(
      feBlock,
      dataLength: data.length,
      ad: _shortAd(data.length, dataBlock),
    );
  }

  /// 文件：FE 在 [feBlock]，内容放物理分区块 [physicalBlock]（long_ad 指回分区 0）。
  void file(int feBlock, int physicalBlock, List<int> content) {
    final int at = (_kPartStart + physicalBlock) * _kSector;
    image.setRange(at, at + content.length, content);
    final Uint8List ad = Uint8List(16);
    _le32(ad, 0, content.length);
    _le32(ad, 4, physicalBlock);
    _le16(ad, 8, 0);
    _fileEntry(feBlock, dataLength: content.length, ad: ad, adType: 1);
  }

  Uint8List finish({required String label}) {
    // 锚点 + 卷描述序列（PVD / PD / LVD / TD）。
    _le16(image, 256 * _kSector, 2);
    _le32(image, 256 * _kSector + 16, 4 * _kSector);
    _le32(image, 256 * _kSector + 20, 32);
    const int pvd = 32 * _kSector;
    _le16(image, pvd, 1);
    image[pvd + 24] = 8;
    _ascii(image, pvd + 25, label);
    image[pvd + 24 + 31] = label.length + 1;
    const int pd = 33 * _kSector;
    _le16(image, pd, 5);
    _le16(image, pd + 22, 0);
    _le32(image, pd + 188, _kPartStart);
    const int lvd = 34 * _kSector;
    _le16(image, lvd, 6);
    _le32(image, lvd + 252, 0); // FSD 在目录树分区的块 0
    _le16(image, lvd + 256, _ref);
    _le32(image, lvd + 268, metadata ? 2 : 1);
    image[lvd + 440] = 1;
    image[lvd + 441] = 6;
    _le16(image, lvd + 444, 0);
    if (metadata) {
      const int map = lvd + 446;
      image[map] = 2;
      image[map + 1] = 64;
      _ascii(image, map + 5, '*UDF Metadata Partition');
      _le16(image, map + 38, 0);
      _le32(image, map + 40, 10); // 元数据文件 FE 在物理块 10
      const int fe = (_kPartStart + 10) * _kSector;
      _le16(image, fe, 266);
      _le16(image, fe + 34, 0);
      _le32(image, fe + 56, 40 * _kSector);
      _le32(image, fe + 208, 0);
      _le32(image, fe + 212, 8);
      _le32(image, fe + 216, 40 * _kSector);
      _le32(image, fe + 220, _kMetaBase);
    }
    _le16(image, 35 * _kSector, 8);
    // FSD → 根目录 FE 在块 1。
    final int fsd = _treeOffset(0);
    _le16(image, fsd, 256);
    _le32(image, fsd + 400, _kSector);
    _le32(image, fsd + 404, 1);
    _le16(image, fsd + 408, _ref);
    return image;
  }
}

void main() {
  group('成员路径判据', () {
    test('蓝光 .mpls / DVD title 反推盘根；普通文件不是原盘成员', () {
      final String bd = p.join(
        '/lib',
        'Movie',
        'BDMV',
        'PLAYLIST',
        '00001.mpls',
      );
      final String dvd = dvdTitlePath(p.join('/lib', 'Show'), 2);
      expect(discRootForMemberPath(bd), p.normalize('/lib/Movie'));
      expect(discRootForMemberPath(dvd), p.normalize('/lib/Show'));
      expect(discRootForMemberPath('/lib/a.mkv'), isNull);
      expect(discFormatHintForMemberPath(bd), DiscFormat.bluray);
      expect(discFormatHintForMemberPath(dvd), DiscFormat.dvd);
      expect(discFormatHintForMemberPath('/lib/a.vob'), isNull);
      expect(isDiscMemberPath(dvd), isTrue);
      expect(
        discMemberBackingFilePath(dvd),
        p.join(p.normalize('/lib/Show'), 'VIDEO_TS', 'VIDEO_TS.IFO'),
      );
      expect(discMemberBackingFilePath(bd), bd);
    });

    test('index.bdmv 版本：0300 是 UHD，0100 / 0200 是 BD，头不对给 null', () {
      expect(
        blurayFormatForIndexHeader('INDX0300'.codeUnits),
        DiscFormat.uhdBluray,
      );
      expect(
        blurayFormatForIndexHeader('INDX0200'.codeUnits),
        DiscFormat.bluray,
      );
      expect(
        blurayFormatForIndexHeader('INDX0100'.codeUnits),
        DiscFormat.bluray,
      );
      expect(blurayFormatForIndexHeader('MOBJ0200'.codeUnits), isNull);
      expect(blurayFormatForIndexHeader('IND'.codeUnits), isNull);
    });
  });

  group('读盘 + 解析器缓存', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('disc_format_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    String bluray(String name, String version) {
      final String root = p.join(tmp.path, name);
      Directory(p.join(root, 'BDMV', 'PLAYLIST')).createSync(recursive: true);
      File(
        p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls'),
      ).writeAsBytesSync(Uint8List(8));
      File(
        p.join(root, 'BDMV', 'index.bdmv'),
      ).writeAsBytesSync(<int>[...'INDX$version'.codeUnits, 0, 0, 0, 0]);
      return root;
    }

    test('盘根读规格：UHD / BD / DVD / 不是盘', () async {
      expect(
        await readDiscFormatAtRoot(bluray('U', '0300')),
        DiscFormat.uhdBluray,
      );
      expect(
        await readDiscFormatAtRoot(bluray('B', '0200')),
        DiscFormat.bluray,
      );
      final String dvd = p.join(tmp.path, 'D');
      writeTvDvdFixture(dvd);
      expect(await readDiscFormatAtRoot(dvd), DiscFormat.dvd);
      expect(await readDiscFormatAtRoot(tmp.path), isNull);
    });

    test('peek 在解析前不猜 BD（UHD 不闪错），解析后给终值；同盘只读一次', () async {
      final String root = bluray('U', '0300');
      int reads = 0;
      final DiscFormatResolver resolver = DiscFormatResolver(
        readFormat: (String r) {
          reads++;
          return readDiscFormatAtRoot(r);
        },
      );
      addTearDown(resolver.dispose);
      final String a = p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls');
      final String b = p.join(root, 'BDMV', 'PLAYLIST', '00002.mpls');
      expect(resolver.peek(a), isNull);
      expect(resolver.isResolved(a), isFalse);
      await Future.wait(<Future<DiscFormat?>>[
        resolver.resolve(a),
        resolver.resolve(b),
      ]);
      expect(resolver.peek(b), DiscFormat.uhdBluray);
      expect(reads, 1);
      // DVD 成员不需要 IO。
      final String dvd = dvdTitlePath(p.join(tmp.path, 'X'), 1);
      expect(resolver.peek(dvd), DiscFormat.dvd);
      expect(resolver.isResolved(dvd), isTrue);
    });

    test('汇总按盘根去重：一张盘多条标题算一张', () {
      final Map<DiscFormat, int> summary = summarizeDiscMembers(
        <String>[
          '/a/D1/BDMV/PLAYLIST/00001.mpls',
          '/a/D1/BDMV/PLAYLIST/00002.mpls',
          '/a/D2/BDMV/PLAYLIST/00001.mpls',
          '/a/D3/BDMV/PLAYLIST/00001.mpls',
          '/a/plain.mkv',
        ],
        (String path) => p.split(path).contains('D3')
            ? DiscFormat.uhdBluray
            : DiscFormat.bluray,
      );
      expect(summary, <DiscFormat, int>{
        DiscFormat.uhdBluray: 1,
        DiscFormat.bluray: 2,
      });
      expect(summary.keys.first, DiscFormat.uhdBluray);
    });
  });

  group('.iso 镜像探测', () {
    test('ISO 9660：VIDEO_TS/VIDEO_TS.IFO → DVD，带卷标', () {
      final Uint8List image = _buildIso(<_IsoNode>[
        _IsoNode.dir('AUDIO_TS', <_IsoNode>[]),
        _IsoNode.dir('VIDEO_TS', <_IsoNode>[
          _IsoNode.file('VIDEO_TS.IFO', List<int>.filled(16, 1)),
        ]),
      ], volumeId: 'MY_DVD');
      final DiscImageProbe probe = probeDiscImage(_reader(image))!;
      expect(probe.format, DiscFormat.dvd);
      expect(probe.volumeLabel, 'MY_DVD');
    });

    test('ISO 9660：BDMV/PLAYLIST + index.bdmv 0300 → UHD', () {
      final Uint8List image = _buildIso(<_IsoNode>[
        _IsoNode.dir('BDMV', <_IsoNode>[
          _IsoNode.dir('PLAYLIST', <_IsoNode>[]),
          _IsoNode.file('INDEX.BDMV', 'INDX0300....'.codeUnits),
        ]),
      ]);
      expect(probeDiscImage(_reader(image))!.format, DiscFormat.uhdBluray);
    });

    test('只有 VIDEO_TS 目录、没有 IFO：不算盘', () {
      final Uint8List image = _buildIso(<_IsoNode>[
        _IsoNode.dir('VIDEO_TS', <_IsoNode>[
          _IsoNode.file('VTS_01_1.VOB', List<int>.filled(4, 0)),
        ]),
      ]);
      expect(probeDiscImage(_reader(image)), isNull);
    });

    test('UDF（物理分区）：DVD', () {
      final _Udf udf = _Udf(metadata: false);
      udf.directory(1, 2, <(String, int, bool)>[('VIDEO_TS', 3, true)]);
      udf.directory(3, 4, <(String, int, bool)>[('VIDEO_TS.IFO', 5, false)]);
      udf.file(5, 6, List<int>.filled(16, 1));
      final DiscImageProbe probe = probeDiscImage(
        _reader(udf.finish(label: 'UDF_DVD')),
      )!;
      expect(probe.format, DiscFormat.dvd);
      expect(probe.volumeLabel, 'UDF_DVD');
    });

    test('UDF 2.50（元数据分区，BD 的形态）：读 index.bdmv 分出 UHD 与 BD', () {
      for (final (String version, DiscFormat expected)
          in <(String, DiscFormat)>[
            ('0300', DiscFormat.uhdBluray),
            ('0200', DiscFormat.bluray),
          ]) {
        final _Udf udf = _Udf(metadata: true);
        udf.directory(1, 2, <(String, int, bool)>[('BDMV', 3, true)]);
        udf.directory(3, 4, <(String, int, bool)>[
          ('PLAYLIST', 5, true),
          ('index.bdmv', 7, false),
        ]);
        udf.directory(5, 6, const <(String, int, bool)>[]);
        udf.file(7, 70, 'INDX$version'.codeUnits);
        expect(
          probeDiscImage(_reader(udf.finish(label: 'BD')))!.format,
          expected,
          reason: version,
        );
      }
    });

    test('随便一段字节 / 空镜像：返回 null 不抛', () {
      expect(probeDiscImage(_reader(Uint8List(0))), isNull);
      expect(
        probeDiscImage(
          _reader(Uint8List.fromList(List<int>.filled(300000, 7))),
        ),
        isNull,
      );
    });
  });
}
