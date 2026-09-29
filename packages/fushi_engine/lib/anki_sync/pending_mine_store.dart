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

  /// 记录 id 的白名单：本机 [newId] 只产 32 位十六进制；远端中转发来的 id 来自
  /// 对端文件名，不可信——id 要拼进本机载荷路径（`<root>/<id>.json`）与墓碑路径，
  /// 含 `..`、分隔符或过长的一律拒收（BUG-2773 路径穿越）。
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// [id] 能不能当本机记录 id（能安全拼进文件路径）。
  static bool isValidId(String id) => _idPattern.hasMatch(id);

  static String _checkedId(String id) {
    if (!isValidId(id)) {
      throw ArgumentError.value(id, 'id', 'invalid pending mine record id');
    }
    return id;
  }

  /// 已落地墓碑保留多久。同一张卡可能经多条同步通道各传一份（BUG-2773），
  /// 任一通道落地后其它通道的副本要靠墓碑认出来；每条通道见到副本就会顺手清掉
  /// 远端，所以只需覆盖「最久不同步的那条通道」的间隔。
  static const Duration landedTombstoneRetention = Duration(days: 180);

  /// 墓碑目录名（`<root>/landed/<id>`，空文件）。不用 `.json` 后缀：
  /// [sweepOrphanPayloads] 只扫根目录的 `.json` / `.tmp`，子目录不受影响。
  static const String _landedDirName = 'landed';

  /// 128 位随机十六进制 id。
  static String newId() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  Future<File> _payloadFile(String id) async =>
      File(p.join((await _root()).path, '${_checkedId(id)}.json'));

  Future<File> _tombstoneFile(String id) async => File(
    p.join((await _root()).path, _landedDirName, _checkedId(id)),
  );

  /// 这张卡（按幂等键 = 记录 id）是否已经在本机落地过。非法 id 按「已落地」处理：
  /// 反正不会收。
  Future<bool> hasLanded(String id) async {
    if (!isValidId(id)) return true;
    try {
      return (await _tombstoneFile(id)).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  /// 记下「这张来自其他设备的卡已在本机落地」。本地持久、与行无关：行删了之后，
  /// 任何一条同步通道再把同 id 的副本送来，[insertRemote] 都会拒收。
  Future<void> _markLanded(String id) async {
    final File f = await _tombstoneFile(id);
    await f.parent.create(recursive: true);
    if (!f.existsSync()) await f.writeAsBytes(const <int>[], flush: true);
  }

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
    if (!isValidId(id)) {
      throw ArgumentError.value(id, 'id', 'invalid pending mine record id');
    }
    // 幂等键：本机已经落过这张（另一条通道送来过），不再收（BUG-2773）。
    if (await hasLanded(id)) return false;
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

  /// 本机的卡要上传到跨设备中转命名空间：先落「已上传」的意图。
  ///
  /// 只在这张卡此刻没在本机补发（`pending` / `failed`）时才成立，返回是否成立。
  /// 与 [markSending] 在同一个事务里互斥：一张卡要么交给落地设备、要么本机补发，
  /// 不会两边各落一张（BUG-2773）。
  Future<bool> markUploaded(String id) => _db.transaction(() async {
    final PendingMineRow? row = await byId(id);
    if (row == null) return false;
    if (row.uploaded) return true;
    if (row.status != PendingMineStatus.pending &&
        row.status != PendingMineStatus.failed) {
      return false;
    }
    await (_db.update(_db.pendingMineQueue)
          ..where(($PendingMineQueueTable t) => t.id.equals(id)))
        .write(const PendingMineQueueCompanion(uploaded: Value<bool>(true)));
    return true;
  });

  /// 撤回上传：远端记录已删掉，这张卡回到本机补发（本机成了落地设备时）。
  Future<void> clearUploaded(String id) => _update(
    id,
    const PendingMineQueueCompanion(uploaded: Value<bool>(false)),
  );

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
  ///
  /// 本机制的、已经上传到跨设备中转的卡不在其中：它已交给落地设备，本机再补发
  /// 就是两台设备各落一张（BUG-2773）。落地设备易主成本机时，中转会先撤回远端
  /// 记录、清掉 `uploaded`，它才回到这里。
  Future<List<PendingMineRow>> sendable() async =>
      (await rows()).where(_isSendable).toList(growable: false);

  static bool _isSendable(PendingMineRow r) =>
      (r.status == PendingMineStatus.pending ||
          r.status == PendingMineStatus.sending) &&
      !(r.uploaded && r.originDeviceId == null);

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

  /// 认领一张卡开始补发，返回是否认领成功。已被中转上传（交给别的设备落地）、
  /// 已落地或已不存在的卡返回 false，调用方跳过它——判据读库里此刻的行，与
  /// [markUploaded] 在事务里互斥（BUG-2773）。
  Future<bool> markSending(String id) => _db.transaction(() async {
    final PendingMineRow? row = await byId(id);
    if (row == null ||
        row.status == PendingMineStatus.landed ||
        (row.uploaded && row.originDeviceId == null)) {
      return false;
    }
    await (_db.update(
      _db.pendingMineQueue,
    )..where(($PendingMineQueueTable t) => t.id.equals(id))).write(
      PendingMineQueueCompanion(
        status: const Value<String>(PendingMineStatus.sending),
        lastAttemptAt: Value<int?>(_clock()),
        attempts: Value<int>(row.attempts + 1),
      ),
    );
    return true;
  });

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
  ///
  /// 来自其他设备的卡另外留一块本地墓碑（[hasLanded]），行删掉之后其它同步通道
  /// 再送来同 id 的副本也不会再落（BUG-2773）。
  Future<void> markDelivered(PendingMineRow row) async {
    final bool remoteCopy = await _db.transaction(() async {
      final PendingMineRow? now = await byId(row.id);
      if (now == null) return false;
      // 墓碑先于行状态落盘：两步之间被杀，最坏多一块墓碑，不会漏。
      if (now.originDeviceId != null) await _markLanded(now.id);
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
  /// 或「删行」与「删文件」之间留下的），以及过了保留期的已落地墓碑。
  Future<void> sweepOrphanPayloads() => _locked<void>(() async {
    final Directory dir = await _root();
    if (!dir.existsSync()) return;
    _sweepExpiredTombstones(Directory(p.join(dir.path, _landedDirName)));
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

  void _sweepExpiredTombstones(Directory dir) {
    if (!dir.existsSync()) return;
    final DateTime cutoff = DateTime.fromMillisecondsSinceEpoch(
      _clock(),
    ).subtract(landedTombstoneRetention);
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File) continue;
      try {
        if (e.lastModifiedSync().isBefore(cutoff)) e.deleteSync();
      } on FileSystemException {
        // 下次再清。
      }
    }
  }

  Future<void> _update(String id, PendingMineQueueCompanion changes) async {
    await (_db.update(
      _db.pendingMineQueue,
    )..where(($PendingMineQueueTable t) => t.id.equals(id))).write(changes);
  }
}
