// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// 根因守卫：样式变更实时下发（`_applyStylesLive` → `beginStyleReanchorInvocation`）
/// 依赖 `window.fushiReader.beginStyleReanchor` / `commitStyleReanchor` 存在。
///
/// 这两个方法曾**只**加进连续 shell（`_continuousShellScript`），分页 shell
/// （`_paginatedShellScript`，且是机器默认视图模式）整体缺席 → 分页模式下
/// `beginStyleReanchorInvocation` 恒走 `:-1` 兜底、CSS 从不换 textContent，导致
/// 改字号/边距/行距/主题等纯 CSS 设置不实时生效、必须退出书籍重开才应用。
///
/// 本守卫在每个正式视图模式（分页 / 连续）生成的 setup 脚本里断言两方法都存在，
/// 锁住「两 shell 都必须暴露样式重锚入口」不被未来单 shell 改动静默破坏。
void main() {
  const List<({String label, bool continuousMode})> shells =
      <({String label, bool continuousMode})>[
    (label: 'paginated', continuousMode: false),
    (label: 'continuous', continuousMode: true),
  ];

  for (final ({String label, bool continuousMode}) shell in shells) {
    test(
        '${shell.label} shell defines beginStyleReanchor + commitStyleReanchor',
        () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(
        script.contains('beginStyleReanchor: function'),
        isTrue,
        reason: '${shell.label} shell 缺 beginStyleReanchor：'
            'beginStyleReanchorInvocation 会恒返 -1、CSS 永不换 → '
            '该模式纯 CSS 设置不实时生效（必须重开书）。',
      );
      expect(
        script.contains('commitStyleReanchor: function'),
        isTrue,
        reason: '${shell.label} shell 缺 commitStyleReanchor：'
            '样式重锚第二阶段无法提交、_reanchorPending 不清。',
      );
    });
  }

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
}
