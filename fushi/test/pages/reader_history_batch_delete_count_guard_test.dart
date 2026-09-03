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
      // 同理不写死 `removed > 0`：删除结果的类型会随需求扩展（PR #1024 起
      // `repo.delete` 返回 SrtBookDeleteResult，本地文件删除报告要随它一起回传，
      // 门控表达式因此是 `removed.deleted > 0`）。BUG-439 的不变量是**门控本身**
      // ——计数器只能由这次删除的返回值决定，不是它写成哪个字面形状。
      expect(
        RegExp(r'if \(removed(\.\w+)? > 0\) deleted\+\+').hasMatch(body),
        isTrue,
        reason: 'only real srt_books deletions may be counted (BUG-439).',
      );
      // 这一条正向匹配就足以钉住 BUG-439：它的原始形态是**删掉门控**、`repo.delete`
      // 之后无条件 `deleted++`；门控一没，上面的正则就不匹配 → 红。（变异实测过。）
    });
  });
}
