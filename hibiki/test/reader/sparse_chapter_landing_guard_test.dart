import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-1349（BUG-666，BUG-661 续）回归守卫（源码/生成产物扫描，CI 可跑）：
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
  final String paged =
      norm(ReaderPaginationScripts.shellScript(initialProgress: 0.99));
  final String continuous = norm(ReaderPaginationScripts.shellScript(
      continuousMode: true, initialProgress: 0.99));

  group('BUG-666 sparse cover chapter backward-turn lands at chapter end', () {
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
      expect(
          continuous.contains(
              'this.__imgReanchorProgress = progress; this.forceLoadPendingImages(); this.scrollToChapterEnd();'),
          isTrue,
          reason: '连续 restoreProgress 章末分支须置重锚资格 + 强制 load + 落章末');
    });

    test('image load callback reanchors continuous via scrollToChapterEnd', () {
      // 判别必须先查 scrollToChapterEnd（连续独有），再回退 scrollToProgressPaged（两 shell 共有）。
      for (final String shell in <String>[paged, continuous]) {
        final int endIdx =
            shell.indexOf("typeof r.scrollToChapterEnd === 'function'");
        final int pagedIdx =
            shell.indexOf("typeof r.scrollToProgressPaged === 'function'");
        expect(endIdx, greaterThan(0),
            reason: 'load 回调须有连续重锚分支（scrollToChapterEnd 判别）');
        expect(pagedIdx, greaterThan(0),
            reason: 'load 回调须保留分页重锚分支（scrollToProgressPaged）');
        expect(endIdx < pagedIdx, isTrue,
            reason:
                'scrollToChapterEnd 判别须在 scrollToProgressPaged 之前（否则连续误走分页分支不重锚）');
      }
      expect(
          continuous.contains(
              'if (r.__imgReanchorProgress >= 0.99) r.scrollToChapterEnd();'),
          isTrue,
          reason: '连续重锚分支须在 >=0.99 时调 scrollToChapterEnd');
    });

    test('continuous paginate clears __imgReanchorProgress', () {
      final int pIdx = continuous.indexOf('paginate: function(direction) {');
      expect(pIdx, greaterThan(0));
      final String window =
          continuous.substring(pIdx, (pIdx + 200).clamp(0, continuous.length));
      expect(window.contains('this.__imgReanchorProgress = null;'), isTrue,
          reason: '连续 paginate 须清重锚资格（避免尾图 late-load 拽回用户已翻走的位置）');
    });

    test(
        'normal text chapter still lazy-loads images (no TODO-1074 regression)',
        () {
      for (final String shell in <String>[paged, continuous]) {
        expect(shell.contains("setAttribute('loading', 'lazy')"), isTrue,
            reason: '普通图仍须 lazy 分支在场（不回退 TODO-1074）');
        expect(
            shell.contains('ttuRegex.test(document.body.textContent'), isTrue,
            reason: '纯图片章判定须基于正文可匹配文本（有文本=非纯图片=仍 lazy）');
      }
    });
  });
}
