import 'dart:convert';
import 'dart:io';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// Anki 媒体字节级去重的应用层编排：journal 落盘 + 上次运行时间持久化。
///
/// **没有任何自动/周期触发路径**（用户拍板方案 A）：唯一入口是设置页的手动
/// 触发，而且必须先跑 [runNow] 的干跑拿到删除清单、由用户在弹窗里确认之后，
/// 才会以 `dryRun: false` 再跑一次真删。Hibiki 不会在用户没点之前动任何文件。
///
/// 真实的扫描/改写/删除在 `BaseAnkiRepository.runMediaDedup`
/// （AnkiConnect 实现）；本类只负责「每次真实改写/删除前把可回溯记录写进
/// `<supportRoot>/backups/media_dedup/<时间戳>.jsonl`」这条保险带。
class AnkiMediaDedupRunner {
  AnkiMediaDedupRunner(this._repository);

  final BaseAnkiRepository _repository;

  Future<Directory> journalDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory dir =
        Directory(p.join(support.path, 'backups', 'media_dedup'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 跑一轮去重。[dryRun] = 只扫描规划、不改动任何东西（不写 journal、不更新
  /// 时间戳），产出的 `AnkiMediaDedupReport.deletions` 就是给用户看的删除清单。
  /// 后端不支持返回 null。
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
}
