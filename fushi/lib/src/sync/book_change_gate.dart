import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi/src/sync/interconnect_sync_backend.dart'
    show InterconnectSyncBackend;
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_baseline_scope.dart'
    show SyncRemoteIdentityUnavailableError, progressBaselineStorageFor;
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

// 云同步书阶段「只同步变了的书」（拍板 wiO0nN8aiG / issue #4332，设计见
// docs/specs/2026-11-24-sync-book-change-manifest.md）。
//
// 一本书的逐本阶段结果只由本地阅读位置时间戳、同步基线、远端书文件夹（progress
// 文件名 + 内容文件在不在）决定。上一次**亲眼看到两端一致**之后这三样都没变，这一轮
// 逐本阶段必然还是 synced、什么都不做——[BookChangeGate] 只跳过这种书。

/// 书级变更清单所在的保留命名空间（`__x__` 形状，旧版客户端一律当保留名、不当书）。
const String kSyncBookManifestNamespace = '__book_manifests__';

/// manifest 模式下距上次完整全扫超过这么久就再全扫一次：兜住不写清单的写入者
/// （ッツ网页版、只开进度不开统计的旧版客户端）与崩溃窗口。
const Duration kBookChangeFullSweepInterval = Duration(hours: 24);

/// 本机书级清单的资产名。
String bookManifestNameFor(String deviceId) => 'books-$deviceId.json';

/// [name] 是书级清单时返回写它的设备 id，否则 null。
String? bookManifestDeviceOf(String name) {
  if (!name.startsWith('books-') || !name.endsWith('.json')) return null;
  final String id = name.substring(
    'books-'.length,
    name.length - '.json'.length,
  );
  return id.isEmpty ? null : id;
}

/// 聚合快照资产名 → 设备 id（旧版客户端检测用，见 [BookChangeGate.prepare] 的
/// `legacyWriters`）。后缀与 `aggregate_sync_service.dart` 的新旧两种一致。
String? aggregateSnapshotDeviceOf(String name) {
  for (final String suffix in const <String>[
    '.fushiaggregate',
    '.hibikiaggregate',
  ]) {
    if (name.endsWith(suffix) && name.length > suffix.length) {
      return name.substring(0, name.length - suffix.length);
    }
  }
  return null;
}

/// 一台设备的书级变更清单：assetKey → 该设备在这个远端上的进度基线。
///
/// 基线随本机对这本书的每一次进度写入 / 导入推进（`SyncManager._handleExport` /
/// `_handleImport`），所以「某台设备的条目变了」⇔「那台设备对这本书写过或读过新状态」。
class BookChangeManifest {
  const BookChangeManifest({required this.deviceId, required this.books});

  static const int wireVersion = 1;

  final String deviceId;
  final Map<String, int> books;

  /// 解析远端 JSON；形状不对抛 [FormatException]。
  factory BookChangeManifest.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('book manifest: not a map');
    final Object? v = json['v'];
    final Object? device = json['device'];
    final Object? books = json['books'];
    if (v is! int || v < 1) {
      throw const FormatException('book manifest: bad version');
    }
    if (device is! String || device.isEmpty) {
      throw const FormatException('book manifest: bad device');
    }
    if (books is! Map) throw const FormatException('book manifest: bad books');
    final Map<String, int> out = <String, int>{};
    for (final MapEntry<Object?, Object?> e in books.entries) {
      final Object? k = e.key;
      final Object? value = e.value;
      if (k is! String || value is! int) {
        throw const FormatException('book manifest: bad entry');
      }
      out[k] = value;
    }
    return BookChangeManifest(deviceId: device, books: out);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': wireVersion,
    'device': deviceId,
    'books': <String, int>{
      for (final String k in books.keys.toList()..sort()) k: books[k]!,
    },
  };

  /// 内容的稳定哈希（键排序后的 JSON），发布去重与「本机清单是否还在远端」比对用。
  String contentHash() =>
      sha1.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

/// 本机「书级清单 / 全扫」的本地账（偏好 JSON，按进度基线存储维度分槽）。
class BookChangeState {
  BookChangeState({
    this.publishedHash,
    this.lastFullSweepMs = 0,
    Map<String, String>? legacyTokens,
  }) : legacyTokens = legacyTokens ?? <String, String>{};

  /// 上次发布成功的本机清单内容哈希。
  String? publishedHash;

  /// 上次 manifest 模式完整全扫跑完的时刻。
  int lastFullSweepMs;

  /// 上次全扫时各旧版客户端（有聚合快照、没有书级清单）的快照版本标记。
  Map<String, String> legacyTokens;

  static String prefKeyFor(String storageDimension) =>
      'sync_book_change_state|$storageDimension';

  static Future<BookChangeState> load(
    FushiDatabase db,
    String storageDimension,
  ) async {
    final String? raw = await db.getPref(prefKeyFor(storageDimension));
    if (raw == null || raw.isEmpty) return BookChangeState();
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) return BookChangeState();
      final Object? tokens = json['legacy'];
      return BookChangeState(
        publishedHash: json['published'] as String?,
        lastFullSweepMs: (json['lastFull'] as int?) ?? 0,
        legacyTokens: tokens is Map
            ? <String, String>{
                for (final MapEntry<Object?, Object?> e in tokens.entries)
                  if (e.key is String && e.value is String)
                    e.key! as String: e.value! as String,
              }
            : null,
      );
    } on FormatException {
      // 坏账 = 没有账：下一轮全扫并重写。
      return BookChangeState();
    } on TypeError {
      return BookChangeState();
    }
  }

  Future<void> save(FushiDatabase db, String storageDimension) => db.setPref(
    prefKeyFor(storageDimension),
    jsonEncode(<String, Object?>{
      'published': publishedHash,
      'lastFull': lastFullSweepMs,
      'legacy': legacyTokens,
    }),
  );
}

/// 进程内按存储维度串行化「建清单 → 上传 → 记哈希」：一轮收尾与退出书同步可能同时
/// 发布，后到的旧内容不得盖掉先到的新内容。
final Map<String, Future<void>> _publishTails = <String, Future<void>>{};

/// 把本机书级清单（本机在 [storageDimension] 下的全部进度基线）发布到远端。
///
/// 内容与上次发布成功的一致且未要求 [force] 时不发任何请求，返回 false。上传失败
/// 照常抛出：本地账不更新，下一次发布自动重发。
Future<bool> publishOwnBookManifest({
  required FushiDatabase db,
  required SyncBackend backend,
  required String deviceId,
  required String storageDimension,
  bool force = false,
}) {
  final Future<void> previous =
      _publishTails[storageDimension] ?? Future<void>.value();
  final Completer<bool> done = Completer<bool>();
  final Future<void> tail = previous.then((_) async {
    try {
      final BookChangeManifest own = BookChangeManifest(
        deviceId: deviceId,
        books: await db.getSyncBaselinesForDimension(storageDimension),
      );
      final String hash = own.contentHash();
      final BookChangeState state = await BookChangeState.load(
        db,
        storageDimension,
      );
      if (!force && state.publishedHash == hash) {
        done.complete(false);
        return;
      }
      final String ns = await backend.ensureNamespace(
        kSyncBookManifestNamespace,
      );
      await backend.putJsonAsset(
        ns,
        bookManifestNameFor(deviceId),
        own.toJson(),
      );
      // 重读再写：同一把串行锁内没有别的发布者，但全扫账可能被编排器同时更新。
      final BookChangeState latest = await BookChangeState.load(
        db,
        storageDimension,
      );
      latest.publishedHash = hash;
      await latest.save(db, storageDimension);
      done.complete(true);
    } catch (e, st) {
      done.completeError(e, st);
    }
  });
  _publishTails[storageDimension] = tail;
  unawaited(
    tail.whenComplete(() {
      if (identical(_publishTails[storageDimension], tail)) {
        _publishTails.remove(storageDimension);
      }
    }),
  );
  return done.future;
}

/// 单本同步（退出书 / 对比弹窗）在云通道落地之后发布本机书级清单。
///
/// 「这台读完马上去那台打开」是最常见的路径：只等本机下一轮整轮同步才发布，对端那一轮
/// 会按旧清单把这本书判成未变。内容没变时只读本地库、不发请求。互联通道不走书文件夹，
/// 不发布。发布失败不影响这次单本同步的结果，只记日志：本地哈希没更新，下一次发布
/// （下一轮收尾或下一次单本同步）自动重发。
Future<void> publishOwnBookManifestAfterBookSync({
  required FushiDatabase db,
  required SyncBackend backend,
}) async {
  final SyncBackend inner = backend is ObfuscatingSyncBackend
      ? backend.inner
      : backend;
  if (inner is InterconnectSyncBackend) return;
  try {
    final String storageDimension = (await progressBaselineStorageFor(
      db,
      backend,
    )).storageDimension;
    await publishOwnBookManifest(
      db: db,
      backend: backend,
      deviceId: await SyncRepository(db).getOrCreateDeviceId(),
      storageDimension: storageDimension,
    );
  } on SyncRemoteIdentityUnavailableError {
    // 认不出远端就不知道该发布哪个槽位的基线；下一轮整轮同步再发。
    return;
  } catch (e, stack) {
    ErrorLogService.instance.log('BookChangeManifest.publish', e, stack);
  }
}

/// 判「远端这本书没变」用的是哪种证据（见设计文档 §2.2）。
enum BookChangeGateMode {
  /// 本轮有整树快照：按书文件夹的实际文件名判，精确。
  snapshot,

  /// 无快照：按各对端书级清单里这本书的条目判，靠全扫回退兜底。
  manifest,
}

/// 一轮书阶段的「哪些书需要进逐本阶段」筛选器。
///
/// 只跳过同时满足以下条件的书：有本地一致指纹、本地阅读位置时间戳与指纹一致、远端证据
/// （快照文件名 / 对端清单条目）与指纹一致、内容检查开关与指纹一致；manifest 模式下
/// 还要求本轮没有触发全扫回退（[fullSweepReason] 为 null）。
class BookChangeGate {
  BookChangeGate({
    required this.mode,
    required this.storageDimension,
    required Map<String, int> fingerprints,
    required this.audioPackageNames,
    RemoteListingSnapshot? listing,
    Map<String, String> peerDigests = const <String, String>{},
    this.fullSweepReason,
    Map<String, String> legacyTokens = const <String, String>{},
    this.ownManifestStale = false,
  }) : _fingerprints = fingerprints,
       _listing = listing,
       _peerDigests = peerDigests,
       _legacyTokens = legacyTokens;

  final BookChangeGateMode mode;

  /// 本机这个远端的进度基线存储维度（清单内容的来源，也是指纹维度的后缀）。
  final String storageDimension;

  /// manifest 模式下本轮不跳过任何书的原因；null = 可以跳过。snapshot 模式恒为 null。
  final String? fullSweepReason;

  /// 本机清单在远端不在 / 与上次发布的不一致：收尾时强制重新发布。
  final bool ownManifestStale;

  /// 有声书包的资产名（新名 + Hibiki 旧名），指纹最低位据此记「见过有声书包」。
  final Set<String> audioPackageNames;

  final Map<String, int> _fingerprints;
  final RemoteListingSnapshot? _listing;
  final Map<String, String> _peerDigests;
  final Map<String, String> _legacyTokens;

  /// 本轮被判「未变」跳过的书数。
  int skipped = 0;

  /// 本轮进了逐本阶段的书数。
  int checked = 0;

  /// 指纹在 `sync_baselines` 里的 dimension。
  static String fingerprintDimensionFor(String storageDimension) =>
      'bookfp|$storageDimension';

  String get fingerprintDimension => fingerprintDimensionFor(storageDimension);

  /// 本轮看到的旧版客户端快照标记（全扫跑完后写进 [BookChangeState.legacyTokens]）。
  Map<String, String> get legacyTokens => _legacyTokens;

  /// 对端清单里关于 [assetKey] 的条目拼成的摘要（设备 id 排序，稳定）。
  static String peerDigestOf(
    Iterable<BookChangeManifest> peers,
    String assetKey,
  ) {
    final List<BookChangeManifest> sorted = peers.toList()
      ..sort(
        (BookChangeManifest a, BookChangeManifest b) =>
            a.deviceId.compareTo(b.deviceId),
      );
    final StringBuffer out = StringBuffer();
    for (final BookChangeManifest m in sorted) {
      final int? v = m.books[assetKey];
      if (v == null) continue;
      out
        ..write(m.deviceId)
        ..write('=')
        ..write(v)
        ..write(';');
    }
    return out.toString();
  }

  /// 指纹：`H(mode, 本地时间戳, 远端证据, 内容检查开关)` 取 52 位左移一位，最低位记
  /// 「这次列举看到了有声书包」（跳过时喂给同轮有声书包阶段，见 [audioPackageSeen]）。
  static int fingerprintOf({
    required BookChangeGateMode mode,
    required int? localStamp,
    required String remoteKey,
    required bool contentChecked,
    required bool audioPackageSeen,
  }) {
    final List<int> digest = sha1
        .convert(
          utf8.encode(
            'v1|${mode.name}|${localStamp ?? 'none'}|$remoteKey|'
            '${contentChecked ? 1 : 0}',
          ),
        )
        .bytes;
    int h = 0;
    for (int i = 0; i < 7; i++) {
      h = (h << 8) | digest[i];
    }
    h &= (1 << 52) - 1;
    return (h << 1) | (audioPackageSeen ? 1 : 0);
  }

  /// [assetKey] 本轮的远端证据；拿不到（快照里没有这个文件夹 / 列举不完整）为 null。
  String? _remoteKeyFor(String assetKey) {
    switch (mode) {
      case BookChangeGateMode.snapshot:
        final RemoteListingSnapshot? listing = _listing;
        if (listing == null || !listing.hasFolder(assetKey)) return null;
        return _namesKey(listing.trioFor(assetKey).fileNames);
      case BookChangeGateMode.manifest:
        return 'm:${_peerDigests[assetKey] ?? ''}';
    }
  }

  static String? _namesKey(Set<String>? names) {
    if (names == null) return null;
    final List<String> sorted = names.toList()..sort();
    return 's:${sha1.convert(utf8.encode(sorted.join('\u0000')))}';
  }

  /// 这本书本轮能否跳过逐本阶段。
  bool canSkip({
    required String assetKey,
    required int? localStamp,
    required bool contentChecked,
  }) {
    if (fullSweepReason != null) return false;
    final int? stored = _fingerprints[assetKey];
    if (stored == null) return false;
    final String? remoteKey = _remoteKeyFor(assetKey);
    if (remoteKey == null) return false;
    final int expected = fingerprintOf(
      mode: mode,
      localStamp: localStamp,
      remoteKey: remoteKey,
      contentChecked: contentChecked,
      audioPackageSeen: false,
    );
    return (stored >> 1) == (expected >> 1);
  }

  /// 被跳过的 [assetKey] 上次一致时书文件夹里有没有有声书包。
  bool audioPackageSeen(String assetKey) =>
      ((_fingerprints[assetKey] ?? 0) & 1) == 1;

  /// [assetKey] 本轮没得到干净的一致结论：删掉旧指纹。
  Future<void> forget(FushiDatabase db, String assetKey) async {
    if (assetKey.isEmpty || _fingerprints.remove(assetKey) == null) return;
    await db.deleteSyncBaseline(assetKey, fingerprintDimension);
  }

  /// 本轮逐本阶段亲眼看到 [assetKey] 两端一致（干净的 synced）：记下指纹。
  ///
  /// [remoteFileNames] 是那次列举看到的书文件夹完整文件名；snapshot 模式下拿不到
  /// 完整清单就不记（下一轮照常逐本确认）。
  Future<void> recordAgreement({
    required FushiDatabase db,
    required String assetKey,
    required int? localStamp,
    required bool contentChecked,
    required Set<String>? remoteFileNames,
  }) async {
    final String? remoteKey = switch (mode) {
      BookChangeGateMode.snapshot => _namesKey(remoteFileNames),
      BookChangeGateMode.manifest => _remoteKeyFor(assetKey),
    };
    if (remoteKey == null) return;
    final bool audioSeen =
        remoteFileNames != null &&
        remoteFileNames.any(audioPackageNames.contains);
    final int fp = fingerprintOf(
      mode: mode,
      localStamp: localStamp,
      remoteKey: remoteKey,
      contentChecked: contentChecked,
      audioPackageSeen: audioSeen,
    );
    if (_fingerprints[assetKey] == fp) return;
    _fingerprints[assetKey] = fp;
    await db.setSyncBaseline(assetKey, fingerprintDimension, fp);
  }
}
