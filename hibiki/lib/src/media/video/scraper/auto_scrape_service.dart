/// 视频刮削**自动化调度层**：把原先靠用户点「批量匹配海报」按钮才跑的刮削，
/// 变成进视频页自动补刮 + 新视频入库自动刮。
///
/// 为什么是一个调度器而不是在每个导入点各挂一次钩子：视频入库的路径有八条
/// （导入弹窗单文件 / 文件夹 / 播放列表 / 流媒体、库扫描、互联下载、云下载、外部
/// 打开），逐个挂钩子既漏又重复。本服务只认**一条判据**——「库里有哪些本地视频还
/// 没有条目资料」——由调用方在两个时机喂进来：
/// * 视频页 initState（全库补刮）
/// * 视频库 uid 集合变化（`watchVideoBookUids` 的既有消费点，新导入天然覆盖）
///
/// 节流与边界（免得把 Bangumi 当自家 CDN 刷）：
/// * 串行，一次只跑一本；本本之间 [_perBookDelay] 间隔。
/// * 每本每进程只尝试一次（[_attempted]）——网络不通/条目查不到时，不会每次进
///   视频页都把整库重刷一遍。用户手动「重新刮削」走弹窗，不受此限。
/// * 同一 subject 的详情请求由 [PosterScraperService] 内部缓存压成一次。
/// * 远端/流媒体书天然不参与（无本地文件名可解析）。
library;

import 'dart:async';

import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// 自动刮削调度器。生命周期跟随视频页（initState 建 / dispose 销），无全局单例：
/// 页面不在就没人需要刮削结果，跑着也是白跑。
class VideoScrapeAutoService {
  VideoScrapeAutoService({
    required VideoBookRepository repository,
    required Future<PosterScraperService> Function() serviceFactory,
    bool Function()? isEnabled,
    Duration perBookDelay = _perBookDelay,
  })  : _repo = repository,
        _serviceFactory = serviceFactory,
        _isEnabled = isEnabled,
        _delay = perBookDelay;

  /// 每本之间的间隔：Bangumi 是公益 API，串行 + 间隔是基本礼貌。整库首刮会慢，
  /// 但它是后台静默跑的，用户不等它。
  static const Duration _perBookDelay = Duration(milliseconds: 600);

  final VideoBookRepository _repo;
  final Future<PosterScraperService> Function() _serviceFactory;

  /// 总闸（`AppModel.videoAutoScrape`）。每轮 [sweep] **进场时**读一次，而不是构造
  /// 时读死：用户在设置里关掉后，下一轮就该立刻不再出网，不必重建服务。null =
  /// 不设闸（测试/内部调用）。
  final bool Function()? _isEnabled;

  final Duration _delay;

  /// 本进程内已尝试过的 bookUid（成功或失败都记），防止反复重刮。
  final Set<String> _attempted = <String>{};

  /// 当前是否有一轮在跑（串行保证：第二次 [sweep] 直接返回，不并发开第二条流水线）。
  bool _running = false;

  /// dispose 后置位，让跑到一半的循环在下一本之前收手。
  bool _disposed = false;

  /// 复用同一个 service 实例，让它内部的条目详情缓存跨轮次生效。
  PosterScraperService? _service;

  /// 本本之间节流用的可取消定时器 + 它的唤醒信号。
  ///
  /// 不能用裸 `Future.delayed`：那个 Timer 无法取消，页面 dispose 后它仍挂在事件
  /// 循环上——真机是白等一拍，widget 测试里则直接踩 flutter_test 的
  /// `!timersPending` 断言（与 BUG-834 同一类孤儿 async）。这里持有 Timer 并在
  /// [dispose] 里 cancel + 立刻完成 completer，让挂起的 [sweep] 循环马上醒来看到
  /// `_disposed` 并收手。
  Timer? _delayTimer;
  Completer<void>? _delayCompleter;

  /// 已刮出的资料条目数（本轮），供测试断言与调试。
  int get attemptedCount => _attempted.length;

  /// 是否正在跑。
  bool get isRunning => _running;

  /// 扫一遍 [books]，对「本地 + 还没有条目资料 + 本进程没试过」的书跑刮削。
  ///
  /// 幂等且可重复调用：已在跑时直接返回（不排队、不并发）。全程不抛——单本失败
  /// 由 [PosterScraperService.scrapeLibrary] 收成 `ScrapeFailed` 继续下一本，整轮
  /// 异常只吞在本方法边界（后台静默任务不该把页面搞崩），下次进页面自然重试。
  Future<void> sweep(List<VideoBookRow> books) async {
    if (_running || _disposed) return;
    // 总闸关 = 一个请求都不发（连「哪些书没刮」的库查询都省了）。
    if (_isEnabled != null && !_isEnabled()) return;
    _running = true;
    try {
      final List<VideoBookRow> pending = await _pending(books);
      if (pending.isEmpty || _disposed) return;

      final PosterScraperService service = _service ??= await _serviceFactory();
      if (_disposed) return;

      for (final VideoBookRow book in pending) {
        _attempted.add(book.bookUid);
      }

      // 逐本流：scrapeLibrary 内部已处理封面来源保护、同目录解析缓存、单本异常
      // 不中断整批。这里只负责节流和中止。
      for (final VideoBookRow book in pending) {
        if (_disposed) return;
        await service.scrapeLibrary(<VideoBookRow>[book]).drain<void>();
        if (_disposed) return;
        await _throttle();
      }
    } catch (_) {
      // 后台静默刮削：整轮失败不影响页面。已进 _attempted 的书本进程不再重试，
      // 下次启动重来（资料是可重建缓存，丢一轮无害）。
    } finally {
      _running = false;
    }
  }

  /// 本本之间的可取消等待。零间隔（测试）直接返回已完成 future，连 Timer 都不建。
  Future<void> _throttle() {
    if (_delay <= Duration.zero || _disposed) return Future<void>.value();
    final Completer<void> completer = Completer<void>();
    _delayCompleter = completer;
    _delayTimer = Timer(_delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// 过滤出真正需要刮的书：本地路径 + 无资料行 + 本进程未尝试过。
  Future<List<VideoBookRow>> _pending(List<VideoBookRow> books) async {
    final List<VideoBookRow> local = <VideoBookRow>[
      for (final VideoBookRow b in books)
        if (_isLocal(b) && !_attempted.contains(b.bookUid)) b,
    ];
    if (local.isEmpty) return const <VideoBookRow>[];
    // 一次性取已刮 uid 集合，避免逐本查询（N+1）。
    final Set<String> scraped = await _repo.scrapedBookUids();
    return <VideoBookRow>[
      for (final VideoBookRow b in local)
        if (!scraped.contains(b.bookUid)) b,
    ];
  }

  /// 本地文件视频判据：与 [PosterScraperService] 一致（http/https = 远端/流媒体）。
  static bool _isLocal(VideoBookRow book) {
    final String path = book.videoPath;
    return path.isNotEmpty &&
        !path.startsWith('http://') &&
        !path.startsWith('https://');
  }

  /// 忘掉某本的「本进程已尝试」记录，让下一轮 [sweep] 重新刮它（用户点「重新刮削」）。
  ///
  /// 同时丢弃缓存的 [PosterScraperService] 实例：它内部记着「这个 subject 的详情
  /// 拉失败过」的负缓存，不丢就会让手动重刮直接被负缓存短路、什么也不发生。下次
  /// sweep 由工厂重建（代价是重读一次离线索引，用户手动动作的低频路径，可接受）。
  void forget(String bookUid) {
    _attempted.remove(bookUid);
    _service = null;
  }

  /// 停止后续刮削（页面 dispose 时调用）。跑到一半的那本会完成当前一步后退出，
  /// 挂在节流等待上的循环则被立刻唤醒 —— 绝不留下 pending Timer（BUG-834 类）。
  void dispose() {
    _disposed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    final Completer<void>? completer = _delayCompleter;
    _delayCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}
