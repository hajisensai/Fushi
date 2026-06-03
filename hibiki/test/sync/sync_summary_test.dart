import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';

/// `summarizeSyncReport` 的边界测试。断言用语言无关信号（箭头 ↓↑、计数数字、
/// ` · ` 分隔符个数），不绑定具体语言措辞，避免 17 语言下的脆弱。
int _seps(String s) => ' · '.allMatches(s).length;

void main() {
  group('summarizeSyncReport', () {
    test('all-zero report → no category arrows (no changes)', () {
      final String s = summarizeSyncReport(SyncRunReport());
      expect(s, isNot(contains('↓')));
      expect(s, isNot(contains('↑')));
      // 仅 done 模板本身的一个 ` · ` 分隔符。
      expect(_seps(s), 1);
    });

    test('single category → one segment, no extra separator', () {
      final SyncRunReport r = SyncRunReport()..booksImported = 2;
      final String s = summarizeSyncReport(r);
      expect(s, contains('↓2'));
      expect(s, isNot(contains('↑')));
      expect(_seps(s), 1);
    });

    test('multiple categories are joined with " · "', () {
      final SyncRunReport r = SyncRunReport()
        ..booksImported = 2
        ..dictionariesExported = 3;
      final String s = summarizeSyncReport(r);
      expect(s, contains('↓2'));
      expect(s, contains('↑3'));
      expect(_seps(s), 2);
    });

    test('errors append a failure segment', () {
      final String ok = summarizeSyncReport(SyncRunReport()..booksImported = 2);
      final SyncRunReport withErrors = SyncRunReport()
        ..booksImported = 2
        ..errors.addAll(<String>['boom1', 'boom2']);
      final String s = summarizeSyncReport(withErrors);
      // 失败后缀使总串更长、且多一个 ` · ` 段。
      expect(s.length, greaterThan(ok.length));
      expect(_seps(s), _seps(ok) + 1);
      // 失败计数（2）出现在串中。
      expect(s, contains('2'));
    });
  });
}
