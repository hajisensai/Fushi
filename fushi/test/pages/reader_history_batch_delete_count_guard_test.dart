import 'package:flutter_test/flutter_test.dart';

import 'reader_history_source_corpus.dart';

/// BUG-439 source guard: the shelf batch-delete must count only books whose
/// rows were actually removed, never optimistically `deleted++` and then claim
/// "已删除 N 本". Previously the SRT branch incremented unconditionally after
/// `repo.delete(uid)` regardless of whether any row was deleted, so deleting an
/// orphan/absent entry still inflated the toast count.
void main() {
  group('reader history batch delete honesty (BUG-439)', () {
    test('SRT branch only counts genuine deletions, not optimistic success',
        () {
      final String source = readReaderHistorySource();

      final int start = source.indexOf('Future<void> _batchDeleteConfirm(');
      expect(start, isNonNegative,
          reason: '_batchDeleteConfirm must exist in the shelf history page');
      final int end = source.indexOf('Future<void>', start + 1);
      final String body =
          end > start ? source.substring(start, end) : source.substring(start);

      // The repo.delete result must be captured and gate the counter.
      // 前缀匹配（`(uid` 而非 `(uid)`）：TODO-2470 起这次调用要多带一个具名参数
      // `propagateDeletion:`（纯字幕书的删除范围），写死右括号会把一次合法的签名
      // 扩展误报成「SRT 分支不再经 repo 删除」。BUG-439 真正的不变量是下面那条
      // ——删除结果必须被捕获并门控计数器——它一字未改。
      expect(
        body.contains('await repo.delete(uid'),
        isTrue,
        reason: 'the SRT branch still deletes via the repo',
      );
      expect(
        body.contains('if (removed > 0) deleted++'),
        isTrue,
        reason: 'only real srt_books deletions may be counted (BUG-439).',
      );
    });
  });
}
