// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// TODO-1349（BUG-671，BUG-661 续）回归守卫（源码/生成产物扫描，CI 可跑）：
/// 「文字少+图片」封面章（含少量文字 → 非纯图片章 → 尾部整页插图仍 loading="lazy"）往前翻
/// `restoreProgress(0.99)`（章尾语义）必须落到该章**最后部分**（章末），而非章首（最开头）。
///
/// 真机 WebView 离屏懒图不发请求 → 0 尺寸 → 被 buildPaginationMetrics（分页 maxScroll 塌缩）/
/// scrollToChapterEnd 可见性判据（连续停章首）排除 → 落章首。修复三处：
///   1. `forceLoadPendingImages`：章末恢复时把仍 lazy 的图强制 eager 触发 load，打破「尾图离屏
///      永不 load → 落点塌缩 → 尾图永不进视口」鸡生蛋。分页/连续 restoreProgress(>=0.99) 均调。
///   2. `_sharedInitImages` 的 img `load` 回调补连续重锚分支（`scrollToChapterEnd`）；判别连续
///      vs 分页用连续独有的 `scrollToChapterEnd`（`scrollToProgressPaged` 在 _sharedJs 两 shell
///      都有，不能作判别，否则连续误走分页分支不重锚）。
///   3. 连续 restoreProgress(>=0.99) 置 `__imgReanchorProgress=progress`；连续 paginate 清它。
///
/// 行为断言在 `tool/reader_pitch_headless/sparse_chapter_landing_probe.mjs`（headless Chrome 真
/// shell + 扣响应忠实复现 0 尺寸态，本机跑）。本守卫锁修复接线不被静默回退（不回退 TODO-1074
/// 懒加载 / BUG-661 纯图片章 eager）。
void main() {
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
  final String paged = norm(ReaderPaginationScripts.paginatedShellSource());
  final String continuous =
      norm(ReaderPaginationScripts.continuousShellSource());

  group('BUG-671 sparse cover chapter backward-turn lands at chapter end', () {
    test('forceLoadPendingImages exists and flips lazy -> eager (both shells)',
        () {
      for (final String shell in <String>[paged, continuous]) {
        expect(shell.contains('forceLoadPendingImages: function'), isTrue,
            reason: '两 shell 都须有 forceLoadPendingImages（章末恢复打破懒图鸡生蛋）');
        expect(
            shell.contains('querySelectorAll(\'img[loading="lazy"]\')'), isTrue,
            reason: 'forceLoadPendingImages 须选中仍 lazy 的图');
        expect(shell.contains("setAttribute('loading', 'eager')"), isTrue,
            reason: 'forceLoadPendingImages 须把 lazy 图改成 eager 触发 load');
      }
    });

    test('paginated restoreProgress(>=0.99) calls forceLoadPendingImages', () {
      expect(
          paged
              .contains('if (progress >= 0.99) this.forceLoadPendingImages();'),
          isTrue,
          reason: '分页 restoreProgress 须在章末(>=0.99)强制 load 尾图');
    });

    test('continuous restoreProgress(>=0.99) registers reanchor + force-loads',
        () {
      // BUG-1140 第二轮：重锚资格的登记收敛到 registerImageLateAnchor（三种语义锚统一），
      // 章末分支的语义不变——登记 + 强制 load + 落章末，三件事仍在同一条链上。
      expect(
          continuous.contains(
              'this.registerImageLateAnchor({progress: progress}); this.forceLoadPendingImages(); this.scrollToChapterEnd();'),
          isTrue,
          reason: '连续 restoreProgress 章末分支须置重锚资格 + 强制 load + 落章末');
    });

    test('image load callback reanchors continuous via scrollToChapterEnd', () {
      // BUG-1140 第二轮：分派从 load 回调内联搬进共享的 reapplyImageLateAnchor，
      // 但「连续判别必须先于分页」这条不变——scrollToProgressPaged 两 shell 都有，
      // 用它判别会让连续误走分页分支不重锚。
      for (final String shell in <String>[paged, continuous]) {
        expect(shell.contains('r.reapplyImageLateAnchor()'), isTrue,
            reason: 'load 回调须触发语义重锚');
        final int reapplyIdx =
            shell.indexOf('reapplyImageLateAnchor: function');
        expect(reapplyIdx, greaterThan(0));
        final int contIdx =
            shell.indexOf('this._isContinuousShell()', reapplyIdx);
        final int pagedIdx =
            shell.indexOf('this.scrollToProgressPaged(rctx, p)', reapplyIdx);
        expect(contIdx, greaterThan(0),
            reason: 'reapply 须有连续分支（_isContinuousShell 判别）');
        expect(pagedIdx, greaterThan(0), reason: 'reapply 须保留分页分支');
        expect(contIdx < pagedIdx, isTrue,
            reason: '连续判别须在分页 scrollToProgressPaged 之前');
        expect(shell.contains("typeof this.scrollToChapterEnd === 'function'"),
            isTrue,
            reason: '判别判据必须是连续独有的 scrollToChapterEnd');
        expect(
            shell.contains('if (p >= 0.99) this.scrollToChapterEnd();'), isTrue,
            reason: '连续重锚分支须在 >=0.99 时调 scrollToChapterEnd');
      }
    });

    test('continuous paginate clears the image late anchor', () {
      final int pIdx = continuous.indexOf('paginate: function(direction) {');
      expect(pIdx, greaterThan(0));
      final String window =
          continuous.substring(pIdx, (pIdx + 200).clamp(0, continuous.length));
      expect(window.contains('this.clearImageLateAnchor();'), isTrue,
          reason: '连续 paginate 须清重锚资格（避免尾图 late-load 拽回用户已翻走的位置）');
    });

    test(
        'normal text chapter still lazy-loads images (no TODO-1074 regression)',
        () {
      for (final String shell in <String>[paged, continuous]) {
        expect(shell.contains("setAttribute('loading', 'lazy')"), isTrue,
            reason: '普通图仍须 lazy 分支在场（不回退 TODO-1074）');
        expect(shell.contains('readerRegex.test(document.body.textContent'),
            isTrue,
            reason: '纯图片章判定须基于正文可匹配文本（有文本=非纯图片=仍 lazy）');
      }
    });
  });
}
