/// 同步 v2 协议 2 的位置准备与 v1 位置的一次性迁移（2026-10-30 格式断代，所有者拍板：一次性断代，旧客户端不能借机
/// 损坏数据、不能往加密位置写明文）。
///
/// **两个集合根**（srs_location_store.dart）：协议 2 的数据在 `fushi-srs/<uid>/v3/`（[kSrsSync2Folder]）；协议 1 的
/// 旧根 `fushi-srs/<uid>/v2/`（[kSrsSync2V1Folder]）。
///
/// **围栏 = 旧根上的一个文件**（[srsEncodeV1Fence]）：`v2/meta.json` 换成「[kSrsV1FenceMagic] + JSON」——旧版本
/// （develop@d407ae22ca）的握手 `jsonDecode` 失败，报 `meta.json unavailable`，整轮在写任何东西之前返回 error：
/// - 文件夹位置：同步 / 归档用途在 `ops.error != null` 时直接返回，只做媒体的位置握手出错同样返回——旧版本在
///   **needsUpgrade** 时仍会跑的明文媒体对账走不到（以前用 `minReader` 围栏就是栽在这里）；
/// - 云盘 / 互联通道：调度器有错误就不跑媒体、不发布 profile 说明。
/// 只改一个文件，所以经 Syncthing 等同步工具转发、跨文件到达顺序不保证时也没有「半个围栏」：旧版本要么看到完整的 v1
/// 旧根（照旧做 v1 的事，只碰旧根、按旧 meta 的加密设定），要么看到围栏停下。meta 缺失才会让旧版本新建集合，所以围栏
/// 从不删、新版本对每个位置（包括全新的）都先立。代价：旧版本只显示「位置不可用」/「meta 不可用」，不提示升级。
///
/// **迁移**（[srsPrepareLocation]，每一步幂等，进度就是位置本身的状态，中断后任何一台新版本设备接着做）：
/// 1. 围栏；
/// 2. 只读导入旧根上的段（媒体绑定要看到全部已有绑定，下一步才不会抢别人的；不记这个位置的 head / 转发账）；
/// 3. 段 / head / 转发件 / 说明文件**原样**写进新根，写完重读、按字节核对；
/// 4. 媒体按内容写进新根的内容目录（明文 `media/<前2>/<sha>`，加密位置 `media-e/<指纹>/…` 按 sha 重新封），写之前先查、
///    写完下载核对内容；按名字存的旧文件（明文 / 整份封装 / 写入者目录）给没人绑过的名字补绑定；
/// 5. 新根的 `meta.json`（只由旧 meta 决定，并发迁移的设备写出同一份）；
/// 6. 删旧文件：只删新根上**按内容核对过**的；按名字存的旧文件（名字 → sha 只记在绑定里）要等本机日志确认已发布到
///    位置之后才删（[srsFinishLocationMigration]，一轮同步成功之后调）。
///
/// 已迁移的判据持久在位置上：旧根的 [kSrsV1SweepMarker] 记下最后一次完整处理时旧根的文件清单指纹——此后只列目录比指纹
/// （不拉段、不动转发账、不重新封），清单变了（同步工具晚到的旧文件）才再做一遍。归档位置只复制不删（§10.3）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;
import 'package:path/path.dart' as p;

/// 围栏 meta 开头的魔数：不是合法 JSON 的开头，旧版本解析失败；新版本认它、读后面的 JSON。
const String kSrsV1FenceMagic = 'FUSHI-SRS-MOVED-TO-V3\n';

/// 围栏 JSON 里的字段：数据挪到了哪个根（[kSrsSync2Folder]）。
const String kSrsV1MovedToKey = 'movedTo';

/// 旧根上的「已处理」标记文件：`{"listing": <旧根文件清单指纹>, "at": <毫秒>}`（旧版本不读它）。
const String kSrsV1SweepMarker = 'migrated.json';

/// 本进程里已经确认旧根处理完的位置（进程重启后的第一轮再看一眼旧根的清单指纹）。调度器持有一份；不给 = 每轮都看。
class SrsLocationMigrationMemo {
  final Set<String> _swept = <String>{};

  bool swept(String profileUid, String locationId) =>
      _swept.contains('$profileUid|$locationId');

  void markSwept(String profileUid, String locationId) =>
      _swept.add('$profileUid|$locationId');
}

/// [srsPrepareLocation] 的结论。
class SrsLocationPrepared {
  /// 位置来自更新的版本：什么都没写。
  bool needsUpgrade = false;

  /// 这个位置这一轮不同步的原因（握手同一套错误）；null = 可以在新根上跑一轮。
  String? error;

  /// 新根已在用时，处理旧根残留失败的原因（读失败 / 解不开 / 新根的口令问题）：不挡新根的同步，下一轮再试。
  /// 调用方必须记日志（[leftoverCause] / [leftoverStack] 是抛出来的原始错误与栈；口令问题没有异常，二者为 null）。
  String? leftoverError;

  /// [leftoverError] 来自异常时的原始错误。
  Object? leftoverCause;

  /// [leftoverCause] 的栈。
  StackTrace? leftoverStack;

  /// [srsFinishLocationMigration] 删旧文件时逐个出的错（读 / 删失败）：这些文件留在待删里下一轮再删，不让已经成功的
  /// 一轮同步报失败；调用方必须记日志。
  final List<(Object, StackTrace)> cleanupErrors = <(Object, StackTrace)>[];

  /// 旧根 `meta.json` 上的加密参数（要口令时 UI 用）。
  SrsKdf? kdf;

  /// 这一轮处理了旧根上的文件。
  bool migrated = false;

  /// 原样写进新根的段 / head / 转发件 / 说明文件数（已在的不算）。
  int copied = 0;

  /// 核对过、在新根上的媒体数（含早就在的）。
  int media = 0;

  /// 补上的媒体绑定数。
  int bound = 0;

  /// 删掉的旧文件数。
  int deleted = 0;

  /// 留在旧根、下次再试的（解不开 / 新根上同名而内容不同）。
  final List<String> skipped = <String>[];

  /// 导入旧段时的非致命错误。
  final List<String> errors = <String>[];

  /// 按名字存的旧文件（旧根路径 → 迁移时读到的原始字节的 sha256）：内容已核对在新根，等绑定发布后由
  /// [srsFinishLocationMigration] 删。删之前按这个 sha 再核对一次——名字是可变的，迁移之后同名文件被换成了别的内容
  /// （同步工具晚到的旧版本写入）就不能删，留给下一次准备重新搬。
  final Map<String, String> deferred = <String, String>{};

  /// 同上，写入者目录里的（写入者, 文件名）→ 原始字节的 sha256。
  final Map<(String, String), String> deferredWriters =
      <(String, String), String>{};

  /// 补绑定之后本机日志的最后一个 seq：位置上传水位到了它，绑定就已发布。
  int? publishSeq;
}

/// 协议 1 之前的旧同步引擎的写入者目录（`fushi-srs/<uid>/<写入者>/`，只有云盘 / 互联通道上有）：迁移只读它们的
/// `media/`，逐个文件搬、逐个文件删（目录本身与别的内容不动）。
abstract interface class SrsV1Writers {
  /// 全部写入者目录名。
  Future<List<String>> writers();

  /// [writer] 的 `media/` 下的文件名。
  Future<List<String>> mediaNames(String writer);

  /// 把 [writer] 的 `media/<name>` 下载到 [dst]。已经不在（别的设备搬完删了）返回 false；读失败（网络 / 限流）**抛出**，
  /// 不能当成不在——那样调用方会当它搬完了。
  Future<bool> getMedia(String writer, String name, File dst);

  /// 删掉 [writer] 的 `media/<name>`（不在视为成功）。
  Future<void> deleteMedia(String writer, String name);
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

  Future<Map<String, String>> _list(String writer) async {
    final String? id = _writerIds[writer];
    final Map<String, String> files = <String, String>{};
    if (id != null) {
      for (final AssetEntry m in await store.listChildren(id)) {
        if (!m.isFolder || m.name != kSrsMediaFolder) continue;
        for (final AssetEntry f in await store.listChildren(m.id)) {
          if (!f.isFolder) files.putIfAbsent(f.name, () => f.id);
        }
      }
    }
    return _media[writer] = files;
  }

  @override
  Future<List<String>> mediaNames(String writer) async =>
      (await _list(writer)).keys.toList()..sort();

  /// 本实例还没列过 [writer] 就先列（收尾可能在另一个实例上跑）：没列过不等于「不在」。
  Future<void> _ensureListed(String writer) async {
    if (_media.containsKey(writer)) return;
    if (!_writerIds.containsKey(writer)) await writers();
    await _list(writer);
  }

  @override
  Future<bool> getMedia(String writer, String name, File dst) async {
    await _ensureListed(writer);
    final String? id = _media[writer]?[name];
    if (id == null) return false;
    try {
      await store.getAsset(id, dst);
      return true;
    } on Object {
      // 只有重新列目录确认它已经不在，才算「别的设备搬完删了」；还在就是读失败，原样抛出。
      if (!(await _list(writer)).containsKey(name)) return false;
      rethrow;
    }
  }

  @override
  Future<void> deleteMedia(String writer, String name) async {
    // 收尾可能在另一个实例上跑（没列过目录）：先列，只删这一个名字现在对应的那个文件。
    await _ensureListed(writer);
    final String? id = _media[writer]?[name];
    if (id != null) await store.deleteAsset(id);
  }
}

/// 围栏 meta 的字节：[kSrsV1FenceMagic] + JSON。
Uint8List srsEncodeV1Fence(Map<String, Object?> meta) =>
    Uint8List.fromList(utf8.encode('$kSrsV1FenceMagic${jsonEncode(meta)}'));

/// [bytes] 是围栏就交回它的 JSON（JSON 部分坏了交回空表），不是围栏为 null。
Map<String, Object?>? srsDecodeV1Fence(Uint8List bytes) {
  final List<int> magic = utf8.encode(kSrsV1FenceMagic);
  if (bytes.length < magic.length) return null;
  for (int i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return null;
  }
  try {
    final Object? j = jsonDecode(utf8.decode(bytes.sublist(magic.length)));
    return j is Map ? j.cast<String, Object?>() : <String, Object?>{};
  } on FormatException {
    return <String, Object?>{};
  }
}

/// 围栏的 JSON：旧 meta 的全部字段（集合身份、创建时刻、`kdf`）照留，记下本协议、数据挪到了哪、何时围的。
Map<String, Object?> srsV1FenceMeta(Map<String, Object?> old, int nowMs) =>
    <String, Object?>{
      ...old,
      'v': kSrsSync2Protocol,
      'minReader': kSrsSync2MinReader,
      kSrsV1MovedToKey: kSrsSync2Folder,
      'fencedAt': nowMs,
    };

/// 迁移写的新根 `meta.json`：只由围栏决定（集合身份、创建时刻、`kdf`），并发迁移的设备写出的字节相同。
Map<String, Object?> srsV2MetaFromV1(
  Map<String, Object?> fence,
  Object? collection,
  int nowMs,
) => <String, Object?>{
  'v': kSrsSync2Protocol,
  'minReader': kSrsSync2MinReader,
  'collection': fence['collection'] ?? collection,
  'createdAt': fence['createdAt'] ?? fence['fencedAt'] ?? nowMs,
  if (fence['kdf'] != null) 'kdf': fence['kdf'],
};

/// 新根 `meta.json` 读的结果：不在（null）、坏的（[_kBadMeta]）或对象。
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

enum _V1Kind { absent, bad, v1, fenced }

Future<({_V1Kind kind, Map<String, Object?> meta})> _readV1(
  SrsLocationStore v1,
) async {
  final Uint8List? bytes = await v1.get('meta.json');
  if (bytes == null) return (kind: _V1Kind.absent, meta: <String, Object?>{});
  final Map<String, Object?>? fence = srsDecodeV1Fence(bytes);
  if (fence != null) return (kind: _V1Kind.fenced, meta: fence);
  try {
    final Object? j = jsonDecode(utf8.decode(bytes));
    if (j is Map) return (kind: _V1Kind.v1, meta: j.cast<String, Object?>());
  } on FormatException {
    // 落到下面。
  }
  return (kind: _V1Kind.bad, meta: <String, Object?>{});
}

int _minReaderOf(Map<String, Object?> meta) {
  final Object? v = meta['minReader'];
  return v is num ? v.toInt() : 1;
}

/// 集合根上除了 `meta.json`（与迁移自己写的 [kSrsV1SweepMarker]，它不是集合数据）之外还有没有东西。
Future<bool> _hasData(SrsLocationStore s) async {
  for (final SrsLocationEntry e in await s.list('')) {
    if (!e.isFolder && (e.name == 'meta.json' || e.name == kSrsV1SweepMarker)) {
      continue;
    }
    if (e.isFolder && (await _files(s, e.name)).isEmpty) continue;
    return true;
  }
  return false;
}

/// [dir] 下的全部文件（递归），`(路径, 字节数)`；根目录的 `meta.json` 与 [kSrsV1SweepMarker] 不算。
Future<List<(String, int?)>> _files(SrsLocationStore s, String dir) async {
  final List<(String, int?)> out = <(String, int?)>[];
  for (final SrsLocationEntry e in await s.list(dir)) {
    final String path = dir.isEmpty ? e.name : '$dir/${e.name}';
    if (e.isFolder) {
      out.addAll(await _files(s, path));
    } else if (dir.isNotEmpty ||
        (e.name != 'meta.json' && e.name != kSrsV1SweepMarker)) {
      out.add((path, e.size));
    }
  }
  return out;
}

String _fingerprint(
  List<(String, int?)> files,
  Map<String, List<String>> writerMedia,
) {
  final List<String> lines = <String>[
    for (final (String, int?) f in files) '${f.$1}\t${f.$2 ?? ''}',
    for (final MapEntry<String, List<String>> w in writerMedia.entries)
      for (final String n in w.value) 'writer:${w.key}/$n',
  ]..sort();
  return sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

Future<String?> _markerOf(SrsLocationStore v1) async {
  final Uint8List? b = await v1.get(kSrsV1SweepMarker);
  if (b == null) return null;
  try {
    final Object? j = jsonDecode(utf8.decode(b));
    return j is Map ? j['listing'] as String? : null;
  } on FormatException {
    return null;
  }
}

/// 按 [meta] 的 `kdf` 定密钥（与 [srsLocationHandshake] 同一套判断，但只读、不写 meta）。
({String? keyHex, String? error, SrsKdf? kdf}) _keyFor(
  Map<String, Object?> meta,
  SrsLocationKey? key,
) {
  final Object? kdfJson = meta['kdf'];
  if (kdfJson == null) {
    // 本机开过加密而 meta 上没有 kdf：不降级成明文（与握手相同）。本机刚开的照常按明文读。
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

/// 准备一个位置跑协议 2 的一轮：确保旧根上的围栏在，必要时把旧根上的数据迁进新根（见库注释）。[v1] / [current] 是同一个
/// 位置的旧根与新根；[recordPresence] = 位置的媒体「有什么」记日志（云盘 / 互联通道）；[writers] = 协议 1 之前的写入者
/// 目录（只有通道上有）；[removeEmptyDirs] = 删完旧文件后清空目录（文件夹位置）；[archive] = 归档位置（只复制、不删）。
///
/// 新根还没有 meta（迁移是这一轮能同步的前提）时出错照常抛出；新根已在用时，处理旧根残留出的任何错都只记进
/// [SrsLocationPrepared.leftoverError]，不挡新根的同步。
Future<SrsLocationPrepared> srsPrepareLocation({
  required SrsSync2Host host,
  required SrsLocationStore v1,
  required SrsLocationStore current,
  required String locationId,
  required SrsLocationKey? key,
  required int Function() nowMs,
  bool recordPresence = false,
  SrsV1Writers? writers,
  Future<void> Function()? removeEmptyDirs,
  SrsLocationMigrationMemo? memo,
  bool archive = false,
  SrsSyncStepCallback? onStep,
}) async {
  final SrsLocationPrepared out = SrsLocationPrepared();
  onStep?.call('migrate:meta');
  final Object? cur = await _readMeta(current);
  if (identical(cur, _kBadMeta)) {
    out.error = kSrsSync2MetaUnavailable;
    return out;
  }
  if (cur is Map<String, Object?> && _minReaderOf(cur) > kSrsSync2Protocol) {
    out.needsUpgrade = true;
    return out;
  }
  final Map<String, Object?>? v3Meta = cur as Map<String, Object?>?;
  // 本进程已经扫干净的位置同样要走第 1 步：每一轮都确认围栏还在（被删 / 被同步工具换回旧 meta 时重立并接着迁移），
  // 只是围栏在时不再列旧根（见 [_Migration.run]）。
  final _Migration m = _Migration(
    host: host,
    v1: v1,
    current: current,
    locationId: locationId,
    key: key,
    nowMs: nowMs,
    recordPresence: recordPresence,
    writers: writers,
    removeEmptyDirs: removeEmptyDirs,
    memo: memo,
    archive: archive,
    v3Meta: v3Meta,
    out: out,
    onStep: onStep,
  );
  if (v3Meta == null) {
    await m.run();
    return out;
  }
  try {
    await m.run();
  } on Object catch (e, stack) {
    // 不挡新根的同步，但不吞：原始错误与栈交给调用方记日志（srs_sync_scheduler.dart 两条路径都记）。
    out
      ..leftoverError = '$e'
      ..leftoverCause = e
      ..leftoverStack = stack;
  }
  return out;
}

/// 一轮同步成功之后：按名字存的旧文件，绑定已发布到位置（[progressId] 的上传水位到了
/// [SrsLocationPrepared.publishSeq]；[progressId] 为 null = 只做媒体的位置，任何一个位置到了都算）就删掉。归档位置
/// 不会有待删的。返回删掉的个数。
Future<int> srsFinishLocationMigration({
  required SrsSync2Host host,
  required SrsLocationStore v1,
  required SrsLocationPrepared prepared,
  required String? progressId,
  SrsV1Writers? writers,
  Future<void> Function()? removeEmptyDirs,
}) async {
  final int? seq = prepared.publishSeq;
  if (seq == null ||
      (prepared.deferred.isEmpty && prepared.deferredWriters.isEmpty)) {
    return 0;
  }
  final Map<String, Object?> status = (await host.sync2Command(
    <String, Object?>{'op': 'status'},
  )).map;
  bool published = false;
  for (final Object? l
      in (status['locations'] as List<Object?>?) ?? const <Object?>[]) {
    if (l is! Map) continue;
    if (progressId != null && l['location'] != progressId) continue;
    if (((l['uploaded'] as num?)?.toInt() ?? 0) >= seq) published = true;
  }
  if (!published) return 0;
  int n = 0;
  final Map<String, String> kept = <String, String>{};
  // 逐个文件：一个读 / 删失败只留下它自己（下一轮再删），记进 cleanupErrors，不让这一轮已经成功的同步报失败。
  await srsRunPooled(prepared.deferred.entries.toList(), kSrsSync2Concurrency, (
    MapEntry<String, String> e,
  ) async {
    try {
      final String? now = await _rawSha(
        (File dst) => srsLocationGetFile(v1, e.key, dst),
      );
      if (now == null) {
        n++; // 已经不在（别的设备收尾删了）。
      } else if (now != e.value) {
        // 迁移之后同名文件换了内容：搬进新根、绑上的是旧内容，这份没人搬过——不删，下一次准备重新搬。
        prepared.skipped.add(e.key);
      } else if (await _deleteOld(v1, e.key)) {
        n++;
      } else {
        kept[e.key] = e.value;
      }
    } on Object catch (err, stack) {
      kept[e.key] = e.value;
      prepared.cleanupErrors.add((err, stack));
    }
  });
  final Map<(String, String), String> keptWriters =
      <(String, String), String>{};
  for (final MapEntry<(String, String), String> e
      in prepared.deferredWriters.entries) {
    final (String w, String name) = e.key;
    try {
      final String? now = await _rawSha(
        (File dst) => writers!.getMedia(w, name, dst),
      );
      if (now == null) {
        n++;
      } else if (now != e.value) {
        prepared.skipped.add('$w/media/$name');
      } else {
        await writers!.deleteMedia(w, name);
        n++;
      }
    } on Object catch (err, stack) {
      keptWriters[e.key] = e.value;
      prepared.cleanupErrors.add((err, stack));
    }
  }
  // 没删掉的留在待删里：这一进程下一轮收尾再删；进程重启了就由下一次准备重新核对、重新排队。
  prepared.deferred
    ..clear()
    ..addAll(kept);
  prepared.deferredWriters
    ..clear()
    ..addAll(keptWriters);
  prepared.deleted += n;
  try {
    await removeEmptyDirs?.call();
  } on Object catch (err, stack) {
    prepared.cleanupErrors.add((err, stack));
  }
  return n;
}

/// 用 [fetch] 把一个旧文件下载到临时文件，交回原始字节的 sha256；已经不在为 null。
Future<String?> _rawSha(Future<bool> Function(File dst) fetch) async {
  final File f = File(
    p.join(
      Directory.systemTemp.path,
      'fushi_srs_migrate_check_${DateTime.now().microsecondsSinceEpoch}_'
      '${Random().nextInt(1 << 30)}',
    ),
  );
  try {
    if (!await fetch(f)) return null;
    return await srsMediaSha256File(f);
  } finally {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // 临时文件留给系统清理。
    }
  }
}

/// 删一个内容已经核对过的旧文件。删不掉（Windows 上别的设备此刻正开着它读——同时迁移的另一台新版本、同步工具）
/// 交回 false，留着下次删；之后它还在就重新核对。已经不在（别人删了）算删掉。
Future<bool> _deleteOld(SrsLocationStore v1, String path) async {
  try {
    await v1.delete(path);
    return true;
  } on PathAccessException {
    return !await v1.exists(path);
  }
}

/// 文件夹位置迁移收尾：删掉旧根下已经空了的目录（自底向上、只删空目录——同步工具这时带回来的文件不会被一起删掉）。
/// 根目录本身与 `meta.json` 不动。
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
      // 非递归：期间有人写进来就删不掉，留着。
      await d.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  if (await v1Root.exists()) await prune(v1Root);
}

class _Migration {
  _Migration({
    required this.host,
    required this.v1,
    required this.current,
    required this.locationId,
    required this.key,
    required this.nowMs,
    required this.recordPresence,
    required this.writers,
    required this.removeEmptyDirs,
    required this.memo,
    required this.archive,
    required this.v3Meta,
    required this.out,
    this.onStep,
  });

  final SrsSync2Host host;
  final SrsLocationStore v1;
  final SrsLocationStore current;
  final String locationId;
  final SrsLocationKey? key;
  final int Function() nowMs;
  final bool recordPresence;
  final SrsV1Writers? writers;
  final Future<void> Function()? removeEmptyDirs;
  final SrsLocationMigrationMemo? memo;
  final bool archive;

  /// 新根的 meta；null = 新根还没在用。
  final Map<String, Object?>? v3Meta;
  final SrsLocationPrepared out;

  /// 诊断用的细分步骤（见 [SrsSyncStepCallback]），一律带 `migrate:` 前缀。
  final SrsSyncStepCallback? onStep;

  void _step(String step) => onStep?.call('migrate:$step');

  bool get ready => v3Meta != null;

  Future<Object?> _identity() async => (await host.sync2Command(
    <String, Object?>{'op': 'identity', 'now': nowMs()},
  )).map['collection'];

  void _markSwept() => memo?.markSwept(host.profileUid, locationId);

  Future<void> run() async {
    // 1. 围栏。
    _step('fence');
    final ({_V1Kind kind, Map<String, Object?> meta}) old = await _readV1(v1);
    final Map<String, Object?> fence;
    switch (old.kind) {
      case _V1Kind.bad:
        // 旧根的 meta 是认不出的东西：旧版本同样读不了（停下）。新根已在用就照常同步，否则不知道该迁什么。
        if (!ready) out.error = kSrsSync2MetaUnavailable;
        return;
      case _V1Kind.absent:
        if (await _hasData(v1)) {
          // 有旧数据却读不到 meta（最终一致的列目录还没看到 / 被删）：不围栏、不迁移，下一轮再看。
          if (!ready) out.error = kSrsSync2MetaUnavailable;
          return;
        }
        // 全新的位置（或旧根已清空）：立围栏，旧版本不能在旧根上新建 v1 集合。
        fence = srsV1FenceMeta(<String, Object?>{
          'collection': await _identity(),
          'createdAt': nowMs(),
        }, nowMs());
        await v1.putNew('meta.json', srsEncodeV1Fence(fence));
      case _V1Kind.v1:
        if (_minReaderOf(old.meta) > 1) {
          // 旧根上是本机不认识的更新格式。
          if (!ready) out.needsUpgrade = true;
          return;
        }
        if (!ready) {
          // 新根还没在用：本机解不开就先不围（围了却迁不了，旧版本白白停下），口令问题照握手报。
          final ({String? keyHex, String? error, SrsKdf? kdf}) k = _keyFor(
            old.meta,
            key,
          );
          out.kdf = k.kdf;
          if (k.error != null) {
            out.error = k.error;
            return;
          }
        }
        // 新根已在用时一律先围（旧版本重建了 v1 集合，必须马上挡住），解不开的残留留到有口令的设备。
        fence = srsV1FenceMeta(old.meta, nowMs());
        await v1.put('meta.json', srsEncodeV1Fence(fence));
      case _V1Kind.fenced:
        fence = old.meta;
        // 围栏原本就在、本进程已经扫干净过：不再列旧根（围栏不在时上面已经重立，接着把旧版本这段时间写的迁走）。
        if (ready && (memo?.swept(host.profileUid, locationId) ?? false)) {
          return;
        }
    }

    // 旧根上还有什么（只列目录）。
    _step('list');
    final Map<String, List<String>> writerMedia = <String, List<String>>{};
    final SrsV1Writers? ws = writers;
    if (ws != null) {
      for (final String w in await ws.writers()) {
        final List<String> names = await ws.mediaNames(w);
        if (names.isNotEmpty) writerMedia[w] = names;
      }
    }
    final List<(String, int?)> files = await _files(v1, '');
    if (files.isEmpty && writerMedia.isEmpty) {
      if (!ready) {
        if (await _hasData(current)) {
          // 迁移早已做完（旧根空了），新根有数据却读不到 meta（被删 / 同步工具还没带过来）：与握手同一条规矩——
          // 不替一份可能还在的 meta 重写（重写会换掉集合身份 / 加密参数），这一轮不同步。
          out.error = kSrsSync2MetaUnavailable;
          return;
        }
        await current.putNew(
          'meta.json',
          utf8.encode(
            jsonEncode(srsV2MetaFromV1(fence, await _identity(), nowMs())),
          ),
        );
      }
      _markSwept();
      return;
    }
    _step('listed files=${files.length} writers=${writerMedia.length}');
    final String listing = _fingerprint(files, writerMedia);
    if (ready && await _markerOf(v1) == listing) {
      // 上次完整处理之后旧根没变（归档位置 / 解不开留下的）：不拉段、不封、不重写。
      _markSwept();
      return;
    }

    // 密钥：读旧根按旧根的 kdf；写新根按新根的 kdf（新根已在用时以它为准——迁移之后才开 / 换的加密）。
    final ({String? keyHex, String? error, SrsKdf? kdf}) read = _keyFor(
      fence,
      key,
    );
    out.kdf ??= read.kdf;
    if (!ready && read.error != null) {
      out.error = read.error;
      return;
    }
    final String? readKey = read.error == null ? read.keyHex : null;
    final String? writeKey;
    if (ready) {
      final ({String? keyHex, String? error, SrsKdf? kdf}) w = _keyFor(
        v3Meta!,
        key,
      );
      if (w.error != null) {
        // 新根的口令问题由新根的握手报；残留这一轮不碰（不往加密的新根写明文）。
        out.leftoverError = w.error;
        return;
      }
      writeKey = w.keyHex;
    } else {
      // 新根的 meta 照抄围栏：旧根加密就是同一把；旧根明文而本机刚开加密，这一轮的握手会写上 kdf——媒体直接按它封。
      writeKey =
          readKey ?? ((key != null && key!.pendingEnable) ? key!.keyHex : null);
    }
    out.migrated = true;

    // 2. 只读导入旧根上的段：不记这个位置的 head / 转发账（progressId 为 null），只为看到已有的媒体绑定。
    // 没读全（解不开 / 部分段拉取失败）就不知道哪些名字已经有人绑过：这一轮按名字存的旧文件一个都不补绑定、不排删，
    // 留在旧根等下一轮读全了再做（内容寻址的照常搬，它们不靠绑定）。
    bool bindingsSeen = false;
    if (readKey != null || fence['kdf'] == null) {
      final SrsSync2Report pulled = SrsSync2Report();
      final bool whole = await srsSync2Pull(
        host: host,
        location: v1,
        progressId: null,
        keyHex: readKey,
        report: pulled,
        onStep: onStep == null ? null : (String s) => _step('pull:$s'),
      );
      out.errors.addAll(pulled.errors);
      if (pulled.missing > 0) {
        out.errors.add('v1 segments not readable yet: ${pulled.missing}');
      }
      bindingsSeen =
          whole &&
          pulled.errors.isEmpty &&
          pulled.missing == 0 &&
          pulled.error == null;
    }

    final List<String> doomed = <String>[];
    final _MediaMover mover = _MediaMover(
      host: host,
      v1: v1,
      current: current,
      read: readKey == null ? null : SrsMediaCipher(host, readKey),
      write: writeKey == null ? null : SrsMediaCipher(host, writeKey),
      nowMs: nowMs,
      out: out,
      canBind: bindingsSeen,
    );

    // 3. 段 / head / 转发件 / 说明文件原样写进新根，核对字节。
    final List<String> deviceFiles = <String>[];
    final List<String> plainFlat = <String>[];
    final List<String> plainObjects = <String>[];
    final Map<String, List<String>> sealedDirs = <String, List<String>>{};
    // 本轮最初列出、按规矩留在旧根不动的文件（不认识的）：完成标记的指纹只由它们算。
    final List<(String, int?)> untouched = <(String, int?)>[];
    for (final (String, int?) f in files) {
      final List<String> parts = f.$1.split('/');
      if (parts.first == 'devices' && parts.length >= 3) {
        deviceFiles.add(f.$1);
      } else if (parts.first == kSrsMediaFolder && parts.length == 2) {
        plainFlat.add(f.$1);
      } else if (parts.first == kSrsMediaFolder && parts.length == 3) {
        plainObjects.add(f.$1);
      } else if (parts.first == kSrsSealedMediaFolder && parts.length >= 3) {
        (sealedDirs['${parts[0]}/${parts[1]}'] ??= <String>[]).add(f.$1);
      } else {
        // 别的（不认识的文件）不碰。
        untouched.add(f);
      }
    }
    int copiedFiles = 0;
    _step('copy 0/${deviceFiles.length}');
    await srsRunPooled(deviceFiles, kSrsSync2Concurrency, (String path) async {
      final Uint8List? bytes = await v1.get(path);
      if (bytes != null) {
        // bytes == null：别的设备搬完删了，它核对过新副本。
        if (await _ensureBytes(path, bytes)) {
          doomed.add(path);
        } else {
          out.skipped.add(path);
        }
      }
      if (++copiedFiles % 25 == 0 || copiedFiles == deviceFiles.length) {
        _step('copy $copiedFiles/${deviceFiles.length}');
      }
    });

    // 4. 媒体。
    _step(
      'media flat=${plainFlat.length} objects=${plainObjects.length} '
      'sealedDirs=${sealedDirs.length} writers=${writerMedia.length}',
    );
    await mover.plainFlat(plainFlat);
    await mover.plainObjects(plainObjects, doomed);
    for (final MapEntry<String, List<String>> d in sealedDirs.entries) {
      await mover.sealedDir(d.key, d.value, doomed);
    }
    for (final MapEntry<String, List<String>> w in writerMedia.entries) {
      await mover.writer(ws!, w.key, w.value);
    }
    _step('bind');
    await mover.bind(recordPresence ? locationId : null);

    // 5. 新根的 meta：段与媒体都到位之后才写，没有它的新根别的设备不会当成可用（它们接着迁移）。
    if (!ready) {
      await current.putNew(
        'meta.json',
        utf8.encode(
          jsonEncode(srsV2MetaFromV1(fence, await _identity(), nowMs())),
        ),
      );
    }

    // 6. 删旧文件（归档位置一个不删）：核对过的立刻删；按名字存的等绑定发布（srsFinishLocationMigration）。
    _step('delete ${doomed.length}');
    if (!archive) {
      await srsRunPooled(doomed, kSrsSync2Concurrency, (String path) async {
        if (await _deleteOld(v1, path)) {
          out.deleted++;
        } else {
          out.skipped.add(path);
        }
      });
      out.deferred.addAll(mover.byName);
      out.deferredWriters.addAll(mover.byWriter);
      await removeEmptyDirs?.call();
    }
    if (out.skipped.isEmpty &&
        out.deferred.isEmpty &&
        out.deferredWriters.isEmpty) {
      // 记下这一次处理完之后旧根该有的样子；下次进程启动只比清单。指纹只由本轮最初列出的文件算（归档：全部，一个
      // 不删；否则：留着不动的那些）——绝不能拿处理完之后重新列出的清单算：迁移期间同步工具 / 旧版本新带来的文件
      // 本轮没搬过，算进指纹就被当成「已处理」，永远留在旧根、别的设备收不到。
      final String? after = archive
          ? listing
          : await _settledListing(untouched);
      if (after == null) {
        // 处理期间旧根多出了 / 换了文件：不写标记、不记扫干净，下一轮重新列、接着搬。
        return;
      }
      await v1.put(
        kSrsV1SweepMarker,
        utf8.encode(
          jsonEncode(<String, Object?>{'listing': after, 'at': nowMs()}),
        ),
      );
      _markSwept();
    }
  }

  /// 删完之后旧根恰好只剩 [untouched]（路径与大小都对得上）时交回它们的清单指纹；多出 / 换了文件为 null。写入者目录
  /// 不在这里比：非归档位置有写入者媒体就一定有待删的（不会走到写标记），晚到的写入者媒体下次列目录时让指纹对不上。
  Future<String?> _settledListing(List<(String, int?)> untouched) async {
    final Set<String> want = <String>{
      for (final (String, int?) f in untouched) '${f.$1}\t${f.$2 ?? ''}',
    };
    final Set<String> now = <String>{
      for (final (String, int?) f in await _files(v1, ''))
        '${f.$1}\t${f.$2 ?? ''}',
    };
    if (now.length != want.length || !now.containsAll(want)) return null;
    return _fingerprint(untouched, const <String, List<String>>{});
  }

  /// [path] 在新根上的字节与 [bytes] 相同（不在就写，写完重读）。新根上同名而内容不同（半截 / 别的东西）不覆盖——
  /// 不知道哪份是对的，留着旧的、记 skipped。
  Future<bool> _ensureBytes(String path, Uint8List bytes) async {
    Uint8List? there = await current.get(path);
    if (there == null) {
      await current.putNew(path, bytes);
      out.copied++;
      there = await current.get(path);
    }
    return there != null && _same(there, bytes);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 迁移里搬媒体的那一段（第 4 步）。
class _MediaMover {
  _MediaMover({
    required this.host,
    required this.v1,
    required this.current,
    required this.read,
    required this.write,
    required this.nowMs,
    required this.out,
    required this.canBind,
  });

  final SrsSync2Host host;
  final SrsLocationStore v1;
  final SrsLocationStore current;

  /// 旧根上的段读全了（已有的媒体绑定都看得到）：只有这时才给按名字存的旧文件补绑定、排删；否则它们这一轮记 skipped。
  final bool canBind;

  /// 解旧根加密媒体的（旧根的 kdf）；null = 旧根明文或本机没有那把密钥。
  final SrsMediaCipher? read;

  /// 写新根的（新根的 kdf）；null = 新根明文。
  final SrsMediaCipher? write;
  final int Function() nowMs;
  final SrsLocationPrepared out;
  final Random _rand = Random();

  /// 新根上的内容目录。
  String get target => write?.folder ?? kSrsMediaFolder;

  final List<Map<String, Object?>> _binds = <Map<String, Object?>>[];
  final Set<String> _stored = <String>{};

  /// 按名字存的旧文件（内容已核对在新根）→ 原始字节的 sha256，绑定发布后核对一次才删。
  final Map<String, String> byName = <String, String>{};
  final Map<(String, String), String> byWriter = <(String, String), String>{};

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

  Future<T> _withTemp<T>(String tag, Future<T> Function(File f) body) async {
    final File f = _scratch(tag);
    try {
      return await body(f);
    } finally {
      await _drop(f);
    }
  }

  /// 新根上 [sha] 的内容对象在、且内容确实是 [sha]（明文按哈希，加密的解开看哈希）。
  Future<bool> _verified(String sha) => _withTemp('verify', (File got) async {
    if (!await srsLocationGetFile(
      current,
      srsMediaContentPath(target, sha),
      got,
    )) {
      return false;
    }
    final SrsMediaCipher? c = write;
    if (c == null) return await srsMediaSha256File(got) == sha;
    return _withTemp('vplain', (File plain) async {
      return (await c.openFile(sha, got, plain)).sha256 == sha;
    });
  });

  /// 把明文文件 [plain]（内容 [sha]）放进新根并核对：已经在且对就什么都不写（不重新封）；在而不对（半截 / 坏的）按
  /// 内容覆盖——内容寻址，本机这份按哈希就是对的。
  Future<bool> _store(File plain, String sha) async {
    if (_stored.contains(sha) || await _verified(sha)) {
      _stored.add(sha);
      out.media++;
      return true;
    }
    final String path = srsMediaContentPath(target, sha);
    final SrsMediaCipher? c = write;
    await _withTemp('seal', (File sealed) async {
      File src = plain;
      if (c != null) {
        if (await c.sealFile(sha, plain, sealed) != sha) {
          throw StateError('migrated media changed while sealing: $sha');
        }
        src = sealed;
      }
      if (await current.exists(path)) {
        await srsLocationPutFile(current, path, src);
      } else {
        await srsLocationPutNewFile(current, path, src);
      }
    });
    if (!await _verified(sha)) return false;
    _stored.add(sha);
    out.media++;
    return true;
  }

  /// 按名字存的旧文件（明文已在 [plain]）：放进新根，名字记进待绑定。交回明文的 sha256；没放成 / 这一轮不能绑定为
  /// null。
  Future<String?> _byName(String name, File plain) async {
    if (!canBind || !srsIsBareMediaName(name)) return null;
    final String sha = await srsMediaSha256File(plain);
    if (!await _store(plain, sha)) return null;
    _binds.add(<String, Object?>{
      'name': name,
      'sha': sha,
      'size': await plain.length(),
    });
    return sha;
  }

  /// 旧根 `media/<名字>`（协议 1 的明文按名字存）。
  Future<void> plainFlat(List<String> paths) =>
      srsRunPooled(paths, kSrsSync2Concurrency, (String path) async {
        await _withTemp('plain', (File tmp) async {
          if (!await srsLocationGetFile(v1, path, tmp)) return;
          // 明文按名字存：原始字节就是明文。
          final String? sha = await _byName(p.posix.basename(path), tmp);
          if (sha != null) {
            byName[path] = sha;
          } else {
            out.skipped.add(path);
          }
        });
      });

  /// 旧根 `media/<前2>/<sha>`（内容寻址明文）与可疑标记。
  Future<void> plainObjects(List<String> paths, List<String> doomed) =>
      srsRunPooled(paths, kSrsSync2Concurrency, (String path) async {
        final String name = p.posix.basename(path);
        if (name.endsWith(kSrsMediaSuspectSuffix)) {
          // 可疑标记：新根上读者会重新核对，标记不搬。
          doomed.add(path);
          return;
        }
        await _withTemp('obj', (File tmp) async {
          if (!await srsLocationGetFile(v1, path, tmp)) return;
          // 按真实内容存（对不上名字的坏对象按真实哈希存下，不丢字节，也不会冒充那份内容）。
          if (await _store(tmp, await srsMediaSha256File(tmp))) {
            doomed.add(path);
          } else {
            out.skipped.add(path);
          }
        });
      });

  /// 旧根 `media-e/<指纹>/…`：认得这个指纹（旧根或新根的密钥）就解开——按名字的整份封装补绑定、内容寻址的分块封装
  /// 按新根的密钥落地（同一把就原样搬）；认不得（换过密钥留下的）原样搬到新根同一路径。
  Future<void> sealedDir(
    String dir,
    List<String> paths,
    List<String> doomed,
  ) async {
    final SrsMediaCipher? reader = <SrsMediaCipher?>[read, write]
        .whereType<SrsMediaCipher>()
        .where((SrsMediaCipher c) => c.folder == dir)
        .firstOrNull;
    await srsRunPooled(paths, kSrsSync2Concurrency, (String path) async {
      final List<String> parts = path.split('/');
      if (reader == null) {
        if (parts.length == 3) {
          // 按名字的整份封装、本机没有那把密钥：名字 → 内容的对应只能解开才知道，留给有口令的设备。
          out.skipped.add(path);
          return;
        }
        if (await _copyVerbatim(path)) {
          doomed.add(path);
        } else {
          out.skipped.add(path);
        }
        return;
      }
      final String name = parts.last;
      if (parts.length == 3) {
        // 按名字的整份封装（协议 1，AAD = 文件名）。
        final Uint8List? sealed = await v1.get(path);
        if (sealed == null) return;
        final Uint8List? plain = await _openV1(reader.keyHex, name, sealed);
        if (plain == null) {
          out.skipped.add(path);
          return;
        }
        await _withTemp('v1', (File tmp) async {
          await tmp.writeAsBytes(plain, flush: true);
          if (await _byName(name, tmp) != null) {
            // 删前核对的是旧根上的原始字节（封装），不是解开的明文。
            byName[path] = sha256.convert(sealed).toString();
          } else {
            out.skipped.add(path);
          }
        });
        return;
      }
      if (parts.length != 4 || name.length != 64) {
        out.skipped.add(path);
        return;
      }
      if (identical(reader, write) || reader.folder == write?.folder) {
        // 新根同一把密钥：原样搬（别的设备封的同一内容 nonce 不同，按解开后的哈希核对）。
        if (await _copyVerbatim(path) || await _verified(name)) {
          _stored.add(name);
          out.media++;
          doomed.add(path);
        } else {
          out.skipped.add(path);
        }
        return;
      }
      // 旧根的密钥、新根换了一把：解开按新密钥重封。
      final bool ok = await _withTemp('sobj', (File got) async {
        if (!await srsLocationGetFile(v1, path, got)) return false;
        return _withTemp('splain', (File plain) async {
          final SrsMediaOpened o = await reader.openFile(name, got, plain);
          if (o.sha256 != name) return false;
          return _store(plain, name);
        });
      });
      if (ok) {
        doomed.add(path);
      } else {
        out.skipped.add(path);
      }
    });
  }

  /// [path] 原样写到新根同一路径并按字节核对（已在的只核对，不覆盖）。
  Future<bool> _copyVerbatim(String path) =>
      _withTemp('copy', (File src) async {
        if (!await srsLocationGetFile(v1, path, src)) return false;
        final Uint8List want = await src.readAsBytes();
        Uint8List? there = await current.get(path);
        if (there == null) {
          await srsLocationPutNewFile(current, path, src);
          there = await current.get(path);
        }
        return there != null && _same(there, want);
      });

  /// 协议 1 的整份封装解开（内核 `open_v1`）；解不开为 null。
  Future<Uint8List?> _openV1(
    String keyHex,
    String name,
    Uint8List sealed,
  ) async {
    final SrsSync2Result r = await host.sync2Command(
      <String, Object?>{'op': 'open_v1', 'key': keyHex, 'name': name},
      blobs: <Uint8List>[sealed],
    );
    if (r.map['failure'] != null || r.files.isEmpty) return null;
    return r.files.single.$2;
  }

  /// 一个写入者目录的媒体：读失败直接抛出（整个迁移失败、什么都不删）。
  Future<void> writer(SrsV1Writers ws, String w, List<String> names) =>
      srsRunPooled(names, kSrsSync2Concurrency, (String name) async {
        await _withTemp('writer', (File tmp) async {
          if (!await ws.getMedia(w, name, tmp)) return;
          final String? sha = await _byName(name, tmp);
          if (sha != null) {
            byWriter[(w, name)] = sha;
          } else {
            out.skipped.add('$w/media/$name');
          }
        });
      });

  /// 补绑定（只补没人绑过的名字）、记「在」，记下绑定发布的判据（本机日志此刻的最后一个 seq）。
  Future<void> bind(String? presenceLocation) async {
    if (_binds.isNotEmpty) {
      final Map<String, Object?> r = (await host.sync2Command(<String, Object?>{
        'op': 'media_bind_unbound',
        'items': _binds,
        'now': nowMs(),
      })).map;
      out.bound += (r['appended'] as int?) ?? 0;
    }
    if (byName.isNotEmpty || byWriter.isNotEmpty) {
      final Map<String, Object?> status = (await host.sync2Command(
        <String, Object?>{'op': 'status'},
      )).map;
      final int next = (status['nextSeq'] as num?)?.toInt() ?? 1;
      out.publishSeq = next - 1;
    }
    if (presenceLocation != null && _stored.isNotEmpty) {
      await host.sync2Command(<String, Object?>{
        'op': 'media_record',
        'location': srsMediaContentPresenceKey(presenceLocation, target),
        'present': _stored.toList(),
        'absent': const <String>[],
        'suspect': const <String>[],
        'seeded': false,
        'now': nowMs(),
      });
    }
  }
}
