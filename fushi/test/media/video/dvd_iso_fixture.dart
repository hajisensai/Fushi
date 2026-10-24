// 把一张文件夹形态的合成 DVD（`dvd_fixture.dart`）打包成 ISO 9660 镜像，给镜像形态的
// DVD 解析 / 扫描测试当输入。只写 ISO 9660（DVD-Video 的桥接文件系统），文件按
// 2048 字节扇区连续存放、可跨多扇区。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const int _kSector = 2048;

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

int _sectorsFor(int bytes) =>
    bytes == 0 ? 1 : (bytes + _kSector - 1) ~/ _kSector;

/// 镜像根下只有一个 `VIDEO_TS/` 目录，内容取 [videoTsFiles]（文件名 → 字节）。
Uint8List buildVideoTsIsoImage(
  Map<String, List<int>> videoTsFiles, {
  String volumeId = 'DVD_VIDEO',
}) {
  const int rootSector = 20;
  const int videoTsSector = 21;
  int next = 22;
  final List<(String, List<int>, int)> files = <(String, List<int>, int)>[];
  final List<String> names = videoTsFiles.keys.toList()..sort();
  for (final String name in names) {
    final List<int> content = videoTsFiles[name]!;
    files.add((name, content, next));
    next += _sectorsFor(content.length);
  }
  final Uint8List image = Uint8List(next * _kSector);

  int record(int at, List<int> name, int sector, int length, bool dir) {
    final int len = 33 + name.length + (name.length.isEven ? 1 : 0);
    image[at] = len;
    _le32(image, at + 2, sector);
    _le32(image, at + 10, length);
    image[at + 25] = dir ? 0x02 : 0;
    image[at + 32] = name.length;
    image.setRange(at + 33, at + 33 + name.length, name);
    return len;
  }

  int at = rootSector * _kSector;
  at += record(at, <int>[0], rootSector, _kSector, true);
  at += record(at, <int>[1], rootSector, _kSector, true);
  record(at, 'VIDEO_TS'.codeUnits, videoTsSector, _kSector, true);

  at = videoTsSector * _kSector;
  at += record(at, <int>[0], videoTsSector, _kSector, true);
  at += record(at, <int>[1], rootSector, _kSector, true);
  for (final (String name, List<int> content, int sector) in files) {
    at += record(at, '$name;1'.codeUnits, sector, content.length, false);
    image.setRange(
      sector * _kSector,
      sector * _kSector + content.length,
      content,
    );
  }

  const int pvd = 16 * _kSector;
  image[pvd] = 1;
  _ascii(image, pvd + 1, 'CD001');
  image[pvd + 6] = 1;
  _ascii(image, pvd + 40, volumeId.padRight(32));
  record(pvd + 156, <int>[0], rootSector, _kSector, true);
  const int term = 17 * _kSector;
  image[term] = 255;
  _ascii(image, term + 1, 'CD001');
  return image;
}

/// 把 [folderDiscRoot]（含 `VIDEO_TS/` 的文件夹盘）打包成 [isoPath]。
void writeIsoFromFolderDisc(String folderDiscRoot, String isoPath) {
  final Directory videoTs = Directory(p.join(folderDiscRoot, 'VIDEO_TS'));
  final Map<String, List<int>> files = <String, List<int>>{
    for (final FileSystemEntity e in videoTs.listSync())
      if (e is File) p.basename(e.path).toUpperCase(): e.readAsBytesSync(),
  };
  File(isoPath)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(buildVideoTsIsoImage(files));
}
