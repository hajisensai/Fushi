import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:path_provider/path_provider.dart';

/// 学习统计诊断日志（用户 2026-09-12：「要有个导出日志的方式用于排查阅读速度异常」）。
///
/// 统计域此前只在**落库失败**时留一行错误日志，成功路径完全不可观测：段何时开 /
/// 封、哪个 tick 被空闲门拒掉、每次翻页入账 / 撤回了多少字、有声书恢复时正文与音频
/// 各落在哪、播放后被拉到了哪一页——用户看到「这一段 3 万字/时」时没有任何线索。
/// 这里是那条线索：一行一事件，永远开着（每次翻页 / 封段几行，代价可忽略），追加进
/// 应用文档目录的 `study_diag_log.txt`（1 MB 滚动保尾），跨运行保留——异常往往是
/// 「昨天那一段」，导出时要能拿到。
///
/// 写入方：
///  * `StudyClock.trace`（`fushi_audio`）：起停表、开 / 封段、守卫拒窗、字数页数
///    入账 / 撤回 / 停表期间丢弃、落库；
///  * 阅读器（`reader_fushi_page` 及 part）：单元 arrive / leave、账本入账 / 撤回、
///    位置恢复、有声书恢复与跟随跳页；
///  * 其余域按需 `add()`。
///
/// 不进错误日志页、不计错误数——它是取证流水，不是报错。导出走
/// [buildStudyDiagExport]（`study_diag_export.dart`，加头信息 + 最近会话快照）。
class StudyDiagLog {
  StudyDiagLog._();

  static final StudyDiagLog instance = StudyDiagLog._();

  /// 内存环（未 [init] / 落盘失败时导出仍有本次运行的流水）。
  static const int maxEntries = 4000;

  /// 文件上限：超过就保尾并对齐到行首。
  static const int maxFileBytes = 1024 * 1024;

  static const String fileName = 'study_diag_log.txt';

  final List<String> _lines = <String>[];
  File? _file;
  Future<void> _chain = Future<void>.value();

  /// 本次运行内存流水（只读快照，最旧在前）。
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 在途落盘链（测试确定性 await）。
  Future<void> get pending => _chain;

  /// [directoryOverride] 仅供测试；生产走 [fushiTestDirectory] / 应用文档目录。
  Future<void> init({Directory? directoryOverride}) async {
    try {
      final Directory dir = directoryOverride ??
          fushiTestDirectory('app-documents') ??
          await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$fileName');
      await _trimFile();
    } catch (e) {
      debugPrint('[StudyDiagLog] init failed: $e');
    }
    add('log', 'session start');
  }

  /// 记一行：`yyyy-MM-dd HH:mm:ss.SSS [source] message`。多行消息压成一行（`⏎`），
  /// 流水一行一事件才能 grep。
  void add(String source, String message) {
    final String line = formatLine(DateTime.now(), source, message);
    _lines.add(line);
    if (_lines.length > maxEntries) _lines.removeAt(0);
    final File? file = _file;
    if (file == null) return;
    _chain = _chain.then((_) => _append(file, line)).catchError((Object e) {
      debugPrint('[StudyDiagLog] append failed: $e');
    });
  }

  /// 纯函数：一行的格式（测试与 [add] 共用）。
  static String formatLine(DateTime at, String source, String message) {
    final String ts = at.toIso8601String().replaceFirst('T', ' ');
    final String flat = message.replaceAll('\r', '').replaceAll('\n', '⏎');
    return '$ts [$source] $flat';
  }

  Future<void> _append(File file, String line) async {
    await file.writeAsString('$line\n', mode: FileMode.append);
    if (await file.length() > maxFileBytes) await _trimFile();
  }

  /// 超限保尾：截到 [maxFileBytes] 再丢掉第一段残行。
  Future<void> _trimFile() async {
    final File? file = _file;
    if (file == null || !await file.exists()) return;
    if (await file.length() <= maxFileBytes) return;
    final List<int> bytes = await file.readAsBytes();
    await file.writeAsString(trimTail(bytes));
  }

  /// 纯函数：保尾到 [maxFileBytes] 并对齐到行首（第一段残行丢弃）。
  static String trimTail(List<int> bytes, {int maxBytes = maxFileBytes}) {
    if (bytes.length <= maxBytes) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    final String content = utf8.decode(
      bytes.sublist(bytes.length - maxBytes),
      allowMalformed: true,
    );
    final int nl = content.indexOf('\n');
    if (nl < 0 || nl + 1 >= content.length) return content;
    return content.substring(nl + 1);
  }

  /// 等在途落盘写完（导出 / 退出前）。
  Future<void> flush() => _chain;

  /// 持久化全文（含此前运行）；没文件就退回内存流水。
  Future<String> readPersisted() async {
    await flush();
    final File? file = _file;
    try {
      if (file != null && await file.exists()) {
        return utf8.decode(await file.readAsBytes(), allowMalformed: true);
      }
    } catch (e) {
      debugPrint('[StudyDiagLog] read failed: $e');
    }
    return _lines.join('\n');
  }

  Future<void> clear() async {
    _lines.clear();
    await flush();
    try {
      await _file?.writeAsString('');
    } catch (e) {
      debugPrint('[StudyDiagLog] clear failed: $e');
    }
  }
}

/// 阅读器 / 时钟埋点的统一入口：`studyDiag('reader', '...')`。
void studyDiag(String source, String message) =>
    StudyDiagLog.instance.add(source, message);
