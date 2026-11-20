/// 作品页的「哪些章已下载」缓存（manga-4）。
///
/// 判据本体是 [isChapterDownloaded]：读整份章 `manga.json` 再逐页 stat，一章几十
/// 次磁盘访问。作品页以前在下载任务表的**每一个**信号上（每下完一页写一次进度就是
/// 一个信号）对全书每章重判一遍——已下载 100 章的书开着作品页再下一章，每页都是
/// 100 份 `manga.json` 解析 + 几千次 stat，全在 UI isolate 上。
///
/// 这里按章缓存结论，只重判「结论可能变了」的章：
/// - 第一次 / 书目录变了（下载任务刚把书搬进下载根）：全部；
/// - 章表里新出现的章（源刷新多了章）：只判新章；
/// - 某章的任务行**身份或状态**变了（入队 → 下载中 → 完成 / 失败 / 取消、任务行被
///   删）：只判那一章。纯进度信号（状态不变、只有 `pagesDone` 动）不重判；
/// - 调用方显式作废的章（作品页「删除本章下载」之后）。
///
/// 页面以外的删除（下载中心删任务连文件、书被别处移出书架）都会改任务行，落在第三
/// 条里；调用方在「从阅读器回来」这类时机仍可 [invalidateAll] 做一次全量复核。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';

/// 单章判据（测试缝；生产用 [isChapterDownloaded]）。
typedef MangaChapterDownloadCheck =
    Future<bool> Function(String bookDir, String chapterKey);

/// 按章缓存的「已下载」结论，见库注释。
class MangaChapterDownloadVerdicts {
  MangaChapterDownloadVerdicts({
    MangaChapterDownloadCheck check = isChapterDownloaded,
  }) : _check = check;

  final MangaChapterDownloadCheck _check;

  final Map<String, bool> _verdicts = <String, bool>{};

  /// 上一次看到的每章任务行身份 + 状态（`jobId\u001fstatus`）。
  final Map<String, String> _jobMarks = <String, String>{};
  final Set<String> _stale = <String>{};
  String? _bookDir;
  bool _all = true;

  /// 下一次 [resolve] 重判这些章。
  void invalidate(Iterable<String> chapterKeys) => _stale.addAll(chapterKeys);

  /// 下一次 [resolve] 全量重判。
  void invalidateAll() => _all = true;

  /// 丢掉全部缓存（条目移出书架）。
  void clear() {
    _verdicts.clear();
    _jobMarks.clear();
    _stale.clear();
    _bookDir = null;
    _all = true;
  }

  /// 按当前章表与任务行算出已下载的章 key 集合；只对需要的章调判据。
  ///
  /// 作废标记在判据开跑**之前**取走：判的过程中再来的作废记到下一轮，不会被本轮
  /// 吞掉（调用方的串行刷新会再跑一轮）。某章判据抛错时，它和后面没判的章都放回
  /// 作废集，下一轮必重判，异常照常抛给调用方。
  Future<Set<String>> resolve({
    required String bookDir,
    required List<String> chapterKeys,
    required Map<String, MangaDownloadJobRow> jobs,
  }) async {
    final bool all = _all || bookDir != _bookDir;
    _all = false;
    final Set<String> stale = Set<String>.of(_stale);
    _stale.clear();
    final Set<String> listed = chapterKeys.toSet();
    final List<String> toCheck = <String>[];
    for (final String key in chapterKeys) {
      final MangaDownloadJobRow? job = jobs[key];
      final String? mark = job == null
          ? null
          : '${job.jobId}\u001f${job.status}';
      final bool jobChanged = mark != _jobMarks[key];
      if (mark == null) {
        _jobMarks.remove(key);
      } else {
        _jobMarks[key] = mark;
      }
      if (all ||
          jobChanged ||
          stale.contains(key) ||
          !_verdicts.containsKey(key)) {
        toCheck.add(key);
      }
    }
    _verdicts.removeWhere((String key, bool _) => !listed.contains(key));
    _jobMarks.removeWhere((String key, String _) => !listed.contains(key));
    _bookDir = bookDir;
    for (int i = 0; i < toCheck.length; i++) {
      try {
        _verdicts[toCheck[i]] = await _check(bookDir, toCheck[i]);
      } on Object {
        // 任务行标记已经记成新值，没判完的章要是不放回作废集，之后的纯进度信号
        // 不会再触发重判，它们会一直挂着旧结论。
        _stale.addAll(toCheck.skip(i));
        rethrow;
      }
    }
    return <String>{
      for (final MapEntry<String, bool> e in _verdicts.entries)
        if (e.value) e.key,
    };
  }
}

/// 串行合并的异步刷新：同一时刻只跑一轮；跑的过程中再被请求，就在本轮结束后
/// **再跑一轮**（多次请求合成一轮），所有等待方都等到最后那一轮结束。
///
/// 作品页的下载状态刷新被任务表信号、用户动作、从阅读器回来多处触发，并发跑会让
/// 慢的旧一轮晚于新一轮落 setState（旧结论盖住新结论），也会把同一批磁盘判据
/// 重复跑几遍。
class CoalescedRefresh {
  CoalescedRefresh(this._body);

  final Future<void> Function() _body;
  Future<void>? _running;
  bool _again = false;

  /// 是否有一轮在跑（测试用）。
  bool get isRunning => _running != null;

  /// 请求一轮刷新；返回值在包含这次请求的那一轮跑完时完成。
  Future<void> request() {
    final Future<void>? running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final Future<void> run = _loop();
    _running = run;
    return run;
  }

  /// 某一轮抛错不中断循环：那一轮期间来的请求仍要补跑（否则它们拿到的是一轮
  /// 早于自己的结果，请求本身被丢掉）。所有轮跑完后，等待方收到第一个错误。
  Future<void> _loop() async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      do {
        _again = false;
        try {
          await _body();
        } on Object catch (error, stack) {
          if (firstError == null) {
            firstError = error;
            firstStack = stack;
          }
        }
      } while (_again);
    } finally {
      _running = null;
    }
    final Object? error = firstError;
    if (error != null) Error.throwWithStackTrace(error, firstStack!);
  }
}
