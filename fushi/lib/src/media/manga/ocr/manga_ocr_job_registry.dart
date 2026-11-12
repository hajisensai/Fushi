/// App 级整卷 OCR 任务注册表（BUG-2449）。
///
/// 整卷 OCR 是分钟到小时量级的批处理，而它原先唯一的持有者是阅读页的 State：
/// `dispose()` 无条件 cancel 订阅，五个执行器的 `onCancel` 又都是真中止（isolate
/// cancel token / SIGKILL 子进程 / 向互联主机发 DELETE），于是「返回书架」等价于
/// 「把跑了一半的任务杀掉」。任务的寿命不该绑在一帧路由上。
///
/// 这里把所有权收到 app 级：注册表**唯一**持有底层事件流的订阅，按 `bookKey` 索引；
/// 页面只是观察者——它订阅的是 [MangaOcrRunningJob.events] 这条广播流，取消观察
/// 不影响底层任务。真正的 cancel 只由三处触发：HUD 的取消按钮、删书、退出 app。
///
/// 完成时的落盘（把执行器产物写进书根 manga.json）也随所有权一起搬到这里：页面
/// 可能早就不在了，落盘不能依赖它还活着。写侧仍经 `manga_json_writeback.dart` 的
/// per-path 写锁 + 原子写（那边文件头的调用点清单已同步登记本文件）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart'
    show ocrIntraOpNumThreads, resolveOcrPlatform;

/// 一个正在（或刚刚）跑的整卷 OCR 任务。
///
/// 观察者拿到它之后：读 [lastEvent] 立刻恢复进度显示，订阅 [events] 接着收后续
/// 事件；完成后 [result] 是已经落盘的整卷 payload。
class MangaOcrRunningJob {
  MangaOcrRunningJob._({
    required this.job,
    required this.mangaJsonPath,
    required List<MangaReaderSession> sessions,
  }) : _sessions = List<MangaReaderSession>.of(sessions);

  final MangaOcrBackgroundJob job;

  /// 完成后落盘的书根 manga.json 路径。
  final String mangaJsonPath;

  /// 任务期间必须保持打开的在线阅读会话（在线 OCR 靠它取页图）。任务结束时由
  /// 注册表关闭；页面在自己的 dispose 里先问 [ownsSession] 再决定要不要关。
  final List<MangaReaderSession> _sessions;

  final StreamController<MangaOcrBackgroundEvent> _observers =
      StreamController<MangaOcrBackgroundEvent>.broadcast();
  StreamSubscription<MangaOcrBackgroundEvent>? _source;

  MangaOcrBackgroundEvent? _lastEvent;
  MokuroPayload? _result;
  Object? _error;
  bool _cancelled = false;
  bool _ended = false;
  final Completer<void> _endedCompleter = Completer<void>();

  String get bookKey => job.bookKey;

  /// 最近一次事件（进度快照），晚到的观察者用它补齐 HUD。
  MangaOcrBackgroundEvent? get lastEvent => _lastEvent;

  /// 完成且已落盘的整卷结果；未完成 / 失败 / 取消时为 null。
  MokuroPayload? get result => _result;

  Object? get error => _error;

  bool get isCancelled => _cancelled;

  /// 底层任务已结束（完成、失败或取消）。
  bool get isEnded => _ended;

  /// 结束时完成（完成 / 失败 / 取消一律正常完成，不带错误）：排队等同书上一个
  /// 任务的调用方只关心「轮到我了没」。
  Future<void> get whenEnded => _endedCompleter.future;

  /// 广播给观察者的事件流：与底层流同序，finished 事件在落盘**之后**才转发。
  ///
  /// 有跟随步骤（[MangaOcrBackgroundJob.follower]，大模型重读）时，它改好的页
  /// 以带页的 progress 事件插进来——任务结束（[whenEnded]，名额已释放）之后也
  /// 可能还有，流要等跟随步骤做完才关。
  Stream<MangaOcrBackgroundEvent> get events => _observers.stream;

  MangaOcrJobFollower? get _follower => job.follower;
  StreamSubscription<MangaOcrPageUpdate>? _followerUpdates;

  /// 跟随步骤改好一页：转成带页的进度事件给观察者（计数沿用最近一次快照）。
  void _forwardFollowerUpdate(MangaOcrPageUpdate update) {
    if (_observers.isClosed) return;
    final MangaOcrBackgroundEvent? last = _lastEvent;
    _observers.add(
      MangaOcrBackgroundEvent.progress(
        pagesDone: last?.pagesDone ?? 0,
        pagesTotal: last?.pagesTotal ?? 0,
        uploading: last?.uploading ?? false,
        pageIndex: update.pageIndex,
        page: update.page,
      ),
    );
  }

  /// 读者翻到了 [pageIndex]：任务下一页先跑它，再从它往后接着跑。任务不支持
  /// 改道（[MangaOcrBackgroundJob.focus] 为 null）或已结束时什么都不做。
  void focusPage(int pageIndex) {
    if (_ended) return;
    job.focus?.request(pageIndex);
  }

  bool ownsSession(MangaReaderSession session) =>
      _sessions.any((MangaReaderSession s) => identical(s, session));

  /// 用户主动取消：真停底层任务（各执行器既有的取消语义），并释放会话。
  Future<void> cancel() async {
    await _cancelFollower();
    if (_ended) return;
    _cancelled = true;
    await _source?.cancel();
    _source = null;
    await _end();
  }

  /// 停掉跟随步骤（任务已结束、它还在收尾时也有效）。
  Future<void> _cancelFollower() async {
    await _follower?.cancel();
  }

  Future<void> _end() async {
    if (_ended) return;
    _ended = true;
    for (final MangaReaderSession session in _sessions) {
      try {
        await session.close();
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaOcrJobRegistry.closeSession',
          error,
          stack,
        );
      }
    }
    _sessions.clear();
    if (!_endedCompleter.isCompleted) _endedCompleter.complete();
    // 观察者流等跟随步骤收完尾再关（没有跟随步骤时立即关）。
    final Future<void> followerDone = _follower?.done ?? Future<void>.value();
    unawaited(
      followerDone.whenComplete(() async {
        await _followerUpdates?.cancel();
        _followerUpdates = null;
        // 刻意不 await：广播流的 done 要等每个观察者消费完才算送达，一个正卡在
        // 异步事件处理里的页面观察者不该把「真停任务」也一起卡住。
        unawaited(_observers.close());
      }),
    );
  }
}

/// 整卷 OCR 同时能跑几卷（跨书的全局上限，[MangaOcrJobRegistry.enqueue] 用）。
///
/// 进入阅读器即整卷识别之后，连着点开 N 本本地卷就是 N 个任务：本地 ONNX 每个任务
/// 一个 isolate + 一整套 ORT 会话，Lens 则是 N 路并发上传。手机与开了低内存模式的
/// 设备只跑 1 卷；桌面按核数给 1～2 卷（ONNX 自己就吃多核，再多只是互相抢）。
/// [requestedTasks] 为 0 时自动选择，桌面用户可显式选择 1～[maxTasks] 个任务
/// （[maxTasks] 见 [mangaOcrMaxParallelTasks]）。
int resolveMangaOcrJobConcurrency({
  required bool isMobile,
  required bool lowMemoryMode,
  required int processors,
  int requestedTasks = 0,
  int maxTasks = kMangaOcrMinSelectableTasks,
}) {
  if (isMobile || lowMemoryMode) return 1;
  if (requestedTasks > 0) return requestedTasks.clamp(1, maxTasks);
  return (processors ~/ 4).clamp(1, 2);
}

/// 手动档至少给到 4（放开前的上限；已存 4 的用户不能被悄悄降档）。
const int kMangaOcrMinSelectableTasks = 4;

/// 手动档的硬顶：每个任务一个 isolate + 一整套 ORT 会话（逐列 CTC 一套约 42 MB），
/// 再多就是内存问题而不是 CPU 问题。偏好存储也按它截断。
const int kMangaOcrMaxSelectableTasks = 16;

/// 本机手动档最多能选几个跨书任务。
///
/// 单个任务的吞吐不随线程数涨（Windows 每任务钉 2 线程是实测最优，见
/// `ocrIntraOpNumThreads`），机器更大时只能靠多开任务吃满核：上限 = 逻辑核 /
/// 每任务线程数。[threadsPerJob] 为 null（非 Windows，ORT 默认吃满核）时多开只是
/// 互抢，保持 [kMangaOcrMinSelectableTasks]。
int mangaOcrMaxParallelTasks({
  required int processors,
  required int? threadsPerJob,
}) {
  final int threads = threadsPerJob ?? processors;
  if (threads <= 0) return kMangaOcrMinSelectableTasks;
  return (processors ~/ threads).clamp(
    kMangaOcrMinSelectableTasks,
    kMangaOcrMaxSelectableTasks,
  );
}

/// 当前宿主的 [mangaOcrMaxParallelTasks]（设置 UI 与注册表共用）。
int hostMangaOcrMaxParallelTasks() {
  final int processors = Platform.numberOfProcessors;
  return mangaOcrMaxParallelTasks(
    processors: processors,
    threadsPerJob: ocrIntraOpNumThreads(
      platform: resolveOcrPlatform(Platform.operatingSystem),
      processorCount: processors,
    ),
  );
}

/// OCR 任务管理页上一行的状态（反馈 iuv4-jWC8S）。
enum MangaOcrJobStatus { running, queued, paused }

/// OCR 任务管理页的一行：某本书某个目录（章 / 卷）上的整卷任务快照。
///
/// 只是注册表状态的只读投影，管理页每次 [MangaOcrJobRegistry.changes] 重新取，
/// 不另存镜像。
@immutable
class MangaOcrJobEntry {
  const MangaOcrJobEntry({
    required this.bookKey,
    required this.directory,
    required this.engine,
    required this.status,
    required this.canPause,
    this.title,
    this.lastEvent,
  });

  final String bookKey;

  /// 任务目录（[MangaOcrBackgroundJob.managedDirectory]），与 [bookKey] 一起定位一行。
  final String directory;
  final String? title;
  final MangaOcrEngineId engine;
  final MangaOcrJobStatus status;

  /// 运行中 = 最近一次进度快照；已暂停 = 暂停那一刻的快照（排队中暂停的为 null）。
  final MangaOcrBackgroundEvent? lastEvent;

  /// 能不能暂停：排队中的恒可以（任务还没订阅，原样留着继续用）；运行中的要有
  /// [MangaOcrBackgroundJob.resume] 重建口。已暂停的行为 false。
  final bool canPause;

  MangaOcrJobRef get ref => (bookKey: bookKey, directory: directory);
}

/// 排着队、还没轮到的任务（任务还没订阅）。
class _QueuedJob {
  _QueuedJob(this.job, this.mangaJsonPath);

  final MangaOcrBackgroundJob job;
  final String mangaJsonPath;

  String get directory => job.managedDirectory;
}

/// 用户暂停的任务。[job] 只供管理页取身份 / 显示名 / 引擎；继续时由 [take] 给出
/// **尚未订阅**、可直接重新排队的那一个：排队中暂停 = 原任务原样；运行中暂停 =
/// 到继续那一刻才经 [MangaOcrBackgroundJob.resume] 重建（重建会现读大模型识别等
/// 偏好、新建跟随步骤，暂停期间改的设置要在继续时生效，不能在暂停时就冻住）。
class _PausedJob {
  _PausedJob(this.job, this.mangaJsonPath, this.lastEvent, this.take);

  final MangaOcrBackgroundJob job;
  final String mangaJsonPath;
  final MangaOcrBackgroundEvent? lastEvent;
  final MangaOcrBackgroundJob Function() take;

  String get bookKey => job.bookKey;
  String get directory => job.managedDirectory;
}

/// 管理页批量操作的目标：一本书的一个任务目录。
typedef MangaOcrJobRef = ({String bookKey, String directory});

/// 按 `bookKey` 索引的任务注册表；一本书同一时刻最多一个整卷任务。
///
/// [maxConcurrentJobs] 是跨书的全局上限（每次排到时现读，低内存模式开关即时生效）；
/// null = 不限（单测与只起单个任务的场景）。
class MangaOcrJobRegistry {
  MangaOcrJobRegistry({int Function()? maxConcurrentJobs})
    : _maxConcurrentJobs = maxConcurrentJobs;

  final int Function()? _maxConcurrentJobs;

  /// 经 [enqueue] 占着全局名额的任务数，与等名额的排队者。
  int _activeSlots = 0;
  final Queue<Completer<void>> _slotWaiters = Queue<Completer<void>>();

  Future<void> _acquireSlot() {
    final int? limit = _maxConcurrentJobs?.call();
    if (limit == null || _activeSlots < limit) {
      _activeSlots += 1;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _slotWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseSlot() {
    _activeSlots -= 1;
    refreshConcurrencyLimit();
  }

  /// 设置提高并发后立即唤醒排队任务；调低时让已有任务完成，不中断识别。
  void refreshConcurrencyLimit() {
    final int? limit = _maxConcurrentJobs?.call();
    while (_slotWaiters.isNotEmpty && (limit == null || _activeSlots < limit)) {
      _activeSlots += 1;
      _slotWaiters.removeFirst().complete();
    }
  }

  final Map<String, MangaOcrRunningJob> _jobs = <String, MangaOcrRunningJob>{};

  /// 按 bookKey 的排队链尾（[enqueue] 用）；链上没人时不留条目。
  final Map<String, Future<void>> _queues = <String, Future<void>>{};

  /// 按 bookKey 排着队、还没轮到的任务，按入队序。作品页据此给章节行标「等待
  /// 识别」（BUG-2481，经 [queuedDirectories]）；管理页据此列排队行并可暂停。
  final Map<String, List<_QueuedJob>> _queued = <String, List<_QueuedJob>>{};

  /// 用户暂停的任务，按暂停序（反馈 iuv4-jWC8S）。只存在于本次运行：退出 app 时
  /// 所有任务本来就会被真停，下次从书架「识别文字」重排即可从逐页缓存续跑。
  final List<_PausedJob> _paused = <_PausedJob>[];

  /// 任务集合变了（起了 / 结束了 / 入队了 / 轮到了）就发一下；进度本身走各任务的
  /// [MangaOcrRunningJob.events]。作品页订阅它决定「要不要重新挂到当前任务上」。
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 这本书排着队、还没开始的任务目录（按入队序）；没有则空。
  List<String> queuedDirectories(String bookKey) =>
      List<String>.unmodifiable(<String>[
        for (final _QueuedJob queued
            in _queued[bookKey] ?? const <_QueuedJob>[])
          queued.directory,
      ]);

  /// 管理页的全部行：运行中、排队中（按书、按入队序）、已暂停（按暂停序）。
  List<MangaOcrJobEntry> entries() => <MangaOcrJobEntry>[
    for (final MangaOcrRunningJob running in _jobs.values)
      MangaOcrJobEntry(
        bookKey: running.bookKey,
        directory: running.job.managedDirectory,
        title: running.job.title,
        engine: running.job.engine,
        status: MangaOcrJobStatus.running,
        lastEvent: running.lastEvent,
        canPause: running.job.resume != null,
      ),
    for (final List<_QueuedJob> list in _queued.values)
      for (final _QueuedJob queued in list)
        MangaOcrJobEntry(
          bookKey: queued.job.bookKey,
          directory: queued.directory,
          title: queued.job.title,
          engine: queued.job.engine,
          status: MangaOcrJobStatus.queued,
          canPause: true,
        ),
    for (final _PausedJob paused in _paused)
      MangaOcrJobEntry(
        bookKey: paused.bookKey,
        directory: paused.directory,
        title: paused.job.title,
        engine: paused.job.engine,
        status: MangaOcrJobStatus.paused,
        lastEvent: paused.lastEvent,
        canPause: false,
      ),
  ];

  /// 这本书正在跑的任务；没有则 null。已结束的任务不会留在这里。
  MangaOcrRunningJob? running(String bookKey) => _jobs[bookKey];

  Iterable<MangaOcrRunningJob> get all => _jobs.values;

  /// 启动（订阅）任务并接管所有权。
  ///
  /// 同一本书已有任务在跑时直接返回那一个：调用方重复起任务是它自己的防重入漏了，
  /// 注册表不能因此并发跑两份同书 OCR（两份结果会互相覆盖 manga.json）。
  MangaOcrRunningJob start({
    required MangaOcrBackgroundJob job,
    required String mangaJsonPath,
    List<MangaReaderSession> sessions = const <MangaReaderSession>[],
  }) {
    final MangaOcrRunningJob? existing = _jobs[job.bookKey];
    if (existing != null) {
      return existing;
    }
    final MangaOcrRunningJob running = MangaOcrRunningJob._(
      job: job,
      mangaJsonPath: mangaJsonPath,
      sessions: sessions,
    );
    _dropPaused(job.bookKey, job.managedDirectory);
    _jobs[job.bookKey] = running;
    _notifyChanged();
    // 同目录上一个任务的跟随步骤还在收尾：新任务会重写这份 manga.json 并带着
    // 自己的跟随步骤，旧的继续跑只会对着过期的页花钱。
    unawaited(
      _cancelFollowersFor(job.bookKey, directory: job.managedDirectory),
    );
    final MangaOcrJobFollower? follower = job.follower;
    if (follower != null) {
      running._followerUpdates = follower.updates.listen(
        running._forwardFollowerUpdate,
      );
    }
    // asyncMap 串行化事件处理：finished 的落盘有 await，期间源流被暂停，观察者
    // 收到 finished 时文件已经在盘上。
    running._source = job.events
        .asyncMap((MangaOcrBackgroundEvent event) => _ingest(running, event))
        .listen(
          (MangaOcrBackgroundEvent event) {
            running._lastEvent = event;
            if (!running._observers.isClosed) {
              running._observers.add(event);
            }
          },
          onError: (Object error, StackTrace stack) {
            ErrorLogService.instance.log(
              'MangaOcrJobRegistry.${job.engine.name}',
              error,
              stack,
            );
            // 任务失败：没有整卷结果可落，跟随步骤也就没有落点。
            unawaited(running._cancelFollower());
            running._error = error;
            if (!running._observers.isClosed) {
              running._observers.addError(error, stack);
            }
            _forget(running);
            unawaited(running._end());
          },
          onDone: () {
            _forget(running);
            _trackFollower(running);
            unawaited(running._end());
          },
          cancelOnError: true,
        );
    return running;
  }

  /// 排队启动：同一本书已有任务在跑（或已有排队者）时，等它结束再 [start]。
  ///
  /// 下载完成钩子的自动 OCR 用这条：同书连下三章、上一章还在识别时，[start] 会
  /// 直接把已在跑的那个返回、本章被静默吞掉。这里按 bookKey 串成 FIFO，每章都
  /// 轮得到。返回的 Future 在**本任务真正启动**时完成（不等它跑完）；排队期间
  /// 被 [cancel] 放弃的以 null 完成。
  ///
  /// 轮到本书之后还要等一个全局名额（[resolveMangaOcrJobConcurrency]）；等名额
  /// 期间仍算「排队中」（[queuedDirectories] 里有它）。
  Future<MangaOcrRunningJob?> enqueue({
    required MangaOcrBackgroundJob job,
    required String mangaJsonPath,
  }) {
    final String bookKey = job.bookKey;
    final Future<void> previous =
        _queues[bookKey] ?? _jobs[bookKey]?.whenEnded ?? Future<void>.value();
    final Completer<MangaOcrRunningJob?> started =
        Completer<MangaOcrRunningJob?>();
    final _QueuedJob entry = _QueuedJob(job, mangaJsonPath);
    // 别处（阅读器、作品页、管理页「继续」）把暂停的目录重新排上：暂停作废。
    _dropPaused(bookKey, job.managedDirectory);
    _queued.putIfAbsent(bookKey, () => <_QueuedJob>[]).add(entry);
    _notifyChanged();
    final Future<void> tail = previous.then((_) async {
      await _acquireSlot();
      try {
        final List<_QueuedJob>? queue = _queued[bookKey];
        if (queue == null || !queue.remove(entry)) {
          // 排队期间（含等全局名额期间）被 cancel(bookKey) 整本放弃、或被用户
          // 暂停（[pause]）：不启动。目录可能已随「移出书架」被删，对着空目录跑
          // 只会产出一条失败日志。
          started.complete(null);
          return;
        }
        if (queue.isEmpty) _queued.remove(bookKey);
        // 前一个刚 _forget 时 running() 可能已为空，但也可能仍是「刚结束还没被
        // 清掉」的那一个；start 只认 _jobs 里的，_forget 与 _end 同步发生，安全。
        final MangaOcrRunningJob running = start(
          job: job,
          mangaJsonPath: mangaJsonPath,
        );
        started.complete(running);
        await running.whenEnded;
      } finally {
        _releaseSlot();
      }
    });
    _queues[bookKey] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_queues[bookKey], tail)) _queues.remove(bookKey);
      }),
    );
    return started.future;
  }

  /// 用户取消这本书的任务：正在跑的真停，排着队还没轮到的一并放弃；两者都没有
  /// 则 no-op。只停正在跑的那一个是不够的——它一结束链尾就把下一个 start 起来
  /// （BUG-2513「移出书架」删完目录后排队者仍会对空目录开跑）。
  Future<void> cancel(String bookKey) async {
    await _cancelFollowersFor(bookKey);
    final bool hadQueued = _queued.remove(bookKey) != null;
    // 删书 / 取消本书：暂停着的也一并作废，否则「继续」会对着已删的目录开跑。
    final int pausedBefore = _paused.length;
    _paused.removeWhere((_PausedJob paused) => paused.bookKey == bookKey);
    final bool hadPaused = _paused.length != pausedBefore;
    final MangaOcrRunningJob? running = _jobs.remove(bookKey);
    if (running == null && !hadQueued && !hadPaused) return;
    _notifyChanged();
    await running?.cancel();
  }

  /// 退出 app / 切换 Profile 等整体拆栈：把所有任务真停掉。
  ///
  /// 排队者也一并放弃（与 [cancel] 同理，BUG-2513）：只停运行中的，它一结束
  /// 同书队列链就把下一个排队者 start 起来，拆栈之后还在跑。
  Future<void> cancelAll() async {
    final List<MangaOcrRunningJob> jobs = <MangaOcrRunningJob>[
      ..._jobs.values,
      for (final List<MangaOcrRunningJob> list in _finishing.values) ...list,
    ];
    final bool hadAny =
        _jobs.isNotEmpty || _queued.isNotEmpty || _paused.isNotEmpty;
    _jobs.clear();
    _finishing.clear();
    _queued.clear();
    _paused.clear();
    if (hadAny) _notifyChanged();
    for (final MangaOcrRunningJob running in jobs) {
      await running.cancel();
    }
  }

  /// 暂停 [bookKey] 在 [directory] 上的任务（OCR 任务管理页，反馈 iuv4-jWC8S）。
  ///
  /// - 排队中：从队列摘下（排队链轮到它时发现不在队里就跳过），原任务留着继续用；
  /// - 运行中：真停（各执行器在页边界停、逐页缓存保留），释放全局名额让下一个
  ///   排队者开跑；记下 [MangaOcrBackgroundJob.resume] 重建口，[resume] 时才重建。
  ///
  /// 本书其它排队的章不受影响。没有匹配的任务、或运行中的任务不支持暂停时返回
  /// false。
  Future<bool> pause(String bookKey, String directory) async {
    final List<_QueuedJob>? queue = _queued[bookKey];
    final int queuedIndex =
        queue?.indexWhere(
          (_QueuedJob queued) => p.equals(queued.directory, directory),
        ) ??
        -1;
    if (queue != null && queuedIndex >= 0) {
      final _QueuedJob queued = queue.removeAt(queuedIndex);
      if (queue.isEmpty) _queued.remove(bookKey);
      final MangaOcrBackgroundJob original = queued.job;
      _paused.add(
        _PausedJob(original, queued.mangaJsonPath, null, () => original),
      );
      _notifyChanged();
      return true;
    }
    final MangaOcrRunningJob? running = _jobs[bookKey];
    final MangaOcrBackgroundJob Function()? rebuild = running?.job.resume;
    if (running == null ||
        rebuild == null ||
        !p.equals(running.job.managedDirectory, directory)) {
      return false;
    }
    _jobs.remove(bookKey);
    _paused.add(
      _PausedJob(
        running.job,
        running.mangaJsonPath,
        running.lastEvent,
        rebuild,
      ),
    );
    _notifyChanged();
    await running.cancel();
    return true;
  }

  /// 继续一个已暂停的任务：重新经 [enqueue] 排到本书队尾（同书 FIFO + 全局名额
  /// 照旧）。没有匹配的暂停项返回 false。
  bool resume(String bookKey, String directory) {
    final int index = _paused.indexWhere(
      (_PausedJob paused) =>
          paused.bookKey == bookKey && p.equals(paused.directory, directory),
    );
    if (index < 0) return false;
    final _PausedJob paused = _paused.removeAt(index);
    unawaited(enqueue(job: paused.take(), mangaJsonPath: paused.mangaJsonPath));
    return true;
  }

  /// 批量暂停。先摘排队的、再停运行中的：反过来的话，停掉一个运行中的任务会
  /// 立刻放下一个排队者开跑，而它可能正是这批里下一个要暂停的。返回暂停成功数。
  Future<int> pauseAll(Iterable<MangaOcrJobRef> targets) async {
    final List<MangaOcrJobRef> list = targets.toList(growable: false);
    bool isRunning(MangaOcrJobRef ref) {
      final MangaOcrRunningJob? running = _jobs[ref.bookKey];
      return running != null &&
          p.equals(running.job.managedDirectory, ref.directory);
    }

    final List<MangaOcrJobRef> ordered = <MangaOcrJobRef>[
      ...list.where((MangaOcrJobRef ref) => !isRunning(ref)),
      ...list.where(isRunning),
    ];
    int paused = 0;
    for (final MangaOcrJobRef ref in ordered) {
      if (await pause(ref.bookKey, ref.directory)) paused += 1;
    }
    return paused;
  }

  /// 批量继续（按传入顺序重新排队）。返回继续成功数。
  int resumeAll(Iterable<MangaOcrJobRef> targets) {
    int resumed = 0;
    for (final MangaOcrJobRef ref in targets.toList(growable: false)) {
      if (resume(ref.bookKey, ref.directory)) resumed += 1;
    }
    return resumed;
  }

  void _dropPaused(String bookKey, String directory) {
    final int before = _paused.length;
    _paused.removeWhere(
      (_PausedJob paused) =>
          paused.bookKey == bookKey && p.equals(paused.directory, directory),
    );
    if (_paused.length != before) _notifyChanged();
  }

  /// 任务已结束、跟随步骤（大模型重读）还在收尾的，按 bookKey。删书 / 取消本书
  /// 也要停它们：否则删完目录后它还会往原路径写 manga.json。
  final Map<String, List<MangaOcrRunningJob>> _finishing =
      <String, List<MangaOcrRunningJob>>{};

  void _trackFollower(MangaOcrRunningJob running) {
    final MangaOcrJobFollower? follower = running.job.follower;
    if (follower == null || running.isCancelled) return;
    final List<MangaOcrRunningJob> list = _finishing.putIfAbsent(
      running.bookKey,
      () => <MangaOcrRunningJob>[],
    )..add(running);
    unawaited(
      follower.done.whenComplete(() {
        list.remove(running);
        if (list.isEmpty && identical(_finishing[running.bookKey], list)) {
          _finishing.remove(running.bookKey);
        }
      }),
    );
  }

  /// 停掉本书还在收尾的跟随步骤；给了 [directory] 时只停同目录的。
  Future<void> _cancelFollowersFor(String bookKey, {String? directory}) async {
    final List<MangaOcrRunningJob> list = <MangaOcrRunningJob>[
      ...?_finishing[bookKey],
    ];
    for (final MangaOcrRunningJob running in list) {
      if (directory != null &&
          !p.equals(running.job.managedDirectory, directory)) {
        continue;
      }
      await running._cancelFollower();
    }
  }

  void _forget(MangaOcrRunningJob running) {
    if (identical(_jobs[running.bookKey], running)) {
      _jobs.remove(running.bookKey);
      _notifyChanged();
    }
  }

  /// 事件进注册表：progress 原样透传（同时交给跟随步骤）；finished 先把产物落进
  /// 书根 manga.json——跟随步骤已改好的页同步并进去，**不等**它还没做完的页。
  Future<MangaOcrBackgroundEvent> _ingest(
    MangaOcrRunningJob running,
    MangaOcrBackgroundEvent event,
  ) async {
    final MangaOcrJobFollower? follower = running.job.follower;
    if (!event.finished) {
      follower?.onProgress(event);
      return event;
    }
    final String? resultPath = event.resultPath;
    if (resultPath == null) {
      throw StateError('OCR finished without a result path');
    }
    final String source = await File(resultPath).readAsString();
    final MokuroPayload local = event.external
        ? parseMokuro(source)
        : parseMangaJson(source);
    if (local.images.isEmpty) {
      throw StateError('OCR result has no pages');
    }
    final MokuroPayload payload = follower?.mergeInto(local) ?? local;
    // 整卷落盘与在线几何回填共用同一把 per-path 写锁：两者都是整份读-改-写，
    // 交叠会互相覆盖。
    final String target = running.mangaJsonPath;
    // 落盘的是并进 PDF 文字层之后的那份：阅读页拿 result 刷新显示，必须和磁盘一致。
    final MokuroPayload written = await runExclusiveOnMangaJson<MokuroPayload>(
      target,
      () => writeMangaJsonAtomically(target, payload),
    );
    running._result = written;
    follower?.onPersisted(target, written);
    return event;
  }
}
