// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

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
        (label: 'visual novel', source: ReaderVisualNovelScripts.vnShellScript),
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
          reason:
              '${shell.label} shell 缺 beginStyleReanchor：'
              '该模式换样式只能走裸换 CSS 兜底、丢失翻页/翻屏保位。',
        );
        expect(
          script.contains('commitStyleReanchor = function') ||
              script.contains('commitStyleReanchor: function'),
          isTrue,
          reason:
              '${shell.label} shell 缺 commitStyleReanchor：'
              '样式重锚第二阶段无法提交。',
        );
      },
    );
  }

  test('three shells really are three different scripts', () {
    final Set<String> distinct = shells
        .map((({String label, String Function() source}) s) => s.source())
        .toSet();
    expect(
      distinct.length,
      shells.length,
      reason: '守卫曾两轮都读分页脚本——连续 shell 从未被真正断言',
    );
  });

  test('beginStyleReanchorInvocation 目标方法在分页脚本里真实可解析', () {
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
    // 调用点用 typeof === 'function' 门控；脚本里必须存在同名函数定义，否则门控恒假。
    expect(
      ReaderPaginationScripts.beginStyleReanchorInvocation(
        '"body{}"',
      ).contains('window.fushiReader.beginStyleReanchor'),
      isTrue,
    );
    expect(
      paginated.contains('beginStyleReanchor: function(styleEl, css)'),
      isTrue,
    );
  });

  test('BUG-2261：invocation 的无方法兜底自己换 CSS，而不是裸返 -1', () {
    final String invocation =
        ReaderPaginationScripts.beginStyleReanchorInvocation('"body{}"');
    // 有方法 → 交给 shell 原子「换 CSS + 采锚」；没方法 → 调用点就地换 CSS 再返 -1。
    final int callIdx = invocation.indexOf(
      'window.fushiReader.beginStyleReanchor(el, css)',
    );
    final int swapIdx = invocation.indexOf('el.textContent = css');
    final int minusOneIdx = invocation.lastIndexOf('return -1');
    expect(callIdx, isNonNegative);
    expect(
      swapIdx,
      greaterThan(callIdx),
      reason: '兜底换 CSS 必须在方法分支 return 之后、只在无方法时执行',
    );
    expect(
      minusOneIdx,
      greaterThan(swapIdx),
      reason: '-1 只能在换完 CSS 之后返回；CSS 永不丢',
    );
    expect(
      invocation,
      contains('paginationMetrics = null'),
      reason: '兜底换 CSS 后须失效分页 metrics，让余白/字号几何重新分栏',
    );
  });

  // ── 方法 × shell 总表 ────────────────────────────────────────────────────
  //
  // 三种 shell 之间没有声明的接口：共享段与 Dart 调用串靠
  // `typeof x === 'function'` 判断「这是哪个 shell / 这个 shell 有没有实现」。新加一个跨
  // shell 方法时漏掉一个 shell 不报错，只会静默退化——BUG-849（分页缺席）、VN 缺席、
  // BUG-2261 是同一个漏洞的三次复发，而此前的守卫都是逐方法、事后补的。
  //
  // 这张表就是那份接口声明。两栏：
  //   · [_requiredInAllShells]：三种 shell 都必须定义。Dart 无条件调用或三种模式都依赖的
  //     方法放这里；缺一个即红。
  //   · [_shellSpecific]：只允许在列出的 shell 里出现，并写明另外的 shell 为什么不需要。
  //     **缺席也是断言**：共享段正是拿「方法在不在」识别 shell（`scrollToChapterEnd`
  //     = 连续、`_charsBeforeEdge` = 连续、`warmPaginationMetrics` = 分页），往另一个
  //     shell 加同名方法会让共享段走错分支，所以多出来同样要红、要回来改表并写理由。
  // 另有一条闭包检查：`lib/src` 里凡是用 `typeof` 探测过的 shell 方法（`window.fushiReader.<名>`
  // 以及共享段 / 桥接脚本里的 `this` / `r` / `reader` / `self` 别名写法）都必须登记在表里
  // ——新加一个靠探测调用的方法而不声明它属于哪些 shell，就红。
  group('方法 × shell 总表', () {
    final Map<_Shell, String> scripts = <_Shell, String>{
      _Shell.paginated: maskJsComments(
        ReaderPaginationScripts.paginatedShellSource(),
      ),
      _Shell.continuous: maskJsComments(
        ReaderPaginationScripts.continuousShellSource(),
      ),
      _Shell.visualNovel: maskJsComments(
        ReaderVisualNovelScripts.vnShellScript(),
      ),
    };

    for (final String method in _requiredInAllShells) {
      test('$method：三种 shell 都必须定义', () {
        for (final _Shell shell in _Shell.values) {
          expect(
            _definesMethod(scripts[shell]!, method),
            isTrue,
            reason:
                '${shell.label} shell 缺 $method。它在「三种都必须有」一栏：'
                '漏掉的那个模式不会报错，只会静默退化。确实不适用就把它挪到 '
                '_shellSpecific 并写明原因。',
          );
        }
      });
    }

    _shellSpecific.forEach((String method, _ShellSpecific spec) {
      final String allowed = spec.shells.map((_Shell s) => s.label).join(' / ');
      test('$method：只在 $allowed', () {
        expect(spec.reason.trim(), isNotEmpty, reason: '$method 必须写明缺席原因');
        expect(
          spec.shells.length,
          lessThan(_Shell.values.length),
          reason: '$method 三种 shell 都有就该放进 _requiredInAllShells',
        );
        for (final _Shell shell in _Shell.values) {
          final bool expected = spec.shells.contains(shell);
          expect(
            _definesMethod(scripts[shell]!, method),
            expected,
            reason: expected
                ? '${shell.label} shell 缺 $method（表里登记它应当有）。'
                : '${shell.label} shell 多了 $method，但表里登记它不属于这个 shell'
                      '（${spec.reason}）。共享段 / Dart 调用串拿方法是否存在来识别 '
                      'shell，多出来会走错分支；确实要加就改表并更新原因。',
          );
        }
      });
    });

    test('两栏不重叠', () {
      expect(
        _requiredInAllShells.toSet().intersection(_shellSpecific.keys.toSet()),
        isEmpty,
      );
      expect(
        _requiredInAllShells.toSet().length,
        _requiredInAllShells.length,
        reason: '_requiredInAllShells 有重复项',
      );
    });

    test('lib/src 里用 typeof 探测的 shell 方法都登记在表里', () {
      // Dart 把 JS 拼在相邻字符串字面量里，`typeof window.fushiReader.x` 与
      // `=== "function"` 可能分在两行两个字面量中，所以只锚 typeof 这一半。
      //
      // 探测有两种写法，口径不同：
      //   · `typeof window.fushiReader.<名>`：接收者确定是阅读器对象，探测到的名字一律要登记。
      //   · `typeof (this|r|reader|self).<名>`：共享段 / audiobook_bridge / webview.part 里的
      //     别名写法。接收者不一定是阅读器（`r` 也可能是一个 Range），同一写法还用来读状态
      //     字段（`typeof this.__imgReanchorProgress === 'number'`），所以只认「至少一种
      //     shell 把这个名字定义成了方法」的那些——状态字段与别的对象的属性不会被定义成
      //     shell 方法，自然排除；而一旦登记进表，「该有的 shell 缺席 / 不该有的 shell 多出」
      //     就由上面两组逐格断言接管。
      final RegExp qualifiedProbe = RegExp(
        r'typeof window\.fushiReader\.([A-Za-z_]\w*)',
      );
      //   · `this.<名> && this.<名>(`：不带 typeof 的同类探测（共享段的 revealRange）。
      final RegExp aliasProbe = RegExp(
        r'typeof (?:this|r|reader|self)\.([A-Za-z_]\w*)'
        r'|(?:this|r|reader|self)\.([A-Za-z_]\w*) && (?:this|r|reader|self)\.\(',
      );
      final Set<String> declared = <String>{
        ..._requiredInAllShells,
        ..._shellSpecific.keys,
      };
      final Map<String, String> undeclared = <String, String>{};
      int qualifiedProbes = 0;
      int aliasMethodProbes = 0;
      for (final FileSystemEntity entity in Directory(
        'lib/src',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String text = entity.readAsStringSync();
        final String path = entity.path.replaceAll(r'\', '/');
        for (final RegExpMatch m in qualifiedProbe.allMatches(text)) {
          qualifiedProbes++;
          final String name = m.group(1)!;
          if (!declared.contains(name)) {
            undeclared.putIfAbsent(name, () => path);
          }
        }
        for (final RegExpMatch m in aliasProbe.allMatches(text)) {
          final String name = (m.group(1) ?? m.group(2))!;
          final bool isShellMethod = scripts.values.any(
            (String script) => _definesMethod(script, name),
          );
          if (!isShellMethod) continue;
          aliasMethodProbes++;
          if (!declared.contains(name)) {
            undeclared.putIfAbsent(name, () => path);
          }
        }
      }
      expect(
        qualifiedProbes,
        greaterThan(10),
        reason: '探测扫描没扫到东西：正则或目录失效，守卫等于零断言',
      );
      expect(
        aliasMethodProbes,
        greaterThan(10),
        reason: '别名写法的探测扫描没扫到东西：正则或目录失效，守卫等于零断言',
      );
      expect(
        undeclared,
        isEmpty,
        reason:
            '这些方法靠 typeof 探测调用，却没在「方法 × shell 总表」里声明属于哪些 '
            'shell：$undeclared。\n'
            '三种都该有 → _requiredInAllShells；只有部分 shell 有 → _shellSpecific 并写原因。',
      );
    });

    test('_definesMethod 认得三种定义写法，且不把调用当定义', () {
      expect(_definesMethod('  foo: function(a) {', 'foo'), isTrue);
      expect(_definesMethod('  foo: async function() {', 'foo'), isTrue);
      expect(_definesMethod('vn.foo = function() {', 'foo'), isTrue);
      expect(
        _definesMethod('window.fushiReader.foo = async function(x) {', 'foo'),
        isTrue,
      );
      expect(_definesMethod('  foo(a, b) {\n', 'foo'), isTrue);
      expect(_definesMethod('  async foo() {\n', 'foo'), isTrue);
      expect(_definesMethod('this.foo(a);', 'foo'), isFalse);
      expect(
        _definesMethod("if (typeof r.foo === 'function') r.foo();", 'foo'),
        isFalse,
      );
      expect(_definesMethod('  fooBar: function() {', 'foo'), isFalse);
      expect(_definesMethod('  _foo: function() {', 'foo'), isFalse);
    });
  });
}

enum _Shell {
  paginated('paginated'),
  continuous('continuous'),
  visualNovel('visual novel');

  const _Shell(this.label);
  final String label;
}

class _ShellSpecific {
  const _ShellSpecific(this.shells, this.reason);

  /// 允许（且必须）定义该方法的 shell。
  final Set<_Shell> shells;

  /// 其余 shell 为什么不需要它。
  final String reason;
}

/// 三种 shell 都必须定义的方法。
const List<String> _requiredInAllShells = <String>[
  // 生命周期 / 恢复落点（Dart 在三种模式下都无条件调用）。
  'initialize',
  'restoreProgress',
  'restoreToCharOffset',
  'jumpToFragment',
  'notifyRestoreComplete',
  // 翻页 / 进度采样（fushiProgressDetails 无参调用）。
  'paginate',
  'calculateProgress',
  'isAtEnd',
  'getFirstVisibleCharOffset',
  'getLastVisibleCharOffset',
  // 几何与样式（缺席 = 设置改了不生效或丢保位，BUG-849 / BUG-2261）。
  'updatePageSize',
  'setChromeInsets',
  'beginStyleReanchor',
  'commitStyleReanchor',
  // 文本口径与遍历。
  'isVertical',
  'createWalker',
  'countChars',
  'isMatchableChar',
  'buildNodeOffsets',
  // 搜索。
  'scrollToSearchMatch',
  'clearSearchHighlight',
  // 有声书 cue。
  'applySentenceAudioCues',
  'highlightSentenceAudioCue',
  'clearSentenceAudioCue',
  'resetSentenceAudioCues',
  'cueIdAtPoint',
  'cueIdAtDomPoint',
];

const Set<_Shell> _pagedOnly = <_Shell>{_Shell.paginated};
const Set<_Shell> _continuousOnly = <_Shell>{_Shell.continuous};
const Set<_Shell> _vnOnly = <_Shell>{_Shell.visualNovel};
const Set<_Shell> _scrollShells = <_Shell>{_Shell.paginated, _Shell.continuous};

/// 只属于部分 shell 的方法 → 允许出现的 shell + 其余 shell 不需要它的原因。
const Map<String, _ShellSpecific> _shellSpecific = <String, _ShellSpecific>{
  // ── 只有分页 ──
  'curlPreview': _ShellSpecific(_pagedOnly, '卷页预览要有「相邻整页」；连续没有页，VN 换屏不走卷页覆盖层'),
  'curlRevert': _ShellSpecific(_pagedOnly, '同 curlPreview'),
  'pageInfo': _ShellSpecific(_pagedOnly, '「第几页 / 共几页」只有分页网格有定义'),
  'scrollToRange': _ShellSpecific(
    _pagedOnly,
    '分页的程序化揭示入口（落到 range 起始边所在页）；连续用 scrollToTarget，'
    'VN 的揭示是换屏。scrollToSearchMatch 拿它识别分页',
  ),
  'warmPaginationMetrics': _ShellSpecific(
    _pagedOnly,
    '分页度量缓存的空闲预热；notifyRestoreComplete 拿它识别分页，连续 / VN 没有这份缓存',
  ),
  'heldReadingAnchorCharOffset': _ShellSpecific(
    _pagedOnly,
    '几何重锚持锚期间的读数真值；只有分页有 _geometryReanchorAnchor',
  ),
  'whenPageTurnApplied': _ShellSpecific(
    _pagedOnly,
    '翻页动画（reader_page_turn_script）只拼进分页 shell；调用方 typeof 探测后退回立即执行',
  ),
  'finishPageTurnAnimation': _ShellSpecific(
    _pagedOnly,
    '同 whenPageTurnApplied',
  ),
  'pageTurnBusy': _ShellSpecific(
    _pagedOnly,
    '同 whenPageTurnApplied；进度采样探测到才跳过',
  ),
  // ── 只有连续 ──
  'scrollToChapterEnd': _ShellSpecific(
    _continuousOnly,
    '共享段 _isContinuousShell 拿它识别连续 shell——分页 / VN 绝不能有同名方法',
  ),
  '_charsBeforeEdge': _ShellSpecific(
    _continuousOnly,
    '连续 shell 的章内文本索引；共享段 firstVisibleCharOffsetByScan 探测到才走索引',
  ),
  'scrollToTarget': _ShellSpecific(
    _continuousOnly,
    '连续的程序化揭示入口（滚进跟读安全带）；分页用 scrollToRange',
  ),
  'beginUiScaleReanchor': _ShellSpecific(
    _continuousOnly,
    '界面缩放 / 恢复后的两段式保位只在连续滚动里需要；分页走几何重锚，VN 按屏重切',
  ),
  'commitUiScaleReanchor': _ShellSpecific(
    _continuousOnly,
    '同 beginUiScaleReanchor',
  ),
  'beginRestoreReanchor': _ShellSpecific(
    _continuousOnly,
    '同 beginUiScaleReanchor（BUG-2652 的恢复锚版本）',
  ),
  // ── 分页 + 连续（VN 没有滚动视口）──
  'scrollToCharOffset': _ShellSpecific(
    _scrollShells,
    '按字符偏移滚动（两 shell 签名不同）；VN 按屏定位走 screenIndexForCharOffset',
  ),
  'charOffsetInRange': _ShellSpecific(
    _scrollShells,
    '恢复越界兜底；VN 的 restoreToCharOffset 自己按屏表钳位',
  ),
  'registerImageLateAnchor': _ShellSpecific(
    _scrollShells,
    '迟到图片语义重锚修的是「scroll 指向的内容被图片顶走」；VN 没有 scroll，图片单独成屏',
  ),
  'clearImageLateAnchor': _ShellSpecific(
    _scrollShells,
    '同 registerImageLateAnchor',
  ),
  'reapplyImageLateAnchor': _ShellSpecific(
    _scrollShells,
    '同 registerImageLateAnchor；图片 load 监听 typeof 探测后才调',
  ),
  'noteUserScroll': _ShellSpecific(_scrollShells, '滚动意图认领（放弃恢复锚）；VN 没有滚动'),
  // ── 经别名（this / r / reader / self）探测的方法 ──
  '_invalidateGeometryReanchor': _ShellSpecific(
    _pagedOnly,
    '几何重锚 token 只有分页有（列网格随几何变）；共享段 clearImageLateAnchor / '
    'reapplyImageLateAnchor 用 typeof this._invalidateGeometryReanchor 分支，'
    '连续 / VN 多出同名方法会让共享段去作废一个不存在的 token 协议',
  ),
  'exploredCharsThroughCharOffset': _ShellSpecific(
    _pagedOnly,
    '「已探索字数」按分页的页首索引换算；连续 / VN 探测不到时 Dart 侧脚本用 min(held, total)',
  ),
  'isEinkMode': _ShellSpecific(
    _pagedOnly,
    '翻页动画（reader_page_turn_script）只拼进分页 shell；探测不到即不是墨水屏分页',
  ),
  'followDragEnabled': _ShellSpecific(_pagedOnly, '跟手拖动翻页属于翻页动画模块，只有分页'),
  'followDragCancel': _ShellSpecific(_pagedOnly, '同 followDragEnabled'),
  'chapterCharTotal': _ShellSpecific(
    _continuousOnly,
    '连续按视口边缘前的字数算进度，要一份章总字数；分页走度量缓存，VN 走屏表',
  ),
  'claimBoundaryTurn': _ShellSpecific(
    _continuousOnly,
    '「滚到文档尽头就换章」的三条通道只有连续有；章节无缝衔接模块装饰的也是连续 shell 的这个方法',
  ),
  'revealElement': _ShellSpecific(
    _scrollShells,
    '跟读 / 跨图揭示入口（audiobook_bridge 的 __fushiRevealTarget 用 typeof r.revealElement '
    '探测，缺席就静默退到原生 scrollIntoView）；VN 的揭示是换屏',
  ),
  'revealRange': _ShellSpecific(
    _scrollShells,
    '同 revealElement（BUG-3518：WebKit 上当前句是 Range）；共享段用 this.revealRange && 探测',
  ),
  'sourceTextPosition': _ShellSpecific(
    _vnOnly,
    'VN 重排后的 (节点, 偏移) → 原文位置映射；选区脚本探测不到时按 DOM 原样取',
  ),
  // ── 只有 VN ──
  'highlightSelectorCue': _ShellSpecific(
    _vnOnly,
    'VN 的选择器 cue 高亮；分页 / 连续走 highlightSentenceAudioCue 的 range 路径',
  ),
  'reportTextLeadsScreenCues': _ShellSpecific(
    _vnOnly,
    '「本屏首句是否由文本领跑」只有按屏切分的 VN 有这个概念',
  ),
  'sourceTextOffsetForNode': _ShellSpecific(
    _vnOnly,
    'VN 重排后的节点 → 原文偏移映射；分页 / 连续的 DOM 就是原文，选区脚本探测不到时用自己的遍历',
  ),
  'getMatchableOffset': _ShellSpecific(_vnOnly, '同 sourceTextOffsetForNode'),
  'refitScreensToCurrentViewport': _ShellSpecific(
    _vnOnly,
    'VN 按当前视口重切屏表、当前屏内容没变就原地不动；分页走几何重锚，连续没有屏表',
  ),
};

/// [script]（已掩注释的 shell JS）里是否**定义**了名为 [name] 的方法。认三种写法：
/// 对象字面量 `name: function` / 赋值 `x.name = function` / 方法简写 `name(args) {`。
bool _definesMethod(String script, String name) {
  final String n = RegExp.escape(name);
  final RegExp property = RegExp(
    '(?:^|[^A-Za-z0-9_\$])$n\\s*[:=]\\s*(?:async\\s+)?function\\b',
    multiLine: true,
  );
  final RegExp shorthand = RegExp(
    '^[ \\t]*(?:async\\s+)?$n\\s*\\([^)]*\\)\\s*\\{[ \\t]*\$',
    multiLine: true,
  );
  return property.hasMatch(script) || shorthand.hasMatch(script);
}
