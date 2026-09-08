// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';

/// 根因守卫：样式变更实时下发（`_applyStylesLive` → `beginStyleReanchorInvocation`）
/// 依赖 `window.fushiReader.beginStyleReanchor` / `commitStyleReanchor` 存在。
///
/// 这两个方法曾**只**加进连续 shell（`_continuousShellScript`），分页 shell
/// （`_paginatedShellScript`，且是机器默认视图模式）整体缺席 → 分页模式下
/// `beginStyleReanchorInvocation` 恒走 `:-1` 兜底、CSS 从不换 textContent，导致
/// 改字号/边距/行距/主题等纯 CSS 设置不实时生效、必须退出书籍重开才应用（BUG-849）。
/// 同一漏洞随后在第三个 shell（视觉小说，TODO-909）上第三次复发：VN 有
/// `window.fushiReader` 但没这对方法（BUG-2261）——而本守卫当时两轮循环都在读分页
/// 脚本，连续 shell 其实从没被断言过，VN 更不在清单里。
///
/// 现在三个正式视图模式各读各的脚本；并且 `beginStyleReanchorInvocation` 的 `:-1`
/// 兜底自己换 CSS，任何 shell 再缺方法也只丢「保位」不丢「样式」。
void main() {
  final List<({String label, String Function() source})> shells =
      <({String label, String Function() source})>[
    (
      label: 'paginated',
      source: ReaderPaginationScripts.paginatedShellSource,
    ),
    (
      label: 'continuous',
      source: ReaderPaginationScripts.continuousShellSource,
    ),
    (
      label: 'visual novel',
      source: ReaderVisualNovelScripts.vnShellScript,
    ),
  ];

  for (final ({String label, String Function() source}) shell in shells) {
    test(
        '${shell.label} shell defines beginStyleReanchor + commitStyleReanchor',
        () {
      final String script = maskJsComments(shell.source());
      expect(
        script.contains('beginStyleReanchor = function') ||
            script.contains('beginStyleReanchor: function'),
        isTrue,
        reason: '${shell.label} shell 缺 beginStyleReanchor：'
            '该模式换样式只能走裸换 CSS 兜底、丢失翻页/翻屏保位。',
      );
      expect(
        script.contains('commitStyleReanchor = function') ||
            script.contains('commitStyleReanchor: function'),
        isTrue,
        reason: '${shell.label} shell 缺 commitStyleReanchor：'
            '样式重锚第二阶段无法提交。',
      );
    });
  }

  test('three shells really are three different scripts', () {
    final Set<String> distinct =
        shells.map((s) => s.source()).toSet();
    expect(distinct.length, shells.length,
        reason: '守卫曾两轮都读分页脚本——连续 shell 从未被真正断言');
  });

  test('beginStyleReanchorInvocation 目标方法在分页脚本里真实可解析', () {
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
    // 调用点用 typeof === 'function' 门控；脚本里必须存在同名函数定义，否则门控恒假。
    expect(
      ReaderPaginationScripts.beginStyleReanchorInvocation('"body{}"')
          .contains('window.fushiReader.beginStyleReanchor'),
      isTrue,
    );
    expect(paginated.contains('beginStyleReanchor: function(styleEl, css)'),
        isTrue);
  });

  test('BUG-2261：invocation 的无方法兜底自己换 CSS，而不是裸返 -1', () {
    final String invocation =
        ReaderPaginationScripts.beginStyleReanchorInvocation('"body{}"');
    // 有方法 → 交给 shell 原子「换 CSS + 采锚」；没方法 → 调用点就地换 CSS 再返 -1。
    final int callIdx =
        invocation.indexOf('window.fushiReader.beginStyleReanchor(el, css)');
    final int swapIdx = invocation.indexOf('el.textContent = css');
    final int minusOneIdx = invocation.lastIndexOf('return -1');
    expect(callIdx, isNonNegative);
    expect(swapIdx, greaterThan(callIdx),
        reason: '兜底换 CSS 必须在方法分支 return 之后、只在无方法时执行');
    expect(minusOneIdx, greaterThan(swapIdx),
        reason: '-1 只能在换完 CSS 之后返回；CSS 永不丢');
    expect(invocation, contains('paginationMetrics = null'),
        reason: '兜底换 CSS 后须失效分页 metrics，让余白/字号几何重新分栏');
  });
}
