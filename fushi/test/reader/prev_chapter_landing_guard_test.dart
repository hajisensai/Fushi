// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// TODO-1349 回归守卫（源码扫描 + 生成产物扫描，CI 可跑）：往前翻到上一章必须落到
/// 该章的**最后部分**（章尾），而非章首（封面/第一张图）。
///
/// 用户报「安達としまむら2 从目录往前翻会去到封面，而不是封面章节的最后部分」。往前翻
/// 走 `_handlePageTurnLimit` backward → `_navigateToChapter(prev, progress: 0.99)` →
/// shell `restoreProgress(0.99)`（章尾语义）。两处根因让「图片章章末落点塌缩到章首」：
///   1. 连续模式 `restoreProgress(0.99)` 走 `scrollToProgressContinuous` → `findNodeAtProgress`
///      只走文本节点，纯图片章无文本 → 返 null → 不滚动 → 停章首。修复 = 新增
///      `scrollToChapterEnd`（最后可见内容元素 `scrollIntoView(block:'end')`，含尾部插图），
///      `restoreProgress(progress>=0.99)` 路由到它（与分页 `contentLastPageScroll` 对称）。
///   2. 插图被挂 `loading="lazy"` → 离屏图永不 load → 0 尺寸、分页 maxScroll 塌缩。
///      已从根上去掉正文图片懒加载（见 `ReaderResourceSanitizer.stripImageLoadingAttributes`）。
///
/// 行为断言在 `tool/reader_pitch_headless/prev_chapter_landing_probe.mjs`（headless Chrome
/// 注入**真 shell**，对纯图片/尾部插图/图文混排三几何 × 分页/连续两 shell 断言
/// restoreProgress(0.99) 落到章末，并覆盖懒加载延迟到位场景；CI 跑不到真 WebView 故本机
/// 跑）。本守卫（CI 可跑）锁住修复接线不被静默回退。
void main() {
  final File paginationFile = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  );
  String src() => paginationFile.readAsStringSync();
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  group('TODO-1349 backward-turn lands at chapter end (not cover)', () {
    test('continuous scrollToChapterEnd exists and aligns to content end', () {
      final String s = src();
      expect(
        s.contains('scrollToChapterEnd: function'),
        isTrue,
        reason: '连续模式必须有章末落点 helper scrollToChapterEnd',
      );
      // 必须把内容对齐到轴末端（block:'end'），而非只走文本节点。
      final int idx = s.indexOf('scrollToChapterEnd: function');
      final String body = s.substring(idx, idx + 700);
      expect(
        body.contains("block: 'end'") || body.contains('block:"end"'),
        isTrue,
        reason: 'scrollToChapterEnd 必须 scrollIntoView(block:end) 落到内容末端（含尾部插图）',
      );
      expect(body.contains('scrollIntoView'), isTrue);
    });

    test(
      'continuous restoreProgress routes progress>=0.99 to scrollToChapterEnd',
      () {
        final String continuous =
            ReaderPaginationScripts.continuousShellSource();
        final String n = norm(continuous);
        // 连续 restoreProgress 里 progress>=0.99 分支必须走 scrollToChapterEnd。
        expect(
          n.contains('progress >= 0.99') &&
              n.contains('this.scrollToChapterEnd()'),
          isTrue,
          reason:
              '连续 restoreProgress 必须把 progress>=0.99（章尾）路由到 scrollToChapterEnd',
        );
      },
    );
  });
}
