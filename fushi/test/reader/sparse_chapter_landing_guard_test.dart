// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// TODO-1349（BUG-671，BUG-661 续）回归守卫（生成产物扫描，CI 可跑）：往前翻
/// `restoreProgress(0.99)`（章尾语义）必须落到该章**最后部分**；尾图若迟到 load，
/// 由 `_sharedInitImages` 的 load 回调按登记的语义锚重锚到真实章末（连续走
/// `scrollToChapterEnd`，分页走 `scrollToProgressPaged`）。
void main() {
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
  final String paged = norm(ReaderPaginationScripts.paginatedShellSource());
  final String continuous = norm(
    ReaderPaginationScripts.continuousShellSource(),
  );

  group('BUG-671 sparse cover chapter backward-turn lands at chapter end', () {
    test(
      'continuous restoreProgress(>=0.99) registers reanchor + lands at end',
      () {
        expect(
          continuous.contains(
            'this.registerImageLateAnchor({progress: progress}); this.scrollToChapterEnd();',
          ),
          isTrue,
          reason: '连续 restoreProgress 章末分支须置重锚资格 + 落章末',
        );
      },
    );

    test('image load callback reanchors continuous via scrollToChapterEnd', () {
      // BUG-1140 第二轮：分派从 load 回调内联搬进共享的 reapplyImageLateAnchor，
      // 但「连续判别必须先于分页」这条不变——scrollToProgressPaged 两 shell 都有，
      // 用它判别会让连续误走分页分支不重锚。
      for (final String shell in <String>[paged, continuous]) {
        expect(
          shell.contains('r.reapplyImageLateAnchor()'),
          isTrue,
          reason: 'load 回调须触发语义重锚',
        );
        final int reapplyIdx = shell.indexOf(
          'reapplyImageLateAnchor: function',
        );
        expect(reapplyIdx, greaterThan(0));
        final int contIdx = shell.indexOf(
          'this._isContinuousShell()',
          reapplyIdx,
        );
        final int pagedIdx = shell.indexOf(
          'this.scrollToProgressPaged(rctx, p)',
          reapplyIdx,
        );
        expect(
          contIdx,
          greaterThan(0),
          reason: 'reapply 须有连续分支（_isContinuousShell 判别）',
        );
        expect(pagedIdx, greaterThan(0), reason: 'reapply 须保留分页分支');
        expect(
          contIdx < pagedIdx,
          isTrue,
          reason: '连续判别须在分页 scrollToProgressPaged 之前',
        );
        expect(
          shell.contains("typeof this.scrollToChapterEnd === 'function'"),
          isTrue,
          reason: '判别判据必须是连续独有的 scrollToChapterEnd',
        );
        expect(
          shell.contains('if (p >= 0.99) this.scrollToChapterEnd();'),
          isTrue,
          reason: '连续重锚分支须在 >=0.99 时调 scrollToChapterEnd',
        );
      }
    });

    test('continuous paginate clears the image late anchor', () {
      final int pIdx = continuous.indexOf('paginate: function(direction) {');
      expect(pIdx, greaterThan(0));
      final String window = continuous.substring(
        pIdx,
        (pIdx + 200).clamp(0, continuous.length),
      );
      expect(
        window.contains('this.clearImageLateAnchor();'),
        isTrue,
        reason: '连续 paginate 须清重锚资格（避免尾图 late-load 拽回用户已翻走的位置）',
      );
    });
  });
}
