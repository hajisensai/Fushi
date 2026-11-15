/// 在线直读章「全部页面」缩略图的预取（反馈 3VwZimDVBE，#3110 遗留，用户拍板做）。
///
/// 不另开第二套缓存 / 下载：页图就是阅读器要读的那一份，经
/// [OnlineMangaReaderSession.backgroundPage] 走会话同一条取页管线（扩展自己的客户端，
/// 请求头 / Referer / 扩展限流拦截器都在那一层）、落同一个会话缓存目录、共用同一个并发
/// 上限，且排在阅读请求之后。本类只管「要哪些页、按什么顺序、失败几次停手」：
///
/// - 可见优先：网格每次滚动给出新的有序页表（可见行在前、往下一屏、往上一行），
///   [requestPages] 把名下还在排队的请求按新顺序重排，窗口外的直接撤掉、不打源。
/// - 可取消：面板关掉 [stop] 撤掉名下所有排队请求；换章时会话 close，排队的随之失败，
///   在飞的交运行时取消。已在飞的缩略图请求不撤——取回的页进缓存，阅读时直接用。
/// - 失败不刷屏：失败不弹提示、格子保持页码占位；同一页最多试 [maxAttemptsPerPage]
///   次（滚回来时再试），连续失败 [consecutiveFailureLimit] 次（离线 / 源限流 / 要登录）
///   本次面板就停手，重开面板重新来。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_page_grid.dart';

/// 同一页在一次面板里最多试几次。
const int kMangaThumbnailPrefetchMaxAttempts = 2;

/// 连续失败几次就停掉本次面板的预取。
const int kMangaThumbnailPrefetchFailureLimit = 3;

/// 撤单 / 会话关闭这类「不是取失败」的错误码，不计入失败。
const Set<String> _kNotAFailureCodes = <String>{
  'PREFETCH_CANCELLED',
  'PREFETCH_STALE',
  'SESSION_CLOSED',
};

class OnlineMangaThumbnailPrefetcher extends ChangeNotifier
    implements MangaPageGridPrefetcher {
  OnlineMangaThumbnailPrefetcher(
    this._session, {
    this.maxAttemptsPerPage = kMangaThumbnailPrefetchMaxAttempts,
    this.consecutiveFailureLimit = kMangaThumbnailPrefetchFailureLimit,
  });

  final OnlineMangaReaderSession _session;
  final int maxAttemptsPerPage;
  final int consecutiveFailureLimit;

  /// 已交给会话、还没落定的页（防同一页重复挂回调）。
  final Set<int> _tracked = <int>{};
  final Map<int, int> _attempts = <int, int>{};
  int _consecutiveFailures = 0;
  bool _stopped = false;
  bool _disposed = false;

  /// 本次面板已不再发新请求（面板关了 / 会话关了 / 连续失败停手）。
  bool get halted =>
      _stopped ||
      _session.isClosed ||
      _consecutiveFailures >= consecutiveFailureLimit;

  @override
  void requestPages(List<int> orderedPages) {
    if (halted) return;
    final List<int> wanted = <int>[];
    for (final int index in orderedPages) {
      if (index < 0 || index >= _session.pageCount) continue;
      if (_session.cachedFilePath(index) != null) continue;
      if ((_attempts[index] ?? 0) >= maxAttemptsPerPage &&
          !_tracked.contains(index)) {
        continue;
      }
      wanted.add(index);
      if (_tracked.add(index)) _track(index);
    }
    // 先挂新单（排到队尾）再按新顺序整体重排：可见页排在旧的预读页前面。
    _session.retainBackgroundPages(this, wanted);
  }

  void _track(int index) {
    _attempts[index] = (_attempts[index] ?? 0) + 1;
    _session
        .backgroundPage(index, owner: this)
        .then<void>(
          (_) {
            _tracked.remove(index);
            _consecutiveFailures = 0;
            if (!_disposed) notifyListeners();
          },
          onError: (Object error) {
            _tracked.remove(index);
            if (error is MihonRuntimeException &&
                _kNotAFailureCodes.contains(error.code)) {
              // 撤单不算一次尝试：滚回来时照常再要。
              _attempts[index] = (_attempts[index] ?? 1) - 1;
              return;
            }
            _consecutiveFailures++;
            if (_consecutiveFailures >= consecutiveFailureLimit &&
                !_session.isClosed) {
              _session.cancelBackgroundPages(this);
            }
          },
        );
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    if (!_session.isClosed) _session.cancelBackgroundPages(this);
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
