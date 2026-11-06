// `.iso` 盘镜像的规格探测：打开镜像读文件系统，看里面是不是 DVD / BD，不靠扩展名猜。
//
// 两种文件系统都读：
//
//   - **UDF**（DVD-Video 是 UDF 1.02，BD 是 UDF 2.50）：锚点 → 主卷描述序列 → 分区 /
//     逻辑卷 → 文件集描述符 → 根目录。UDF 2.50 的 BD 把目录放在「元数据分区」里，
//     要先读元数据文件的分配描述符把逻辑块映射回物理扇区，这里一并支持。
//   - **ISO 9660**：DVD 一般带 UDF + ISO 9660 桥接，UDF 读不动时退回它；BD 镜像多半
//     只有 UDF。
//
// 探测只读到判规格为止：根目录有没有 `VIDEO_TS/VIDEO_TS.IFO`、`BDMV/PLAYLIST`，以及
// 蓝光的 `BDMV/index.bdmv` 头 8 字节（分 UHD）。DVD 镜像的整盘入库另经
// [DiscImageFileSystem] 读出 `VIDEO_TS/*.IFO` 字节，交给 `dvd_disc.dart` 与文件夹形态
// 同一条解析 / 选片链路（见 `readDvdDiscImage`）。
//
// 探测读坏 / 不是盘镜像一律返回 null，不抛：探不出来就是「不是盘」。

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/disc/disc_format.dart';

/// 光盘镜像的扇区大小（ISO 9660 与 UDF 在 DVD / BD 上都是 2048）。
const int kDiscImageSectorSize = 2048;

/// 一次探测结果：规格 + 卷标（取不到为 null）。
class DiscImageProbe {
  const DiscImageProbe({required this.format, this.volumeLabel});

  final DiscFormat format;
  final String? volumeLabel;
}

/// 从镜像随机读 [length] 字节（读到末尾返回较短的结果）。
typedef DiscImageRead = Uint8List Function(int offset, int length);

/// 打开 [imagePath] 探测；打不开、不是盘镜像返回 null。
Future<DiscImageProbe?> probeDiscImageFile(String imagePath) async {
  RandomAccessFile? raf;
  try {
    raf = await File(imagePath).open();
    final RandomAccessFile file = raf;
    final int size = await file.length();
    return probeDiscImage((int offset, int length) {
      if (offset < 0 || offset >= size) return Uint8List(0);
      file.setPositionSync(offset);
      return file.readSync(length);
    });
  } on FileSystemException {
    return null;
  } finally {
    await raf?.close();
  }
}

/// 在任意可随机读的镜像上探测（测试可直接喂内存字节）。
DiscImageProbe? probeDiscImage(DiscImageRead read) {
  try {
    final DiscImageFileSystem? udf = _UdfFs.open(read);
    final DiscImageProbe? viaUdf = udf == null ? null : _probeFs(udf);
    if (viaUdf != null) return viaUdf;
    final DiscImageFileSystem? iso = _Iso9660Fs.open(read);
    return iso == null ? null : _probeFs(iso);
  } on DiscImageFormatException {
    return null;
  }
}

DiscImageProbe? _probeFs(DiscImageFileSystem fs) {
  final List<DiscImageEntry> root = fs.listRoot();
  final DiscImageEntry? videoTs = _find(root, 'VIDEO_TS', directory: true);
  if (videoTs != null) {
    final List<DiscImageEntry> inside = fs.list(videoTs);
    if (inside.any(
      (DiscImageEntry e) =>
          !e.isDirectory && _plainName(e.name) == 'VIDEO_TS.IFO',
    )) {
      return DiscImageProbe(format: DiscFormat.dvd, volumeLabel: fs.label);
    }
  }
  final DiscImageEntry? bdmv = _find(root, 'BDMV', directory: true);
  if (bdmv != null) {
    final List<DiscImageEntry> inside = fs.list(bdmv);
    if (_find(inside, 'PLAYLIST', directory: true) != null) {
      final DiscImageEntry? index = inside
          .where(
            (DiscImageEntry e) =>
                !e.isDirectory && _plainName(e.name) == 'INDEX.BDMV',
          )
          .firstOrNull;
      final DiscFormat format = index == null
          ? DiscFormat.bluray
          : blurayFormatForIndexHeader(fs.readFile(index, 8)) ??
                DiscFormat.bluray;
      return DiscImageProbe(format: format, volumeLabel: fs.label);
    }
  }
  return null;
}

/// ISO 9660 文件名带 `;1` 版本号后缀，比较前去掉并统一大写。
String _plainName(String name) {
  final int semi = name.indexOf(';');
  return (semi < 0 ? name : name.substring(0, semi)).toUpperCase();
}

DiscImageEntry? _find(
  List<DiscImageEntry> entries,
  String name, {
  required bool directory,
}) {
  for (final DiscImageEntry e in entries) {
    if (e.isDirectory == directory && _plainName(e.name) == name) return e;
  }
  return null;
}

/// 镜像文件系统结构不合法（标签不符、越界、分配描述符溢出……）。
class DiscImageFormatException implements Exception {
  const DiscImageFormatException(this.message);

  final String message;

  @override
  String toString() => 'DiscImageFormatException: $message';
}

/// 镜像里的一个目录项：名字 + 是否目录 + 文件系统私有的定位信息。
class DiscImageEntry {
  const DiscImageEntry({
    required this.name,
    required this.isDirectory,
    required this.location,
    required this.length,
    this.partRef = 0,
  });

  final String name;
  final bool isDirectory;

  /// ISO 9660：数据起始扇区；UDF：文件项（ICB）的分区内逻辑块。
  final int location;

  /// ISO 9660：数据长度；UDF：未用（由文件项给）。
  final int length;

  /// UDF：文件项所在的分区引用号；ISO 9660 未用。
  final int partRef;
}

/// 只读的镜像文件系统（UDF 或 ISO 9660）。读坏抛 [DiscImageFormatException]。
abstract class DiscImageFileSystem {
  /// 卷标；取不到为 null。
  String? get label;
  List<DiscImageEntry> listRoot();
  List<DiscImageEntry> list(DiscImageEntry directory);

  /// 文件 [file] 的前 [limit] 字节（文件更短就是整个文件）。
  Uint8List readFile(DiscImageEntry file, int limit);
}

/// ISO 9660 文件名带 `;1` 版本号后缀：去掉并统一大写，用于按名比较。
String discImagePlainName(String name) => _plainName(name);

/// 在 [entries] 里按 [discImagePlainName] 找名为 [name]（大写）的目录 / 文件。
DiscImageEntry? findDiscImageEntry(
  List<DiscImageEntry> entries,
  String name, {
  required bool directory,
}) => _find(entries, name, directory: directory);

/// 打开镜像文件系统：优先 UDF（DVD-Video / BD 的主文件系统），UDF 读不动退回
/// ISO 9660 桥接；都不是返回 null。
DiscImageFileSystem? openDiscImageFileSystem(DiscImageRead read) {
  try {
    final DiscImageFileSystem? udf = _UdfFs.open(read);
    if (udf != null) {
      try {
        udf.listRoot();
        return udf;
      } on DiscImageFormatException {
        // 根目录读不动：退回 ISO 9660。
      }
    }
    return _Iso9660Fs.open(read);
  } on DiscImageFormatException {
    return null;
  }
}

/// 打开 [imagePath]，在 [body] 里随机读它；文件打不开时 [body] 收到 null。
Future<T> withDiscImageFile<T>(
  String imagePath,
  Future<T> Function(DiscImageFileSystem? fs) body,
) async {
  RandomAccessFile? raf;
  try {
    raf = await File(imagePath).open();
  } on FileSystemException {
    return body(null);
  }
  final RandomAccessFile file = raf;
  try {
    final int size = await file.length();
    return await body(
      openDiscImageFileSystem((int offset, int length) {
        if (offset < 0 || offset >= size) return Uint8List(0);
        file.setPositionSync(offset);
        return file.readSync(length);
      }),
    );
  } finally {
    await file.close();
  }
}

int _le16(Uint8List b, int at) {
  if (at + 2 > b.length) throw const DiscImageFormatException('short read');
  return b[at] | (b[at + 1] << 8);
}

int _le32(Uint8List b, int at) {
  if (at + 4 > b.length) throw const DiscImageFormatException('short read');
  return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
}

int _le64(Uint8List b, int at) => _le32(b, at) + _le32(b, at + 4) * 0x100000000;

Uint8List _sector(DiscImageRead read, int sector, [int count = 1]) {
  final Uint8List bytes = read(
    sector * kDiscImageSectorSize,
    count * kDiscImageSectorSize,
  );
  if (bytes.length < count * kDiscImageSectorSize) {
    throw const DiscImageFormatException('sector past end of image');
  }
  return bytes;
}

/// 目录数据读入上限：根目录与 `BDMV` 这种一级目录实测都在几个扇区内。
const int _kMaxDirectoryBytes = 4 * 1024 * 1024;

// ───────────────────────────── ISO 9660 ─────────────────────────────

class _Iso9660Fs implements DiscImageFileSystem {
  _Iso9660Fs(this._read, this._root, this.label);

  final DiscImageRead _read;
  final DiscImageEntry _root;

  @override
  final String? label;

  static _Iso9660Fs? open(DiscImageRead read) {
    // 卷描述符从 16 号扇区起，类型 255 终止。
    for (int sector = 16; sector < 32; sector++) {
      final Uint8List d = _sector(read, sector);
      if (String.fromCharCodes(d.sublist(1, 6)) != 'CD001') return null;
      final int type = d[0];
      if (type == 255) return null;
      if (type != 1) continue;
      final String volumeId = String.fromCharCodes(d.sublist(40, 72)).trim();
      final DiscImageEntry root = DiscImageEntry(
        name: '',
        isDirectory: true,
        location: _le32(d, 156 + 2),
        length: _le32(d, 156 + 10),
      );
      return _Iso9660Fs(read, root, volumeId.isEmpty ? null : volumeId);
    }
    return null;
  }

  @override
  List<DiscImageEntry> listRoot() => list(_root);

  @override
  List<DiscImageEntry> list(DiscImageEntry directory) {
    if (directory.length > _kMaxDirectoryBytes) {
      throw const DiscImageFormatException('directory too large');
    }
    final int sectors =
        (directory.length + kDiscImageSectorSize - 1) ~/ kDiscImageSectorSize;
    if (sectors == 0) return const <DiscImageEntry>[];
    final Uint8List data = _sector(_read, directory.location, sectors);
    final List<DiscImageEntry> out = <DiscImageEntry>[];
    int at = 0;
    while (at < directory.length) {
      final int len = data[at];
      if (len == 0) {
        // 目录项不跨扇区：本扇区剩余是填充，跳到下一扇区。
        at = (at ~/ kDiscImageSectorSize + 1) * kDiscImageSectorSize;
        continue;
      }
      if (len < 34 || at + len > data.length) {
        throw const DiscImageFormatException('bad ISO 9660 directory record');
      }
      final int nameLength = data[at + 32];
      if (33 + nameLength > len) {
        throw const DiscImageFormatException('bad ISO 9660 name length');
      }
      final Uint8List rawName = data.sublist(at + 33, at + 33 + nameLength);
      // 0x00 / 0x01 是「本目录」「上级目录」。
      if (!(nameLength == 1 && rawName[0] <= 1)) {
        out.add(
          DiscImageEntry(
            name: String.fromCharCodes(rawName),
            isDirectory: data[at + 25] & 0x02 != 0,
            location: _le32(data, at + 2),
            length: _le32(data, at + 10),
          ),
        );
      }
      at += len;
    }
    return out;
  }

  @override
  Uint8List readFile(DiscImageEntry file, int limit) {
    final int n = file.length < limit ? file.length : limit;
    if (n <= 0) return Uint8List(0);
    final int sectors = (n + kDiscImageSectorSize - 1) ~/ kDiscImageSectorSize;
    return Uint8List.sublistView(_sector(_read, file.location, sectors), 0, n);
  }
}

// ──────────────────────────────── UDF ────────────────────────────────

/// UDF 描述符标签号（ECMA-167 7.2.1）。
const int _kTagPrimaryVolume = 1;
const int _kTagAnchor = 2;
const int _kTagPartition = 5;
const int _kTagLogicalVolume = 6;
const int _kTagTerminating = 8;
const int _kTagFileSet = 256;
const int _kTagFileIdentifier = 257;
const int _kTagFileEntry = 261;
const int _kTagExtendedFileEntry = 266;

/// 分区映射的种类。
enum _UdfMapKind { physical, metadata, unsupported }

/// 一段分配：分区引用 + 分区内逻辑块 + 字节长度。
class _UdfExtent {
  const _UdfExtent(this.partRef, this.block, this.length);

  final int partRef;
  final int block;
  final int length;
}

class _UdfFs implements DiscImageFileSystem {
  _UdfFs._(this._read, this._partitionStart, this._maps, this.label);

  final DiscImageRead _read;

  /// 物理分区起始扇区（物理分区逻辑块 0 所在的扇区）。
  final int _partitionStart;

  /// 分区引用号 → 映射种类（逻辑卷描述符的分区映射表顺序）。
  final List<_UdfMapKind> _maps;

  /// UDF 2.50 元数据分区：元数据文件的分配（按元数据分区内字节偏移顺序排列，块号
  /// 是物理分区内的逻辑块）。
  List<_UdfExtent> _metadataExtents = const <_UdfExtent>[];

  late _UdfExtent _rootIcb;

  @override
  final String? label;

  static _UdfFs? open(DiscImageRead read) {
    final Uint8List anchor;
    try {
      anchor = _sector(read, 256);
    } on DiscImageFormatException {
      return null;
    }
    if (_le16(anchor, 0) != _kTagAnchor) return null;
    final int vdsLength = _le32(anchor, 16);
    final int vdsStart = _le32(anchor, 20);
    final int vdsSectors = (vdsLength ~/ kDiscImageSectorSize).clamp(1, 64);

    int? partitionNumber;
    int? partitionStart;
    String? label;
    Uint8List? lvd;
    for (int i = 0; i < vdsSectors; i++) {
      final Uint8List d = _sector(read, vdsStart + i);
      final int tag = _le16(d, 0);
      if (tag == _kTagTerminating) break;
      if (tag == _kTagPrimaryVolume) {
        label = _dstring(d.sublist(24, 56));
      } else if (tag == _kTagPartition && partitionStart == null) {
        partitionNumber = _le16(d, 22);
        partitionStart = _le32(d, 188);
      } else if (tag == _kTagLogicalVolume) {
        lvd = d;
      }
    }
    if (partitionStart == null || lvd == null) return null;

    // 分区映射表：类型 1 = 物理分区；类型 2 且标识为元数据分区 = UDF 2.50（BD）。
    // 其它类型（虚拟分区 / 可备用分区）只出现在可写盘上，DVD-Video / BD-ROM 没有。
    final int mapCount = _le32(lvd, 268);
    final List<_UdfMapKind> maps = <_UdfMapKind>[];
    int? metadataFileLocation;
    int at = 440;
    for (int i = 0; i < mapCount && at + 2 <= lvd.length; i++) {
      final int type = lvd[at];
      final int len = lvd[at + 1];
      if (len == 0) break;
      if (type == 1) {
        maps.add(_UdfMapKind.physical);
      } else if (type == 2 && at + 44 <= lvd.length) {
        final String id = String.fromCharCodes(lvd.sublist(at + 5, at + 28));
        final int number = _le16(lvd, at + 38);
        if (id.startsWith('*UDF Metadata Partition') &&
            (partitionNumber == null || number == partitionNumber)) {
          maps.add(_UdfMapKind.metadata);
          metadataFileLocation = _le32(lvd, at + 40);
        } else {
          maps.add(_UdfMapKind.unsupported);
        }
      } else {
        maps.add(_UdfMapKind.unsupported);
      }
      at += len;
    }
    if (maps.isEmpty) maps.add(_UdfMapKind.physical);

    final _UdfFs fs = _UdfFs._(read, partitionStart, maps, label);
    if (metadataFileLocation != null) {
      final int physicalRef = maps.indexOf(_UdfMapKind.physical);
      final (List<_UdfExtent> extents, Uint8List? _, int _) = fs._readFileEntry(
        _UdfExtent(physicalRef < 0 ? 0 : physicalRef, metadataFileLocation, 0),
      );
      fs._metadataExtents = extents;
    }

    // 文件集描述符：LVD 的「逻辑卷内容使用」字段是指向它的 long_ad。
    final Uint8List fsd = fs._block(
      _UdfExtent(_le16(lvd, 256), _le32(lvd, 252), 0),
    );
    if (_le16(fsd, 0) != _kTagFileSet) return null;
    fs._rootIcb = _UdfExtent(_le16(fsd, 408), _le32(fsd, 404), 0);
    return fs;
  }

  /// 分区引用 [partRef] 里的逻辑块 [block] → 物理扇区。
  int _sectorOf(int partRef, int block) {
    final _UdfMapKind kind = partRef < _maps.length
        ? _maps[partRef]
        : _UdfMapKind.unsupported;
    switch (kind) {
      case _UdfMapKind.physical:
        return _partitionStart + block;
      case _UdfMapKind.metadata:
        int remaining = block * kDiscImageSectorSize;
        for (final _UdfExtent e in _metadataExtents) {
          if (remaining < e.length) {
            return _partitionStart +
                e.block +
                remaining ~/ kDiscImageSectorSize;
          }
          remaining -= e.length;
        }
        throw const DiscImageFormatException('metadata block out of range');
      case _UdfMapKind.unsupported:
        throw const DiscImageFormatException('unsupported UDF partition map');
    }
  }

  Uint8List _block(_UdfExtent at) =>
      _sector(_read, _sectorOf(at.partRef, at.block));

  /// 读 [icb] 处的文件项：数据分配（short_ad 落在文件项自己的分区，long_ad 自带分区
  /// 引用）、内嵌数据（分配类型 3）与文件长度。
  (List<_UdfExtent>, Uint8List?, int) _readFileEntry(_UdfExtent icb) {
    final Uint8List fe = _block(icb);
    final int tag = _le16(fe, 0);
    final int adBase;
    final int adLength;
    if (tag == _kTagFileEntry) {
      adLength = _le32(fe, 172);
      adBase = 176 + _le32(fe, 168);
    } else if (tag == _kTagExtendedFileEntry) {
      adLength = _le32(fe, 212);
      adBase = 216 + _le32(fe, 208);
    } else {
      throw const DiscImageFormatException('not a UDF file entry');
    }
    final int infoLength = _le64(fe, 56);
    if (adBase + adLength > fe.length) {
      throw const DiscImageFormatException(
        'UDF allocation descriptors overflow',
      );
    }
    final int adType = _le16(fe, 16 + 18) & 0x07;
    if (adType == 3) {
      return (
        const <_UdfExtent>[],
        Uint8List.fromList(fe.sublist(adBase, adBase + adLength)),
        infoLength,
      );
    }
    if (adType != 0 && adType != 1) {
      throw const DiscImageFormatException('unsupported UDF allocation type');
    }
    final int step = adType == 0 ? 8 : 16;
    final List<_UdfExtent> extents = <_UdfExtent>[];
    for (int at = adBase; at + step <= adBase + adLength; at += step) {
      final int rawLength = _le32(fe, at);
      final int length = rawLength & 0x3FFFFFFF;
      if (length == 0) break;
      // 高两位非 0 = 已分配未写入 / 未分配：没有数据可读。
      if (rawLength >> 30 != 0) continue;
      extents.add(
        _UdfExtent(
          adType == 0 ? icb.partRef : _le16(fe, at + 8),
          _le32(fe, at + 4),
          length,
        ),
      );
    }
    return (extents, null, infoLength);
  }

  /// 文件 [icb] 的前 [limit] 字节内容。逐扇区经 [_sectorOf] 映射：元数据分区里逻辑
  /// 连续的块在物理上未必连续。
  Uint8List _fileData(_UdfExtent icb, int limit) {
    final (List<_UdfExtent> extents, Uint8List? inline, int infoLength) =
        _readFileEntry(icb);
    final int wanted = infoLength < limit ? infoLength : limit;
    if (inline != null) {
      return inline.length <= wanted ? inline : inline.sublist(0, wanted);
    }
    final BytesBuilder out = BytesBuilder(copy: false);
    int remaining = wanted;
    for (final _UdfExtent e in extents) {
      for (
        int offset = 0;
        offset < e.length && remaining > 0;
        offset += kDiscImageSectorSize
      ) {
        final Uint8List sector = _block(
          _UdfExtent(e.partRef, e.block + offset ~/ kDiscImageSectorSize, 0),
        );
        int take = e.length - offset;
        if (take > kDiscImageSectorSize) take = kDiscImageSectorSize;
        if (take > remaining) take = remaining;
        out.add(sector.sublist(0, take));
        remaining -= take;
      }
      if (remaining <= 0) break;
    }
    return out.takeBytes();
  }

  @override
  List<DiscImageEntry> listRoot() => _listIcb(_rootIcb);

  @override
  List<DiscImageEntry> list(DiscImageEntry directory) =>
      _listIcb(_UdfExtent(directory.partRef, directory.location, 0));

  List<DiscImageEntry> _listIcb(_UdfExtent icb) {
    final Uint8List data = _fileData(icb, _kMaxDirectoryBytes);
    final List<DiscImageEntry> out = <DiscImageEntry>[];
    int at = 0;
    while (at + 38 <= data.length) {
      if (_le16(data, at) != _kTagFileIdentifier) {
        throw const DiscImageFormatException('bad UDF file identifier');
      }
      final int characteristics = data[at + 18];
      final int nameLength = data[at + 19];
      final int icbBlock = _le32(data, at + 24);
      final int icbPartRef = _le16(data, at + 28);
      final int iuLength = _le16(data, at + 36);
      final int nameStart = at + 38 + iuLength;
      if (nameStart + nameLength > data.length) {
        throw const DiscImageFormatException('UDF name overflow');
      }
      final bool isParent = characteristics & 0x08 != 0;
      final bool isDeleted = characteristics & 0x04 != 0;
      if (!isParent && !isDeleted && nameLength > 0) {
        out.add(
          DiscImageEntry(
            name: _dstringBytes(
              data.sublist(nameStart, nameStart + nameLength),
            ),
            isDirectory: characteristics & 0x02 != 0,
            location: icbBlock,
            length: 0,
            partRef: icbPartRef,
          ),
        );
      }
      at += (38 + iuLength + nameLength + 3) & ~3;
    }
    return out;
  }

  @override
  Uint8List readFile(DiscImageEntry file, int length) =>
      _fileData(_UdfExtent(file.partRef, file.location, 0), length);
}

/// 定长 dstring（最后一字节是有效长度）。
String? _dstring(Uint8List field) {
  final int used = field.last;
  if (used == 0 || used >= field.length) return null;
  final String value = _dstringBytes(field.sublist(0, used)).trim();
  return value.isEmpty ? null : value;
}

/// OSTA 压缩 Unicode：首字节 8 = 每字符 1 字节，16 = 每字符 2 字节（大端）。
String _dstringBytes(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  final int compression = bytes[0];
  if (compression == 16) {
    final StringBuffer out = StringBuffer();
    for (int i = 1; i + 1 < bytes.length; i += 2) {
      out.writeCharCode((bytes[i] << 8) | bytes[i + 1]);
    }
    return out.toString();
  }
  return String.fromCharCodes(bytes.sublist(1));
}
