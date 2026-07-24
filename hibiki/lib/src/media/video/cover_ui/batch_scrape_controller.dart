/// 批量刮削后台运行控制器 —— 运行状态与弹窗分离（用户拍板 2026-07-24：
/// 「这个刮削应该支持后台，而不是只有一个关闭按钮」）。
///
/// 根因视角：批量运行状态原先归 `BatchScrapeDialog` 的 State 拥有，关弹窗 =
/// 订阅取消 = 任务中断。改为本控制器持有 [PosterScraperService.scrapeLibrary]
/// 的订阅、逐组进度与结果列表；弹窗降级为纯视图（订阅本控制器渲染），关弹窗
/// 只是视图离场，任务照跑：
///
/// - 同时只允许**一个**批量在跑（[start] 运行中直接返回 false，入口重复点击
///   只是重新打开进度视图，不会重开一轮）；
/// - 「取消」= [cancel] 真中止；「后台运行」= 关弹窗（控制器不受影响）；
/// - 运行完成时若无任何弹窗在挂（[attachView]/[detachView] 计数为 0），用
///   [HibikiToast] 给一条汇总提示；
/// - 结果列表（含待确认队列）在 done 后保留，重开弹窗可继续逐条确认；直到
///   下一次 [start]/[resetIfDone] 才清空。
///
/// 归属：进程级单例 [instance]（与 `ErrorLogService.instance` 同款模式）——
/// 状态天然跨页面/跨弹窗存活，不依赖任何 widget 生命周期。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;

/// 批量运行阶段（弹窗据此选渲染分支）。
enum BatchScrapePhase { idle, running, done }

/// 一行（= 一组）结果快照。
class BatchScrapeRow {
  const BatchScrapeRow(this.group, this.outcome, this.coverableUids);

  final ScrapeGroup group;
  final ScrapeOutcome outcome;

  /// 单本组可覆盖成员 uid（合集组恒空，见 [BatchScrapeProgress.coverableUids]）。
  final List<String> coverableUids;
}

/// 批量刮削运行状态的唯一拥有者（[ChangeNotifier]：弹窗/页头角标订阅重绘）。
class BatchScrapeController extends ChangeNotifier {
  /// 可实例化（测试用独立实例，互不串状态）；生产用 [instance]。
  BatchScrapeController();

  /// 进程级单例（生产入口/弹窗/页头角标共用）。
  static final BatchScrapeController instance = BatchScrapeController();

  BatchScrapePhase _phase = BatchScrapePhase.idle;
  final List<BatchScrapeRow> _rows = <BatchScrapeRow>[];
  int _current = 0;
  int _total = 0;
  StreamSubscription<BatchScrapeProgress>? _sub;
  int _attachedViews = 0;

  BatchScrapePhase get phase => _phase;
  bool get isRunning => _phase == BatchScrapePhase.running;

  /// 已产出的逐组结果（运行中增量增长；done 后保留供继续确认）。只读视图。
  List<BatchScrapeRow> get rows => List<BatchScrapeRow>.unmodifiable(_rows);

  /// 当前进度（分子 = 已完成组数，分母 = 总组数；running 初期分母为书本数占位，
  /// 首个进度事件后换成真实组数）。
  int get current => _current;
  int get total => _total;

  /// 汇总计数（弹窗尾部与后台完成 toast 共用）。
  ({int applied, int confirm, int skipped}) get summary {
    int applied = 0;
    int confirm = 0;
    int skipped = 0;
    for (final BatchScrapeRow row in _rows) {
      switch (row.outcome) {
        case ScrapeApplied():
          applied++;
        case ScrapeNeedsConfirm():
          confirm++;
        case ScrapeNoMatch():
        case ScrapeSkippedNoTitle():
        case ScrapeSkippedProtected():
        case ScrapeSkippedDirectoryGroup():
        case ScrapeNotEligible():
        case ScrapeFailed():
          skipped++;
      }
    }
    return (applied: applied, confirm: confirm, skipped: skipped);
  }

  /// 启动一轮批量。运行中重复调用**不**重开（返回 false）；否则清空上一轮结果、
  /// 订阅 [PosterScraperService.scrapeLibrary] 并立即返回 true（任务在后台流式跑）。
  bool start({
    required PosterScraperService service,
    required List<VideoBookRow> books,
    bool rescrapeScraped = false,
  }) {
    if (_phase == BatchScrapePhase.running) return false;
    _rows.clear();
    _current = 0;
    _total = books.length;
    _phase = BatchScrapePhase.running;
    notifyListeners();
    _sub =
        service.scrapeLibrary(books, rescrapeScraped: rescrapeScraped).listen(
      (BatchScrapeProgress p) {
        _rows.add(BatchScrapeRow(p.group, p.outcome, p.coverableUids));
        _current = p.index + 1;
        _total = p.total;
        notifyListeners();
      },
      onDone: _finish,
      // 单组异常已在 service 内收敛为 ScrapeFailed；这里兜底流级异常（如
      // groupLibrary 阶段抛出），按完成收尾，已产出的结果保留。
      onError: (Object _) => _finish(),
    );
    return true;
  }

  /// 真中止：取消订阅并进入 done（已产出的结果保留，可继续确认）。
  Future<void> cancel() async {
    final StreamSubscription<BatchScrapeProgress>? sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (_phase == BatchScrapePhase.running) {
      _phase = BatchScrapePhase.done;
      notifyListeners();
    }
  }

  /// done → idle：清结果回到初始态（重新开始一轮前调用）。running 时 no-op。
  void resetIfDone() {
    if (_phase != BatchScrapePhase.done) return;
    _rows.clear();
    _current = 0;
    _total = 0;
    _phase = BatchScrapePhase.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  /// 弹窗视图挂载/卸载登记（决定完成时是否需要 toast 兜底告知）。
  void attachView() => _attachedViews++;
  void detachView() {
    if (_attachedViews > 0) _attachedViews--;
  }

  /// 仅测试：当前是否有视图在挂。
  @visibleForTesting
  int get attachedViews => _attachedViews;

  void _finish() {
    _sub = null;
    if (_phase != BatchScrapePhase.running) return;
    _phase = BatchScrapePhase.done;
    notifyListeners();
    if (_attachedViews == 0) {
      // 后台完成：弹窗已关，用全局 toast 报一条汇总（含待确认数提示）。
      try {
        final ({int applied, int confirm, int skipped}) s = summary;
        HibikiToast.show(
          msg: t.video_scrape_batch_summary(
            applied: s.applied,
            confirm: s.confirm,
            skipped: s.skipped,
          ),
        );
      } catch (_) {
        // 无 overlay/binding（纯 Dart 测试）时 toast 失败不影响状态机。
      }
    }
  }
}
