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

    // 出站两项此前根本不进摘要：一轮把视频/书都推上去的同步照样显示「无新增」，
    // 用户据此认定「有些没上传」。这两条锁住它们必须可见。
    test('uploaded videos show up in the summary', () {
      final String s = summarizeSyncReport(SyncRunReport()..videosExported = 3);
      expect(s, contains('↑3'));
      expect(_seps(s), 1, reason: '单类别只占一段');
    });

    test('pushed books show up in the summary', () {
      final String s = summarizeSyncReport(SyncRunReport()..booksPushed = 4);
      expect(s, contains('↑4'));
    });

    test('a purely outbound run no longer reads as "no changes"', () {
      final String noChanges = summarizeSyncReport(SyncRunReport());
      final String outbound = summarizeSyncReport(SyncRunReport()
        ..booksPushed = 2
        ..videosExported = 1);
      expect(outbound, isNot(equals(noChanges)));
      expect(outbound, contains('↑2'));
      expect(outbound, contains('↑1'));
      expect(_seps(outbound), 2, reason: '两个出站类别各占一段');
    });
  });

  group('SyncRunReport.needsLocalLibraryRefresh', () {
    test('is true when sync imported visible local library content', () {
      expect(
        (SyncRunReport()..booksImported = 1).needsLocalLibraryRefresh,
        isTrue,
      );
      expect(
        (SyncRunReport()..dictionariesImported = 1).needsLocalLibraryRefresh,
        isTrue,
      );
      expect(
        (SyncRunReport()..audiobooksImported = 1).needsLocalLibraryRefresh,
        isTrue,
      );
      expect(
        (SyncRunReport()..localAudioImported = 1).needsLocalLibraryRefresh,
        isTrue,
      );
      expect(
        (SyncRunReport()..videosImported = 1).needsLocalLibraryRefresh,
        isTrue,
      );
    });

    test('is false when sync only exported or changed remote data', () {
      expect(SyncRunReport().needsLocalLibraryRefresh, isFalse);
      expect(
        (SyncRunReport()
              ..dictionariesExported = 1
              ..audiobooksExported = 1
              ..localAudioExported = 1
              // 纯出站计数不得触发本地库刷新（否则每轮同步都白刷一遍书架）。
              ..booksPushed = 5
              ..videosExported = 5)
            .needsLocalLibraryRefresh,
        isFalse,
      );
    });
  });

  test('manual video download counts as a real asset transfer', () {
    final SyncRunReport report = SyncRunReport()..videosImported = 1;
    expect(report.assetsTransferred, 1);
  });
}
