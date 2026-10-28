part of '../manga_fushi_page.dart';

/// 漫画阅读器侧的 Kavita 进度同步接线：全部逻辑在
/// `media/kavita/kavita_manga_sync.dart`，本扩展只负责拿到阅读器的上下文
/// （服务器清单、冲突弹窗、换章 / 关书时机）。
extension _MangaKavitaSyncExtension on _MangaFushiPageState {
  /// 开章前调用：先收掉上一章的会话（限时 flush，不 await 网络），再为 Kavita
  /// 条目的 [chapter] 建会话（拉取 + 决策，可能改写本地章进度）。非 Kavita 条目
  /// 直接返回；任何失败只记日志，绝不影响开章。
  ///
  /// 返回打开时采用了服务器进度的页（0 起；未采用 / 非 Kavita 为 null）：调用方
  /// 必须以它为起始页——只靠 `resolveMangaChapterResumePoint` 读回章进度会被「读完
  /// 过的章从头看」吞掉刚采用的页。
  Future<int?> _attachKavitaMangaSync(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) async {
    _closeKavitaMangaSync();
    if (_sourceReviewActive || !KavitaMangaSyncSession.appliesTo(entry)) {
      return null;
    }
    try {
      final KavitaMangaSyncSession? session =
          await KavitaMangaSyncSession.attach(
            db: appModel.database,
            bookUid: row.uid,
            entry: entry,
            chapter: chapter,
            servers: appModel.prefsRepo.kavitaServers,
            apiFor: KavitaApiRegistry.instance.apiFor,
            stamps: PrefKavitaMangaSyncStampStore(
              read: () =>
                  appModel.prefsRepo.getPref(
                        kKavitaMangaSyncStatePref,
                        defaultValue: '',
                      )
                      as String,
              write: (String value) =>
                  appModel.prefsRepo.setPref(kKavitaMangaSyncStatePref, value),
            ),
            promptConflict:
                (KavitaProgress server, MangaChapterStateRow local) async {
                  if (!mounted) return KavitaSyncAction.none;
                  return showKavitaProgressConflictDialog(
                    context,
                    localSection: local.lastPage,
                    serverSection: server.pageNum,
                  );
                },
          );
      if (!mounted) {
        unawaited(session?.close());
        return null;
      }
      _kavitaMangaSync = session;
      return session?.adoptedPage;
    } on Object catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.attachKavitaSync', e, stack);
    }
    return null;
  }

  /// 章进度落库后转发给 Kavita 同步（防抖上报；非 Kavita 条目为空操作）。
  void _reportKavitaMangaPage(String chapterKey, int page) =>
      _kavitaMangaSync?.onPageSaved(chapterKey, page);

  /// 收掉当前会话：限时 flush 待推进度后释放（不 await，内部吞错）。
  void _closeKavitaMangaSync() {
    // 防抖里还没落库的最后一页：补报页面缓存的当前页（纯内存），否则 dispose 后
    // 迟到的章状态保存会撞上已置空的会话，最后一页永远推不到服务器。
    final String? chapterKey = _shelfChapterKey;
    if (chapterKey != null && _payload != null) {
      _reportKavitaMangaPage(chapterKey, _currentPage);
    }
    final KavitaMangaSyncSession? session = _kavitaMangaSync;
    _kavitaMangaSync = null;
    if (session != null) unawaited(session.close());
  }
}
