import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// Anki 媒体字节级去重的应用层编排：journal 落盘 + 上次运行时间持久化 +
/// 启动周期触发（每 7 天）。
///
/// 真实的扫描/改写/删除在 `BaseAnkiRepository.runMediaDedup`
/// （AnkiConnect 实现）；本类只负责「每次真实改写/删除前把可回溯记录写进
/// `<supportRoot>/backups/media_dedup/<时间戳>.jsonl`」这条保险带，以及
/// check-due 周期门。
class AnkiMediaDedupRunner {
  AnkiMediaDedupRunner(this._repository);

  final BaseAnkiRepository _repository;

  /// 启动周期触发的会话级闸门（HomePage 重建不重跑）。
  static bool _ranThisSession = false;

  /// 测试用：重置会话级闸门。
  @visibleForTesting
  static void resetSessionGate() => _ranThisSession = false;

  Future<Directory> journalDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory dir =
        Directory(p.join(support.path, 'backups', 'media_dedup'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 跑一轮去重（设置页手动入口与周期触发共用）。[dryRun] = 只扫描不改动
  /// （不写 journal、不更新时间戳）。后端不支持返回 null。
  Future<AnkiMediaDedupReport?> runNow({required bool dryRun}) async {
    if (!_repository.supportsMediaMaintenance) return null;
    if (dryRun) return _repository.runMediaDedup(dryRun: true);

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
      );
      if (report != null) {
        await _repository.updateSettings((AnkiSettings s) => s.copyWith(
            lastMediaDedupAtMs: DateTime.now().millisecondsSinceEpoch));
      }
      return report;
    } finally {
      await sink.flush();
      await sink.close();
      // 这一轮啥也没改（无重复/全跳过）：不留空 journal 文件。
      if (!wroteAny && await journal.exists()) await journal.delete();
    }
  }

  /// 启动周期触发：开关开启 + 距上次 ≥7 天才真正跑。Anki 未运行/不可达是
  /// 常态，静默跳过（时间戳不更新，下次启动再试）。
  Future<void> maybeRunPeriodic() async {
    if (_ranThisSession) return;
    _ranThisSession = true;
    if (!_repository.supportsMediaMaintenance) return;
    final AnkiSettings settings = await _repository.loadSettings();
    if (!settings.mediaDedupAutoEnabled) return;
    if (!shouldRunPeriodicMediaDedup(
      lastRunMs: settings.lastMediaDedupAtMs,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    )) {
      return;
    }
    try {
      final AnkiMediaDedupReport? report = await runNow(dryRun: false);
      if (report != null) {
        debugPrint('AnkiMediaDedupRunner.periodic: ${report.toJson()}');
      }
    } catch (e) {
      debugPrint('AnkiMediaDedupRunner.periodic: skipped (unreachable?): $e');
    }
  }
}
