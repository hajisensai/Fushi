/// 进程启动时的远程更新收尾：换到一半被杀的按换包日志还原、删上一次换包留下的
/// 旧文件。
///
/// 必须在打开数据库**之前**做（`withServerRuntime` 拿到数据目录锁后第一件事）：换包
/// 中断时 `bin/` 里可能已经是新版可执行文件，服务管理器拉起的就是它。它若先开库，
/// drift 迁移会把库升到新 schema，随后还原成旧版文件、以 75 退出——拉起来的旧版见到
/// 更新的 schema 拒绝开库（`FushiDatabaseDowngradeException`），服务端从此起不来。
/// 所以还原动到正在运行的可执行文件时，调用方直接以 `kExitSelfUpdated`（75）退出，什么都
/// 不碰。
///
/// 放在数据目录锁之后：换包只发生在持锁的 `serve` 进程里，拿到锁 = 没有别的进程正在
/// 换包，日志一定是中断留下的，不会和一次进行中的换包抢着改文件。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';

import 'package:fushi_server/src/self_update/server_bundle_swap.dart';
import 'package:fushi_server/src/self_update/server_release.dart';

/// 启动收尾的结论。
enum ServerUpdateRecovery {
  /// 不是发布包，或没有要收尾的东西 / 收尾完：照常启动。
  proceed,

  /// 还原动到了正在运行的可执行文件：此刻跑的是没换完的新版，必须不碰数据库直接
  /// 退出（`kExitSelfUpdated`），由服务管理器拉起盘上已还原的旧版。
  restartRequired,
}

/// 对 [installRoot]（缺省 = 正在运行的发布包根目录；`dart run` / `dart test` / 自建
/// bundle → 不是发布包，什么都不做）做启动收尾。失败只留痕，不抛。
/// [runningExecutable] 是测试缝（缺省当前进程的可执行文件）。
Future<ServerUpdateRecovery> recoverServerSelfUpdate({
  Directory? installRoot,
  String? runningExecutable,
}) async {
  final Directory? root =
      installRoot ??
      currentReleaseBundleRoot(executablePath: runningExecutable);
  if (root == null) return ServerUpdateRecovery.proceed;
  final ServerUpdateCleanup r = await cleanupAfterServerUpdate(
    root,
    runningExecutable: runningExecutable,
  );
  if (r.rolledBack) {
    engineLog.logDiagnostic(
      'ServerSelfUpdate',
      'previous update was interrupted mid-swap; restored ${root.path}',
    );
  }
  if (r.failed > 0) {
    engineLog.logDiagnostic(
      'ServerSelfUpdate',
      'cleanup left ${r.failed} item(s) under ${root.path}',
    );
  }
  if (r.restartRequired) {
    engineLog.logDiagnostic(
      'ServerSelfUpdate',
      'running executable was rolled back; exiting for restart '
          'before opening the database',
    );
    return ServerUpdateRecovery.restartRequired;
  }
  return ServerUpdateRecovery.proceed;
}
