import 'dart:io';

import 'package:fushi/src/pages/implementations/stat_trends.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 统计诊断日志导出正文（设置 › 诊断 › 导出统计诊断日志）：头信息 + 最近会话快照
/// + [StudyDiagLog] 持久化流水。会话快照给排查者一眼就能看到「哪一段的字/时爆
/// 了」，再拿它的起止时刻去流水里找那一段的入账 / 跳页事件。
///
/// [db] 只读 `loadStatFacts`（统计读取面唯一入口，不直读表）。
Future<String> buildStudyDiagExport(
  FushiDatabase db, {
  required String appVersion,
  required int readingIdleTimeoutMinutes,
  required int statDayResetHour,
  int sessionLimit = 40,
  DateTime? now,
}) async {
  final DateTime at = now ?? DateTime.now();
  final StringBuffer buf = StringBuffer()
    ..writeln('Fushi study diagnostics')
    ..writeln('exported: ${at.toIso8601String()} (tz ${at.timeZoneName})')
    ..writeln('app: $appVersion')
    ..writeln(
      'platform: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}',
    )
    ..writeln('reading idle timeout: $readingIdleTimeoutMinutes min')
    ..writeln('stat day reset hour: $statDayResetHour')
    ..writeln();

  try {
    final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
    final List<StudySession> sessions = facts.sessions;
    buf.writeln(
      '── recent sessions (${sessions.length} total, newest first) ──',
    );
    buf.writeln(
      'start → end | kind | duration ms | chars | pages | chars/h | '
      'device | segments | title',
    );
    for (final StudySession s in sessions.take(sessionLimit)) {
      buf.writeln(formatStudySessionDiagRow(s));
    }
  } catch (e) {
    buf.writeln('sessions unavailable: $e');
  }
  buf.writeln();
  buf.writeln('── trace ──');
  buf.write(await StudyDiagLog.instance.readPersisted());
  if (!buf.toString().endsWith('\n')) buf.writeln();
  return buf.toString();
}

/// 纯函数：会话快照一行。速度经 [computeCph]（最小样本 1 分钟，不足写 `-`），
/// 与统计页外显同一口径，导出里的数和页面上看到的能对上。
String formatStudySessionDiagRow(StudySession s) {
  final double? cph = computeCph(s.chars, s.durationMs);
  final String start = DateTime.fromMillisecondsSinceEpoch(
    s.startAt,
  ).toIso8601String();
  final String end = DateTime.fromMillisecondsSinceEpoch(
    s.endAt,
  ).toIso8601String();
  return '$start → $end | ${s.mediaKind} | ${s.durationMs} | ${s.chars} | '
      '${s.pages} | ${cph == null ? '-' : cph.round()} | ${s.deviceId} | '
      '${s.segmentUids.length} | ${s.title}';
}
