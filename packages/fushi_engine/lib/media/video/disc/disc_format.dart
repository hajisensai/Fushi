// 原盘规格（BD / UHD BD / DVD）：只按文件结构判、必须能确证。
//
// 判据（2026-10-24 交接文档拍板）：
//
//   - BD      = `BDMV/PLAYLIST/*.mpls`
//   - UHD BD  = BD 且 `BDMV/index.bdmv` 头 8 字节是 `INDX0300`（BD-ROM 3.0 = UHD；
//               普通 BD 是 `INDX0100` / `INDX0200`）
//   - DVD     = `VIDEO_TS/VIDEO_TS.IFO`
//
// 规格**不入库**（不改 schema）：库里每条原盘标题的成员路径已经编码了盘根与格式——
// 蓝光是真实的 `.mpls`，DVD 是虚拟的 `TITLE_nn.dvdtitle`（见 `dvd_disc.dart`）。所以
// BD / DVD 纯字符串就分得出；只有「BD 里是不是 UHD」要读一次 `index.bdmv`，按盘根缓存
// 在 [DiscFormatResolver] 里，同一张盘整个会话只读一次。
//
// 规格与「能不能开原盘菜单」无关：后者是运行时能力（平台制品、BD-J、AACS、CSS），
// 不在这里判。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show blurayDiscRootForPlaylistPath, isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/disc/disc_image_probe.dart'
    show probeDiscImageFile;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';

/// 原盘规格。顺序即角标 / 汇总的展示顺序。
enum DiscFormat { uhdBluray, bluray, dvd }

/// `index.bdmv` 头部：`INDX` + 4 位版本号。
const String kBlurayIndexMagic = 'INDX';

/// UHD BD 的 `index.bdmv` 版本号。
const String kUhdBlurayIndexVersion = '0300';

/// [memberPath] 是不是一条原盘标题的成员路径（蓝光 `.mpls` 或 DVD title）。
bool isDiscMemberPath(String memberPath) =>
    discRootForMemberPath(memberPath) != null;

/// 从原盘标题的成员路径反推盘根（含 `BDMV` / `VIDEO_TS` 的那一层）；不是原盘成员
/// 返回 null。纯函数，不碰文件系统，渲染路径可直接调。
String? discRootForMemberPath(String memberPath) {
  if (isBlurayPlaylistPath(memberPath)) {
    return blurayDiscRootForPlaylistPath(memberPath);
  }
  if (isDvdTitlePath(memberPath)) return dvdDiscRootForTitlePath(memberPath);
  return null;
}

/// 只看路径能定下的规格：DVD 成员 → [DiscFormat.dvd]；蓝光成员 → [DiscFormat.bluray]
/// （**还没区分 UHD**，要确证用 [DiscFormatResolver]）；其它 → null。
DiscFormat? discFormatHintForMemberPath(String memberPath) {
  if (isDvdTitlePath(memberPath)) {
    return dvdDiscRootForTitlePath(memberPath) == null ? null : DiscFormat.dvd;
  }
  if (isBlurayPlaylistPath(memberPath)) {
    return blurayDiscRootForPlaylistPath(memberPath) == null
        ? null
        : DiscFormat.bluray;
  }
  return null;
}

/// 成员路径背后真实存在的文件：蓝光就是 `.mpls` 本身；DVD 是盘的 `VIDEO_TS.IFO`，
/// 镜像形态是 `.iso` 本身（title 路径是虚拟的）。下游「这一条还在不在」先过它再 `existsSync`。不是原盘
/// 成员时原样返回 [memberPath]。
String discMemberBackingFilePath(String memberPath) {
  if (isDvdTitlePath(memberPath)) {
    return dvdTitleBackingFilePath(memberPath) ?? memberPath;
  }
  return memberPath;
}

/// 按 `index.bdmv` 头 8 字节定蓝光规格；头不对返回 null。
DiscFormat? blurayFormatForIndexHeader(List<int> head) {
  if (head.length < 8) return null;
  final String text = String.fromCharCodes(head.take(8));
  if (!text.startsWith(kBlurayIndexMagic)) return null;
  return text.substring(4) == kUhdBlurayIndexVersion
      ? DiscFormat.uhdBluray
      : DiscFormat.bluray;
}

/// 读盘根定规格（IO）：有 `VIDEO_TS/VIDEO_TS.IFO` → DVD；有 `BDMV/PLAYLIST` → 看
/// `index.bdmv` 头分 BD / UHD（读不动按 BD——`PLAYLIST` 已确证是蓝光，只是证不了 UHD）；
/// 都没有 → null。
Future<DiscFormat?> readDiscFormatAtRoot(String discRootPath) async {
  // 镜像形态：盘根就是 `.iso` 文件，打开探测（不靠扩展名猜里面是什么）。
  if (isDiscImagePath(discRootPath) &&
      FileSystemEntity.typeSync(discRootPath) == FileSystemEntityType.file) {
    return (await probeDiscImageFile(discRootPath))?.format;
  }
  if (findDvdVideoTsIfo(discRootPath) != null) return DiscFormat.dvd;
  final String bdmv = p.join(discRootPath, 'BDMV');
  if (!Directory(p.join(bdmv, 'PLAYLIST')).existsSync()) return null;
  for (final String name in <String>['index.bdmv', 'INDEX.BDMV']) {
    final File index = File(p.join(bdmv, name));
    try {
      if (!index.existsSync()) continue;
      final RandomAccessFile raf = await index.open();
      try {
        final Uint8List head = await raf.read(8);
        return blurayFormatForIndexHeader(head) ?? DiscFormat.bluray;
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      break;
    }
  }
  return DiscFormat.bluray;
}

/// 把一组成员路径汇总成「每种规格几张盘」：按盘根去重（一张盘多条标题只算一张），
/// 规格由 [formatOf] 给（通常是 [DiscFormatResolver.peek]）；给不出的盘不计。
///
/// 返回按 [DiscFormat] 声明顺序排好的有序表，只含计数 > 0 的项。
Map<DiscFormat, int> summarizeDiscMembers(
  Iterable<String> memberPaths,
  DiscFormat? Function(String memberPath) formatOf,
) {
  final Map<String, DiscFormat> byRoot = <String, DiscFormat>{};
  for (final String path in memberPaths) {
    final String? root = discRootForMemberPath(path);
    if (root == null || byRoot.containsKey(root)) continue;
    final DiscFormat? format = formatOf(path);
    if (format != null) byRoot[root] = format;
  }
  final Map<DiscFormat, int> counts = <DiscFormat, int>{};
  for (final DiscFormat format in DiscFormat.values) {
    final int n = byRoot.values.where((DiscFormat f) => f == format).length;
    if (n > 0) counts[format] = n;
  }
  return counts;
}

/// 按盘根缓存的规格解析器。
///
/// [peek] 是纯读（渲染路径用）：DVD 成员不需要 IO 直接给；蓝光成员要等 [resolve]
/// 读过一次 `index.bdmv` 才给，之前返回 null——**不先给个「BD」再变「UHD」**，否则
/// UHD 盘的角标首帧会闪错。同一盘根并发 [resolve] 只读一次。
class DiscFormatResolver {
  DiscFormatResolver({
    Future<DiscFormat?> Function(String discRootPath)? readFormat,
  }) : _readFormat = readFormat ?? readDiscFormatAtRoot;

  final Future<DiscFormat?> Function(String discRootPath) _readFormat;

  /// 盘根 → 规格；值为 null 表示读过、盘根已不成盘（目录被删 / 移走）。
  final Map<String, DiscFormat?> _byRoot = <String, DiscFormat?>{};
  final Map<String, Future<DiscFormat?>> _inFlight =
      <String, Future<DiscFormat?>>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 有新盘根解析完成时发一次（调用方据此重建）。
  Stream<void> get changes => _changes.stream;

  /// 同步读规格；没解析过的蓝光返回 null。
  DiscFormat? peek(String memberPath) {
    final DiscFormat? hint = discFormatHintForMemberPath(memberPath);
    if (hint == null || hint == DiscFormat.dvd) return hint;
    final String root = discRootForMemberPath(memberPath)!;
    return _byRoot[root];
  }

  /// [memberPath] 的规格是否已有结论（[peek] 的结果就是终值）。
  bool isResolved(String memberPath) {
    final DiscFormat? hint = discFormatHintForMemberPath(memberPath);
    if (hint == null || hint == DiscFormat.dvd) return true;
    return _byRoot.containsKey(discRootForMemberPath(memberPath));
  }

  /// 解析 [memberPath] 的规格（蓝光按盘根读一次 `index.bdmv`）。
  Future<DiscFormat?> resolve(String memberPath) async {
    final DiscFormat? hint = discFormatHintForMemberPath(memberPath);
    if (hint == null || hint == DiscFormat.dvd) return hint;
    final String root = discRootForMemberPath(memberPath)!;
    if (_byRoot.containsKey(root)) return _byRoot[root];
    final Future<DiscFormat?> pending = _inFlight[root] ??= () async {
      DiscFormat? format;
      try {
        format = await _readFormat(root);
      } on FileSystemException {
        format = null;
      }
      _byRoot[root] = format;
      _inFlight.remove(root);
      if (!_changes.isClosed) _changes.add(null);
      return format;
    }();
    return pending;
  }

  /// 批量解析（筛选面板一次性要全库规格时用）。
  Future<void> resolveAll(Iterable<String> memberPaths) async {
    final Map<String, String> firstByRoot = <String, String>{};
    for (final String path in memberPaths) {
      if (discFormatHintForMemberPath(path) != DiscFormat.bluray) continue;
      firstByRoot.putIfAbsent(discRootForMemberPath(path)!, () => path);
    }
    await Future.wait<DiscFormat?>(<Future<DiscFormat?>>[
      for (final String path in firstByRoot.values) resolve(path),
    ]);
  }

  /// 丢掉某张盘的缓存（盘目录被替换时）。
  void invalidate(String discRootPath) => _byRoot.remove(discRootPath);

  Future<void> dispose() => _changes.close();
}
