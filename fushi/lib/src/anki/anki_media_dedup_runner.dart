import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 自动处理两次扫描之间的最短间隔。全量哈希媒体目录不便宜，每次启动都跑没
/// 必要；用户手动触发不受这个节流影响。
const Duration kAnkiMediaDedupAutoInterval = Duration(days: 7);

/// 自动处理该不该跑这一轮（纯函数，便于单测边界）。
///
/// [lastScanAtMs] = 上次扫描完成时刻（epoch ms），null = 从未扫过 → 跑。
bool shouldRunAutoMediaDedupScan({
  required int? lastScanAtMs,
  required DateTime now,
  Duration interval = kAnkiMediaDedupAutoInterval,
}) {
  if (lastScanAtMs == null) return true;
  final DateTime last = DateTime.fromMillisecondsSinceEpoch(lastScanAtMs);
  return now.difference(last) >= interval;
}

/// 一轮自动处理的结果。
///
/// 数据结构本身就把「干跑」和「真删」分开：[plan] 永远是干跑清单，[applied]
/// 只有在用户**显式**打开「自动直接删除」时才非空。UI 拿到 [needsConfirmation]
/// == true 就必须先让用户确认才能删——自动路径不存在绕过确认的分支。
class AnkiMediaDedupAutoOutcome {
  const AnkiMediaDedupAutoOutcome({required this.plan, this.applied});

  /// 干跑清单（删哪些、各多大、保留哪一份）。
  final AnkiMediaDedupReport plan;

  /// 已真删的结果。非 null ⟺ 用户显式打开了「自动直接删除」。
  final AnkiMediaDedupReport? applied;

  /// 有可删的东西、但还没删：UI 必须提示用户并拿到确认。
  bool get needsConfirmation => applied == null && plan.deletions.isNotEmpty;
}

/// Anki 媒体字节级去重的应用层编排：journal 落盘 + 时刻持久化 + 自动处理闸门。
///
/// **默认没有任何自动路径**（用户拍板方案 A）：`mediaDedupAutoEnabled` 默认
/// false，[maybeAutoRunOnStartup] 直接返回 null。用户可以在设置页主动打开自动
/// 处理，打开之后**仍然只做干跑并提示**，必须确认才真删；只有再显式打开
/// 「自动直接删除」才会跳过确认。原实现的缺陷正是「自动路径绕过确认框」，
/// 把开关加回来不能把这个坑一起加回来。
///
/// 手动路径同样是「先干跑 → 用户确认 → 再真删」，见设置页 `_runMediaDedup`。
///
/// 真实的扫描/改写/删除在 `BaseAnkiRepository.runMediaDedup`
/// （AnkiConnect 实现）；本类只负责「每次真实改写/删除前把可回溯记录写进
/// `<supportRoot>/backups/media_dedup/<时间戳>.jsonl`」这条保险带。
class AnkiMediaDedupRunner {
  AnkiMediaDedupRunner(this._repository);

  final BaseAnkiRepository _repository;

  /// 自动处理的会话级闸门：HomePage 可能重建，每进程只跑一次。
  static bool _autoRanThisSession = false;

  /// 测试用：重置会话级闸门。
  @visibleForTesting
  static void resetAutoSessionGate() => _autoRanThisSession = false;

  Future<Directory> journalDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory dir =
        Directory(p.join(support.path, 'backups', 'media_dedup'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 传给 [runNow] 的 `onProgress` / `shouldCancel` 是不是真会被调用（互联
  /// 「制卡到已配对设备」把整轮推给主机跑，两者都跨不过那次 HTTP 往返）。
  /// 进度弹窗据此画不确定进度条并隐藏取消按钮。
  bool get supportsProgress => _repository.supportsMediaMaintenanceProgress;

  /// 跑一轮去重。[dryRun] = 只扫描规划、不改动任何东西（不写 journal、不更新
  /// 时间戳），产出的 `AnkiMediaDedupReport.deletions` 就是给用户看的删除清单。
  /// [onProgress] / [shouldCancel] 直通仓库层（BUG-1263：分钟级长任务必须有
  /// 进度和取消）。后端不支持返回 null。
  Future<AnkiMediaDedupReport?> runNow({
    required bool dryRun,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (!_repository.supportsMediaMaintenance) return null;
    if (dryRun) {
      return _repository.runMediaDedup(
          dryRun: true, onProgress: onProgress, shouldCancel: shouldCancel);
    }

    final Directory dir = await journalDirectory();
    final String stamp =
        DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final File journal = File(p.join(dir.path, 'dedup-$stamp.jsonl'));
    final IOSink sink = journal.openWrite();
    bool wroteAny = false;
    try {
      final AnkiMediaDedupReport? report = await _repository.runMediaDedup(
        onJournal: (Map<String, dynamic> entry) async {
          wroteAny = true;
          sink.writeln(jsonEncode(entry));
        },
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
      // 取消的轮不算「完成过一轮」：不推进时间戳，下次自动扫描照常到期。
      if (report != null && !report.cancelled) {
        final int nowMs = DateTime.now().millisecondsSinceEpoch;
        await _repository.updateSettings((AnkiSettings s) => s.copyWith(
              lastMediaDedupAtMs: nowMs,
              lastMediaDedupScanAtMs: nowMs,
            ));
      }
      return report;
    } finally {
      await sink.flush();
      await sink.close();
      // 这一轮啥也没改（无重复/全跳过）：不留空 journal 文件。
      if (!wroteAny && await journal.exists()) await journal.delete();
    }
  }

  /// 启动时的自动处理。返回 null = 这一轮什么都没做（开关关着 / 后端不支持 /
  /// 还没到间隔 / 本进程已跑过）。
  ///
  /// 打开开关之后的确切行为：**只跑干跑**，把清单经 [AnkiMediaDedupAutoOutcome]
  /// 交回 UI 提示，用户确认后才由 UI 调 `runNow(dryRun: false)` 真删。只有用户
  /// 另外显式打开「自动直接删除」（`mediaDedupAutoDelete`），这里才会直接接上
  /// 真删并把结果放进 [AnkiMediaDedupAutoOutcome.applied]。
  Future<AnkiMediaDedupAutoOutcome?> maybeAutoRunOnStartup({
    DateTime? now,
  }) async {
    if (_autoRanThisSession) return null;
    _autoRanThisSession = true;
    if (!_repository.supportsMediaMaintenance) return null;
    final AnkiSettings settings = await _repository.loadSettings();
    // 默认关：用户没主动打开，Hibiki 连扫都不扫。
    if (!settings.mediaDedupAutoEnabled) return null;
    final DateTime at = now ?? DateTime.now();
    if (!shouldRunAutoMediaDedupScan(
      lastScanAtMs: settings.lastMediaDedupScanAtMs,
      now: at,
    )) {
      return null;
    }
    final AnkiMediaDedupReport? plan =
        await _repository.runMediaDedup(dryRun: true);
    if (plan == null) return null;
    await _repository.updateSettings((AnkiSettings s) =>
        s.copyWith(lastMediaDedupScanAtMs: at.millisecondsSinceEpoch));
    if (plan.deletions.isEmpty) {
      return AnkiMediaDedupAutoOutcome(plan: plan);
    }
    if (!settings.mediaDedupAutoDelete) {
      // 保守路径（默认）：只给清单，删不删由用户在确认弹窗里定。
      debugPrint('AnkiMediaDedupRunner.auto: ${plan.deletions.length} '
          'duplicates found, awaiting user confirmation');
      return AnkiMediaDedupAutoOutcome(plan: plan);
    }
    debugPrint('AnkiMediaDedupRunner.auto: auto-delete explicitly enabled, '
        'removing ${plan.deletions.length} duplicates');
    return AnkiMediaDedupAutoOutcome(
      plan: plan,
      applied: await runNow(dryRun: false),
    );
  }
}
