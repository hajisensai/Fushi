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
import 'dart:io';

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

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

  String get bookKey => job.bookKey;

  /// 最近一次事件（进度快照），晚到的观察者用它补齐 HUD。
  MangaOcrBackgroundEvent? get lastEvent => _lastEvent;

  /// 完成且已落盘的整卷结果；未完成 / 失败 / 取消时为 null。
  MokuroPayload? get result => _result;

  Object? get error => _error;

  bool get isCancelled => _cancelled;

  /// 底层任务已结束（完成、失败或取消）。
  bool get isEnded => _ended;

  /// 广播给观察者的事件流：与底层流同序，finished 事件在落盘**之后**才转发。
  Stream<MangaOcrBackgroundEvent> get events => _observers.stream;

  bool ownsSession(MangaReaderSession session) =>
      _sessions.any((MangaReaderSession s) => identical(s, session));

  /// 用户主动取消：真停底层任务（各执行器既有的取消语义），并释放会话。
  Future<void> cancel() async {
    if (_ended) return;
    _cancelled = true;
    await _source?.cancel();
    _source = null;
    await _end();
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
    // 刻意不 await：广播流的 done 要等每个观察者消费完才算送达，一个正卡在异步
    // 事件处理里的页面观察者不该把「真停任务」也一起卡住。
    unawaited(_observers.close());
  }
}

/// 按 `bookKey` 索引的任务注册表；一本书同一时刻最多一个整卷任务。
class MangaOcrJobRegistry {
  final Map<String, MangaOcrRunningJob> _jobs = <String, MangaOcrRunningJob>{};

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
    _jobs[job.bookKey] = running;
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
        running._error = error;
        if (!running._observers.isClosed) {
          running._observers.addError(error, stack);
        }
        _forget(running);
        unawaited(running._end());
      },
      onDone: () {
        _forget(running);
        unawaited(running._end());
      },
      cancelOnError: true,
    );
    return running;
  }

  /// 用户取消这本书的任务；没有任务在跑则 no-op。
  Future<void> cancel(String bookKey) async {
    final MangaOcrRunningJob? running = _jobs.remove(bookKey);
    if (running == null) return;
    await running.cancel();
  }

  /// 退出 app / 切换 Profile 等整体拆栈：把所有任务真停掉。
  Future<void> cancelAll() async {
    final List<MangaOcrRunningJob> jobs = _jobs.values.toList();
    _jobs.clear();
    for (final MangaOcrRunningJob running in jobs) {
      await running.cancel();
    }
  }

  void _forget(MangaOcrRunningJob running) {
    if (identical(_jobs[running.bookKey], running)) {
      _jobs.remove(running.bookKey);
    }
  }

  /// 事件进注册表：progress 原样透传；finished 先把产物落进书根 manga.json。
  Future<MangaOcrBackgroundEvent> _ingest(
    MangaOcrRunningJob running,
    MangaOcrBackgroundEvent event,
  ) async {
    if (!event.finished) return event;
    final String? resultPath = event.resultPath;
    if (resultPath == null) {
      throw StateError('OCR finished without a result path');
    }
    final String source = await File(resultPath).readAsString();
    final MokuroPayload payload =
        event.external ? parseMokuro(source) : parseMangaJson(source);
    if (payload.images.isEmpty) {
      throw StateError('OCR result has no pages');
    }
    // 整卷落盘与框选回写、在线几何回填共用同一把 per-path 写锁：三者都是整份
    // 读-改-写，交叠会互相覆盖。
    final String target = running.mangaJsonPath;
    await runExclusiveOnMangaJson<void>(
      target,
      () => writeMangaJsonAtomically(target, payload),
    );
    running._result = payload;
    return event;
  }
}
