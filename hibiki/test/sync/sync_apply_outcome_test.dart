import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

/// BUG-014：同步对比对话框把「良性 skipped」误报成「同步错误：<书名>」。
/// 根因是分类只看 [SyncResult.skipped]，没看 [SyncBookResult.error]。
/// 这里钉死纯函数 [classifySyncApply] 的分类边界，谁把良性跳过重新归到
/// failed 就变红。
void main() {
  group('classifySyncApply', () {
    test('良性 skipped（error==null）→ noop，不报错', () {
      // 例如导出方向但本地无阅读位置且未开内容同步：syncBook 返回
      // skipped 且 error 为 null。这正是 BUG-014 被误报的那条路径。
      const result = SyncBookResult(
        direction: SyncResult.skipped,
        title: 'Pagination Test Book',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.noop);
    });

    test('skipped 但带 error → failed（真失败仍要报）', () {
      // syncBook 把后端/通用异常吞进 error 后以 skipped 返回，这才是真失败。
      const result = SyncBookResult(
        direction: SyncResult.skipped,
        title: 'Boom Book',
        error: 'network timeout',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.failed);
    });

    test('imported → applied', () {
      const result = SyncBookResult(
        direction: SyncResult.imported,
        title: 'Imported Book',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.applied);
    });

    test('exported → applied', () {
      const result = SyncBookResult(
        direction: SyncResult.exported,
        title: 'Exported Book',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.applied);
    });

    test('synced（两端一致，无操作）→ noop', () {
      const result = SyncBookResult(
        direction: SyncResult.synced,
        title: 'Already Synced Book',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.noop);
    });

    test('imported/exported 但带 error → 仍判 failed（error 优先）', () {
      // 防御：传输方向枚举不该与 error 共存，但若真出现，error 优先级最高。
      const result = SyncBookResult(
        direction: SyncResult.exported,
        title: 'Half Exported Book',
        error: 'partial failure',
      );
      expect(classifySyncApply(result), SyncApplyOutcome.failed);
    });
  });
}
