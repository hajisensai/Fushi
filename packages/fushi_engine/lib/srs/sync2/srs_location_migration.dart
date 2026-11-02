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
/// **迁移分两段**，每一步幂等，进度就是位置本身的状态，中断后任何一台新版本设备接着做：
///
/// 一、[srsPrepareLocation]，同步一轮开头（调度器的串行队列里），只做少量、有界的事：
/// 1. 围栏；
/// 2. 旧根的设备段 / head / 转发件 / 说明文件（`devices/` 下，数量少）**原样**写进新根，写完重读、按字节核对，核对过的删；
/// 3. 新根的 `meta.json`（只由旧 meta 决定，并发迁移的设备写出同一份）。新根有了 meta 就能照常同步——媒体不再是前提：
///    大库的旧根上有几万个按名字存的媒体文件（实测 40,493 个），以前要全部搬完才写 meta，一轮永远跑不完、进程一换从头
///    再来，调度器的串行队列被它整个占住，别的位置（互联 host 目录）的同步也跟着停。
///
/// 二、[srsMigrateV1Media]，新根在用之后，**不在同步一轮里**跑（调度器交给 [SrsV1MediaMigrations] 在后台跑，不进串行
/// 队列）：媒体按内容写进新根的内容目录（明文 `media/<前2>/<sha>`，加密位置 `media-e/<指纹>/…` 按 sha 重新封）。
/// - 先分页列一次新根的内容目录建 sha 集合：已在的不再下载核对，没在的从本机算过哈希的明文上传；
/// - 分批：每批一次 `media_bind_unbound` 给没人绑过的名字补绑定（不跟任何设备的绑定抢），请调用方发布；
/// - 按批删：内容寻址的旧文件写进新根就删；按名字存的旧文件（名字 → sha 只记在绑定里）等本机日志确认绑定已发布到
///   位置之后才删，删前重新列目录核对它还是搬的那份（大小 + 修改时间对不上就下载核对原始字节）。
/// 中途进程没了：已删的不在旧根、已传的在新根的 sha 集合里、已补的绑定在本机日志里——下一次只重下还没删的那几批，
/// 旧根越迁越小。
///
/// 已迁移的判据持久在位置上：旧根的 [kSrsV1SweepMarker] 记下最后一次完整处理时旧根的文件清单指纹——此后只列目录比指纹
/// （不下载、不重新封），清单变了（同步工具晚到的旧文件）才再做一遍。归档位置只复制不删（§10.3）。
library;

import 'dart:async';
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

/// [srsMigrateV1Media] 每批处理的文件数：一批一次 `media_bind_unbound`、一次发布请求、一次按批删。
const int kSrsV1MediaBatch = 256;

/// 本进程里已经确认处理完的位置（进程重启后的第一轮再看一眼旧根）。调度器持有一份；不给 = 每轮都看。
class SrsLocationMigrationMemo {
  final Set<String> _swept = <String>{};
  final Set<String> _mediaDone = <String>{};

  /// 旧根的设备段已经处理完（[srsPrepareLocation] 不再列旧根）。
  bool swept(String profileUid, String locationId) =>
      _swept.contains('$profileUid|$locationId');

  void markSwept(String profileUid, String locationId) =>
      _swept.add('$profileUid|$locationId');

  /// 旧根的媒体残留这一进程里已经处理到头（[srsMigrateV1Media] 不再跑）。
  bool mediaDone(String profileUid, String locationId) =>
      _mediaDone.contains('$profileUid|$locationId');

  void markMediaDone(String profileUid, String locationId) =>
      _mediaDone.add('$profileUid|$locationId');
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

  /// 旧根 `meta.json` 上的加密参数（要口令时 UI 用）。
  SrsKdf? kdf;

  /// 这一轮处理了旧根上的设备段。
  bool migrated = false;

  /// 原样写进新根的段 / head / 转发件 / 说明文件数（已在的不算）。
  int copied = 0;

  /// 删掉的旧设备段数。
  int deleted = 0;

  /// 留在旧根、下次再试的（新根上同名而内容不同 / 删不掉）。
  final List<String> skipped = <String>[];

  /// 旧根上的设备段都已核对在新根：本机在新根上读全一轮，就看得到旧根上已有的全部媒体绑定（[srsMigrateV1Media]
  /// 才能给按名字存的旧文件补绑定）。
  bool devicesSettled = false;

  /// 旧根可能还有媒体残留，要由 [srsMigrateV1Media] 搬（新根在用之后，不在同步一轮里搬）。
  bool mediaLeftover = false;
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

  /// 本实例还没列过 [writer] 就先列：没列过不等于「不在」。
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
    // 可能在另一个实例上跑（没列过目录）：先列，只删这一个名字现在对应的那个文件。
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

bool _isRootMeta(String dir, String name) =>
    dir.isEmpty && (name == 'meta.json' || name == kSrsV1SweepMarker);

/// [dir] 下（递归）有没有文件；根目录的 `meta.json` 与 [kSrsV1SweepMarker]（不是集合数据）不算。找到第一个就停，
/// 不把几万个文件的目录列全。
Future<bool> _anyFile(SrsLocationStore s, String dir) async {
  final List<SrsLocationEntry> entries = await s.list(dir);
  for (final SrsLocationEntry e in entries) {
    if (!e.isFolder && !_isRootMeta(dir, e.name)) return true;
  }
  for (final SrsLocationEntry e in entries) {
    if (e.isFolder &&
        await _anyFile(s, dir.isEmpty ? e.name : '$dir/${e.name}')) {
      return true;
    }
  }
  return false;
}

/// 旧根上列出来的一个文件。
class _V1File {
  const _V1File(this.path, this.size, this.modifiedAt);

  final String path;
  final int? size;
  final int? modifiedAt;
}

/// [dir] 下的全部文件（递归）；根目录的 `meta.json` 与 [kSrsV1SweepMarker] 不算。
Future<List<_V1File>> _files(SrsLocationStore s, String dir) async {
  final List<_V1File> out = <_V1File>[];
  for (final SrsLocationEntry e in await s.list(dir)) {
    final String path = dir.isEmpty ? e.name : '$dir/${e.name}';
    if (e.isFolder) {
      out.addAll(await _files(s, path));
    } else if (!_isRootMeta(dir, e.name)) {
      out.add(_V1File(path, e.size, e.modifiedAt));
    }
  }
  return out;
}

String _fingerprint(
  List<_V1File> files,
  Map<String, List<String>> writerMedia,
) {
  final List<String> lines = <String>[
    for (final _V1File f in files) '${f.path}\t${f.size ?? ''}',
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

/// 准备一个位置跑协议 2 的一轮：确保旧根上的围栏在，把旧根上的设备段迁进新根，新根还没有 meta 就写上（见库注释第一段）。
/// [v1] / [current] 是同一个位置的旧根与新根；[writers] = 协议 1 之前的写入者目录（只有通道上有，这里只看有没有）；
/// [removeEmptyDirs] = 删完旧文件后清空目录（文件夹位置）；[archive] = 归档位置（只复制、不删）。媒体残留不在这里搬：
/// [SrsLocationPrepared.mediaLeftover] 时由调用方交给 [srsMigrateV1Media]。
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

/// 第一段：围栏、设备段、新根 meta。
class _Migration {
  _Migration({
    required this.host,
    required this.v1,
    required this.current,
    required this.locationId,
    required this.key,
    required this.nowMs,
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

  /// 设备段这一段做完时：旧根上可能还有媒体（这一进程里还没处理到头）就交给 [srsMigrateV1Media]。只看旧根的根目录与
  /// 写入者目录名（几次列目录）：根目录除了 meta / 完成标记 / 设备段之外什么都没有、也没有写入者目录，就没有可搬的，
  /// 这一进程记成处理完（全新的位置不为它起后台任务）；有 `media` 之类的目录就交过去（目录里有几万个文件也不在这里列）。
  Future<void> _noteMediaLeftover() async {
    if (memo?.mediaDone(host.profileUid, locationId) ?? false) return;
    bool leftover = false;
    for (final SrsLocationEntry e in await v1.list('')) {
      if (e.isFolder ? e.name != 'devices' : !_isRootMeta('', e.name)) {
        leftover = true;
        break;
      }
    }
    if (!leftover && writers != null) {
      leftover = (await writers!.writers()).isNotEmpty;
    }
    if (leftover) {
      out.mediaLeftover = true;
    } else {
      memo?.markMediaDone(host.profileUid, locationId);
    }
  }

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
        if (await _anyFile(v1, '')) {
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
          out.devicesSettled = true;
          await _noteMediaLeftover();
          return;
        }
    }

    // 2. 设备段（只列 `devices/`，不把几万个媒体文件的目录列全）。
    _step('list');
    final List<_V1File> devices = await _files(v1, 'devices');
    _step('listed devices=${devices.length}');
    if (!ready) {
      if (devices.isEmpty && !await _anyFile(v1, '')) {
        if (await _hasData(current)) {
          // 迁移早已做完（旧根空了），新根有数据却读不到 meta（被删 / 同步工具还没带过来）：与握手同一条规矩——
          // 不替一份可能还在的 meta 重写（重写会换掉集合身份 / 加密参数），这一轮不同步。
          out.error = kSrsSync2MetaUnavailable;
          return;
        }
      } else {
        // 旧根上有数据：读旧根按旧根的 kdf，口令问题照握手报（新根的 meta 照抄围栏的 kdf）。
        final ({String? keyHex, String? error, SrsKdf? kdf}) read = _keyFor(
          fence,
          key,
        );
        out.kdf ??= read.kdf;
        if (read.error != null) {
          out.error = read.error;
          return;
        }
      }
    }
    // 归档位置的旧段从不删，每个进程都会再看到它们：新根上同名同大小的就不再逐个下载比字节。
    final Map<String, int?> there = archive && devices.isNotEmpty
        ? <String, int?>{
            for (final _V1File f in await _files(current, 'devices'))
              f.path: f.size,
          }
        : const <String, int?>{};
    final List<String> doomed = <String>[];
    int copiedFiles = 0;
    _step('copy 0/${devices.length}');
    await srsRunPooled(devices, kSrsSync2Concurrency, (_V1File f) async {
      final int? size = there[f.path];
      if (size == null || size != f.size) {
        out.migrated = true;
        final Uint8List? bytes = await v1.get(f.path);
        if (bytes != null) {
          // bytes == null：别的设备搬完删了，它核对过新副本。
          if (await _ensureBytes(f.path, bytes)) {
            doomed.add(f.path);
          } else {
            out.skipped.add(f.path);
          }
        }
      }
      if (++copiedFiles % 25 == 0 || copiedFiles == devices.length) {
        _step('copy $copiedFiles/${devices.length}');
      }
    });

    // 3. 新根的 meta：段都到位之后才写，没有它的新根别的设备不会当成可用（它们接着迁移）。媒体不再是前提（见库注释）。
    if (!ready) {
      await current.putNew(
        'meta.json',
        utf8.encode(
          jsonEncode(srsV2MetaFromV1(fence, await _identity(), nowMs())),
        ),
      );
    }

    // 核对过的旧段删掉（归档位置一个不删）。
    if (!archive && doomed.isNotEmpty) {
      _step('delete ${doomed.length}');
      await srsRunPooled(doomed, kSrsSync2Concurrency, (String path) async {
        if (await _deleteOld(v1, path)) {
          out.deleted++;
        } else {
          out.skipped.add(path);
        }
      });
      await removeEmptyDirs?.call();
    }
    out.devicesSettled = out.skipped.isEmpty;
    if (out.devicesSettled) {
      memo?.markSwept(host.profileUid, locationId);
    }
    await _noteMediaLeftover();
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

/// 集合根上除了 `meta.json`（与迁移自己写的 [kSrsV1SweepMarker]，它不是集合数据）之外还有没有东西。
Future<bool> _hasData(SrsLocationStore s) => _anyFile(s, '');

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [srsMigrateV1Media] 的结论。
class SrsV1MediaReport {
  /// 这一次列出的旧媒体文件数（含写入者目录）与处理到第几个（进度）。
  int total = 0;
  int done = 0;

  /// 核对过、在新根上的媒体数（含早就在的）。
  int media = 0;

  /// 这一次传进新根的对象数。
  int uploaded = 0;

  /// 补上的媒体绑定数。
  int bound = 0;

  /// 删掉的旧文件数。
  int deleted = 0;

  /// 留在旧根、下个进程再试的（解不开 / 不是合法媒体名 / 新根上同名而内容不同 / 删之前换了内容）。
  final List<String> skipped = <String>[];

  /// 绑上了、绑定还没发布到位置的按名字存的旧文件数：留在旧根，下一次（调用方发布之后）删。
  int awaitingPublish = 0;

  /// 旧根上能搬的都搬完了（写了完成标记）。
  bool finished = false;

  /// 新根的口令问题（[kSrsLocationCryptoErrors] 那一套）：一个字节都没写，新根的握手会报给用户。
  String? error;

  /// 删旧文件时逐个出的错（读 / 删失败）：这些文件留在旧根下一次再删；调用方必须记日志。
  final List<(Object, StackTrace)> cleanupErrors = <(Object, StackTrace)>[];
}

/// 搬旧根的媒体残留（见库注释第二段）。新根在用、旧根上立着围栏时才做事，否则什么都不碰（交回空结论）。
///
/// - [canBind]：本机已在新根上读全一轮（[SrsLocationPrepared.devicesSettled]，且那一轮没有缺段 / 坏段）——看得到
///   已有的全部媒体绑定，才给按名字存的旧文件补绑定、排删；否则它们这一次不碰（不下载）。
/// - [progressId]：按名字存的旧文件等哪个位置的上传水位到了绑定所在的 seq 才删（[srsLocationProgressId]）；null =
///   只做媒体的位置，任何一个位置发布了都算。
/// - [onBound]：一批补上了新绑定之后调（调度器借此请一轮同步把绑定发出去，删除才能跟上）。
/// - [shouldStop]：每个文件之前看一次，true 就收手（已完成的批照样算数）。
///
/// 读失败（网络 / 限流）照常抛出：已经处理完的批不受影响，下一次接着做。
Future<SrsV1MediaReport> srsMigrateV1Media({
  required SrsSync2Host host,
  required SrsLocationStore v1,
  required SrsLocationStore current,
  required String locationId,
  required SrsLocationKey? key,
  required int Function() nowMs,
  required bool canBind,
  String? progressId,
  bool recordPresence = false,
  SrsV1Writers? writers,
  Future<void> Function()? removeEmptyDirs,
  SrsLocationMigrationMemo? memo,
  bool archive = false,
  int batchSize = kSrsV1MediaBatch,
  void Function(int done, int total)? onProgress,
  SrsSyncStepCallback? onStep,
  bool Function()? shouldStop,
  Future<void> Function()? onBound,
}) async {
  final SrsV1MediaReport out = SrsV1MediaReport();
  if (memo?.mediaDone(host.profileUid, locationId) ?? false) {
    out.finished = true;
    return out;
  }
  final Object? cur = await _readMeta(current);
  if (cur is! Map<String, Object?> || _minReaderOf(cur) > kSrsSync2Protocol) {
    // 新根还没在用（或来自更新的版本）：[srsPrepareLocation] 的事。
    return out;
  }
  final ({_V1Kind kind, Map<String, Object?> meta}) old = await _readV1(v1);
  if (old.kind != _V1Kind.fenced) return out;
  // 密钥：读旧根按旧根的 kdf；写新根按新根的 kdf（迁移之后才开 / 换的加密以新根为准）。
  final ({String? keyHex, String? error, SrsKdf? kdf}) read = _keyFor(
    old.meta,
    key,
  );
  final ({String? keyHex, String? error, SrsKdf? kdf}) write = _keyFor(
    cur,
    key,
  );
  if (write.error != null) {
    // 新根的口令问题由新根的握手报；残留这一次不碰（不往加密的新根写明文）。
    out.error = write.error;
    return out;
  }
  final String? readKey = read.error == null ? read.keyHex : null;
  await _MediaMigration(
    host: host,
    v1: v1,
    current: current,
    locationId: locationId,
    read: readKey == null ? null : SrsMediaCipher(host, readKey),
    write: write.keyHex == null ? null : SrsMediaCipher(host, write.keyHex!),
    nowMs: nowMs,
    canBind: canBind,
    progressId: progressId,
    recordPresence: recordPresence,
    writers: writers,
    removeEmptyDirs: removeEmptyDirs,
    memo: memo,
    archive: archive,
    batchSize: max(1, batchSize),
    onProgress: onProgress,
    onStep: onStep,
    shouldStop: shouldStop,
    onBound: onBound,
    out: out,
  ).run();
  return out;
}

/// 按名字存的旧文件来自哪。
enum _ByNameKind { flat, sealed, writer }

/// 一个按名字存的旧文件（明文 `media/<名字>` / 整份封装 `media-e/<指纹>/<名字>` / 写入者目录）。
class _ByName {
  _ByName.file(this.kind, _V1File f, {this.reader})
    : path = f.path,
      name = p.posix.basename(f.path),
      writer = null,
      size = f.size,
      modifiedAt = f.modifiedAt;

  _ByName.writer(String w, this.name)
    : kind = _ByNameKind.writer,
      path = '$w/$kSrsMediaFolder/$name',
      writer = w,
      size = null,
      modifiedAt = null,
      reader = null;

  final _ByNameKind kind;

  /// 旧根上的路径（写入者目录的为 `<写入者>/media/<名字>`，只作记账）。
  final String path;
  final String name;
  final String? writer;

  /// 列目录时的大小 / 修改时间：删之前重新列出来还对得上，就是搬的那一份。
  final int? size;
  final int? modifiedAt;

  /// 整份封装的解封装密钥。
  final SrsMediaCipher? reader;

  /// 迁移时读到的原始字节的 sha256（整份封装是封装的哈希，不是明文的）。
  String? raw;

  /// 补绑定之后本机日志的最后一个 seq：位置上传水位到了它，绑定就已发布。
  int seq = 0;
}

/// 第二段：媒体残留。
class _MediaMigration {
  _MediaMigration({
    required this.host,
    required this.v1,
    required this.current,
    required this.locationId,
    required this.read,
    required this.write,
    required this.nowMs,
    required this.canBind,
    required this.progressId,
    required this.recordPresence,
    required this.writers,
    required this.removeEmptyDirs,
    required this.memo,
    required this.archive,
    required this.batchSize,
    required this.onProgress,
    required this.onStep,
    required this.shouldStop,
    required this.onBound,
    required this.out,
  });

  final SrsSync2Host host;
  final SrsLocationStore v1;
  final SrsLocationStore current;
  final String locationId;

  /// 解旧根加密媒体的（旧根的 kdf）；null = 旧根明文或本机没有那把密钥。
  final SrsMediaCipher? read;

  /// 写新根的（新根的 kdf）；null = 新根明文。
  final SrsMediaCipher? write;
  final int Function() nowMs;
  final bool canBind;
  final String? progressId;
  final bool recordPresence;
  final SrsV1Writers? writers;
  final Future<void> Function()? removeEmptyDirs;
  final SrsLocationMigrationMemo? memo;
  final bool archive;
  final int batchSize;
  final void Function(int done, int total)? onProgress;
  final SrsSyncStepCallback? onStep;
  final bool Function()? shouldStop;
  final Future<void> Function()? onBound;
  final SrsV1MediaReport out;
  final Random _rand = Random();

  /// 新根内容目录里已有的对象：sha → 列出的字节数（明文目录才拿来比大小）。
  final Map<String, int?> _present = <String, int?>{};

  /// 这一批新放进新根 / 核对在新根的 sha（记「在」用）。
  final Set<String> _stored = <String>{};

  /// 绑上了、等发布才删的。
  final List<_ByName> _pending = <_ByName>[];

  /// 这一次有因为「这一次做不了」而留下的（看不全绑定 / 删不掉 / 删的时候出错）：本进程下一次还要再来。
  bool _retry = false;

  /// [shouldStop] 让收手了。
  bool _stopped = false;

  /// 新根上的内容目录。
  String get target => write?.folder ?? kSrsMediaFolder;

  void _step(String step) => onStep?.call('migrate:media:$step');

  bool _halt() {
    if (!_stopped && (shouldStop?.call() ?? false)) _stopped = true;
    return _stopped;
  }

  void _tick() {
    out.done++;
    if (out.done % 25 == 0 || out.done == out.total) {
      onProgress?.call(out.done, out.total);
    }
  }

  File _scratch(String tag) => File(
    p.join(
      Directory.systemTemp.path,
      'fushi_srs_migrate_${tag}_${DateTime.now().microsecondsSinceEpoch}_'
      '${_rand.nextInt(1 << 30)}',
    ),
  );

  Future<T> _withTemp<T>(String tag, Future<T> Function(File f) body) async {
    final File f = _scratch(tag);
    try {
      return await body(f);
    } finally {
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // 临时文件留给系统清理。
      }
    }
  }

  Future<void> run() async {
    _step('list');
    final Map<String, List<String>> writerMedia = <String, List<String>>{};
    final SrsV1Writers? ws = writers;
    if (ws != null) {
      for (final String w in await ws.writers()) {
        final List<String> names = await ws.mediaNames(w);
        if (names.isNotEmpty) writerMedia[w] = names;
      }
    }
    final List<_V1File> files = await _files(v1, '');
    final String listing = _fingerprint(files, writerMedia);
    if (await _markerOf(v1) == listing) {
      // 上次完整处理之后旧根没变（归档位置 / 留下的不认识的文件）：不下载、不封、不重写。
      _finish(markDone: true);
      return;
    }

    final List<_V1File> plainObjects = <_V1File>[];
    final List<(_V1File, SrsMediaCipher?)> sealedObjects =
        <(_V1File, SrsMediaCipher?)>[];
    final List<_ByName> byName = <_ByName>[];
    // 本次列出、媒体迁移不碰的文件（设备段归 [srsPrepareLocation]；不认识的不碰）：完成标记的指纹只由它们算。
    final List<_V1File> untouched = <_V1File>[];
    for (final _V1File f in files) {
      final List<String> parts = f.path.split('/');
      if (parts.first == kSrsMediaFolder && parts.length == 2) {
        byName.add(_ByName.file(_ByNameKind.flat, f));
      } else if (parts.first == kSrsMediaFolder && parts.length == 3) {
        plainObjects.add(f);
      } else if (parts.first == kSrsSealedMediaFolder && parts.length >= 3) {
        final String dir = '${parts[0]}/${parts[1]}';
        final SrsMediaCipher? reader = <SrsMediaCipher?>[read, write]
            .whereType<SrsMediaCipher>()
            .where((SrsMediaCipher c) => c.folder == dir)
            .firstOrNull;
        if (parts.length == 3) {
          if (reader == null) {
            // 按名字的整份封装、本机没有那把密钥：名字 → 内容的对应只能解开才知道，留给有口令的设备。
            out.skipped.add(f.path);
          } else {
            byName.add(_ByName.file(_ByNameKind.sealed, f, reader: reader));
          }
        } else {
          sealedObjects.add((f, reader));
        }
      } else {
        untouched.add(f);
      }
    }
    for (final MapEntry<String, List<String>> w in writerMedia.entries) {
      for (final String n in w.value) {
        byName.add(_ByName.writer(w.key, n));
      }
    }
    out.total = plainObjects.length + sealedObjects.length + byName.length;
    _step(
      'listed byName=${byName.length} objects=${plainObjects.length} '
      'sealed=${sealedObjects.length} writers=${writerMedia.length}',
    );
    if (out.total > 0) {
      onProgress?.call(0, out.total);
      await _listPresent();
      _step('present ${_present.length}');
      await _batches(plainObjects, (_V1File f) => f.path, _plainObject);
      await _batches(
        sealedObjects,
        ((_V1File, SrsMediaCipher?) o) => o.$1.path,
        _sealedObject,
      );
      if (!canBind && byName.isNotEmpty) {
        // 看不全已有的绑定：按名字存的一个都不补、不排删（不下载），留在旧根等能读全的那一次。
        _retry = true;
        for (final _ByName it in byName) {
          out.skipped.add(it.path);
          _tick();
        }
      } else {
        await _byNameBatches(byName);
      }
      await _flush(force: true);
      if (!archive) await removeEmptyDirs?.call();
    }
    out.awaitingPublish = _pending.length;
    final bool settled =
        !_stopped && !_retry && _pending.isEmpty && out.cleanupErrors.isEmpty;
    if (settled && out.skipped.isEmpty) {
      // 记下这一次处理完之后旧根该有的样子；下次进程启动只比清单。指纹只由本次最初列出的文件算（归档：全部，一个
      // 不删；否则：留着不动的那些）——绝不能拿处理完之后重新列出的清单算：迁移期间同步工具 / 旧版本新带来的文件
      // 本次没搬过，算进指纹就被当成「已处理」，永远留在旧根、别的设备收不到。
      final String? after = archive
          ? listing
          : await _settledListing(untouched);
      if (after == null) {
        // 处理期间旧根多出了 / 换了文件：不写标记，下一次重新列、接着搬。
        return;
      }
      await v1.put(
        kSrsV1SweepMarker,
        utf8.encode(
          jsonEncode(<String, Object?>{'listing': after, 'at': nowMs()}),
        ),
      );
      _finish(markDone: true);
    } else if (settled) {
      // 只剩这台设备这个进程里做不了的（解不开 / 不是合法媒体名 / 内容对不上）：不再每轮重下一遍，下个进程再看。
      memo?.markMediaDone(host.profileUid, locationId);
    }
  }

  void _finish({required bool markDone}) {
    out.finished = true;
    if (markDone) memo?.markMediaDone(host.profileUid, locationId);
  }

  /// 删完之后旧根恰好只剩 [untouched]（路径与大小都对得上）时交回它们的清单指纹；多出 / 换了文件为 null。写入者目录
  /// 不在这里比：非归档位置有写入者媒体就一定有待删的（不会走到写标记），晚到的写入者媒体下次列目录时让指纹对不上。
  Future<String?> _settledListing(List<_V1File> untouched) async {
    final Set<String> want = <String>{
      for (final _V1File f in untouched) '${f.path}\t${f.size ?? ''}',
    };
    final Set<String> now = <String>{
      for (final _V1File f in await _files(v1, ''))
        '${f.path}\t${f.size ?? ''}',
    };
    if (now.length != want.length || !now.containsAll(want)) return null;
    return _fingerprint(untouched, const <String, List<String>>{});
  }

  /// 分页列一次新根的内容目录（`<target>/<前2>/<sha>`），建 sha 集合：已在的对象不再逐个下载核对。
  Future<void> _listPresent() async {
    final List<String> prefixes = <String>[
      for (final SrsLocationEntry e in await current.list(target))
        if (e.isFolder) e.name,
    ];
    await srsRunPooled(prefixes, kSrsSync2Concurrency, (String pre) async {
      for (final SrsLocationEntry e in await current.list('$target/$pre')) {
        if (!e.isFolder && e.name.length == 64 && e.name.startsWith(pre)) {
          _present[e.name] = e.size;
        }
      }
    });
  }

  /// 新根上已有 [sha] 的对象，且（明文目录、知道大小时）大小与 [plainSize] 相同。加密目录的对象大小与明文不可比，
  /// 列出来就算在：读者下载时按哈希核对，坏的记可疑、由持有者重传（srs_media_sync.dart）。
  bool _has(String sha, int? plainSize) {
    if (!_present.containsKey(sha)) return false;
    if (write != null) return true;
    final int? there = _present[sha];
    return there == null || plainSize == null || there == plainSize;
  }

  /// 把明文文件 [plain]（内容 [sha]，本机刚算过的哈希就是核对）放进新根：已在就什么都不写（不重新封）；在而大小不对
  /// （半截 / 坏的）按内容覆盖——内容寻址，本机这份按哈希就是对的。
  Future<void> _store(File plain, String sha) async {
    final int size = await plain.length();
    if (!_has(sha, size)) {
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
        if (_present.containsKey(sha)) {
          await srsLocationPutFile(current, path, src);
        } else {
          await srsLocationPutNewFile(current, path, src);
        }
        _present[sha] = c == null ? size : await src.length();
      });
      out.uploaded++;
    }
    _stored.add(sha);
    out.media++;
  }

  /// 内容寻址的旧文件按 [batchSize] 一批批过 [task]（批内并发；true = 已核对在新根，[pathOf] 那个旧文件可以删），
  /// 每批之后删掉这一批核对过的旧文件、记「在」。
  Future<void> _batches<T>(
    List<T> items,
    String Function(T item) pathOf,
    Future<bool> Function(T item) task,
  ) async {
    for (int i = 0; i < items.length && !_halt(); i += batchSize) {
      final List<T> batch = items.sublist(i, min(i + batchSize, items.length));
      final List<String> doomed = <String>[];
      await srsRunPooled(batch, kSrsSync2Concurrency, (T item) async {
        if (_halt()) return;
        if (await task(item)) doomed.add(pathOf(item));
        _tick();
      });
      await _deleteDoomed(doomed);
      await _recordPresence();
    }
  }

  Future<void> _deleteDoomed(List<String> doomed) async {
    if (archive || doomed.isEmpty) return;
    await srsRunPooled(doomed, kSrsSync2Concurrency, (String path) async {
      if (await _deleteOld(v1, path)) {
        out.deleted++;
      } else {
        _retry = true;
      }
    });
  }

  Future<void> _recordPresence() async {
    if (!recordPresence || _stored.isEmpty) return;
    final List<String> present = _stored.toList();
    _stored.clear();
    await host.sync2Command(<String, Object?>{
      'op': 'media_record',
      'location': srsMediaContentPresenceKey(locationId, target),
      'present': present,
      'absent': const <String>[],
      'suspect': const <String>[],
      'seeded': false,
      'now': nowMs(),
    });
  }

  /// 旧根 `media/<前2>/<sha>`（内容寻址明文）与可疑标记。
  Future<bool> _plainObject(_V1File f) async {
    final String name = p.posix.basename(f.path);
    // 可疑标记：新根上读者会重新核对，标记不搬。
    if (name.endsWith(kSrsMediaSuspectSuffix)) return true;
    if (name.length == 64 && _has(name, f.size)) {
      _stored.add(name);
      out.media++;
      return true;
    }
    return _withTemp('obj', (File tmp) async {
      if (!await srsLocationGetFile(v1, f.path, tmp)) return false;
      // 按真实内容存（对不上名字的坏对象按真实哈希存下，不丢字节，也不会冒充那份内容）。
      await _store(tmp, await srsMediaSha256File(tmp));
      return true;
    });
  }

  /// 旧根 `media-e/<指纹>/<前2>/<sha>`：认得这个指纹（旧根或新根的密钥）就解开核对——新根同一把密钥原样搬，换过
  /// 密钥的按新根的密钥重封；认不得（换过密钥留下的）原样搬到新根同一路径。
  Future<bool> _sealedObject((_V1File, SrsMediaCipher?) item) async {
    final (_V1File f, SrsMediaCipher? reader) = item;
    final List<String> parts = f.path.split('/');
    final String name = parts.last;
    if (reader == null) {
      if (await _copyVerbatim(f.path)) return true;
      out.skipped.add(f.path);
      return false;
    }
    if (parts.length != 4 || name.length != 64) {
      out.skipped.add(f.path);
      return false;
    }
    if (_has(name, null)) {
      _stored.add(name);
      out.media++;
      return true;
    }
    final bool ok = await _withTemp('sobj', (File got) async {
      if (!await srsLocationGetFile(v1, f.path, got)) return true;
      return _withTemp('splain', (File plain) async {
        final SrsMediaOpened o = await reader.openFile(name, got, plain);
        if (o.sha256 != name) return false;
        if (reader.folder == target) {
          // 新根同一把密钥：原样搬（解开核对过内容）。
          if (!_present.containsKey(name)) {
            await srsLocationPutNewFile(
              current,
              srsMediaContentPath(target, name),
              got,
            );
            _present[name] = await got.length();
            out.uploaded++;
          }
          _stored.add(name);
          out.media++;
        } else {
          await _store(plain, name);
        }
        return true;
      });
    });
    if (!ok) out.skipped.add(f.path);
    return ok;
  }

  /// [path] 原样写到新根同一路径并按字节核对（已在的只核对，不覆盖）。只用于本机没有密钥的加密对象（罕见）。
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

  /// 按名字存的旧文件，一批一批：放进新根 → 一次补绑定 → 请发布 → 删已发布的。
  Future<void> _byNameBatches(List<_ByName> items) async {
    for (int i = 0; i < items.length && !_halt(); i += batchSize) {
      final List<_ByName> batch = items.sublist(
        i,
        min(i + batchSize, items.length),
      );
      final List<Map<String, Object?>> binds = <Map<String, Object?>>[];
      final List<_ByName> moved = <_ByName>[];
      await srsRunPooled(batch, kSrsSync2Concurrency, (_ByName it) async {
        if (_halt()) return;
        final Map<String, Object?>? bind = await _byName(it);
        if (bind != null) {
          binds.add(bind);
          moved.add(it);
        }
        _tick();
      });
      _step('bind ${binds.length}');
      int appended = 0;
      if (binds.isNotEmpty) {
        final Map<String, Object?> r = (await host.sync2Command(
          <String, Object?>{
            'op': 'media_bind_unbound',
            'items': binds,
            'now': nowMs(),
          },
        )).map;
        appended = (r['appended'] as int?) ?? 0;
        out.bound += appended;
      }
      // 发布判据取在补绑定之后、记「在」之前（记「在」也写日志，不该让删除多等它）。
      if (!archive && moved.isNotEmpty) {
        final int seq = await _lastSeq();
        for (final _ByName it in moved) {
          it.seq = seq;
        }
        _pending.addAll(moved);
      }
      await _recordPresence();
      // 名字早就绑过（上一次绑了、进程没等到发布就没了）的不再请：它们随已经请过的那一轮发布。
      if (appended > 0) await onBound?.call();
      await _flush();
    }
  }

  /// 一个按名字存的旧文件：放进新根，交回它的绑定；已经不在（别的设备搬完删了）/ 这一次做不了为 null。
  Future<Map<String, Object?>?> _byName(_ByName it) async {
    if (!srsIsBareMediaName(it.name)) {
      out.skipped.add(it.path);
      return null;
    }
    return _withTemp('named', (File plain) async {
      switch (it.kind) {
        case _ByNameKind.flat:
          if (!await srsLocationGetFile(v1, it.path, plain)) return null;
          // 明文按名字存：原始字节就是明文。
          it.raw = await srsMediaSha256File(plain);
        case _ByNameKind.writer:
          if (!await writers!.getMedia(it.writer!, it.name, plain)) return null;
          it.raw = await srsMediaSha256File(plain);
        case _ByNameKind.sealed:
          // 按名字的整份封装（协议 1，AAD = 文件名）。删前核对的是旧根上的原始字节（封装），不是解开的明文。
          final Uint8List? sealed = await v1.get(it.path);
          if (sealed == null) return null;
          final Uint8List? opened = await _openV1(
            it.reader!.keyHex,
            it.name,
            sealed,
          );
          if (opened == null) {
            out.skipped.add(it.path);
            return null;
          }
          await plain.writeAsBytes(opened, flush: true);
          it.raw = sha256.convert(sealed).toString();
      }
      final String sha = it.kind == _ByNameKind.sealed
          ? await srsMediaSha256File(plain)
          : it.raw!;
      await _store(plain, sha);
      return <String, Object?>{
        'name': it.name,
        'sha': sha,
        'size': await plain.length(),
      };
    });
  }

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

  /// 本机日志此刻的最后一个 seq（刚补的绑定在它之内）。
  Future<int> _lastSeq() async {
    final Map<String, Object?> status = (await host.sync2Command(
      <String, Object?>{'op': 'status'},
    )).map;
    return ((status['nextSeq'] as num?)?.toInt() ?? 1) - 1;
  }

  /// [progressId]（null = 任何一个位置）的上传水位。
  Future<int> _published() async {
    final Map<String, Object?> status = (await host.sync2Command(
      <String, Object?>{'op': 'status'},
    )).map;
    int best = 0;
    for (final Object? l
        in (status['locations'] as List<Object?>?) ?? const <Object?>[]) {
      if (l is! Map) continue;
      if (progressId != null && l['location'] != progressId) continue;
      best = max(best, (l['uploaded'] as num?)?.toInt() ?? 0);
    }
    return best;
  }

  /// 删掉绑定已发布的按名字存的旧文件。删之前重新列它所在的目录：名字是可变的，迁移之后同名文件被换成了别的内容
  /// （同步工具晚到的旧版本写入）就不能删，留给下一次重新搬。大小与修改时间都对得上就是搬的那份；对不上 / 后端给不出
  /// 修改时间时下载核对原始字节。[force] = 收尾那一次（即使这一批没有新绑定也看一眼水位）。
  Future<void> _flush({bool force = false}) async {
    if (_pending.isEmpty) return;
    final int watermark = await _published();
    final List<_ByName> ready = <_ByName>[
      for (final _ByName it in _pending)
        if (it.seq <= watermark) it,
    ];
    if (ready.isEmpty) return;
    _pending.removeWhere((_ByName it) => it.seq <= watermark);
    _step('delete ${ready.length}${force ? ' final' : ''}');
    final Map<String, Map<String, SrsLocationEntry>> fresh =
        <String, Map<String, SrsLocationEntry>>{};
    for (final String dir in <String>{
      for (final _ByName it in ready)
        if (it.kind != _ByNameKind.writer) p.posix.dirname(it.path),
    }) {
      fresh[dir] = <String, SrsLocationEntry>{
        for (final SrsLocationEntry e in await v1.list(dir))
          if (!e.isFolder) e.name: e,
      };
    }
    await srsRunPooled(ready, kSrsSync2Concurrency, (_ByName it) async {
      try {
        if (it.kind == _ByNameKind.writer) {
          final String? now = await _rawSha(
            (File dst) => writers!.getMedia(it.writer!, it.name, dst),
          );
          if (now == null) {
            out.deleted++; // 已经不在（别的设备收尾删了）。
          } else if (now != it.raw) {
            out.skipped.add(it.path);
          } else {
            await writers!.deleteMedia(it.writer!, it.name);
            out.deleted++;
          }
          return;
        }
        final SrsLocationEntry? e = fresh[p.posix.dirname(it.path)]?[it.name];
        if (e == null) {
          out.deleted++; // 已经不在（别的设备收尾删了）。
          return;
        }
        final bool unchanged =
            it.modifiedAt != null &&
            e.modifiedAt == it.modifiedAt &&
            e.size == it.size;
        if (!unchanged) {
          final String? now = await _rawSha(
            (File dst) => srsLocationGetFile(v1, it.path, dst),
          );
          if (now == null) {
            out.deleted++;
            return;
          }
          if (now != it.raw) {
            // 搬进新根、绑上的是旧内容，这份没人搬过——不删，下一次重新搬。
            out.skipped.add(it.path);
            return;
          }
        }
        if (await _deleteOld(v1, it.path)) {
          out.deleted++;
        } else {
          _retry = true;
        }
      } on Object catch (err, stack) {
        // 逐个文件：一个读 / 删失败只留下它自己（下一次重新核对再删），记进 cleanupErrors。
        out.cleanupErrors.add((err, stack));
      }
    });
  }
}

/// 一个位置的旧根媒体迁移此刻的进度（[SrsV1MediaMigrations.progress]）。
class SrsV1MediaProgress {
  const SrsV1MediaProgress(this.done, this.total);

  final int done;
  final int total;
}

/// 一次后台迁移：给它一个报进度的回调，跑完交回结论。
typedef SrsV1MediaJob =
    Future<SrsV1MediaReport> Function(
      void Function(int done, int total) onProgress,
    );

/// 旧根媒体残留的后台迁移（[srsMigrateV1Media]）：每个位置至多一个在跑，**不进同步一轮的串行队列**——大库上要搬
/// 几万个文件、跑几个小时，不能挡住别的位置（互联 host 目录等）的同步。一个跑完 / 失败之后不按时间重试：位置的下一轮
/// 同步成功后调用方再交一次（失败的原因记日志，进度在位置上，接着做）。在跑的时候又交来的（迁移请的发布轮跑完了）
/// 记下最新的那一个，跑完接着跑一次：最后一批绑定发布之后，旧文件靠它删掉。
class SrsV1MediaMigrations {
  SrsV1MediaMigrations({this.onProgress, this.onReport, this.onError});

  /// 全部在跑的迁移合起来的进度；都跑完了为 null。
  final void Function(SrsV1MediaProgress? progress)? onProgress;

  /// 一个位置的迁移跑完了（调用方记 cleanupErrors / skipped 日志）。
  final void Function(String locationId, SrsV1MediaReport report)? onReport;

  /// 一个位置的迁移抛了（读失败 / 限流）：调用方必须记日志。
  final void Function(String locationId, Object error, StackTrace stack)?
  onError;

  final Map<String, Future<void>> _running = <String, Future<void>>{};
  final Map<String, SrsV1MediaJob> _again = <String, SrsV1MediaJob>{};
  final Map<String, SrsV1MediaProgress> _progress =
      <String, SrsV1MediaProgress>{};

  /// [locationId] 有一个在跑。
  bool isRunning(String locationId) => _running.containsKey(locationId);

  /// 此刻合起来的进度；没在跑为 null。
  SrsV1MediaProgress? get progress {
    if (_progress.isEmpty) return null;
    int done = 0;
    int total = 0;
    for (final SrsV1MediaProgress v in _progress.values) {
      done += v.done;
      total += v.total;
    }
    return SrsV1MediaProgress(done, total);
  }

  void _emit() => onProgress?.call(progress);

  /// 在后台跑 [job]。[locationId] 已有一个在跑：记下 [job]，那一个跑完接着跑它（只留最新交来的一个），交回 false。
  bool start(String locationId, SrsV1MediaJob job) {
    if (_running.containsKey(locationId)) {
      _again[locationId] = job;
      return false;
    }
    _progress[locationId] = const SrsV1MediaProgress(0, 0);
    _emit();
    final Completer<void> done = Completer<void>();
    _running[locationId] = done.future;
    unawaited(() async {
      try {
        final SrsV1MediaReport r = await job((int d, int t) {
          if (!_progress.containsKey(locationId)) return;
          _progress[locationId] = SrsV1MediaProgress(d, t);
          _emit();
        });
        onReport?.call(locationId, r);
      } on Object catch (e, stack) {
        onError?.call(locationId, e, stack);
      } finally {
        _running.remove(locationId);
        final SrsV1MediaJob? next = _again.remove(locationId);
        if (next == null) {
          _progress.remove(locationId);
          _emit();
        } else {
          // 先登记下一个再放行 [idle]：等的人不会在两次之间以为都跑完了。
          start(locationId, next);
        }
        done.complete();
      }
    }());
    return true;
  }

  /// 等此刻在跑的（以及等待期间新起的）都跑完。
  Future<void> idle() async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.values.toList());
    }
  }
}
