part of '../reader_fushi_page.dart';

/// 阅读器侧的 Kavita 进度同步接线：全部逻辑在 `media/kavita/kavita_epub_sync.dart`，
/// 本扩展只负责拿到阅读器的上下文（服务器清单、冲突弹窗、dispose 时机）。
extension _ReaderKavitaExtension on _ReaderFushiPageState {
  /// 为 Kavita 绑定书建同步会话（打开时拉取 + 决策）。非 Kavita 书直接返回。
  /// 任何失败只记日志，绝不影响开书。
  Future<void> _attachKavitaSync(FushiDatabase db, EpubBookRow row) async {
    if (!isKavitaBookMetadata(row.sourceMetadata)) return;
    try {
      final KavitaEpubSyncSession? session = await KavitaEpubSyncSession.attach(
        db: db,
        row: row,
        servers: appModelNoUpdate.prefsRepo.kavitaServers,
        apiFor: KavitaApiRegistry.instance.apiFor,
        promptConflict:
            (KavitaProgress server, ReaderPositionRow? local) async {
              if (!mounted || local == null) return KavitaSyncAction.pushLocal;
              return showKavitaProgressConflictDialog(
                context,
                localSection: local.sectionIndex,
                serverSection: server.pageNum,
              );
            },
      );
      if (!mounted) {
        unawaited(session?.close());
        return;
      }
      _kavitaSync = session;
    } on Object catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi._attachKavitaSync', e, stack);
    }
  }
}
