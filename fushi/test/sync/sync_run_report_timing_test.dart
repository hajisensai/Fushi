import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';

/// XVEF3huDTF：慢同步的反馈只附带错误日志，看不出时间花在哪一步。SyncRunReport
/// 记分阶段耗时与最慢的几本书，[SyncRunReport.describeTiming] 写进诊断日志。
void main() {
  test('只保留最慢的 5 本书，按耗时降序', () {
    final SyncRunReport report = SyncRunReport();
    for (int i = 1; i <= 8; i++) {
      report.noteBookDuration('book$i', i * 1000);
    }
    expect(
      report.slowestBooks.map((({String title, int ms}) b) => b.title),
      <String>['book8', 'book7', 'book6', 'book5', 'book4'],
    );
  });

  test('摘要按执行顺序列出各阶段，并带最慢的书', () {
    final SyncRunReport report = SyncRunReport()
      ..phaseMs['resolve+listing'] = 120
      ..phaseMs['readingData'] = 480000
      ..noteBookDuration('かがみの孤城', 45000);
    expect(
      report.describeTiming(totalMs: 540000),
      'total=540000ms; resolve+listing=120ms, readingData=480000ms; '
      'slowest books: かがみの孤城=45000ms',
    );
  });
}
