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

  /// 第一遍（真正升级的那一遍）的结果；没有词典时为 null。
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
/// 1. 在 [controller] 的词典写锁里跑（[DictionaryDownloadController.runWhenIdle]：别的
///    写任务在跑就排队等它结束，不并发、不因撞上而永久跳过）。
/// 2. 先**静默**处理：phase 保持 idle，状态行不出现——「全部已是最新」的常态启动
///    UI 一帧都不闪。收到第一个 [FushiDictUpgradeOutcome.upgraded] 才
///    [DictionaryDownloadJob.markUpgradePhase] 亮出状态行，之后每本更新「已处理 /
///    总数」。哪些词典要升级只有原生侧知道（文件布局是原生侧的事），所以不预判。
/// 3. 只要有一本升级过：出锁后 [reload]（影子引擎装完再切换）让新格式生效，再
///    [settleOldEngine] 等旧引擎的后台借用归还（旧句柄此刻才解除映射），然后在锁里
///    **静默**补跑一遍：Windows 上第一遍删不掉的被映射旧文件这时才清得掉。补跑不亮
///    UI、不再重载（正常只会返回「已是最新」；万一有本在两遍之间才变成可升级，它的
///    新格式等下一次装载生效）。
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

  /// 要升级的全部词典目录（全部类型，含隐藏的）。每一遍开始时重新取，拿到的是当时的
  /// 词典集合。
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
    if (dictDirs().isEmpty) {
      return const DictionaryFormatUpgradeRun(
        first: null,
        revealed: false,
        reloaded: false,
      );
    }
    bool revealed = false;
    final FushiDictUpgradeReport first = await controller.runWhenIdle(
      (DictionaryDownloadJob job) => upgrade(
        dictDirs(),
        onProgress:
            (int done, int total, String dir, FushiDictUpgradeOutcome outcome) {
              if (!revealed && outcome == FushiDictUpgradeOutcome.upgraded) {
                revealed = true;
                job.markUpgradePhase();
              }
              if (!revealed) return;
              job.message.value = message(done, total);
              job.progress.value = total == 0 ? 0 : done / total;
            },
      ),
    );
    _logProblems(first, pass: 'first');
    if (!first.anyUpgraded) {
      return DictionaryFormatUpgradeRun(
        first: first,
        revealed: revealed,
        reloaded: false,
      );
    }

    await reload();
    await settleOldEngine();
    final FushiDictUpgradeReport cleanup = await controller.runWhenIdle(
      (DictionaryDownloadJob job) => upgrade(dictDirs()),
    );
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
