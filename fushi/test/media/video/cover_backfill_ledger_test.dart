import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_backfill_ledger.dart';

/// BUG-1564 ②：封面回填失败记账。失败一次后，同一文件（mtime/size 不变）不再进入
/// 抽帧重试；文件被替换（身份变化）自动放行；显式清账（下拉刷新入口）放行。
void main() {
  group('CoverBackfillLedger', () {
    late Directory tmp;
    late CoverBackfillLedger ledger;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_cover_ledger_');
      ledger = CoverBackfillLedger.forTesting();
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    File seedFile(String name, String content) {
      final File f = File('${tmp.path}${Platform.pathSeparator}$name');
      f.writeAsStringSync(content);
      return f;
    }

    test('无记录 -> 允许尝试', () {
      final File f = seedFile('a.mkv', 'x');
      expect(ledger.shouldAttempt(f.path), isTrue);
    });

    test('失败记账后同一文件不再重试（每轮刷新不重烧 ffmpeg）', () {
      final File f = seedFile('a.mkv', 'x');
      ledger.recordFailure(f.path, reason: 'extract-failed');
      // 反复多轮（模拟页面反复刷新触发回填）恒被拦。
      expect(ledger.shouldAttempt(f.path), isFalse);
      expect(ledger.shouldAttempt(f.path), isFalse);
      expect(ledger.failureReason(f.path), 'extract-failed');
    });

    test('文件内容变化（size 变）-> 放行重试并丢弃旧账', () {
      final File f = seedFile('a.mkv', 'x');
      ledger.recordFailure(f.path, reason: 'extract-failed');
      expect(ledger.shouldAttempt(f.path), isFalse);
      f.writeAsStringSync('replaced with longer content');
      expect(ledger.shouldAttempt(f.path), isTrue);
      // 旧账已作废：不再残留失败原因。
      expect(ledger.failureReason(f.path), isNull);
    });

    test('仅 mtime 变化（size 不变）-> 放行重试', () {
      final File f = seedFile('a.mkv', 'x');
      ledger.recordFailure(f.path, reason: 'extract-failed');
      f.setLastModifiedSync(
        f.lastModifiedSync().add(const Duration(seconds: 5)),
      );
      expect(ledger.shouldAttempt(f.path), isTrue);
    });

    test('文件缺失：记账后持续拦截；文件出现后放行', () {
      final String missing = '${tmp.path}${Platform.pathSeparator}gone.mkv';
      ledger.recordFailure(missing, reason: 'file-missing');
      expect(ledger.shouldAttempt(missing), isFalse);
      // 文件出现（身份从 (null,null) 变为真实 stat）→ 放行。
      File(missing).writeAsStringSync('now exists');
      expect(ledger.shouldAttempt(missing), isTrue);
    });

    test('clear 单条 / clearAll 全清 -> 放行', () {
      final File a = seedFile('a.mkv', 'x');
      final File b = seedFile('b.mkv', 'y');
      ledger.recordFailure(a.path, reason: 'extract-failed');
      ledger.recordFailure(b.path, reason: 'extract-failed');
      expect(ledger.debugFailureCount, 2);

      ledger.clear(a.path);
      expect(ledger.shouldAttempt(a.path), isTrue);
      expect(ledger.shouldAttempt(b.path), isFalse);

      ledger.clearAll();
      expect(ledger.debugFailureCount, 0);
      expect(ledger.shouldAttempt(b.path), isTrue);
    });
  });
}
