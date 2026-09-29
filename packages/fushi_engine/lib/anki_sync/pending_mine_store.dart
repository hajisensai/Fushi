import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:path/path.dart' as p;

/// 设备端「待发制卡」队列的存储：一行元数据（`pending_mine_queue`）+ 一个载荷
/// 文件（`<root>/<id>.json`，[ForwardedMinePayload] 的 JSON，媒体字节已内联）。
///
/// 载荷不进数据库：一张带视频截图的卡动辄几 MB，塞进 SQLite 会让整库备份、
/// WAL 都跟着膨胀；文件名由 id 派生，表里也就没有需要跨设备重定位的路径列。
///
/// 写入顺序保证「有行必有文件」：先原子写文件（`.tmp` → rename），再插行；
/// 删除反过来，先删行再删文件。进程在两步之间崩溃，最坏留下一个孤儿文件，
/// 不会留下一个读不出载荷的行。
class PendingMineStore {
  PendingMineStore({
    required FushiDatabase Function() db,
    required Future<Directory> Function() root,
    int Function()? clock,
  }) : _dbOf = db,
       _root = root,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 本机的待发队列：载荷在 `<support>/<dirName>`（app 与无头服务端各自解析 support）。
  factory PendingMineStore.inSupportDir(
    FushiDatabase Function() db,
    Future<Directory> Function() support,
  ) => PendingMineStore(
    db: db,
    root: () async => Directory(p.join((await support()).path, dirName)),
  );

  /// 载荷目录名（`<support>/pending_mine_queue`）。
  static const String dirName = 'pending_mine_queue';

  /// 延迟取库：仓库 provider 在 AppModel 初始化前就可能被构建（widget 测试的
  /// 最小宿主根本没有库），只有真的入队 / 补发时才需要它。
  final FushiDatabase Function() _dbOf;
  FushiDatabase get _db => _dbOf();
  final Future<Directory> Function() _root;
  final int Function() _clock;

  static final Random _random = Random.secure();

  /// 128 位随机十六进制 id。
  static String newId() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  Future<File> _payloadFile(String id) async =>
      File(p.join((await _root()).path, '$id.json'));

  /// 冻结一张卡：写载荷文件，再插一行 `pending`。返回新 id。
  Future<String> enqueue(
    ForwardedMinePayload payload, {
    required String expression,
    required String reading,
  }) async {
    final String id = newId();
    await _writeRecord(
      id,
      jsonEncode(payload.toJson()),
      PendingMineQueueCompanion.insert(
        id: id,
        createdAt: _clock(),
        expression: expression,
        reading: Value<String>(reading),
      ),
    );
    return id;
  }

  /// 收下另一台设备经跨设备中转发来的卡（本机是落地设备）：沿用对方的 id 与入队
  /// 时刻，记下来源设备。已经有这一行（上一轮收过）时什么都不做。
  Future<bool> insertRemote({
    required String id,
    required int createdAt,
    required String expression,
    required String reading,
    required String originDeviceId,
    required String payloadJson,
  }) async {
    if (await byId(id) != null) return false;
    await _writeRecord(
      id,
      payloadJson,
      PendingMineQueueCompanion.insert(
        id: id,
        createdAt: createdAt,
        expression: expression,
        reading: Value<String>(reading),
        originDeviceId: Value<String?>(originDeviceId),
      ),
    );
    return true;
  }

  /// 本机的卡已上传到跨设备中转命名空间。
  Future<void> markUploaded(String id) =>
      _update(id, const PendingMineQueueCompanion(uploaded: Value<bool>(true)));

  /// 载荷原文（跨设备中转上传用）；读不到返回 null。
  Future<String?> readPayloadJson(String id) async {
    try {
      final File file = await _payloadFile(id);
      return file.existsSync() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  /// 用户删掉一张待发卡。远端中转命名空间里还有它（上传过 / 来自其他设备）时不能
  /// 直接删行——下一轮中转要靠这一行去清掉远端，否则落地设备照样会把它落进 Anki。
  Future<void> discard(PendingMineRow row) => markDelivered(row);

  /// 「写载荷文件 → 插行」与 [sweepOrphanPayloads] 共用的进程内锁：清理绝不能看到
  /// 「文件已写、行还没插」的中间态，把刚入队的卡当孤儿删掉。跨实例，所以是静态的。
  static Future<void> _io = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() body) {
    final Future<T> result = _io.then((_) => body());
    _io = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _writeRecord(
    String id,
    String payloadJson,
    PendingMineQueueCompanion row,
  ) => _locked<void>(() async {
    final File file = await _payloadFile(id);
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payloadJson, flush: true);
    await tmp.rename(file.path);
    await _db.into(_db.pendingMineQueue).insert(row);
  });

  /// 全部行（含已落地、等远端清理的 `landed`），按入队顺序（最早的在前）。
  Future<List<PendingMineRow>> rows() =>
      (_db.select(_db.pendingMineQueue)
            ..orderBy(<OrderingTerm Function($PendingMineQueueTable)>[
              ($PendingMineQueueTable t) => OrderingTerm.asc(t.createdAt),
              ($PendingMineQueueTable t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// 用户眼里的待发卡：还没交给 Anki 的（不含 `landed`）。
  Future<List<PendingMineRow>> all() async => (await rows())
      .where((PendingMineRow r) => r.status != PendingMineStatus.landed)
      .toList(growable: false);

  /// 可以补发的卡：`pending`，以及上次补发到一半进程就没了的 `sending`。
  /// `failed` 要等用户点「重试」；`landed` 已经交给 Anki 了。
  Future<List<PendingMineRow>> sendable() async => (await rows())
      .where(
        (PendingMineRow r) =>
            r.status == PendingMineStatus.pending ||
            r.status == PendingMineStatus.sending,
      )
      .toList(growable: false);

  /// 待发卡张数（与 [all] 同口径）。
  Future<int> count() async => (await all()).length;

  Future<PendingMineRow?> byId(String id) => (_db.select(
    _db.pendingMineQueue,
  )..where(($PendingMineQueueTable t) => t.id.equals(id))).getSingleOrNull();

  /// 队列表有任何变化时发一个事件（UI 据此重读）。用 tableUpdates 而不是
  /// `select().watch()`：后者在长驻页面 dispose 时会留下 Timer（BUG-834）。
  Stream<void> changes() => _db
      .tableUpdates(TableUpdateQuery.onTable(_db.pendingMineQueue))
      .map((_) {});

  /// 读回载荷；文件丢了、读不了或内容坏了都返回 null（调用方把这张标 failed）。
  Future<ForwardedMinePayload?> readPayload(String id) async {
    try {
      final File file = await _payloadFile(id);
      if (!file.existsSync()) return null;
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return ForwardedMinePayload.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  Future<void> markSending(String id) => _update(
    id,
    PendingMineQueueCompanion(
      status: const Value<String>(PendingMineStatus.sending),
      lastAttemptAt: Value<int?>(_clock()),
    ),
    bumpAttempts: true,
  );

  /// 这次没送出去（后端不可达等），回到 `pending` 等下一次补发。
  Future<void> markPending(String id, {String? error}) => _update(
    id,
    PendingMineQueueCompanion(
      status: const Value<String>(PendingMineStatus.pending),
      lastError: Value<String?>(error),
    ),
  );

  /// 送到了但 Anki 拒收（字段不匹配等），停在 `failed` 等用户处理。
  Future<void> markFailed(String id, String error) => _update(
    id,
    PendingMineQueueCompanion(
      status: const Value<String>(PendingMineStatus.failed),
      lastError: Value<String?>(error),
    ),
  );

  /// 用户点「重试」：`failed` → `pending`。
  Future<void> retry(String id) => markPending(id);

  /// 这张卡已交给 Anki。本机制的、从没上传过的直接出队；上传过的或来自其他设备的
  /// 远端还有一份记录，标 `landed` 等跨设备中转清理远端后再删——否则落地设备会再落一次。
  ///
  /// 判据读**库里此刻**的行，不信调用方手上的快照：补发与跨设备中转并发时，快照里
  /// 的 `uploaded` 可能已经过期——按过期的 false 直接删行，远端那份就没人撤了。
  Future<void> markDelivered(PendingMineRow row) async {
    final bool remoteCopy = await _db.transaction(() async {
      final PendingMineRow? now = await byId(row.id);
      if (now == null) return false;
      final bool remote = now.originDeviceId != null || now.uploaded;
      if (remote) {
        await (_db.update(
          _db.pendingMineQueue,
        )..where(($PendingMineQueueTable t) => t.id.equals(row.id))).write(
          const PendingMineQueueCompanion(
            status: Value<String>(PendingMineStatus.landed),
            lastError: Value<String?>(null),
          ),
        );
      }
      return remote;
    });
    if (!remoteCopy) await remove(row.id);
  }

  /// 送达（或确认重复）/ 用户删除：先删行，再删载荷。
  Future<void> remove(String id) async {
    await (_db.delete(
      _db.pendingMineQueue,
    )..where(($PendingMineQueueTable t) => t.id.equals(id))).go();
    final File file = await _payloadFile(id);
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // 孤儿文件不影响正确性，[sweepOrphanPayloads] 会再清。
    }
  }

  /// 删掉没有对应行的载荷文件与写到一半的 `.tmp`（崩在「写文件」与「插行」之间、
  /// 或「删行」与「删文件」之间留下的）。
  Future<void> sweepOrphanPayloads() => _locked<void>(() async {
    final Directory dir = await _root();
    if (!dir.existsSync()) return;
    final Set<String> ids = (await rows())
        .map((PendingMineRow r) => r.id)
        .toSet();
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      final String name = p.basename(e.path);
      final bool orphan =
          name.endsWith('.tmp') ||
          (name.endsWith('.json') &&
              !ids.contains(name.substring(0, name.length - '.json'.length)));
      if (!orphan) continue;
      try {
        e.deleteSync();
      } on FileSystemException {
        // 下次再清。
      }
    }
  });

  Future<void> _update(
    String id,
    PendingMineQueueCompanion changes, {
    bool bumpAttempts = false,
  }) async {
    await _db.transaction(() async {
      final PendingMineRow? row =
          await (_db.select(_db.pendingMineQueue)
                ..where(($PendingMineQueueTable t) => t.id.equals(id)))
              .getSingleOrNull();
      if (row == null) return;
      await (_db.update(
        _db.pendingMineQueue,
      )..where(($PendingMineQueueTable t) => t.id.equals(id))).write(
        bumpAttempts
            ? changes.copyWith(attempts: Value<int>(row.attempts + 1))
            : changes,
      );
    });
  }
}
