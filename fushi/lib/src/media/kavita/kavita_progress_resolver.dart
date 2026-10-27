/// Kavita 进度同步的纯决策函数（无 IO，便于表驱动测试）。
///
/// 难点：Kavita 的 `lastModifiedUtc` 由**服务器**盖章，客户端无法在上报里带时间；
/// 本地时钟又可能和服务器不同步。所以不直接比较两侧时间戳的大小，而是：
///
/// 1. 用「上次成功同步的时刻」[lastSyncAt] 作基线，问两个问题——自那以后服务器
///    变过吗？本地变过吗？（各自都加 [kKavitaClockSkewToleranceMs] 容差）
/// 2. 只有一侧变过 → 以变过的一侧为准；两侧都变过 → 冲突，交给 UI 问用户；
/// 3. 从没同步过（[lastSyncAt] 为空）→ 只能直接比较两侧时间戳，差距在容差内按
///    冲突处理，免得因为时钟偏差悄悄丢掉一侧的进度。
///
/// 页号两侧都是 0 起（与 `Reader/image?page=` 一致）。
library;

/// 时钟偏差容差：2 分钟。本机时钟与服务器相差在这个范围内不当成「谁更新」的证据。
const int kKavitaClockSkewToleranceMs = 2 * 60 * 1000;

enum KavitaSyncAction {
  /// 两侧一致（或都没有进度）：什么都不做。
  none,

  /// 采用服务器进度（跳到服务器页）。
  adoptServer,

  /// 本地更新：推给服务器。
  pushLocal,

  /// 两侧都变过且页号不同：需要用户裁决。
  conflict,
}

class KavitaSyncDecision {
  const KavitaSyncDecision(this.action, {this.preferred});

  final KavitaSyncAction action;

  /// 冲突时按时间戳看更像更新的一侧（仅作 UI 默认选项）：
  /// [KavitaSyncAction.adoptServer] 或 [KavitaSyncAction.pushLocal]。
  final KavitaSyncAction? preferred;

  @override
  String toString() => 'KavitaSyncDecision($action, preferred: $preferred)';

  @override
  bool operator ==(Object other) =>
      other is KavitaSyncDecision &&
      other.action == action &&
      other.preferred == preferred;

  @override
  int get hashCode => Object.hash(action, preferred);
}

/// 决定一次「打开时拉取」后该做什么。
///
/// - [serverPage] / [serverModifiedAt]：服务器进度页与其 `lastModifiedUtc`
///   （epoch 毫秒）；服务器没有这章记录时 [serverModifiedAt] 为 null。
/// - [localPage] / [localUpdatedAt]：本地进度页与更新时刻；本地从没读过时都为 null。
/// - [lastSyncAt]：最近一次成功推/拉的本地时刻（取绑定里 `lastPushedAt`、
///   `lastPulledAt` 的较大者）；从没同步过为 null。
/// - [lastSyncedPage]：最近一次两侧达成一致的页号（推成功 / 采用服务器 / 拉取时
///   两侧相同）；未知为 null。本地页号仍等于它时，本地**没有**动过同步单位——
///   [localUpdatedAt] 晚于基线只是因为同一页 / 同一章内的落库（EPUB 章内滚动、
///   漫画标已读），不能算「本地推进过」，否则另一台设备一推进就会被误判成冲突。
KavitaSyncDecision resolveKavitaProgress({
  required int? serverPage,
  required int? serverModifiedAt,
  required int? localPage,
  required int? localUpdatedAt,
  required int? lastSyncAt,
  int? lastSyncedPage,
  int toleranceMs = kKavitaClockSkewToleranceMs,
}) {
  final bool hasServer = serverModifiedAt != null && serverPage != null;
  final bool hasLocal = localUpdatedAt != null && localPage != null;

  if (!hasServer && !hasLocal) {
    return const KavitaSyncDecision(KavitaSyncAction.none);
  }
  if (hasServer && !hasLocal) {
    // 服务器记录了 0 页（刚标未读 / 刚打开）也算「没读过」，不必跳。
    return serverPage > 0
        ? const KavitaSyncDecision(KavitaSyncAction.adoptServer)
        : const KavitaSyncDecision(KavitaSyncAction.none);
  }
  if (!hasServer && hasLocal) {
    return localPage > 0
        ? const KavitaSyncDecision(KavitaSyncAction.pushLocal)
        : const KavitaSyncDecision(KavitaSyncAction.none);
  }
  if (serverPage == localPage) {
    return const KavitaSyncDecision(KavitaSyncAction.none);
  }

  final int server = serverModifiedAt!;
  final int local = localUpdatedAt!;

  if (lastSyncAt == null) {
    // 从没同步过：直接比时间戳。
    final int diff = server - local;
    if (diff.abs() <= toleranceMs) {
      return KavitaSyncDecision(
        KavitaSyncAction.conflict,
        preferred: diff >= 0
            ? KavitaSyncAction.adoptServer
            : KavitaSyncAction.pushLocal,
      );
    }
    return diff > 0
        ? const KavitaSyncDecision(KavitaSyncAction.adoptServer)
        : const KavitaSyncDecision(KavitaSyncAction.pushLocal);
  }

  final bool serverMoved = server > lastSyncAt + toleranceMs;
  final bool localMoved =
      local > lastSyncAt + toleranceMs &&
      (lastSyncedPage == null || localPage != lastSyncedPage);
  if (serverMoved && localMoved) {
    return KavitaSyncDecision(
      KavitaSyncAction.conflict,
      preferred: server >= local
          ? KavitaSyncAction.adoptServer
          : KavitaSyncAction.pushLocal,
    );
  }
  if (serverMoved) {
    return const KavitaSyncDecision(KavitaSyncAction.adoptServer);
  }
  if (localMoved) {
    return const KavitaSyncDecision(KavitaSyncAction.pushLocal);
  }
  // 两侧自上次同步后都没动，页号却不同（比如上次同步后用户在别处手改）：不动。
  return const KavitaSyncDecision(KavitaSyncAction.none);
}

/// 一章读到哪算「读完」：最后一页（0 起：`page >= pages - 1`）。
bool isKavitaChapterFinished({required int page, required int totalPages}) =>
    totalPages > 0 && page >= totalPages - 1;
