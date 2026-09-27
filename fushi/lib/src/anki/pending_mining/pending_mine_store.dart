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
    final File file = await _payloadFile(id);
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload.toJson()), flush: true);
    await tmp.rename(file.path);
    await _db
        .into(_db.pendingMineQueue)
        .insert(
          PendingMineQueueCompanion.insert(
            id: id,
            createdAt: _clock(),
            expression: expression,
            reading: Value<String>(reading),
          ),
        );
    return id;
  }

  /// 全部待发卡，按入队顺序（最早的在前）。
  Future<List<PendingMineRow>> all() =>
      (_db.select(_db.pendingMineQueue)
            ..orderBy(<OrderingTerm Function($PendingMineQueueTable)>[
              ($PendingMineQueueTable t) => OrderingTerm.asc(t.createdAt),
              ($PendingMineQueueTable t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// 可以（自动）补发的卡：`pending`，以及上次补发到一半进程就没了的 `sending`。
  /// `failed` 不在其列——它们要等用户点「重试」。
  Future<List<PendingMineRow>> sendable() async => (await all())
      .where((PendingMineRow r) => r.status != PendingMineStatus.failed)
      .toList(growable: false);

  /// 队列里一共几张（任何状态）。
  Future<int> count() async {
    final Expression<int> n = _db.pendingMineQueue.id.count();
    final TypedResult row = await (_db.selectOnly(
      _db.pendingMineQueue,
    )..addColumns(<Expression<Object>>[n])).getSingle();
    return row.read(n) ?? 0;
  }

  /// 队列表有任何变化时发一个事件（UI 据此重读）。用 tableUpdates 而不是
  /// `select().watch()`：后者在长驻页面 dispose 时会留下 Timer（BUG-834）。
  Stream<void> changes() => _db
      .tableUpdates(TableUpdateQuery.onTable(_db.pendingMineQueue))
      .map((_) {});

  /// 读回载荷；文件丢了或坏了返回 null。
  Future<ForwardedMinePayload?> readPayload(String id) async {
    final File file = await _payloadFile(id);
    if (!file.existsSync()) return null;
    try {
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return ForwardedMinePayload.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
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

  /// 送达（或确认重复）/ 用户删除：先删行，再删载荷。
  Future<void> remove(String id) async {
    await (_db.delete(
      _db.pendingMineQueue,
    )..where(($PendingMineQueueTable t) => t.id.equals(id))).go();
    final File file = await _payloadFile(id);
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // 孤儿文件不影响正确性，下次清理再说。
    }
  }

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
