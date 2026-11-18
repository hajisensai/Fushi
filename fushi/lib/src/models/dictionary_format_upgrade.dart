import 'dart:async';

import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/models/dictionary_download_controller.dart';

/// 跑一轮原生升级（生产里是 [FushiDicts.upgradeDictionaryFormats]）。
typedef DictionaryUpgradeRunner =
    Future<FushiDictUpgradeReport> Function(
      List<String> dictDirs, {
      FushiDictUpgradeProgress? onProgress,
    });

/// 状态行文案（`done` / `total` 与 [FushiDictUpgradeProgress] 同义）。
typedef DictionaryUpgradeMessage = String Function(int done, int total);

/// 记一条不打扰用户的诊断（生产里是 `ErrorLogService`）。
typedef DictionaryUpgradeLogger = void Function(String tag, Object info);

/// 一次 [DictionaryFormatUpgradeCoordinator.run] 的经过（给调用方 / 测试看）。
class DictionaryFormatUpgradeRun {
  const DictionaryFormatUpgradeRun({
    required this.first,
    required this.revealed,
    required this.reloaded,
    this.cleanup,
  });

  /// 第一遍（真正升级的那一遍，静默段 + 亮着状态行的那段合计）的结果；没有词典时
  /// 为 null。
  final FushiDictUpgradeReport? first;

  /// 第一遍是否亮过状态行。
  final bool revealed;

  /// 是否触发过引擎重载。
  final bool reloaded;

  /// 重载之后静默补跑的那一遍（清理之前删不掉的旧文件）；没补跑时为 null。
  final FushiDictUpgradeReport? cleanup;
}

/// 启动期「存量词典原地升级到新磁盘格式」的编排。所有副作用都注入，逻辑可单测。
///
/// 时序：
/// 1. **静默段，不占词典写锁**：从头逐本调 [upgrade]。常态启动（全部已是最新）到此
///    结束——UI 一帧都不变，也不挡用户点的下载 / 启动自动更新（它们撞上被占的锁是
///    直接放弃的，启动时每次都撞上就等于自动更新永远不跑）。不占锁也安全：与删 /
///    覆盖词典的串行由 [FushiDicts.upgradeDictionaryFormats] 自己的借用账本保证，
///    与存量 redirect 标记补写同一套。哪些词典要升级只有原生侧知道（文件布局是原生侧
///    的事），所以不预判，以「有一本返回已升级」为准。
/// 2. **有一本升级了、且后面还有词典**：这是一次真的存量升级（通常是新版本的首次
///    启动，后面多半都要升级），剩下的放进 [controller] 的写锁里做
///    （[DictionaryDownloadController.runWhenIdle]：别的写任务在跑就排队等它结束），
///    一占到锁就 [DictionaryDownloadJob.markUpgradePhase] 亮出状态行，每本更新
///    「已处理 / 总数」。
/// 3. 只要有一本升级过：[reload]（影子引擎装完再切换）让新格式生效，再
///    [settleOldEngine] 等旧引擎的后台借用归还（旧句柄此刻才解除映射），然后**静默、
///    不占锁**补跑一遍：Windows 上第一遍删不掉的被映射旧文件这时才清得掉。补跑不
///    亮 UI、不再重载（正常只会返回「已是最新」；万一有本在两遍之间才变成可升级，
///    它的新格式等下一次装载生效）。
/// 4. 失败（-1）/ 不适用（2）只记 [log]，不打扰用户：两者词典都按旧格式照常可用，
///    下次启动再试。被映射释放作用域推迟的（[FushiDictUpgradeReport.deferred]）同样
///    下次再说。
class DictionaryFormatUpgradeCoordinator {
  DictionaryFormatUpgradeCoordinator({
    required this.controller,
    required this.dictDirs,
    required this.upgrade,
    required this.reload,
    required this.settleOldEngine,
    required this.message,
    required this.log,
  });

  final DictionaryDownloadController controller;

  /// 要升级的全部词典目录（全部类型，含隐藏的）。第一遍与补跑那一遍开始时各取一次，
  /// 拿到的是当时的词典集合。
  final List<String> Function() dictDirs;

  final DictionaryUpgradeRunner upgrade;

  /// 重载词典引擎（生产里是 `AppModel._rebuildDictPathsCacheAsync`）。
  final Future<void> Function() reload;

  /// 等旧引擎真正释放映射（生产里是 [FushiDicts.whenBackgroundBorrowsSettled]）。
  final Future<void> Function() settleOldEngine;

  final DictionaryUpgradeMessage message;

  final DictionaryUpgradeLogger log;

  /// 诊断 tag。
  static const String logTag = 'AppModel.dictFormatUpgrade';

  /// 跑一轮（第一遍 + 必要时的重载与静默补跑）。原生库缺导出等异常原样抛给调用方。
  Future<DictionaryFormatUpgradeRun> run() async {
    final List<String> dirs = dictDirs();
    if (dirs.isEmpty) {
      return const DictionaryFormatUpgradeRun(
        first: null,
        revealed: false,
        reloaded: false,
      );
    }
    final Map<String, FushiDictUpgradeOutcome> results =
        <String, FushiDictUpgradeOutcome>{};
    final List<String> deferred = <String>[];
    void collect(FushiDictUpgradeReport report) {
      results.addAll(report.results);
      deferred.addAll(report.deferred);
    }

    // 静默段：逐本、不占锁，到第一本「已升级」为止。
    int next = 0;
    bool anyUpgraded = false;
    while (next < dirs.length && !anyUpgraded) {
      final FushiDictUpgradeReport one = await upgrade(<String>[dirs[next]]);
      collect(one);
      anyUpgraded = one.anyUpgraded;
      next++;
    }

    // 确有存量词典要升级、后面还有：剩下的占着写锁、亮着状态行做。
    bool revealed = false;
    if (anyUpgraded && next < dirs.length) {
      final int offset = next;
      revealed = true;
      collect(
        await controller.runWhenIdle((DictionaryDownloadJob job) {
          // 占到锁的同一拍亮出来：锁被占着而状态行不亮的时刻不存在。
          job.markUpgradePhase();
          job.message.value = message(offset, dirs.length);
          job.progress.value = offset / dirs.length;
          return upgrade(
            dirs.sublist(offset),
            onProgress:
                (
                  int done,
                  int total,
                  String dir,
                  FushiDictUpgradeOutcome outcome,
                ) {
                  job.message.value = message(offset + done, dirs.length);
                  job.progress.value = (offset + done) / dirs.length;
                },
          );
        }),
      );
    }

    final FushiDictUpgradeReport first = FushiDictUpgradeReport(
      results: results,
      deferred: deferred,
    );
    _logProblems(first, pass: 'first');
    if (!anyUpgraded) {
      return DictionaryFormatUpgradeRun(
        first: first,
        revealed: false,
        reloaded: false,
      );
    }

    await reload();
    await settleOldEngine();
    final FushiDictUpgradeReport cleanup = await upgrade(dictDirs());
    _logProblems(cleanup, pass: 'cleanup');
    return DictionaryFormatUpgradeRun(
      first: first,
      revealed: revealed,
      reloaded: true,
      cleanup: cleanup,
    );
  }

  void _logProblems(FushiDictUpgradeReport report, {required String pass}) {
    String names(List<String> dirs) =>
        dirs.map((String d) => d.split(RegExp(r'[\\/]')).last).join(', ');
    if (report.failed.isNotEmpty) {
      log(
        logTag,
        '词典格式升级失败（词典仍按旧格式可用，下次启动重试）[$pass]: '
        '${names(report.failed)}',
      );
    }
    if (report.notApplicable.isNotEmpty) {
      log(logTag, '词典格式升级不适用（保持旧式）[$pass]: ${names(report.notApplicable)}');
    }
  }
}
