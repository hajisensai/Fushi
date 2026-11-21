/// 复习库代际状态的分类（交接说明 §8.1）：本机库打不开是因为要换代迁移 / 别的进程在迁移 / 旁边有没迁移的旧库……
/// 而不是「坏了」时，打开抛的是 [SrsStoreOpenBlocked] 的子类或 [SrsLegacyMainDatabasePending]。
///
/// 代际状态页（`srs_generation_view.dart`）按 [srsGenerationKindOf] 出内容；制卡链路（`srs_mining.dart`、互联主机
/// 替对端制卡）按同一个分类给失败码（[srsGenerationMineErrorCode]），制卡失败提示据此说「去复习页完成升级」，而不是
/// 笼统的「复习不可用」（BUG-5069）。纯逻辑，不依赖 UI。
library;

import 'package:fushi_anki/fushi_anki.dart'
    show AnkiErrorCode, MineOutcome, isSrsGenerationErrorCode;
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart';

/// 页面按哪一种状态出内容（由打开错误 + 是否主进程决定）。
enum SrsGenerationKind {
  /// 主进程、要迁移：迁移面板。
  migrate,

  /// 主进程、上次迁移没完成：迁移面板（「重新升级」）。
  retryFailed,

  /// 非主进程、要迁移 / 上次没完成：去主窗口。
  openMainWindow,

  /// 别的窗口 / 进程在迁移。
  migratingElsewhere,

  /// 只剩封存旧库。
  sealedOldOnly,

  /// 旁边有没迁移的协议 3 旧库（-6）。
  legacyUnmigrated,

  /// 协议 1 的数据还在主库里。
  legacyMainDatabase,

  /// 已经可以用了（状态在页面挂着时变了）：只给重试。
  ready,
}

/// [error] 是不是「库在换代途中」的打开错误（[SrsStoreOpenBlocked] 的子类或 [SrsLegacyMainDatabasePending]）。
/// 其余异常（真的打不开 / 坏了）不算。
bool isSrsGenerationBlocked(Object error) =>
    error is SrsStoreOpenBlocked || error is SrsLegacyMainDatabasePending;

/// [error] 在本进程（[isMainProcess]）里该出哪一种内容。
SrsGenerationKind srsGenerationKindOf(
  Object error, {
  required bool isMainProcess,
}) {
  return switch (error) {
    SrsLegacyMainDatabasePending() => SrsGenerationKind.legacyMainDatabase,
    SrsStoreMigrating() => SrsGenerationKind.migratingElsewhere,
    SrsStoreLegacyUnmigrated() => SrsGenerationKind.legacyUnmigrated,
    SrsStoreNotMigrated(:final SrsGenState state) => switch (state) {
      SrsGenState.needsMigration =>
        isMainProcess
            ? SrsGenerationKind.migrate
            : SrsGenerationKind.openMainWindow,
      SrsGenState.migrationFailed =>
        isMainProcess
            ? SrsGenerationKind.retryFailed
            : SrsGenerationKind.openMainWindow,
      SrsGenState.migratingElsewhere => SrsGenerationKind.migratingElsewhere,
      SrsGenState.sealedOldOnly => SrsGenerationKind.sealedOldOnly,
      SrsGenState.ready => SrsGenerationKind.ready,
    },
    _ => SrsGenerationKind.ready,
  };
}

/// 制卡因 [error]（库在换代途中）没写进复习时的失败码（[AnkiErrorCode] 的 `srs*`，与 locale 无关，随互联回包上
/// wire）；[error] 不是代际状态时为 null。
///
/// 分类与代际状态页同一个（[srsGenerationKindOf]），只是按「用户下一步做什么」收成四类：要升级 / 上次没升级完 →
/// 去复习页升级；正在升级（含状态刚变成可用）→ 等完成再试；其余三种要人处理的状态 → 去复习页看说明。
String? srsGenerationMineErrorCode(Object error) {
  if (!isSrsGenerationBlocked(error)) return null;
  // 进程无关：非主进程的「去主窗口」同样是「要升级」，文案本身就指向主窗口。
  return switch (srsGenerationKindOf(error, isMainProcess: true)) {
    SrsGenerationKind.migrate ||
    SrsGenerationKind.openMainWindow => AnkiErrorCode.srsNeedsMigration,
    SrsGenerationKind.retryFailed => AnkiErrorCode.srsMigrationFailed,
    // ready：打开时的状态在这之后变了，重试就能用，与「正在升级、完成后再试」是同一个下一步。
    SrsGenerationKind.migratingElsewhere ||
    SrsGenerationKind.ready => AnkiErrorCode.srsMigrating,
    SrsGenerationKind.sealedOldOnly ||
    SrsGenerationKind.legacyUnmigrated ||
    SrsGenerationKind.legacyMainDatabase => AnkiErrorCode.srsNeedsAttention,
  };
}

/// 制卡因 [error]（[isSrsGenerationBlocked] 为真）没写进复习的结果：带 [srsGenerationMineErrorCode] 分类码，原始
/// 异常进诊断（错误日志）。
MineOutcome srsGenerationMineFailure(Object error, StackTrace stackTrace) {
  final String code = srsGenerationMineErrorCode(error)!;
  assert(isSrsGenerationErrorCode(code));
  return MineOutcome.failure(
    'Fushi review data is not ready for new cards ($code).',
    errorCode: code,
    error: error,
    stackTrace: stackTrace,
  );
}
