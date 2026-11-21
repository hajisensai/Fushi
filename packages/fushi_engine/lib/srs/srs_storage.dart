/// SRS 的存储装配：Rust 独占的库目录（`<数据库目录>`，新代库 `srs4.db` 在它里面；
/// docs/specs/2026-10-23-srs-rust-store.md、docs/specs/2026-11-15-srs-gen4-handoff.md §8.1）。一个进程一份，所有
/// profile 共用。读写一律是内核命令：写见 `SrsDbStore`，读见 srs_reads.dart。
library;

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnectionUser, QueryRow;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_core_workers.dart';

/// 协议 3 库的文件名（与主库 `fushi.db` 同目录；冻结名）。新代迁移后它原位封存、不删。
const String kSrsDatabaseFileName = 'srs.db';

/// 新代库的文件名（native/fushi_fsrs/src/store/gen4/files.rs `GEN4_FILE`）。
const String kSrsGen4DatabaseFileName = 'srs4.db';

/// 主库 `fushi.db` 里还留着协议 1 的 SRS 表（`srs_entities` 等，从没搬进过 `srs.db`）：新代不认这些表，也没有
/// 搬迁入口（协议 3 的 `ffsrs_store_legacy_*` 与 Dart 的 `srsMigrateLegacyStore` 已随 G7-6 删掉），存储不打开、
/// 给出明确状态（app 给升级提示：先用旧版本打开一次完成搬迁）。主库里的表一行不动。
final class SrsLegacyMainDatabasePending implements Exception {
  const SrsLegacyMainDatabasePending();

  @override
  String toString() =>
      'SrsLegacyMainDatabasePending: fushi.db still holds protocol 1 SRS '
      'tables that this version cannot import; open it once with an '
      'older version to migrate them first';
}

/// 打开的 SRS 存储。
class SrsStorage {
  SrsStorage._(this.core, this.directory);

  /// Rust 侧句柄（连接、事务、全部读写命令）。
  final SrsCore core;

  /// 库目录（`<数据库目录>`）。
  final String directory;

  bool _closed = false;

  /// [directory] 下的协议 3 库路径（封存的旧库 / 迁移来源）。
  static String legacyPathIn(String directory) =>
      '$directory${Platform.pathSeparator}$kSrsDatabaseFileName';

  /// [directory] 下的新代库路径。
  static String gen4PathIn(String directory) =>
      '$directory${Platform.pathSeparator}$kSrsGen4DatabaseFileName';

  /// 打开 [directory] 的新代库（[mode] 缺省 Primary：全新安装时建空库）。打开本身一律在后台 isolate（见
  /// [SrsCore.openInBackground]）。
  ///
  /// 库目录处在某个代际状态（要迁移 / 别的进程在迁移 / 旁边有没迁移的旧库）时抛 [SrsStoreOpenBlocked] 的子类，
  /// 由调用方给迁移页 / 恢复页（交接说明 §8.1），这里不自动迁移。
  ///
  /// [legacy]（只有主进程传）：主库连接。主库里还留着协议 1 的 SRS 表、而库目录里从没有过 SRS 库时抛
  /// [SrsLegacyMainDatabasePending]（新代没有搬迁入口，不建空库把那些数据藏起来）。
  static Future<SrsStorage> open({
    required String directory,
    SrsOpenMode mode = SrsOpenMode.primary,
    DatabaseConnectionUser? legacy,
  }) async {
    if (legacy != null &&
        await srsLegacyMainDatabasePending(db: legacy, directory: directory)) {
      throw const SrsLegacyMainDatabasePending();
    }
    final SrsCore core = await SrsCore.openInBackground(directory, mode: mode);
    try {
      // 查询道的 worker 上限 = 内核只读连接池的上限（按核数算，只在 Rust 里算一次；这一下只读一个数，不碰库）。
      SrsCoreWorkers.of(
        core.libraryPath,
      ).setQueryConcurrency(core.readConcurrency);
      return SrsStorage._(core, directory);
    } on Object {
      _closeCore(core);
      rethrow;
    }
  }

  /// 关 Rust 连接（之后到达的命令报「已关闭」）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeCore(core);
  }

  /// 关 Rust 连接，并让内核命令 worker 丢掉为这个句柄包的 [SrsCore]（srs_core_workers.dart：换 profile / 覆盖恢复
  /// 反复开关库时不越攒越多）。
  static void _closeCore(SrsCore core) {
    final int address = core.address;
    final String? libraryPath = core.libraryPath;
    core.close();
    SrsCoreWorkers.of(libraryPath).forget(address);
  }

  bool get isClosed => _closed;
}

/// 主库里还留着协议 1 的 SRS 表（`srs_entities`），而库目录里既没有协议 3 的 `srs.db` 也没有新代库：这份数据从没
/// 搬进过 SRS 库。旧版本搬迁成功后会删掉主库里的表；搬过、只是删表没成功的，目录里一定有 `srs.db`（搬迁标记与数据
/// 同一个事务提交进去）。
Future<bool> srsLegacyMainDatabasePending({
  required DatabaseConnectionUser db,
  required String directory,
}) async {
  if (File(SrsStorage.legacyPathIn(directory)).existsSync() ||
      File(SrsStorage.gen4PathIn(directory)).existsSync()) {
    return false;
  }
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'srs_entities'",
      )
      .get();
  return rows.isNotEmpty;
}
