/// 还原点存储（设计 `docs/specs/2026-11-25-auto-backup-restore-points.md` 第一层）。
///
/// 布局：`<库目录>/restore_points/<id>/`，一个目录一个还原点：
/// - 快照文件与活库同名（主库 `fushi.db`、复习库 `srs4.db`）；
/// - `restore_point.json` **最后**写（临时名 + 改名），它在 = 这个还原点完整；没有它的目录
///   是写到一半的残留，下次建点时清掉；
/// - id = `<UTC yyyyMMdd-HHmmss-SSS>-<database>-<kind>`（撞名补 `-2`、`-3`…），按字典序即按时间。
///
/// 主库的更新前快照由 `database.dart` 的 `_openDb` 在迁移之前调 [RestorePointStore.snapshotBeforeMigration]；
/// 复习库由 Rust（`native/fushi_fsrs` `store/gen4/restore_point.rs`）按同一格式写，两边只清
/// 自己 database 的目录。每次尝试后写 `last_snapshot_status.<database>.json`，失败只记录、
/// 绝不挡开库；app 启动后据此提示一次。
///
/// 回滚（降级屏 / 主库损坏屏的「恢复更新前的数据」）在库关着时做：当前文件挪进新的
/// `pre_rollback` 还原点（回滚本身可撤销），快照经临时名复制回来。进度记在
/// `rollback_pending.json`，崩在中途由下次开库前的 [RestorePointStore.recoverPendingRollback]
/// 按记下的步骤补完。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../utils/backup_retention.dart';
import '../utils/fushi_debug_print.dart';
import 'database.dart' show kMinSupportedSchemaVersion;
import 'db_schema_version.dart';
import 'free_space.dart';

/// 还原点根目录名（库目录的直接子目录）。
const String kRestorePointsDirName = 'restore_points';

/// 还原点元数据文件名；它的存在就是「这个还原点完整」的标记。
const String kRestorePointMetaFileName = 'restore_point.json';

/// 元数据 / 状态文件的格式版本。
const int kRestorePointFormat = 1;

/// 每个库保留的更新前还原点数（D3）。迁移成功后**不删**：那正是需要回滚的时候。
const int kRestorePointKeepPreUpdate = 3;

/// 每个库保留的回滚前还原点数。
const int kRestorePointKeepPreRollback = 3;

/// 操作前还原点（覆盖下载、复习迁移、从还原点页「替换」之前）**每个 `reason`** 保留的最新份数。
/// 按 reason 分开算：同步对比跑上几次不会把「Anki 迁移之前」那份挤掉（D6 的承诺）。
const int kRestorePointKeepPreOperation = 5;

/// 个别 reason 的保留份数（不在表里的用 [kRestorePointKeepPreOperation]）。
const Map<String, int> kRestorePointKeepPreOperationByReason = <String, int>{};

/// 定时还原点的保留（D3）：48 小时内全留，之后 7 天每天、4 周每周、3 个月每月各留最新一份，
/// 总大小不超过 5 GB（从最旧的定时还原点删起）。最新一份永远留。
const BackupRetentionPolicy kRestorePointScheduledRetention =
    BackupRetentionPolicy(
      keepMinimum: 1,
      keepAllWithin: Duration(hours: 48),
      dailyDays: 7,
      weeklyWeeks: 4,
      monthlyMonths: 3,
      maxTotalBytes: 5 * 1024 * 1024 * 1024,
    );

/// 定时还原点里的整包备份文件名（与手动导出同一格式的 zip）。
const String kRestorePointArchiveFileName = 'backup.zip';

/// 回滚进度日志（崩溃恢复用）。
const String kRestorePointRollbackJournalFileName = 'rollback_pending.json';

/// 定时还原点目录里的「谁在写」标记（内容 = 写入设备的 id）：[RestorePointStore.begin] 一开始就写，
/// 不算还原点的文件。共用文件夹（同步盘）里没有元数据的目录可能是别的设备正在写、或同步还没传完的点；
/// 只有标记是本机的才当作本机写到一半的残留清掉（[RestorePointStore.cleanIncompleteScheduled]）。
const String kRestorePointOwnerFileName = '.restore_point_owner';

/// 定时还原点 id 的形状：`<UTC yyyyMMdd-HHmmss-SSS>-<库>-scheduled[-n]`。
final RegExp _kScheduledIdPattern = RegExp(
  r'^\d{8}-\d{6}-\d{3}-(fushi|srs)-scheduled(-\d{1,4})?$',
);

/// [id] 是不是一个合格的定时还原点目录名（用户文件夹 / 云端副本的 id 来自外部：Android 上是提供者给的
/// 显示名，云端是列目录的结果；取回本机时按它拼路径，`..`、绝对路径之类会逃出存储根）。
bool isScheduledRestorePointId(String id) =>
    isPlainRestorePointFileName(id) && _kScheduledIdPattern.hasMatch(id);

/// [name] 是不是目录里的一个普通名字（不空、不是 `.` / `..`、不带路径分隔符、NUL 或 `:`——Windows 上
/// `名字:流` 是 NTFS 备用数据流，写进去的内容不出现在目录列表里）。
bool isPlainRestorePointFileName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains(r'\') &&
    !name.contains(':') &&
    !name.contains('\x00');

const String _kTmpSuffix = '.tmp';
const String _kRollbackTmpSuffix = '.rollback-tmp';

/// 活库的侧车；回滚时随活库一起挪走（先挪侧车、最后挪主文件）。
const List<String> _kSidecarSuffixes = <String>['-wal', '-shm', '-journal'];

/// 还原点的种类。
enum RestorePointKind {
  /// 主库 / 复习库迁移之前的原始库快照（第一期）。
  preUpdate('pre_update'),

  /// 回滚 / 替换之前被换下来的活库（回滚本身可撤销）。
  preRollback('pre_rollback'),

  /// 定时备份：一份整包备份 zip（[kRestorePointArchiveFileName]），内容按用户勾选的类别。
  scheduled('scheduled'),

  /// 有破坏性的操作之前强制拍的原始库快照（元数据 `reason` 写明是哪个操作）。
  preOperation('pre_operation');

  const RestorePointKind(this.wire);

  /// 写进 id 与元数据的名字。
  final String wire;

  static RestorePointKind? fromWire(Object? raw) {
    for (final RestorePointKind k in values) {
      if (k.wire == raw) return k;
    }
    return null;
  }
}

/// 还原点属于哪个库。
enum RestorePointDatabase {
  /// 主库 `fushi.db`（drift，本包）。
  fushi('fushi', 'fushi.db'),

  /// 复习库 `srs4.db`（Rust 内核独占）。
  srs('srs', 'srs4.db');

  const RestorePointDatabase(this.wire, this.fileName);

  /// 写进 id 与元数据的名字。
  final String wire;

  /// 活库（也是快照）的文件名。
  final String fileName;

  static RestorePointDatabase? fromWire(Object? raw) {
    for (final RestorePointDatabase d in values) {
      if (d.wire == raw) return d;
    }
    return null;
  }
}

/// 还原点里的一个文件。
class RestorePointFile {
  const RestorePointFile({required this.name, required this.size});

  final String name;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'size': size,
  };
}

/// 一个完整的还原点（目录里有可解析的元数据）。
class RestorePoint {
  const RestorePoint({
    required this.id,
    required this.directory,
    required this.kind,
    required this.database,
    required this.createdAtMs,
    required this.fromSchema,
    required this.toSchema,
    required this.files,
    this.appVersion,
    this.reason,
    this.categories,
    this.excludedCategories,
    this.includesSrsMedia,
    this.fullDatabase,
    this.deviceId,
    this.deviceName,
    this.copiedBackAtMs,
  });

  /// 目录名。
  final String id;

  /// 还原点目录的绝对路径。
  final String directory;
  final RestorePointKind kind;
  final RestorePointDatabase database;
  final int createdAtMs;

  /// 快照里那份库的 schema（更新前快照 = 升级前的版本；0 = 未知，例如损坏的库）。
  final int fromSchema;

  /// 触发快照的那次升级要升到的 schema（回滚前还原点与 [fromSchema] 相同）。
  final int toSchema;

  /// 写下它的 app 版本（宿主没注入时为 null）。
  final String? appVersion;
  final List<RestorePointFile> files;

  /// 操作前还原点：是哪个操作之前拍的（`sync_download` / `srs_migration` / `replace` …）。
  final String? reason;

  /// 定时还原点：备份里带了哪些类别（`BackupCategory.name`）；其它种类为 null。
  final List<String>? categories;

  /// 定时还原点：用户没勾的类别。
  final List<String>? excludedCategories;

  /// 定时还原点：复习媒体（卡片图片 / 音频）有没有随包（D2，默认不带）。
  final bool? includesSrsMedia;

  /// 定时还原点：zip 里的主库是不是整库（不按类别剥行；用户 2026-11-25 拍板）。整库点的
  /// [categories] / [excludedCategories] 只说明哪些**文件树**随包，库里的数据一律都在。
  /// 老的定时点为 null（按类别剥过行）。
  final bool? fullDatabase;

  /// 哪台设备写的（同步 / 设备本地的设备 id）：定时还原点（本机存储、自定义文件夹）与用户文件夹 /
  /// 云端副本都带。文件夹可能被几台设备共用（同步盘），保留规则只修剪本机写的点；更早的点为 null。
  final String? deviceId;

  /// [deviceId] 那台设备的显示名（还原点页标「来自另一台设备」用）。
  final String? deviceName;

  /// 从用户文件夹 / 云端副本取回本机的时刻。取回的点**从不自动修剪**（用户在还原点页自己删）：否则
  /// 下一次定时备份的保留规则会把刚取回、还没来得及用的旧点删掉。
  final int? copiedBackAtMs;

  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true);

  /// 全部文件的字节数。
  int get totalBytes =>
      files.fold<int>(0, (int sum, RestorePointFile f) => sum + f.size);

  /// 快照主文件的路径（与活库同名）。
  String get snapshotPath => p.join(directory, database.fileName);

  /// [db] 的原始库快照路径（操作前还原点可能同时带主库与复习库）；不在这个点里返回 null。
  String? rawDatabasePath(RestorePointDatabase db) {
    if (!files.any((RestorePointFile f) => f.name == db.fileName)) return null;
    return p.join(directory, db.fileName);
  }

  /// 整包备份 zip 的路径（定时还原点）；没有返回 null。
  String? get archivePath =>
      files.any((RestorePointFile f) => f.name == kRestorePointArchiveFileName)
      ? p.join(directory, kRestorePointArchiveFileName)
      : null;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': kRestorePointFormat,
    'kind': kind.wire,
    'database': database.wire,
    'createdAtMs': createdAtMs,
    'fromSchema': fromSchema,
    'toSchema': toSchema,
    'appVersion': appVersion,
    'files': <Map<String, Object?>>[
      for (final RestorePointFile f in files) f.toJson(),
    ],
    if (reason != null) 'reason': reason,
    if (categories != null) 'categories': categories,
    if (excludedCategories != null) 'excludedCategories': excludedCategories,
    if (includesSrsMedia != null) 'srsMedia': includesSrsMedia,
    if (fullDatabase != null) 'fullDatabase': fullDatabase,
    if (deviceId != null) 'deviceId': deviceId,
    if (deviceName != null) 'deviceName': deviceName,
    if (copiedBackAtMs != null) 'copiedBackAtMs': copiedBackAtMs,
  };

  /// 解析 [directory] 里的元数据；缺字段 / 不认识的种类 / 读不了返回 null（当作不完整）。
  static RestorePoint? tryRead(String directory) {
    try {
      final File meta = File(p.join(directory, kRestorePointMetaFileName));
      if (!meta.existsSync()) return null;
      return tryParse(
        meta.readAsStringSync(),
        id: p.basename(directory),
        directory: directory,
      );
    } on Object {
      return null;
    }
  }

  /// 解析元数据正文 [text]（[tryRead] 与用户文件夹里的副本共用：Android 的 SAF 文件夹没有
  /// 文件路径，元数据由原生读成文本交回）。[directory] 是这份点的位置（本地路径，或文件夹副本的
  /// 句柄）。缺字段 / 不认识的种类返回 null。
  static RestorePoint? tryParse(
    String text, {
    required String id,
    required String directory,
  }) {
    try {
      final Object? raw = jsonDecode(text);
      if (raw is! Map<String, Object?>) return null;
      final RestorePointKind? kind = RestorePointKind.fromWire(raw['kind']);
      final RestorePointDatabase? db = RestorePointDatabase.fromWire(
        raw['database'],
      );
      final Object? created = raw['createdAtMs'];
      final Object? from = raw['fromSchema'];
      final Object? to = raw['toSchema'];
      final Object? files = raw['files'];
      if (kind == null ||
          db == null ||
          created is! int ||
          from is! int ||
          to is! int ||
          files is! List<Object?>) {
        return null;
      }
      final Object? app = raw['appVersion'];
      final Object? reason = raw['reason'];
      final Object? srsMedia = raw['srsMedia'];
      final Object? fullDb = raw['fullDatabase'];
      // 文件名只能是目录里的一个文件（用户文件夹里的副本元数据不完全可信：取回本机时按这些名字
      // 拼路径，`../` 之类会写到目录外面）。有一个不合格就整份当作不完整。
      for (final Object? f in files) {
        final Object? name = f is Map<String, Object?> ? f['name'] : null;
        if (name is String && !isPlainRestorePointFileName(name)) {
          return null;
        }
      }
      final Object? device = raw['deviceId'];
      final Object? deviceName = raw['deviceName'];
      final Object? copiedBack = raw['copiedBackAtMs'];
      List<String>? strings(Object? v) => v is List<Object?>
          ? <String>[
              for (final Object? e in v)
                if (e is String) e,
            ]
          : null;
      return RestorePoint(
        id: id,
        directory: directory,
        kind: kind,
        database: db,
        createdAtMs: created,
        fromSchema: from,
        toSchema: to,
        appVersion: app is String ? app : null,
        files: <RestorePointFile>[
          for (final Object? f in files)
            if (f is Map<String, Object?> &&
                f['name'] is String &&
                f['size'] is int)
              RestorePointFile(
                name: f['name']! as String,
                size: f['size']! as int,
              ),
        ],
        reason: reason is String ? reason : null,
        categories: strings(raw['categories']),
        excludedCategories: strings(raw['excludedCategories']),
        includesSrsMedia: srsMedia is bool ? srsMedia : null,
        fullDatabase: fullDb is bool ? fullDb : null,
        deviceId: device is String && device.isNotEmpty ? device : null,
        deviceName: deviceName is String && deviceName.isNotEmpty
            ? deviceName
            : null,
        copiedBackAtMs: copiedBack is int ? copiedBack : null,
      );
    } on Object {
      return null;
    }
  }
}

/// 最近一次快照尝试的结果（`last_snapshot_status.<database>.json`）。
class RestorePointSnapshotStatus {
  const RestorePointSnapshotStatus({
    required this.database,
    required this.ok,
    required this.atMs,
    required this.fromSchema,
    required this.toSchema,
    this.pointId,
    this.error,
    this.acknowledged = false,
  });

  final RestorePointDatabase database;
  final bool ok;
  final int atMs;
  final int fromSchema;
  final int toSchema;
  final String? pointId;
  final String? error;

  /// 失败已经提示过用户。
  final bool acknowledged;

  /// 要不要在启动后提示一次。
  bool get needsNotice => !ok && !acknowledged;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': kRestorePointFormat,
    'database': database.wire,
    'ok': ok,
    'atMs': atMs,
    'fromSchema': fromSchema,
    'toSchema': toSchema,
    'pointId': pointId,
    'error': error,
    'acknowledged': acknowledged,
  };

  static RestorePointSnapshotStatus? tryParse(String text) {
    try {
      final Object? raw = jsonDecode(text);
      if (raw is! Map<String, Object?>) return null;
      final RestorePointDatabase? db = RestorePointDatabase.fromWire(
        raw['database'],
      );
      final Object? ok = raw['ok'];
      final Object? at = raw['atMs'];
      if (db == null || ok is! bool || at is! int) return null;
      final Object? from = raw['fromSchema'];
      final Object? to = raw['toSchema'];
      final Object? id = raw['pointId'];
      final Object? error = raw['error'];
      return RestorePointSnapshotStatus(
        database: db,
        ok: ok,
        atMs: at,
        fromSchema: from is int ? from : 0,
        toSchema: to is int ? to : 0,
        pointId: id is String ? id : null,
        error: error is String ? error : null,
        acknowledged: raw['acknowledged'] == true,
      );
    } on Object {
      return null;
    }
  }
}

/// 一次回滚要换的库：[target] 换回来，当前活库挪进新的回滚前还原点。
class RestorePointRollbackPlan {
  const RestorePointRollbackPlan({required this.target, this.database});

  final RestorePoint target;

  /// 换哪个库；null = [target] 自己的库。操作前还原点同时带两个库，换复习库时点名
  /// [RestorePointDatabase.srs]。
  final RestorePointDatabase? database;

  /// 实际要换的库。
  RestorePointDatabase get effectiveDatabase => database ?? target.database;

  /// 目标快照文件。
  String get snapshotPath =>
      p.join(target.directory, effectiveDatabase.fileName);
}

/// 一个正在写的还原点：目录已占住，元数据还没写（[RestorePointStore.commit] 写元数据、
/// [RestorePointStore.discard] 删目录）。进程内登记着，写的过程中 [RestorePointStore.prune]
/// 不会把它当残留删掉。
class RestorePointDraft {
  const RestorePointDraft._({
    required this.id,
    required this.directory,
    required this.kind,
    required this.database,
    required this.createdAtMs,
  });

  final String id;
  final String directory;
  final RestorePointKind kind;
  final RestorePointDatabase database;
  final int createdAtMs;
}

/// 仅供测试：在 `VACUUM INTO` 写出快照之后、校验之前返回 true，模拟快照失败（磁盘写满等
/// 无法在测试里真造出来的现场）。生产代码从不设置它。
bool Function()? debugRestorePointSnapshotFailureForTesting;

/// 仅供测试：回滚的每一步完成之后调用（步骤名），抛异常即模拟「崩在这一步之后」。
/// 生产代码从不设置它。
void Function(String step)? debugRestorePointRollbackStepForTesting;

/// 一个库目录下的还原点存储。
class RestorePointStore {
  /// [rootDirectory] 缺省 = `<dbDirectory>/restore_points`；定时备份选了自定义文件夹时
  /// 用那个文件夹（只放定时还原点，回滚与状态文件仍在默认位置）。
  RestorePointStore(this.dbDirectory, {String? rootDirectory})
    : _rootOverride = rootDirectory;

  /// 活库所在目录（`fushi.db` / `srs4.db` 都在这里）。
  final String dbDirectory;

  final String? _rootOverride;

  /// 进程内正在写的还原点目录（绝对路径）。
  static final Set<String> _activeDrafts = <String>{};

  /// 进程内正在被还原（替换 / 补回）的还原点目录（规范化路径 → 持有计数）。任何修剪都不删它们。
  static final Map<String, int> _heldPoints = <String, int>{};

  /// 在还原 [directory] 那个点的整个过程中把它钉住：[prune] / [pruneScheduled] 都不删它。
  /// 返回的回调解除这一次持有（可重复调，只生效一次）。
  static void Function() hold(String directory) {
    final String key = p.normalize(directory);
    _heldPoints[key] = (_heldPoints[key] ?? 0) + 1;
    bool released = false;
    return () {
      if (released) return;
      released = true;
      final int left = (_heldPoints[key] ?? 1) - 1;
      if (left <= 0) {
        _heldPoints.remove(key);
      } else {
        _heldPoints[key] = left;
      }
    };
  }

  /// [directory] 是不是正被钉住（[hold]）。
  static bool isHeld(String directory) =>
      _heldPoints.containsKey(p.normalize(directory));

  /// 宿主注入的 app 版本，写进新建还原点的元数据。fushi_core 自己不知道版本号，由 app /
  /// 服务端在开库前设置；没设置时元数据里为 null。
  static String? appVersion;

  /// 还原点根目录。
  String get root =>
      _rootOverride ?? p.join(dbDirectory, kRestorePointsDirName);

  String _statusPath(RestorePointDatabase db) =>
      p.join(root, 'last_snapshot_status.${db.wire}.json');

  String get _journalPath => p.join(root, kRestorePointRollbackJournalFileName);

  /// 有没有没做完的回滚。
  bool get hasPendingRollback => File(_journalPath).existsSync();

  /// 完整的还原点，新的在前；[database] 非空时只列那个库的。
  List<RestorePoint> list({RestorePointDatabase? database}) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return const <RestorePoint>[];
    final List<RestorePoint> out = <RestorePoint>[];
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final RestorePoint? point = RestorePoint.tryRead(e.path);
      if (point == null) continue;
      if (database != null && point.database != database) continue;
      out.add(point);
    }
    out.sort(_newestFirst);
    return out;
  }

  static int _newestFirst(RestorePoint a, RestorePoint b) {
    final int byTime = b.createdAtMs.compareTo(a.createdAtMs);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  }

  /// 本版本能直接打开的 [database] 还原点（快照 schema 在 `[minSchema, maxSchema]` 内、
  /// 快照文件还在），新的在前。降级屏 / 损坏屏据此列出可回滚的点。
  List<RestorePoint> compatible({
    required RestorePointDatabase database,
    required int maxSchema,
    int minSchema = 1,
  }) => <RestorePoint>[
    for (final RestorePoint point in list(database: database))
      if (point.fromSchema >= minSchema &&
          point.fromSchema <= maxSchema &&
          File(point.snapshotPath).existsSync())
        point,
  ];

  /// 主库版的 [compatible]：本构建的 schema 区间。
  List<RestorePoint> compatibleMainDatabasePoints() => compatible(
    database: RestorePointDatabase.fushi,
    maxSchema: kFushiDbSchemaVersion,
    minSchema: kMinSupportedSchemaVersion,
  );

  /// 与主库还原点 [mainPoint] 出自同一次更新的复习库还原点：复习库的更新前快照建在
  /// [mainPoint] 之后、下一个主库更新前还原点之前，且当前 `srs4.db` 还停在那次升级升到的
  /// schema（之后没再被别的版本升过）。满足时回滚主库要把复习库一起换回去，否则旧版本会
  /// 因为复习库比它新而打不开复习；不满足返回 null（复习库原样保留）。
  ///
  /// 目前新代复习库没有原地升级阶梯（Rust 不会建复习库的更新前还原点），这条恒为 null；
  /// 阶梯落地后自动生效。
  RestorePoint? companionSrsPoint(RestorePoint mainPoint) {
    // 只有「更新前」点有配对：别的种类（回滚前、以后的定时 / 操作前点）不是某次更新拍的，
    // 拿时间窗去配一份复习库更新前快照，会把那次更新以来的复习记录悄悄换掉。
    if (mainPoint.database != RestorePointDatabase.fushi ||
        mainPoint.kind != RestorePointKind.preUpdate) {
      return null;
    }
    final List<RestorePoint> srsPoints = <RestorePoint>[
      for (final RestorePoint point in list(database: RestorePointDatabase.srs))
        if (point.kind == RestorePointKind.preUpdate) point,
    ];
    if (srsPoints.isEmpty) return null;
    int? nextMainMs;
    for (final RestorePoint point in list(
      database: RestorePointDatabase.fushi,
    )) {
      if (point.kind == RestorePointKind.preUpdate &&
          point.createdAtMs > mainPoint.createdAtMs &&
          (nextMainMs == null || point.createdAtMs < nextMainMs)) {
        nextMainMs = point.createdAtMs;
      }
    }
    final int? liveSchema = readSrsLibrarySchema(
      p.join(dbDirectory, RestorePointDatabase.srs.fileName),
    );
    if (liveSchema == null) return null;
    final List<RestorePoint> candidates = <RestorePoint>[
      for (final RestorePoint point in srsPoints)
        if (point.createdAtMs >= mainPoint.createdAtMs &&
            (nextMainMs == null || point.createdAtMs < nextMainMs) &&
            point.toSchema == liveSchema &&
            File(point.snapshotPath).existsSync())
          point,
    ];
    // [list] 新的在前：同一窗口里取最早的那个（最接近更新前的状态）。
    return candidates.isEmpty ? null : candidates.last;
  }

  /// 最近一次快照尝试的结果；没有 / 读不了返回 null。
  RestorePointSnapshotStatus? readLastStatus(RestorePointDatabase database) {
    final File f = File(_statusPath(database));
    if (!f.existsSync()) return null;
    try {
      return RestorePointSnapshotStatus.tryParse(f.readAsStringSync());
    } on Object {
      return null;
    }
  }

  /// 写最近一次快照尝试的结果（临时名 + 改名）。写不进去只记日志。
  void writeLastStatus(RestorePointSnapshotStatus status) {
    try {
      Directory(root).createSync(recursive: true);
      _writeAtomicSync(
        _statusPath(status.database),
        jsonEncode(status.toJson()),
      );
    } on Object catch (e) {
      fushiDebugPrint('[restore-points] status write failed: $e');
    }
  }

  /// 主库与复习库里还没提示过的失败（启动后提示一次用）。
  List<RestorePointSnapshotStatus> unacknowledgedFailures() =>
      <RestorePointSnapshotStatus>[
        for (final RestorePointDatabase db in RestorePointDatabase.values)
          if (readLastStatus(db) case final RestorePointSnapshotStatus s
              when s.needsNotice)
            s,
      ];

  /// 把 [database] 的失败标成已提示。
  void acknowledgeLastStatus(RestorePointDatabase database) {
    final RestorePointSnapshotStatus? s = readLastStatus(database);
    if (s == null || s.acknowledged) return;
    writeLastStatus(
      RestorePointSnapshotStatus(
        database: s.database,
        ok: s.ok,
        atMs: s.atMs,
        fromSchema: s.fromSchema,
        toSchema: s.toSchema,
        pointId: s.pointId,
        error: s.error,
        acknowledged: true,
      ),
    );
  }

  // ── 更新前快照 ──────────────────────────────────────────────────────────────

  /// 主库迁移之前调用（只在主进程、只对目录形式开的活库，见 `database.dart` 的 `_openDb`）：库的 `user_version` 落在
  /// `[kMinSupportedSchemaVersion, kFushiDbSchemaVersion)` 才建点——全新库（0）、同版本、
  /// 比本版本新（降级，开库会被拒）、低于门槛（开库会被拒）都不建。
  ///
  /// `user_version` 用一条原始连接读（WAL 库的第 1 页可能还在 `-wal` 里，读文件头不可靠），
  /// 快照用 `VACUUM INTO`（一致、带上 WAL 里的页），再对副本 `PRAGMA quick_check`，最后写元数据。
  /// 快照与校验在后台 isolate 里跑。**永不抛**：失败删掉半截目录、记状态，返回 null，迁移照常。
  Future<RestorePoint?> snapshotBeforeMigration({
    required String dbFilePath,
    RestorePointDatabase database = RestorePointDatabase.fushi,
    int targetSchema = kFushiDbSchemaVersion,
    int minSchema = kMinSupportedSchemaVersion,
  }) async {
    if (!File(dbFilePath).existsSync()) return null;
    final int version;
    try {
      // 每次启动都走这里：开一条只读连接读一个 PRAGMA 是毫秒级，不值得起 isolate。
      version = readSqliteUserVersionSync(dbFilePath);
    } on Object catch (e) {
      // 读不了版本号：开库本身会在后面按原有路径报错 / 恢复，这里不额外记失败。
      fushiDebugPrint('[restore-points] user_version probe failed: $e');
      return null;
    }
    if (version == 0 || version < minSchema || version >= targetSchema) {
      return null;
    }
    return createPreUpdatePoint(
      dbFilePath: dbFilePath,
      database: database,
      fromSchema: version,
      toSchema: targetSchema,
    );
  }

  /// 建一个更新前还原点（[snapshotBeforeMigration] 判定之后的那一半；测试可直接调）。永不抛。
  Future<RestorePoint?> createPreUpdatePoint({
    required String dbFilePath,
    required RestorePointDatabase database,
    required int fromSchema,
    required int toSchema,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    String? pointDir;
    try {
      // 空间不够就不拍（[NotEnoughSpaceException] 记成状态里的 `not_enough_space`），迁移照常。
      ensureFreeSpace(<SpaceNeed>[
        SpaceNeed(root, _liveDatabaseBytes(dbFilePath)),
      ]);
      Directory(root).createSync(recursive: true);
      final String id = _uniqueId(now, database, RestorePointKind.preUpdate);
      pointDir = p.join(root, id);
      Directory(pointDir).createSync();
      final String dest = p.join(pointDir, database.fileName);
      await Isolate.run(() => _vacuumIntoSync(dbFilePath, dest));
      if (debugRestorePointSnapshotFailureForTesting?.call() ?? false) {
        throw const FileSystemException('simulated snapshot failure');
      }
      await Isolate.run(() => _quickCheckSync(dest));
      final RestorePoint point = RestorePoint(
        id: id,
        directory: pointDir,
        kind: RestorePointKind.preUpdate,
        database: database,
        createdAtMs: now,
        fromSchema: fromSchema,
        toSchema: toSchema,
        appVersion: appVersion,
        files: <RestorePointFile>[
          RestorePointFile(
            name: database.fileName,
            size: File(dest).lengthSync(),
          ),
        ],
      );
      _writeAtomicSync(
        p.join(pointDir, kRestorePointMetaFileName),
        jsonEncode(point.toJson()),
      );
      writeLastStatus(
        RestorePointSnapshotStatus(
          database: database,
          ok: true,
          atMs: now,
          fromSchema: fromSchema,
          toSchema: toSchema,
          pointId: id,
        ),
      );
      prune(database);
      fushiDebugPrint(
        '[restore-points] ${database.wire} v$fromSchema → v$toSchema: $id',
      );
      return point;
    } on Object catch (e) {
      fushiDebugPrint('[restore-points] ${database.wire} snapshot failed: $e');
      if (pointDir != null) _deleteDirQuietly(pointDir);
      writeLastStatus(
        RestorePointSnapshotStatus(
          database: database,
          ok: false,
          atMs: now,
          fromSchema: fromSchema,
          toSchema: toSchema,
          error: '$e',
        ),
      );
      return null;
    }
  }

  /// 保留策略：[database] 的更新前还原点留最新 [kRestorePointKeepPreUpdate] 份、回滚前还原点
  /// 留最新 [kRestorePointKeepPreRollback] 份、操作前还原点**按 reason 各留**最新
  /// [kRestorePointKeepPreOperation] 份（[kRestorePointKeepPreOperationByReason] 可单独定）；
  /// 属于 [database]、没有元数据的残留目录删掉（有没做完的回滚时不删：它的回滚前还原点要到最后
  /// 才写元数据）。别的库、不认识的目录不碰。[protectIds] 里的点与正被还原的点（[hold]）永不删，
  /// 也不占份额。
  void prune(
    RestorePointDatabase database, {
    Set<String> protectIds = const <String>{},
  }) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return;
    final bool rollbackPending = hasPendingRollback;
    final String marker = '-${database.wire}-';
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final String id = p.basename(e.path);
      if (!rollbackPending &&
          id.contains(marker) &&
          !_activeDrafts.contains(e.path) &&
          !File(p.join(e.path, kRestorePointMetaFileName)).existsSync()) {
        _deleteDirQuietly(e.path);
      }
    }
    final Map<String, List<RestorePoint>> groups =
        <String, List<RestorePoint>>{};
    final Map<String, int> keepOf = <String, int>{};
    for (final RestorePoint point in list(database: database)) {
      if (protectIds.contains(point.id) || isHeld(point.directory)) continue;
      final (String group, int keep)? quota = switch (point.kind) {
        RestorePointKind.preUpdate => (
          'pre_update',
          kRestorePointKeepPreUpdate,
        ),
        RestorePointKind.preRollback => (
          'pre_rollback',
          kRestorePointKeepPreRollback,
        ),
        RestorePointKind.preOperation => (
          'pre_operation:${point.reason ?? ''}',
          kRestorePointKeepPreOperationByReason[point.reason] ??
              kRestorePointKeepPreOperation,
        ),
        // 定时还原点走 [pruneScheduled]。
        RestorePointKind.scheduled => null,
      };
      if (quota == null) continue;
      (groups[quota.$1] ??= <RestorePoint>[]).add(point);
      keepOf[quota.$1] = quota.$2;
    }
    for (final MapEntry<String, List<RestorePoint>> g in groups.entries) {
      // [list] 已经新的在前。
      for (final RestorePoint stale in g.value.skip(keepOf[g.key]!)) {
        _deleteDirQuietly(stale.directory);
      }
    }
  }

  String _uniqueId(int ms, RestorePointDatabase db, RestorePointKind kind) {
    final String base = '${restorePointTimestamp(ms)}-${db.wire}-${kind.wire}';
    String id = base;
    for (int n = 2; Directory(p.join(root, id)).existsSync(); n++) {
      id = '$base-$n';
    }
    return id;
  }

  // ── 定时 / 操作前还原点（第二期） ─────────────────────────────────────────────

  /// 占住一个新还原点目录（`<root>/<id>/`）。写完调 [commit]，失败调 [discard]。
  RestorePointDraft begin({
    required RestorePointKind kind,
    RestorePointDatabase database = RestorePointDatabase.fushi,
    int? nowMs,
    String? ownerDeviceId,
  }) {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    Directory(root).createSync(recursive: true);
    final String id = _uniqueId(now, database, kind);
    final String dir = p.join(root, id);
    Directory(dir).createSync();
    _activeDrafts.add(dir);
    if (ownerDeviceId != null) {
      // 先落「谁在写」：共用文件夹里另一台设备据此认出这不是它的残留（[cleanIncompleteScheduled]）。
      File(
        p.join(dir, kRestorePointOwnerFileName),
      ).writeAsStringSync(ownerDeviceId, flush: true);
    }
    return RestorePointDraft._(
      id: id,
      directory: dir,
      kind: kind,
      database: database,
      createdAtMs: now,
    );
  }

  /// 写 [draft] 的元数据（完整标记，最后写）。[files] 缺省 = 目录里现有的文件。
  RestorePoint commit(
    RestorePointDraft draft, {
    required int fromSchema,
    required int toSchema,
    String? reason,
    List<String>? categories,
    List<String>? excludedCategories,
    bool? includesSrsMedia,
    bool? fullDatabase,
    String? deviceId,
    String? deviceName,
  }) {
    try {
      final List<RestorePointFile> files =
          <RestorePointFile>[
            for (final FileSystemEntity f in Directory(
              draft.directory,
            ).listSync())
              if (f is File &&
                  p.basename(f.path) != kRestorePointMetaFileName &&
                  p.basename(f.path) != kRestorePointOwnerFileName)
                RestorePointFile(
                  name: p.basename(f.path),
                  size: f.lengthSync(),
                ),
          ]..sort(
            (RestorePointFile a, RestorePointFile b) =>
                a.name.compareTo(b.name),
          );
      final RestorePoint point = RestorePoint(
        id: draft.id,
        directory: draft.directory,
        kind: draft.kind,
        database: draft.database,
        createdAtMs: draft.createdAtMs,
        fromSchema: fromSchema,
        toSchema: toSchema,
        appVersion: appVersion,
        files: files,
        reason: reason,
        categories: categories,
        excludedCategories: excludedCategories,
        includesSrsMedia: includesSrsMedia,
        fullDatabase: fullDatabase,
        deviceId: deviceId,
        deviceName: deviceName,
      );
      _writeAtomicSync(
        p.join(draft.directory, kRestorePointMetaFileName),
        jsonEncode(point.toJson()),
      );
      return point;
    } finally {
      _activeDrafts.remove(draft.directory);
    }
  }

  /// 放弃 [draft]：删掉半截目录。
  void discard(RestorePointDraft draft) {
    _activeDrafts.remove(draft.directory);
    _deleteDirQuietly(draft.directory);
  }

  /// 活库快照的大小上界：库文件 + `-wal`（`VACUUM INTO` 的副本不会比两者之和大）。
  static int _liveDatabaseBytes(String dbFilePath) =>
      fileBytesOrZero(dbFilePath) + fileBytesOrZero('$dbFilePath-wal');

  /// 操作前还原点：[fushiDbPath] 非空时 `VACUUM INTO` 主库（活库开着也行：另开一条只读连接，
  /// WAL 下读到一致的已提交状态），[snapshotSrs] 非空时由调用方把复习库快照写到给定路径
  /// （复习库归 Rust 内核独占，走内核自己的快照命令）。主库副本再 `quick_check`，最后写元数据，
  /// 然后按 [kRestorePointKeepPreOperation]（按 reason 分开算）修剪；[protectIds] 里的点（例如
  /// 「替换」的目标点）这次修剪不删。失败删掉半截目录并抛出，由调用方决定要不要继续那个操作。
  /// 两个都没给时抛 [ArgumentError]。动笔之前先查空间（[freeBytes] 缺省用登记的探针），不够抛
  /// [NotEnoughSpaceException]（`toString` 是 `not_enough_space`）。
  Future<RestorePoint> createPreOperationPoint({
    required String reason,
    String? fushiDbPath,
    Future<void> Function(String destPath)? snapshotSrs,
    Set<String> protectIds = const <String>{},
    VolumeFreeBytes? freeBytes,
  }) async {
    if (fushiDbPath == null && snapshotSrs == null) {
      throw ArgumentError('nothing to snapshot');
    }
    // 空间不够：动任何东西之前抛 [NotEnoughSpaceException]，调用方照旧按「没拍成」处理（替换不做）。
    ensureFreeSpace(<SpaceNeed>[
      SpaceNeed(
        root,
        (fushiDbPath == null ? 0 : _liveDatabaseBytes(fushiDbPath)) +
            (snapshotSrs == null
                ? 0
                : _liveDatabaseBytes(
                    p.join(dbDirectory, RestorePointDatabase.srs.fileName),
                  )),
      ),
    ], probe: freeBytes);
    final RestorePointDraft draft = begin(
      kind: RestorePointKind.preOperation,
      database: fushiDbPath != null
          ? RestorePointDatabase.fushi
          : RestorePointDatabase.srs,
    );
    try {
      int schema = 0;
      if (fushiDbPath != null && File(fushiDbPath).existsSync()) {
        final String dest = p.join(
          draft.directory,
          RestorePointDatabase.fushi.fileName,
        );
        await Isolate.run(() => _vacuumIntoSync(fushiDbPath, dest));
        await Isolate.run(() => _quickCheckSync(dest));
        schema = await Isolate.run(() => readSqliteUserVersionSync(dest));
      }
      if (snapshotSrs != null) {
        await snapshotSrs(
          p.join(draft.directory, RestorePointDatabase.srs.fileName),
        );
      }
      if (Directory(draft.directory).listSync().isEmpty) {
        throw const FileSystemException('no database to snapshot');
      }
      final RestorePoint point = commit(
        draft,
        fromSchema: schema,
        toSchema: schema,
        reason: reason,
      );
      prune(draft.database, protectIds: protectIds);
      fushiDebugPrint('[restore-points] pre-operation ($reason): ${point.id}');
      return point;
    } on Object {
      discard(draft);
      rethrow;
    }
  }

  /// 定时还原点的保留（[policy] 缺省 [kRestorePointScheduledRetention]）。[protectId] 那一份
  /// （刚写好的）与正被还原的点（[hold]）永不删；返回删掉的点。只动 [root] 下的定时还原点，
  /// 顺带清掉 [root] 下写到一半的定时点目录（[cleanIncompleteScheduled]）——自定义文件夹不归
  /// [prune] 管，没有这一步那里的半截 zip 永远不会被清。
  ///
  /// **只修剪本机写的点**（[isOwnScheduledPoint]）：取回本机的点（[RestorePoint.copiedBackAtMs]）在哪里都
  /// 从不自动删；[sharedRoot]（存储根可能被几台设备共用：桌面自定义文件夹）里别的设备写的、没有设备
  /// 标记的点不占日 / 周 / 月桶、不算进大小上限、从不自动删。私有存储不看设备标记。
  List<RestorePoint> pruneScheduled({
    required String? deviceId,
    bool sharedRoot = false,
    String? protectId,
    DateTime? now,
    BackupRetentionPolicy policy = kRestorePointScheduledRetention,
  }) {
    cleanIncompleteScheduled(deviceId: deviceId, sharedRoot: sharedRoot);
    final List<RestorePoint> scheduled = <RestorePoint>[
      for (final RestorePoint point in list())
        if (point.kind == RestorePointKind.scheduled &&
            isOwnScheduledPoint(
              point,
              deviceId: deviceId,
              sharedRoot: sharedRoot,
            ))
          point,
    ];
    final List<RestorePoint> doomed = planBackupRetention<RestorePoint>(
      scheduled,
      timestampOf: (RestorePoint point) => point.createdAt,
      now: (now ?? DateTime.now()).toUtc(),
      policy: policy,
      sizeOf: (RestorePoint point) => point.totalBytes,
      protect: (RestorePoint point) =>
          point.id == protectId || isHeld(point.directory),
    );
    for (final RestorePoint point in doomed) {
      _deleteDirQuietly(point.directory);
    }
    return doomed;
  }

  /// [point] 算不算本机写的、可以自动修剪的定时还原点：取回本机的副本（[RestorePoint.copiedBackAtMs]）
  /// 从不算。私有存储（不是 [sharedRoot]）只有本机在写——别的设备的点只能经「取回本机」进来，而那会记下
  /// copiedBackAtMs——所以其余的都算、不看设备标记：同步设备 id 重新生成过（清数据、换库）时，旧 id
  /// 写的点照样修剪，不会永远占着空间。共用存储里只算设备标记是 [deviceId] 的（[deviceId] 为 null 时
  /// 一份都不算；没有标记的可能是别的设备写的，不算）。
  static bool isOwnScheduledPoint(
    RestorePoint point, {
    required String? deviceId,
    required bool sharedRoot,
  }) {
    if (point.copiedBackAtMs != null) return false;
    if (!sharedRoot) return true;
    final String? owner = point.deviceId;
    return owner != null && owner == deviceId;
  }

  /// 删掉 [root] 下写到一半的定时还原点目录（id 带 `-scheduled`、没有元数据、本进程没在写）。
  /// [sharedRoot]（共用的自定义文件夹）时只删「谁在写」标记（[kRestorePointOwnerFileName]）是
  /// [deviceId] 的：没有标记 / 标记是别人的目录可能是别的设备正在写、或同步盘还没传完元数据的点，删了
  /// 会经同步把那台设备的点也删掉。[deviceId] 为 null（查不出本机 id）时共用存储里一个都不删：不然
  /// 「没有标记」和「本机 id 为 null」会被当成同一个人，别的设备没写完的点就被删了。返回删掉的目录数。
  int cleanIncompleteScheduled({String? deviceId, bool sharedRoot = false}) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return 0;
    final String marker = '-${RestorePointKind.scheduled.wire}';
    int removed = 0;
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      if (!p.basename(e.path).contains(marker) ||
          _activeDrafts.contains(e.path) ||
          File(p.join(e.path, kRestorePointMetaFileName)).existsSync()) {
        continue;
      }
      if (sharedRoot && (deviceId == null || _ownerOf(e.path) != deviceId)) {
        continue;
      }
      _deleteDirQuietly(e.path);
      removed++;
    }
    return removed;
  }

  static String? _ownerOf(String directory) {
    try {
      final File f = File(p.join(directory, kRestorePointOwnerFileName));
      if (!f.existsSync()) return null;
      final String text = f.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  /// 删掉一个还原点（还原点页「删除」）。
  void delete(RestorePoint point) {
    final Directory dir = Directory(point.directory);
    if (!dir.existsSync()) return;
    dir.deleteSync(recursive: true);
  }

  // ── 回滚 ────────────────────────────────────────────────────────────────────

  /// 把 [plans] 里每个库换回它的目标还原点。调用方保证这些库**都关着**（没有任何连接）。
  ///
  /// 每个库：当前活库（连同 `-wal` / `-shm` / `-journal`）挪进新的 `pre_rollback` 还原点，
  /// 快照经临时名复制成活库。动手前先校验目标快照（`quick_check`），坏了就什么都不动、抛出。
  /// 进度逐步记进 [kRestorePointRollbackJournalFileName]，崩在中途由
  /// [recoverPendingRollback] 补完。返回新建的回滚前还原点。
  Future<List<RestorePoint>> rollback(
    List<RestorePointRollbackPlan> plans,
  ) async {
    if (plans.isEmpty) return const <RestorePoint>[];
    if (hasPendingRollback) await recoverPendingRollback();
    for (final RestorePointRollbackPlan plan in plans) {
      final String snapshot = plan.snapshotPath;
      await Isolate.run(() => _quickCheckSync(snapshot));
    }
    // 活库还被别的句柄占着（Windows 上改不了名）时在写日志之前就失败：否则日志落了盘，
    // 下次启动会把一次用户以为失败了的回滚补完。
    for (final RestorePointRollbackPlan plan in plans) {
      _probeMovable(p.join(dbDirectory, plan.effectiveDatabase.fileName));
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    Directory(root).createSync(recursive: true);
    final List<_RollbackEntry> entries = <_RollbackEntry>[];
    for (final RestorePointRollbackPlan plan in plans) {
      final RestorePointDatabase db = plan.effectiveDatabase;
      final String live = p.join(dbDirectory, db.fileName);
      int liveSchema = 0;
      if (File(live).existsSync()) {
        try {
          liveSchema = await Isolate.run(() => readSqliteUserVersionSync(live));
        } on Object {
          liveSchema = 0; // 损坏的库读不出版本，照样整份留进回滚前还原点。
        }
      }
      final String backupId = _uniqueId(now, db, RestorePointKind.preRollback);
      // 先占住目录名，同一次回滚里两个库的 id 不会撞。
      Directory(p.join(root, backupId)).createSync();
      entries.add(
        _RollbackEntry(
          database: db,
          targetId: plan.target.id,
          backupId: backupId,
          liveSchema: liveSchema,
          createdAtMs: now,
        ),
      );
    }
    _writeJournal(entries);
    await _runRollback(entries);
    return <RestorePoint>[
      for (final _RollbackEntry e in entries)
        if (RestorePoint.tryRead(p.join(root, e.backupId))
            case final RestorePoint point)
          point,
    ];
  }

  /// 补完上次没做完的回滚（开库之前调用，只在主进程）。没有就什么都不做。返回是否补了。
  /// 补不完（目标快照没了等）记日志、删日志文件，让开库按原有路径继续——不能把启动卡死。
  Future<bool> recoverPendingRollback() async {
    final File journal = File(_journalPath);
    if (!journal.existsSync()) return false;
    List<_RollbackEntry> entries;
    try {
      entries = _readJournal(journal.readAsStringSync());
    } on Object catch (e) {
      fushiDebugPrint('[restore-points] unreadable rollback journal: $e');
      _deleteFileQuietly(journal.path);
      return false;
    }
    try {
      await _runRollback(entries);
    } on Object catch (e) {
      fushiDebugPrint('[restore-points] rollback recovery failed: $e');
      _deleteFileQuietly(journal.path);
      return false;
    }
    return true;
  }

  Future<void> _runRollback(List<_RollbackEntry> entries) async {
    for (final _RollbackEntry entry in entries) {
      final String live = p.join(dbDirectory, entry.database.fileName);
      final String backupDir = p.join(root, entry.backupId);
      if (entry.state == _RollbackState.pending) {
        // 第 1 步：活库挪进回滚前还原点。先挪侧车、最后挪主文件；重跑时只挪还在原处的。
        Directory(backupDir).createSync(recursive: true);
        for (final String suffix in _kSidecarSuffixes) {
          _moveIfExists(
            '$live$suffix',
            p.join(backupDir, '${entry.database.fileName}$suffix'),
          );
        }
        _moveIfExists(live, p.join(backupDir, entry.database.fileName));
        entry.state = _RollbackState.moved;
        _writeJournal(entries);
        debugRestorePointRollbackStepForTesting?.call('moved');
      }
      if (entry.state == _RollbackState.moved) {
        // 第 2 步：快照经临时名复制成活库。
        final String source = p.join(
          root,
          entry.targetId,
          entry.database.fileName,
        );
        final String tmp = '$live$_kRollbackTmpSuffix';
        _deleteFileQuietly(tmp);
        await File(source).copy(tmp);
        await File(tmp).rename(live);
        entry.state = _RollbackState.copied;
        _writeJournal(entries);
        debugRestorePointRollbackStepForTesting?.call('copied');
      }
      // 第 3 步：回滚前还原点写元数据（完整标记）。目录是空的（原来就没有活库）就删掉。
      _finishBackupPoint(entry, backupDir);
    }
    _deleteFileQuietly(_journalPath);
    for (final RestorePointDatabase db in <RestorePointDatabase>{
      for (final _RollbackEntry e in entries) e.database,
    }) {
      prune(db);
    }
  }

  void _finishBackupPoint(_RollbackEntry entry, String backupDir) {
    final Directory dir = Directory(backupDir);
    if (!dir.existsSync()) return;
    if (File(p.join(backupDir, kRestorePointMetaFileName)).existsSync()) return;
    final List<RestorePointFile> files =
        <RestorePointFile>[
          for (final FileSystemEntity f in dir.listSync())
            if (f is File)
              RestorePointFile(name: p.basename(f.path), size: f.lengthSync()),
        ]..sort(
          (RestorePointFile a, RestorePointFile b) => a.name.compareTo(b.name),
        );
    if (files.isEmpty) {
      _deleteDirQuietly(backupDir);
      return;
    }
    final RestorePoint point = RestorePoint(
      id: entry.backupId,
      directory: backupDir,
      kind: RestorePointKind.preRollback,
      database: entry.database,
      createdAtMs: entry.createdAtMs,
      fromSchema: entry.liveSchema,
      toSchema: entry.liveSchema,
      appVersion: appVersion,
      files: files,
    );
    _writeAtomicSync(
      p.join(backupDir, kRestorePointMetaFileName),
      jsonEncode(point.toJson()),
    );
  }

  void _writeJournal(List<_RollbackEntry> entries) {
    _writeAtomicSync(
      _journalPath,
      jsonEncode(<String, Object?>{
        'format': kRestorePointFormat,
        'entries': <Map<String, Object?>>[
          for (final _RollbackEntry e in entries) e.toJson(),
        ],
      }),
    );
  }

  static List<_RollbackEntry> _readJournal(String text) {
    final Object? raw = jsonDecode(text);
    if (raw is! Map<String, Object?> || raw['entries'] is! List<Object?>) {
      throw const FormatException('rollback journal without entries');
    }
    return <_RollbackEntry>[
      for (final Object? e in raw['entries']! as List<Object?>)
        _RollbackEntry.fromJson(e),
    ];
  }
}

/// 回滚日志里一个库的进度。
enum _RollbackState { pending, moved, copied }

class _RollbackEntry {
  _RollbackEntry({
    required this.database,
    required this.targetId,
    required this.backupId,
    required this.liveSchema,
    required this.createdAtMs,
    this.state = _RollbackState.pending,
  });

  factory _RollbackEntry.fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('rollback journal entry is not an object');
    }
    final RestorePointDatabase? db = RestorePointDatabase.fromWire(
      raw['database'],
    );
    final Object? target = raw['targetId'];
    final Object? backup = raw['backupId'];
    final _RollbackState? state = _RollbackState.values
        .where((_RollbackState s) => s.name == raw['state'])
        .firstOrNull;
    if (db == null || target is! String || backup is! String || state == null) {
      throw const FormatException('malformed rollback journal entry');
    }
    final Object? schema = raw['liveSchema'];
    final Object? created = raw['createdAtMs'];
    return _RollbackEntry(
      database: db,
      targetId: target,
      backupId: backup,
      liveSchema: schema is int ? schema : 0,
      createdAtMs: created is int ? created : 0,
      state: state,
    );
  }

  final RestorePointDatabase database;
  final String targetId;
  final String backupId;
  final int liveSchema;
  final int createdAtMs;
  _RollbackState state;

  Map<String, Object?> toJson() => <String, Object?>{
    'database': database.wire,
    'targetId': targetId,
    'backupId': backupId,
    'liveSchema': liveSchema,
    'createdAtMs': createdAtMs,
    'state': state.name,
  };
}

/// UTC 时间戳 `yyyyMMdd-HHmmss-SSS`（还原点 id 的前缀，按字典序即按时间）。
String restorePointTimestamp(int ms) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}-'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// 用一条原始连接读 `PRAGMA user_version`（只读、同步；后台 isolate 里调用）。
int readSqliteUserVersionSync(String path) {
  final sqlite3.Database db = sqlite3.sqlite3.open(
    path,
    mode: sqlite3.OpenMode.readOnly,
  );
  try {
    return db.select('PRAGMA user_version').first.columnAt(0) as int;
  } finally {
    db.close();
  }
}

/// 复习库文件里记的 schema（`srs_meta.schema`）；文件不在 / 读不了返回 null。只读。
int? readSrsLibrarySchema(String path) {
  if (!File(path).existsSync()) return null;
  try {
    final sqlite3.Database db = sqlite3.sqlite3.open(
      path,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      final sqlite3.ResultSet rows = db.select(
        "SELECT value FROM srs_meta WHERE key = 'schema'",
      );
      if (rows.isEmpty) return null;
      return int.tryParse('${rows.first.columnAt(0)}');
    } finally {
      db.close();
    }
  } on Object {
    return null;
  }
}

void _vacuumIntoSync(String source, String dest) {
  final sqlite3.Database db = sqlite3.sqlite3.open(
    source,
    mode: sqlite3.OpenMode.readOnly,
  );
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('VACUUM INTO ?', <Object?>[dest]);
  } finally {
    db.close();
  }
}

void _quickCheckSync(String path) {
  if (!File(path).existsSync()) {
    throw FileSystemException('snapshot missing', path);
  }
  final sqlite3.Database db = sqlite3.sqlite3.open(
    path,
    mode: sqlite3.OpenMode.readOnly,
  );
  try {
    final List<Object?> rows = <Object?>[
      for (final sqlite3.Row r in db.select('PRAGMA quick_check'))
        r.columnAt(0),
    ];
    if (rows.length != 1 || rows.single != 'ok') {
      throw FileSystemException(
        'quick_check failed: ${rows.take(5).join('; ')}',
        path,
      );
    }
  } finally {
    db.close();
  }
}

void _writeAtomicSync(String path, String body) {
  final File tmp = File('$path$_kTmpSuffix');
  tmp.writeAsStringSync(body, flush: true);
  tmp.renameSync(path);
}

/// [path] 能不能改名（存在时原地改名再改回来）；被占用时抛 [FileSystemException]。
void _probeMovable(String path) {
  final File f = File(path);
  if (!f.existsSync()) return;
  final String probe = '$path.rollback-probe';
  f.renameSync(probe);
  File(probe).renameSync(path);
}

void _moveIfExists(String from, String to) {
  final File f = File(from);
  if (!f.existsSync()) return;
  if (File(to).existsSync()) File(to).deleteSync();
  f.renameSync(to);
}

void _deleteDirQuietly(String path) {
  try {
    final Directory d = Directory(path);
    if (d.existsSync()) d.deleteSync(recursive: true);
  } on Object catch (e) {
    fushiDebugPrint('[restore-points] could not delete $path: $e');
  }
}

void _deleteFileQuietly(String path) {
  try {
    final File f = File(path);
    if (f.existsSync()) f.deleteSync();
  } on Object catch (e) {
    fushiDebugPrint('[restore-points] could not delete $path: $e');
  }
}
