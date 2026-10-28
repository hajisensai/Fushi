part of '../reader_fushi_page.dart';

/// 阅读器侧的 Kavita 进度同步接线：全部逻辑在 `media/kavita/kavita_epub_sync.dart`，
/// 本扩展只负责拿到阅读器的上下文（服务器清单、冲突弹窗、dispose 时机）。
extension _ReaderKavitaExtension on _ReaderFushiPageState {
  /// 为 Kavita 绑定书建同步会话（打开时拉取 + 决策）。非 Kavita 书直接返回。
  /// 任何失败只记日志，绝不影响开书。
  Future<void> _attachKavitaSync(FushiDatabase db, EpubBookRow row) async {
    if (!isKavitaBookMetadata(row.sourceMetadata)) return;
    // 登记「这本书正开在阅读器里」：后台进度对账跳过它，系列页关书后等它的最后
    // 一次推送（dispose 里 [_releaseKavitaSync] 配对释放）。
    if (!_kavitaOpenMarked) {
      _kavitaOpenMarked = true;
      KavitaOpenBooks.opened(widget.bookKey);
    }
    try {
      final KavitaEpubSyncSession? session = await KavitaEpubSyncSession.attach(
        db: db,
        row: row,
        servers: appModelNoUpdate.prefsRepo.kavitaServers,
        apiFor: KavitaApiRegistry.instance.apiFor,
        promptConflict:
            (KavitaProgress server, ReaderPositionRow? local) async {
              if (!mounted || local == null) return KavitaSyncAction.none;
              return showKavitaProgressConflictDialog(
                context,
                localSection: local.sectionIndex,
                serverSection: server.pageNum,
              );
            },
        onSectionCountMismatch: (int serverSections, int localSections) {
          if (!mounted) return;
          FushiToast.show(
            msg: t.kavita_sync_section_mismatch(
              server: '$serverSections',
              local: '$localSections',
            ),
            severity: ToastSeverity.warning,
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

  /// 关书：限时 flush 待推进度并释放登记（dispose 调；不阻塞、内部吞错）。flush 的
  /// future 交给 [KavitaOpenBooks]，系列页据此等最后一次推送落地再重取进度。
  void _releaseKavitaSync() {
    final Future<void>? flush = _kavitaSync?.close();
    _kavitaSync = null;
    if (_kavitaOpenMarked) {
      _kavitaOpenMarked = false;
      KavitaOpenBooks.closed(widget.bookKey, flush: flush);
    } else if (flush != null) {
      unawaited(flush);
    }
  }
}
