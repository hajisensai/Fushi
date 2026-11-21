import 'dart:async';

import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/models/dictionary_download_controller.dart';

/// 跑一轮原生升级 / 检查（生产里是 [FushiDicts.upgradeDictionaryFormats] /
/// [FushiDicts.tidyDictionaryFormats]）。
typedef DictionaryUpgradeRunner =
    Future<FushiDictUpgradeReport> Function(
      List<String> dictDirs, {
      FushiDictUpgradeProgress? onProgress,
    });

/// 状态行文案（`done` / `total` 与 [FushiDictUpgradeProgress] 同义）。
typedef DictionaryUpgradeMessage = String Function(int done, int total);

/// 问用户要不要现在升级这 [pendingCount] 本词典（生产里是启动期对话框；词典页的升级
/// 按钮本身就是同意，直接返回 true）。
typedef DictionaryUpgradeConfirm = Future<bool> Function(int pendingCount);

/// 记一条不打扰用户的诊断（生产里是 `ErrorLogService`）。
typedef DictionaryUpgradeLogger = void Function(String tag, Object info);

/// 一次 [DictionaryFormatUpgradeCoordinator.run] 的经过（给调用方 / 测试看）。
class DictionaryFormatUpgradeRun {
  const DictionaryFormatUpgradeRun({
    required this.checked,
    required this.confirmed,
    this.upgrade,
    this.cleanup,
  });

  /// 静默检查那一遍（只检查 + 清理，旧式词典不改写）的结果；没有词典时为 null。
  final FushiDictUpgradeReport? checked;

  /// 待升级（旧式）的目录；空 = 不用问用户。
  List<String> get pending => checked?.pending ?? const <String>[];

  /// 用户是否同意了升级（没有待升级的词典时为 false，没问）。
  final bool confirmed;

  /// 同意之后占着写锁、亮着状态行的那一遍；没升级时为 null。
  final FushiDictUpgradeReport? upgrade;

  /// 是否触发过引擎重载（有一本升级过才重载）。
  bool get reloaded => cleanup != null;

  /// 重载之后静默补跑的那一遍检查（清理之前删不掉的旧文件）；没补跑时为 null。
  final FushiDictUpgradeReport? cleanup;
}

/// 存量词典「原地升级到新磁盘格式」的编排。所有副作用都注入，逻辑可单测。
///
/// 拍板台 pr3554（维护者 2026-11-17）：升级会整本改写用户数据根里的词典文件（删
/// hash.table / bloom.filter、可能重写 blobs.bin；数据根在网盘上时触发一次全量重新
/// 同步），而且升级后旧版本读不了——所以**先提示、用户同意了才升级**，不在后台自动做。
///
/// 时序：
/// 1. **静默检查，不占词典写锁**：[tidy] 逐本只检查 + 清理。已是新格式的顺带清掉遗留
///    旧文件、把完成标记换成新名字（几个字节）；旧式词典**一个字节都不写**，报待升级。
///    常态启动（全部已是最新）到此结束——UI 一帧都不变，也不挡用户点的下载 / 启动
///    自动更新。不占锁也安全：与删 / 覆盖词典的串行由原生调用自己的借用账本保证。
/// 2. **有待升级的**：[confirm] 问用户。不同意就到此为止（词典照旧格式可用）。
/// 3. **同意了**：待升级的那几本放进 [controller] 的写锁里做
///    （[DictionaryDownloadController.runWhenIdle]：别的写任务在跑就排队），一占到锁就
///    [DictionaryDownloadJob.markUpgradePhase] 亮出状态行，每本更新「已处理 / 总数」。
/// 4. 只要有一本升级过：[reload]（影子引擎装完再切换）让新格式生效，再
///    [settleOldEngine] 等旧引擎的后台借用归还，然后**静默、不占锁**再检查一遍：
///    Windows 上升级时删不掉的被映射旧文件这时才清得掉。
/// 5. 失败（-1）/ 不适用（2）只记 [log]，不打扰用户：两者词典都按旧格式照常可用。被
///    映射释放作用域推迟的（[FushiDictUpgradeReport.deferred]）下次再说。
class DictionaryFormatUpgradeCoordinator {
  DictionaryFormatUpgradeCoordinator({
    required this.controller,
    required this.dictDirs,
    required this.tidy,
    required this.upgrade,
    required this.confirm,
    required this.reload,
    required this.settleOldEngine,
    required this.message,
    required this.log,
  });

  final DictionaryDownloadController controller;

  /// 全部词典目录（全部类型，含隐藏的）。检查与补跑那一遍开始时各取一次。
  final List<String> Function() dictDirs;

  /// 只检查 + 清理（生产里是 [FushiDicts.tidyDictionaryFormats]）。
  final DictionaryUpgradeRunner tidy;

  /// 真正升级（生产里是 [FushiDicts.upgradeDictionaryFormats]），只对用户同意了的
  /// 待升级目录调用。
  final DictionaryUpgradeRunner upgrade;

  final DictionaryUpgradeConfirm confirm;

  /// 重载词典引擎（生产里是 `AppModel._rebuildDictPathsCacheAsync`）。
  final Future<void> Function() reload;

  /// 等旧引擎真正释放映射（生产里是 [FushiDicts.whenBackgroundBorrowsSettled]）。
  final Future<void> Function() settleOldEngine;

  final DictionaryUpgradeMessage message;

  final DictionaryUpgradeLogger log;

  /// 诊断 tag。
  static const String logTag = 'AppModel.dictFormatUpgrade';

  /// 跑一轮（检查 → 必要时问用户 → 升级 → 重载与静默补跑）。原生库缺导出等异常原样
  /// 抛给调用方。
  Future<DictionaryFormatUpgradeRun> run() async {
    final List<String> dirs = dictDirs();
    if (dirs.isEmpty) {
      return const DictionaryFormatUpgradeRun(checked: null, confirmed: false);
    }
    final FushiDictUpgradeReport checked = await tidy(dirs);
    _logProblems(checked, pass: 'check');
    final List<String> pending = checked.pending;
    if (pending.isEmpty || !await confirm(pending.length)) {
      return DictionaryFormatUpgradeRun(checked: checked, confirmed: false);
    }

    final FushiDictUpgradeReport upgraded = await controller.runWhenIdle((
      DictionaryDownloadJob job,
    ) {
      // 占到锁的同一拍亮出来：锁被占着而状态行不亮的时刻不存在。
      job.markUpgradePhase();
      job.message.value = message(0, pending.length);
      job.progress.value = 0;
      return upgrade(
        pending,
        onProgress:
            (int done, int total, String dir, FushiDictUpgradeOutcome outcome) {
              job.message.value = message(done, total);
              job.progress.value = done / total;
            },
      );
    });
    _logProblems(upgraded, pass: 'upgrade');
    if (!upgraded.anyUpgraded) {
      return DictionaryFormatUpgradeRun(
        checked: checked,
        confirmed: true,
        upgrade: upgraded,
      );
    }

    await reload();
    await settleOldEngine();
    final FushiDictUpgradeReport cleanup = await tidy(dictDirs());
    _logProblems(cleanup, pass: 'cleanup');
    return DictionaryFormatUpgradeRun(
      checked: checked,
      confirmed: true,
      upgrade: upgraded,
      cleanup: cleanup,
    );
  }

  void _logProblems(FushiDictUpgradeReport report, {required String pass}) {
    String names(List<String> dirs) =>
        dirs.map((String d) => d.split(RegExp(r'[\\/]')).last).join(', ');
    if (report.failed.isNotEmpty) {
      log(
        logTag,
        '词典格式升级失败（词典仍按旧格式可用）[$pass]: '
        '${names(report.failed)}',
      );
    }
    if (report.notApplicable.isNotEmpty) {
      log(logTag, '词典格式升级不适用（保持旧式）[$pass]: ${names(report.notApplicable)}');
    }
  }
}
