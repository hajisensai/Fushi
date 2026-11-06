/// SRS 的存储装配：Rust 独占的 `<数据库目录>/srs.db` + 它上面的 Drift 视图
/// （docs/specs/2026-10-23-srs-rust-store.md）。一个进程一份，所有 profile 共用。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_legacy_store_migration.dart';

/// srs.db 的文件名（与主库 `fushi.db` 同目录）。
const String kSrsDatabaseFileName = 'srs.db';

/// 打开的 SRS 存储。
class SrsStorage {
  SrsStorage._(this.core, this.db, this.path);

  /// Rust 侧句柄（连接、事务、Rust 命令）。
  final SrsCore core;

  /// Drift 视图（查询构造器；语句在 [core] 的写连接上执行）。
  final SrsDatabase db;

  /// srs.db 的绝对路径。
  final String path;

  bool _closed = false;

  /// [dbDirectory] 下的 srs.db 路径。
  static String pathIn(String dbDirectory) =>
      '$dbDirectory${Platform.pathSeparator}$kSrsDatabaseFileName';

  /// 打开（不存在就建）；[legacy] 给了就先把主库里残留的旧 SRS 表搬进来（只有主进程传）。
  /// [inline] 时 Drift 执行器跑在当前 isolate（测试）。打开本身（含格式升级）一律在后台 isolate：
  /// 见 [SrsCore.openInBackground]。
  static Future<SrsStorage> open({
    required String path,
    FushiDatabase? legacy,
    bool inline = false,
  }) async {
    final SrsCore core = await SrsCore.openInBackground(path);
    try {
      if (legacy != null) {
        await srsMigrateLegacyStore(db: legacy, core: core);
      }
      final SrsDatabase db = inline
          ? SrsDatabase(srsInlineExecutor(core))
          : SrsDatabase(srsDatabaseConnection(core));
      return SrsStorage._(core, db, path);
    } on Object {
      _closeCore(core);
      rethrow;
    }
  }

  /// 先关 Drift（后台 isolate 停下、不再发语句），再关 Rust 连接。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
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
