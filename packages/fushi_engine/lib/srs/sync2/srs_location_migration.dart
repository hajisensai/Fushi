/// 同步 v2 协议 2 的位置准备与 v1 位置的一次性迁移（2026-10-30 格式断代，所有者拍板：一次性断代，旧客户端不能借机
/// 损坏数据、不能往加密位置写明文）。
///
/// **两个集合根**（srs_location_store.dart）：协议 2 的数据在 `fushi-srs/<uid>/v3/`（[kSrsSync2Folder]）；协议 1 的
/// 旧根 `fushi-srs/<uid>/v2/`（[kSrsSync2V1Folder]）只留下：
/// - 一份 `meta.json` 围栏（[srsV1FenceMeta]：`minReader` = 2、`movedTo` = `v3`，保留原来的集合身份与 `kdf`）。
///   旧版本（develop@d407ae22ca）读到它就报需要升级、一个文件都不写——云盘 / 互联通道在握手后整轮停下；
/// - 文件夹位置另有一个**同名普通文件** `media`（[srsFenceV1FolderMedia]）：旧版本的文件夹位置在需要升级时仍会跑一遍
///   明文媒体对账（往 `media/<名字>` 写、按过期删），`media` 不是目录时它的列目录为空、第一次写就在建目录那一步失败，
///   于是什么也写不进去、什么也删不掉。
/// 新版本对每个位置（包括全新的）都先确保这两样在，旧版本永远不会在旧根上重新建一个 v1 集合。
///
/// **迁移**（新版本第一次碰到一个 v1 位置，[srsPrepareLocation]）。每一步幂等，进度就是位置本身的状态，中断后
/// 任何一台新版本设备接着做：
/// 1. 围栏：先挪走文件夹位置的 `media`（换成普通文件），再把旧根的 `meta.json` 改成围栏——旧版本从此停下；
/// 2. 只读导入：按旧根上的 head 把段收进本机（媒体绑定要看到全部已有绑定，下一步才不会抢别人的）；
/// 3. 段 / head / 转发件 / 说明文件**原样**写进新根（段由作者签名，谁也不能重写；字节格式两个协议相同）；
/// 4. 媒体按内容写进新根的内容目录：按名字存的旧文件（明文 / 整份封装）算 sha256 后写成 `media/<前2>/<sha>`
///    （加密位置一律重新封成分块格式、AAD = sha），给**没人绑过**的名字补绑定；内容寻址的旧对象原样搬（加密位置上
///    明文的那些重新封）；协议 1 之前的写入者目录（`fushi-srs/<uid>/<写入者>/media/`）同样搬；
/// 5. 新根的 `meta.json`（内容由旧 meta 决定：集合身份、创建时刻、`kdf`——几台设备并发写出的是同一份）；
/// 6. 删旧文件：**只删已在新根确认存在的**（写新根成功之后才删它的旧副本；读旧文件时发现已经不在 = 别的设备搬完删了，
///    它的内容按同一规则已在新根），整个写入者目录在它的媒体搬完后删。
///
/// 并发：两台新版本设备同时迁移同一个位置时，写新根一律「已在就不写」（[SrsLocationStore.putNew]），新 meta 字节
/// 相同，删除只删自己确认过新副本的旧文件——谁先谁后都不丢、不互删。旧版本在第 1 步之前还在照常写旧根，第 1 步之后
/// 才写到一半的（围栏那一刻正在跑的一轮）会留在旧根：每次进程启动后的第一轮都会再扫一遍旧根（[SrsLocationMigrationMemo]
/// 只在本进程记「扫干净了」），晚到的照样搬过去。
///
/// 归档用途（设计 §10.3「永不执行任何删除」）：迁移只复制不删——旧根上的段 / head / 媒体搬进新根后原样留着
/// （围栏照立：旧版本照样被挡在外面，文件夹位置的 `media` 目录挪成 [kSrsV1FolderMediaMoved] 是改名不是删除）。
/// 代价是归档位置多留一份旧格式的副本，每次进程启动后的第一轮多扫一遍（新根上已在的不再写）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;
import 'package:path/path.dart' as p;

/// 旧根 `meta.json` 上的围栏字段：协议 2 的新版本接管了这个位置，数据在它指的根（[kSrsSync2Folder]）。
const String kSrsV1MovedToKey = 'movedTo';

/// 文件夹位置旧根下媒体目录被挪到的名字（原名 `media` 换成同名普通文件，见 [srsFenceV1FolderMedia]）。
const String kSrsV1FolderMediaMoved = 'media.v1';

/// 文件夹位置的旧根媒体目录挪不开（围栏之后又冒出来一个 `media` 目录，里面有与已挪走的同名而内容不同的文件）：
/// 不围栏、不迁移，这个位置这一轮不同步（旧版本照常用旧根，不会损坏任何东西）。
const String kSrsV1FolderFenceBlocked =
    'srs v1 folder media could not be fenced';

/// 本进程里已经确认旧根扫干净的位置（每次进程启动后的第一轮仍会再扫一遍，见库注释）。调度器持有一份；不给 = 每轮
/// 都看一眼旧根。
class SrsLocationMigrationMemo {
  final Set<String> _swept = <String>{};

  bool swept(String profileUid, String locationId) =>
      _swept.contains('$profileUid|$locationId');

  void markSwept(String profileUid, String locationId) =>
      _swept.add('$profileUid|$locationId');
}

/// [srsPrepareLocation] 的结论。
class SrsLocationPrepared {
  /// 位置来自更新的版本（新根 `meta.json` 的 `minReader` 比本机新，或旧根上是不认识的更新格式）：什么都没写。
  bool needsUpgrade = false;

  /// 这个位置这一轮不同步的原因（握手同一套错误：口令 / `meta.json` 读不到……）；null = 可以在新根上跑一轮。
  String? error;

  /// 旧根 `meta.json` 上的加密参数（要口令时 UI 用）。
  SrsKdf? kdf;

  /// 这一轮跑了迁移（含接着别的设备 / 上次没做完的）。
  bool migrated = false;

  /// 原样写进新根的段 / head / 转发件 / 说明文件数（已在的不算）。
  int copied = 0;

  /// 按内容写进新根的媒体数（含已在的）。
  int media = 0;

  /// 补上的媒体绑定数。
  int bound = 0;

  /// 删掉的旧文件数。
  int deleted = 0;

  /// 搬不了而留在旧根的（解不开 / 读失败），下次再试。
  final List<String> skipped = <String>[];

  /// 导入旧段时的非致命错误（段损坏等，与一轮同步的 errors 同义）。
  final List<String> errors = <String>[];
}

/// 协议 1 之前的旧同步引擎的写入者目录（`fushi-srs/<uid>/<写入者>/`，只有云盘 / 互联通道上有）：迁移只读它们的
/// `media/`，媒体搬完整个目录删掉（别的内容没有任何版本再读）。
abstract interface class SrsV1Writers {
  /// 全部写入者目录名。
  Future<List<String>> writers();

  /// [writer] 的 `media/` 下的文件名。
  Future<List<String>> mediaNames(String writer);

  /// 把 [writer] 的 `media/<name>` 下载到 [dst]；不在返回 false。
  Future<bool> getMedia(String writer, String name, File dst);

  /// 删掉整个 [writer] 目录。
  Future<void> deleteWriter(String writer);
}

/// [SyncAssetStore] 上的写入者目录。
class SrsAssetV1Writers implements SrsV1Writers {
  SrsAssetV1Writers(this.store, this.profileUid);

  final SyncAssetStore store;
  final String profileUid;
  final Map<String, String> _writerIds = <String, String>{};
  final Map<String, Map<String, String>> _media =
      <String, Map<String, String>>{};

  @override
  Future<List<String>> writers() async {
    final String ns = await store.ensureNamespace(kSrsSync2Namespace);
    final String profile = await store.ensureFolder(ns, profileUid);
    _writerIds.clear();
    for (final AssetEntry w in await store.listChildren(profile)) {
      if (!w.isFolder ||
          w.name == kSrsSync2Folder ||
          w.name == kSrsSync2V1Folder) {
        continue;
      }
      _writerIds[w.name] = w.id;
    }
    return _writerIds.keys.toList()..sort();
  }

  @override
  Future<List<String>> mediaNames(String writer) async {
    final String? id = _writerIds[writer];
    final Map<String, String> files = <String, String>{};
    _media[writer] = files;
    if (id == null) return const <String>[];
    for (final AssetEntry m in await store.listChildren(id)) {
      if (!m.isFolder || m.name != kSrsMediaFolder) continue;
      for (final AssetEntry f in await store.listChildren(m.id)) {
        if (!f.isFolder) files.putIfAbsent(f.name, () => f.id);
      }
    }
    return files.keys.toList()..sort();
  }

  @override
  Future<bool> getMedia(String writer, String name, File dst) async {
    final String? id = _media[writer]?[name];
    if (id == null) return false;
    try {
      await store.getAsset(id, dst);
      return true;
    } on Object {
      // 列出来之后被别的设备搬完删了：当不在。
      return false;
    }
  }

  @override
  Future<void> deleteWriter(String writer) async {
    final String? id = _writerIds[writer];
    if (id != null) await store.deleteAsset(id, isFolder: true);
  }
}

/// 文件夹位置的媒体围栏：把旧根下的 `media` 目录挪成 [kSrsV1FolderMediaMoved]，原名换成一个同名普通文件（内容是
/// 一行说明）。已经是普通文件就什么都不做。挪的时候 [kSrsV1FolderMediaMoved] 已经在（上次挪过、之后又冒出来一个
/// `media` 目录：别的设备经同步工具带回来的）就把里面的文件并过去；同名而内容不同的挪不了 → 返回 false（不围栏）。
Future<bool> srsFenceV1FolderMedia(Directory v1Root) async {
  await v1Root.create(recursive: true);
  final String path = p.join(v1Root.path, kSrsMediaFolder);
  final Directory moved = Directory(
    p.join(v1Root.path, kSrsV1FolderMediaMoved),
  );
  for (int attempt = 0; attempt < 3; attempt++) {
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.file) return true;
    if (type == FileSystemEntityType.directory) {
      final Directory media = Directory(path);
      if (!await moved.exists()) {
        await media.rename(moved.path);
      } else if (!await _mergeInto(media, moved)) {
        return false;
      } else {
        await media.delete(recursive: true);
      }
      continue;
    }
    try {
      // 新建文件（已存在就抛）：与旧版本同时建 `media` 目录时，谁先谁赢，输了就再看一遍。
      await File(path).create(exclusive: true);
      await File(path).writeAsString(
        'fushi SRS sync moved to ../$kSrsSync2Folder (protocol $kSrsSync2Protocol). '
        'This file keeps older app versions from writing media here.\n',
        flush: true,
      );
      return true;
    } on FileSystemException {
      // 期间被建成了目录 / 文件：再看一遍。
    }
  }
  return await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.file;
}

/// 把 [src] 下的文件并进 [dst]（同名同内容的丢掉 [src] 那份）；有同名不同内容的返回 false（一个都不动的那些留着）。
Future<bool> _mergeInto(Directory src, Directory dst) async {
  bool ok = true;
  await for (final FileSystemEntity e in src.list(followLinks: false)) {
    final String target = p.join(dst.path, p.basename(e.path));
    if (e is Directory) {
      final Directory d = Directory(target);
      if (!await d.exists()) {
        await e.rename(target);
      } else if (!await _mergeInto(e, d)) {
        ok = false;
      }
    } else if (e is File) {
      final File t = File(target);
      if (!await t.exists()) {
        await e.rename(target);
      } else if (await srsMediaSha256File(t) == await srsMediaSha256File(e)) {
        await e.delete();
      } else {
        ok = false;
      }
    }
  }
  return ok;
}

/// 文件夹位置迁移收尾：删掉旧根下已经空了的目录（自底向上、只删空目录——删目录前不看内容的话，同步工具这时
/// 带回来的文件会被一起删掉）。`meta.json` 与 `media` 普通文件不动。
Future<void> srsRemoveEmptyV1FolderDirs(Directory v1Root) async {
  Future<bool> prune(Directory d) async {
    bool empty = true;
    try {
      await for (final FileSystemEntity e in d.list(followLinks: false)) {
        if (e is Directory) {
          if (!await prune(e)) empty = false;
        } else {
          empty = false;
        }
      }
    } on PathNotFoundException {
      // 另一台设备同时在收尾，已经删掉了。
      return true;
    }
    if (!empty || d.path == v1Root.path) return false;
    try {
      await d.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  if (await v1Root.exists()) await prune(v1Root);
}

/// 旧根的围栏 `meta.json`：旧 meta 的全部字段（集合身份、创建时刻、`kdf`）照留，`v` / `minReader` 改成本协议，
/// 记下数据挪到了哪、何时围的。[old] 本来就是围栏时原样返回（时刻不变，几台设备写出的是同一份）。
Map<String, Object?> srsV1FenceMeta(Map<String, Object?> old, int nowMs) {
  if (old[kSrsV1MovedToKey] == kSrsSync2Folder) return old;
  return <String, Object?>{
    ...old,
    'v': kSrsSync2Protocol,
    'minReader': kSrsSync2MinReader,
    kSrsV1MovedToKey: kSrsSync2Folder,
    'fencedAt': nowMs,
  };
}

/// 迁移写的新根 `meta.json`：只由旧 meta 决定（集合身份、创建时刻、`kdf`），并发迁移的设备写出的字节相同。
Map<String, Object?> srsV2MetaFromV1(
  Map<String, Object?> v1,
  Object? collection,
  int nowMs,
) => <String, Object?>{
  'v': kSrsSync2Protocol,
  'minReader': kSrsSync2MinReader,
  'collection': v1['collection'] ?? collection,
  'createdAt': v1['createdAt'] ?? v1['fencedAt'] ?? nowMs,
  if (v1['kdf'] != null) 'kdf': v1['kdf'],
};

/// `meta.json` 读的结果：不在（null）、坏的（[_kBadMeta]）或对象。
const Object _kBadMeta = Object();

Future<Object?> _readMeta(SrsLocationStore s) async {
  final Uint8List? bytes = await s.get('meta.json');
  if (bytes == null) return null;
  try {
    final Object? j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) return _kBadMeta;
    return j.cast<String, Object?>();
  } on FormatException {
    return _kBadMeta;
  }
}

int _minReaderOf(Map<String, Object?> meta) {
  final Object? v = meta['minReader'];
  return v is num ? v.toInt() : 1;
}

/// 集合根上除了 `meta.json`（与旧根上文件夹位置的 `media` 普通文件）之外还有没有东西。
Future<bool> _hasData(SrsLocationStore v1) async {
  for (final SrsLocationEntry e in await v1.list('')) {
    if (e.name == 'meta.json' && !e.isFolder) continue;
    if (e.name == kSrsMediaFolder && !e.isFolder) continue;
    return true;
  }
  return false;
}

/// 按旧 meta 的 `kdf` 定迁移用的密钥（与 [srsLocationHandshake] 同一套判断，但只读、不写 meta）。
({String? keyHex, String? error, SrsKdf? kdf}) _v1Key(
  Map<String, Object?> meta,
  SrsLocationKey? key,
) {
  final Object? kdfJson = meta['kdf'];
  if (kdfJson == null) {
    // 本机开过加密而旧根没有 kdf：不降级成明文（与握手相同）。本机刚开的照常按明文搬，之后在新根上握手写 kdf。
    if (key != null && !key.pendingEnable) {
      return (keyHex: null, error: kSrsSync2EncryptionMissing, kdf: null);
    }
    return (keyHex: null, error: null, kdf: null);
  }
  final SrsKdf kdf;
  try {
    if (kdfJson is! Map) throw const FormatException('kdf is not an object');
    kdf = SrsKdf.fromJson(kdfJson.cast<String, Object?>());
  } on FormatException {
    return (keyHex: null, error: kSrsSync2BadKdf, kdf: null);
  }
  if (key == null) return (keyHex: null, error: kSrsSync2NeedsKey, kdf: kdf);
  if (kdfJson['check'] != key.check) {
    return (keyHex: null, error: kSrsSync2WrongKey, kdf: kdf);
  }
  return (keyHex: key.keyHex, error: null, kdf: kdf);
}

/// 准备一个位置跑协议 2 的一轮：确保旧根上的围栏在，必要时把 v1 数据迁进新根（见库注释）。[v1] / [current] 是同一个
/// 位置的旧根与新根；[recordPresence] = 位置的媒体「有什么」记日志（云盘 / 互联通道；文件夹位置每轮列目录，不记）；
/// [v1PlainMediaFolder] = 旧根上明文媒体目录的名字（文件夹位置围栏后是 [kSrsV1FolderMediaMoved]）；[writers] = 协议
/// 1 之前的写入者目录（只有通道上有）；[fenceFolderMedia] = 文件夹位置的媒体围栏（[srsFenceV1FolderMedia]）；
/// [removeEmptyDirs] = 删完旧文件后清空目录（文件夹位置）；[archive] = 归档位置（只复制、不删旧文件）。
Future<SrsLocationPrepared> srsPrepareLocation({
  required SrsSync2Host host,
  required SrsLocationStore v1,
  required SrsLocationStore current,
  required String locationId,
  required SrsLocationKey? key,
  required int Function() nowMs,
  bool recordPresence = false,
  String v1PlainMediaFolder = kSrsMediaFolder,
  SrsV1Writers? writers,
  Future<bool> Function()? fenceFolderMedia,
  Future<void> Function()? removeEmptyDirs,
  SrsLocationMigrationMemo? memo,
  bool archive = false,
}) async {
  final SrsLocationPrepared out = SrsLocationPrepared();
  final Object? cur = await _readMeta(current);
  if (identical(cur, _kBadMeta)) {
    out.error = kSrsSync2MetaUnavailable;
    return out;
  }
  if (cur is Map<String, Object?> && _minReaderOf(cur) > kSrsSync2Protocol) {
    out.needsUpgrade = true;
    return out;
  }
  final bool ready = cur != null;
  if (ready && (memo?.swept(host.profileUid, locationId) ?? false)) return out;

  Future<Object?> identity() async => (await host.sync2Command(
    <String, Object?>{'op': 'identity', 'now': nowMs()},
  )).map['collection'];

  // 协议 1 之前的写入者目录（只有通道上有）：没有 v1 集合根、只有它们的位置同样要把媒体迁过来。
  final List<String> writerDirs = writers == null
      ? const <String>[]
      : await writers.writers();
  Object? old = await _readMeta(v1);
  // 决定迁移用哪把密钥的 meta（旧根的；没有旧根时是新根的——加密与否由新根决定）。
  Map<String, Object?>? keyMeta;
  if (identical(old, _kBadMeta)) {
    // 旧根的 meta 坏了：旧版本也读不了（它们同样停下）。新根已在用就照常同步，否则不知道该迁什么。
    if (!ready) out.error = kSrsSync2MetaUnavailable;
    return out;
  }
  if (old == null) {
    if (await _hasData(v1)) {
      // 有旧数据却读不到 meta（最终一致的列目录还没看到 / 被删）：不围栏、不迁移，下一轮再看。新根已在用就照常同步。
      if (!ready) out.error = kSrsSync2MetaUnavailable;
      return out;
    }
    // 全新的位置（或旧根已清空）：只立围栏。新根的 meta 由这一轮的握手照常新建。
    if (fenceFolderMedia != null && !await fenceFolderMedia()) {
      out.error = kSrsV1FolderFenceBlocked;
      return out;
    }
    final Map<String, Object?> fence = srsV1FenceMeta(<String, Object?>{
      'collection': await identity(),
      'createdAt': nowMs(),
    }, nowMs());
    await v1.putNew('meta.json', utf8.encode(jsonEncode(fence)));
    if (writerDirs.isEmpty) {
      memo?.markSwept(host.profileUid, locationId);
      return out;
    }
    if (!ready && key != null) {
      // 新根还没有 meta、本机又带着密钥：这一轮的握手才定下位置加不加密，写入者目录的媒体下一轮再搬（不在定下之前
      // 按明文写进去）。
      return out;
    }
    old = fence;
    keyMeta = cur is Map<String, Object?> ? cur : const <String, Object?>{};
  }
  final Map<String, Object?> oldMeta = old as Map<String, Object?>;
  final bool fenced = oldMeta[kSrsV1MovedToKey] == kSrsSync2Folder;
  if (!fenced && _minReaderOf(oldMeta) > 1) {
    // 旧根上是本机不认识的更新格式（不是本版本立的围栏）。
    if (!ready) out.needsUpgrade = true;
    return out;
  }
  final ({String? keyHex, String? error, SrsKdf? kdf}) k = _v1Key(
    keyMeta ?? oldMeta,
    key,
  );
  out.kdf = k.kdf;
  if (k.error != null) {
    // 新根已在用：旧根上的残留这一轮不扫（解不开），不挡新根的同步。
    if (!ready) out.error = k.error;
    return out;
  }
  if (!fenced || fenceFolderMedia != null) {
    // 1. 围栏：先挪开文件夹位置的媒体目录，再改 meta（顺序反过来，中间那一刻旧版本会按明文往 `media/` 写）。
    if (fenceFolderMedia != null && !await fenceFolderMedia()) {
      out.error = kSrsV1FolderFenceBlocked;
      return out;
    }
    if (!fenced) {
      await v1.put(
        'meta.json',
        utf8.encode(jsonEncode(srsV1FenceMeta(oldMeta, nowMs()))),
      );
    }
  }
  if (writerDirs.isEmpty && !await _hasData(v1)) {
    if (!ready) {
      if (await _hasData(current)) {
        // 迁移早已做完（旧根空了），新根有数据却读不到 meta（被删 / 同步工具还没带过来）：与握手同一条规矩——
        // 不替一份可能还在的 meta 重写（重写会换掉集合身份 / 加密参数），这一轮不同步。
        out.error = kSrsSync2MetaUnavailable;
        return out;
      }
      await current.putNew(
        'meta.json',
        utf8.encode(
          jsonEncode(srsV2MetaFromV1(oldMeta, await identity(), nowMs())),
        ),
      );
    }
    memo?.markSwept(host.profileUid, locationId);
    return out;
  }
  out.migrated = true;
  final String? keyHex = k.keyHex;
  final String progressId = srsLocationProgressId(locationId, keyHex);

  // 2. 只读导入旧根上的段（媒体绑定要先看到全部已有绑定）。
  final SrsSync2Report pulled = SrsSync2Report();
  await srsSync2Pull(
    host: host,
    location: v1,
    progressId: progressId,
    keyHex: keyHex,
    report: pulled,
  );
  out.errors.addAll(pulled.errors);

  // 3. 段 / head / 转发件 / 说明文件原样写进新根。
  final List<String> doomed = <String>[];
  final List<String> deviceDirs = <String>[
    for (final SrsLocationEntry d in await v1.list('devices'))
      if (d.isFolder) 'devices/${d.name}',
  ];
  for (final String dir in deviceDirs) {
    final Set<String> there = <String>{
      for (final SrsLocationEntry f in await current.list(dir))
        if (!f.isFolder) f.name,
    };
    final List<String> files = <String>[
      for (final SrsLocationEntry f in await v1.list(dir))
        if (!f.isFolder) '$dir/${f.name}',
    ];
    await srsRunPooled(files, kSrsSync2Concurrency, (String path) async {
      final String name = path.substring(path.lastIndexOf('/') + 1);
      if (!there.contains(name)) {
        final Uint8List? bytes = await v1.get(path);
        if (bytes == null) return; // 别的设备搬完删了：它的新副本已在。
        await current.putNew(path, bytes);
        out.copied++;
      }
      doomed.add(path);
    });
  }

  // 4. 媒体。
  final _MediaMover mover = _MediaMover(
    host: host,
    v1: v1,
    current: current,
    keyHex: keyHex,
    presence: recordPresence ? locationId : null,
    nowMs: nowMs,
    out: out,
  );
  await mover.plainFolder(v1PlainMediaFolder, doomed);
  await mover.sealedFolders(doomed);
  final List<String> emptiedWriters = <String>[];
  for (final String w in writerDirs) {
    if (await mover.writer(writers!, w)) emptiedWriters.add(w);
  }
  await mover.finish();
  doomed.addAll(mover.afterBind);

  // 5. 新根的 meta：段与媒体都到位之后才写，没有它的新根别的设备不会当成可用（它们接着迁移）。
  if (!ready) {
    await current.putNew(
      'meta.json',
      utf8.encode(
        jsonEncode(srsV2MetaFromV1(oldMeta, await identity(), nowMs())),
      ),
    );
  }

  // 6. 删旧文件：只删新副本已确认在的（上面写成功 / 早就在的那些）。归档位置一个不删。
  if (archive) {
    if (out.skipped.isEmpty) memo?.markSwept(host.profileUid, locationId);
    return out;
  }
  await srsRunPooled(doomed, kSrsSync2Concurrency, (String path) async {
    await v1.delete(path);
    out.deleted++;
  });
  for (final String w in emptiedWriters) {
    await writers!.deleteWriter(w);
    out.deleted++;
  }
  await removeEmptyDirs?.call();
  if (out.skipped.isEmpty) memo?.markSwept(host.profileUid, locationId);
  return out;
}

/// 迁移里搬媒体的那一段（[srsPrepareLocation] 第 4 步）。
class _MediaMover {
  _MediaMover({
    required this.host,
    required this.v1,
    required this.current,
    required this.keyHex,
    required this.presence,
    required this.nowMs,
    required this.out,
  }) : cipher = keyHex == null ? null : SrsMediaCipher(host, keyHex);

  final SrsSync2Host host;
  final SrsLocationStore v1;
  final SrsLocationStore current;
  final String? keyHex;

  /// 记「新根上有什么」用的位置身份；null = 不记（文件夹位置）。
  final String? presence;
  final int Function() nowMs;
  final SrsLocationPrepared out;
  final SrsMediaCipher? cipher;
  final Random _rand = Random();

  /// 新根上的内容目录（明文 `media`，加密 `media-e/<密钥指纹>`）。
  String get target => cipher?.folder ?? kSrsMediaFolder;

  /// 待补的绑定（名字 → sha / 字节数）。
  final List<Map<String, Object?>> _binds = <Map<String, Object?>>[];

  /// 写进新根的内容（记「在」）。
  final Set<String> _stored = <String>{};

  /// 绑定补上之后才能删的旧文件（按名字存的那些）。
  final List<String> _afterBind = <String>[];

  File _scratch(String tag) => File(
    p.join(
      Directory.systemTemp.path,
      'fushi_srs_migrate_${tag}_${DateTime.now().microsecondsSinceEpoch}_'
      '${_rand.nextInt(1 << 30)}',
    ),
  );

  Future<void> _drop(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // 临时文件留给系统清理。
    }
  }

  /// 把明文文件 [plain]（内容 [sha]）写进新根的内容目录（加密位置先按 sha 封成分块格式）。
  Future<void> _storePlainFile(File plain, String sha) async {
    final String path = srsMediaContentPath(target, sha);
    final SrsMediaCipher? c = cipher;
    if (c == null) {
      await srsLocationPutNewFile(current, path, plain);
    } else {
      final File sealed = _scratch('seal');
      try {
        if (await c.sealFile(sha, plain, sealed) != sha) {
          throw StateError('migrated media changed while sealing: $sha');
        }
        await srsLocationPutNewFile(current, path, sealed);
      } finally {
        await _drop(sealed);
      }
    }
    _stored.add(sha);
    out.media++;
  }

  /// 按名字存的旧文件（明文已在 [plain]）：按内容写进新根，名字没人绑过就补绑定，旧文件 [oldPath] 绑定之后删
  /// （[oldPath] 为 null = 由调用方删，写入者目录）。
  Future<void> _byName(String name, File plain, String? oldPath) async {
    if (!srsIsBareMediaName(name)) return;
    final String sha = await srsMediaSha256File(plain);
    await _storePlainFile(plain, sha);
    _binds.add(<String, Object?>{
      'name': name,
      'sha': sha,
      'size': await plain.length(),
    });
    if (oldPath != null) _afterBind.add(oldPath);
  }

  /// 旧根上的明文媒体目录：按名字存的（协议 1）与内容寻址的（`<前2>/<sha>`，可疑标记一并清掉）。
  Future<void> plainFolder(String folder, List<String> doomed) async {
    final List<SrsLocationEntry> entries = await v1.list(folder);
    final List<String> byName = <String>[
      for (final SrsLocationEntry e in entries)
        if (!e.isFolder) e.name,
    ];
    await srsRunPooled(byName, kSrsSync2Concurrency, (String name) async {
      final File tmp = _scratch('plain');
      try {
        if (!await srsLocationGetFile(v1, '$folder/$name', tmp)) return;
        await _byName(name, tmp, '$folder/$name');
      } finally {
        await _drop(tmp);
      }
    });
    for (final SrsLocationEntry d in entries) {
      if (!d.isFolder || d.name.length != 2) continue;
      final List<String> names = <String>[
        for (final SrsLocationEntry f in await v1.list('$folder/${d.name}'))
          if (!f.isFolder) f.name,
      ];
      await srsRunPooled(names, kSrsSync2Concurrency, (String name) async {
        final String path = '$folder/${d.name}/$name';
        if (name.length != 64) {
          // 可疑标记（`<sha>.suspect`）：新根上读者会重新核对，标记不搬。
          if (name.endsWith(kSrsMediaSuspectSuffix)) doomed.add(path);
          return;
        }
        final File tmp = _scratch('obj');
        try {
          if (!await srsLocationGetFile(v1, path, tmp)) return;
          // 内容寻址对象按它真实的内容存（对不上名字的是坏对象：按真实哈希存下，不丢字节，也不会冒充那份内容）。
          await _storePlainFile(tmp, await srsMediaSha256File(tmp));
          doomed.add(path);
        } finally {
          await _drop(tmp);
        }
      });
    }
  }

  /// 旧根上的 `media-e/<密钥指纹>/`：本机密钥的按名字存的整份封装解开重封、内容寻址的分块封装原样搬；别的密钥的
  /// （换过密钥留下的）解不开，原样搬到新根同一路径。
  Future<void> sealedFolders(List<String> doomed) async {
    final SrsMediaCipher? c = cipher;
    for (final SrsLocationEntry fp in await v1.list(kSrsSealedMediaFolder)) {
      if (!fp.isFolder) continue;
      final String dir = '$kSrsSealedMediaFolder/${fp.name}';
      final bool mine = c != null && c.folder == dir;
      final List<SrsLocationEntry> entries = await v1.list(dir);
      if (!mine) {
        await _copyTree(dir, entries, doomed);
        continue;
      }
      final List<String> byName = <String>[
        for (final SrsLocationEntry e in entries)
          if (!e.isFolder) e.name,
      ];
      await srsRunPooled(byName, kSrsSync2Concurrency, (String name) async {
        final Uint8List? sealed = await v1.get('$dir/$name');
        if (sealed == null) return;
        final Uint8List? plain = await _openV1(name, sealed);
        if (plain == null) {
          out.skipped.add('$dir/$name');
          return;
        }
        final File tmp = _scratch('v1');
        try {
          await tmp.writeAsBytes(plain, flush: true);
          await _byName(name, tmp, '$dir/$name');
        } finally {
          await _drop(tmp);
        }
      });
      for (final SrsLocationEntry d in entries) {
        if (!d.isFolder) continue;
        final List<String> names = <String>[
          for (final SrsLocationEntry f in await v1.list('$dir/${d.name}'))
            if (!f.isFolder) f.name,
        ];
        await srsRunPooled(names, kSrsSync2Concurrency, (String name) async {
          final String path = '$dir/${d.name}/$name';
          if (name.length == 64) {
            final File tmp = _scratch('obj');
            try {
              if (!await srsLocationGetFile(v1, path, tmp)) return;
              await srsLocationPutNewFile(current, path, tmp);
              _stored.add(name);
              out.media++;
            } finally {
              await _drop(tmp);
            }
          }
          doomed.add(path);
        });
      }
    }
  }

  /// [dir] 下的整棵树原样写到新根同一路径（解不开的别的密钥的媒体）。
  Future<void> _copyTree(
    String dir,
    List<SrsLocationEntry> entries,
    List<String> doomed,
  ) async {
    for (final SrsLocationEntry e in entries) {
      final String path = '$dir/${e.name}';
      if (e.isFolder) {
        await _copyTree(path, await v1.list(path), doomed);
        continue;
      }
      final File tmp = _scratch('copy');
      try {
        if (!await srsLocationGetFile(v1, path, tmp)) continue;
        await srsLocationPutNewFile(current, path, tmp);
        doomed.add(path);
      } finally {
        await _drop(tmp);
      }
    }
  }

  /// 协议 1 的整份封装解开（内核 `open_v1`，AAD = 文件名）；解不开为 null。
  Future<Uint8List?> _openV1(String name, Uint8List sealed) async {
    final SrsSync2Result r = await host.sync2Command(
      <String, Object?>{'op': 'open_v1', 'key': keyHex, 'name': name},
      blobs: <Uint8List>[sealed],
    );
    if (r.map['failure'] != null || r.files.isEmpty) return null;
    return r.files.single.$2;
  }

  /// 一个写入者目录的媒体搬完：返回 true = 全部搬成，整个目录可以删。
  Future<bool> writer(SrsV1Writers writers, String w) async {
    bool all = true;
    final List<String> names = await writers.mediaNames(w);
    await srsRunPooled(names, kSrsSync2Concurrency, (String name) async {
      final File tmp = _scratch('writer');
      try {
        if (!await writers.getMedia(w, name, tmp)) return;
        await _byName(name, tmp, null);
      } on Object {
        all = false;
        out.skipped.add('$w/media/$name');
      } finally {
        await _drop(tmp);
      }
    });
    return all;
  }

  /// 补绑定、记「在」，把按名字存的旧文件并进待删清单（绑定写进日志之后才删）。
  Future<void> finish() async {
    if (_binds.isNotEmpty) {
      final Map<String, Object?> r = (await host.sync2Command(<String, Object?>{
        'op': 'media_bind_unbound',
        'items': _binds,
        'now': nowMs(),
      })).map;
      out.bound += (r['appended'] as int?) ?? 0;
    }
    final String? loc = presence;
    if (loc != null && _stored.isNotEmpty) {
      await host.sync2Command(<String, Object?>{
        'op': 'media_record',
        'location': srsMediaContentPresenceKey(loc, target),
        'present': _stored.toList(),
        'absent': const <String>[],
        'suspect': const <String>[],
        'seeded': false,
        'now': nowMs(),
      });
    }
  }

  /// 绑定补上之后才能删的旧文件。
  List<String> get afterBind => _afterBind;
}
