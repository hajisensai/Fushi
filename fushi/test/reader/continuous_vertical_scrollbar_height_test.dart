// BUG-2013：竖排连续模式是横向滚动，桌面 WebView2 的水平滚动条是**占位式**的
// （移动端是不占位的 overlay，所以这条只在桌面复现），从视口底部吃掉约 15px。
// `window.innerHeight` 和 Dart 传来的 MediaQuery 高度都是视口**外框**高度、不扣
// 这条；body 又是 `box-sizing: border-box` + `height: var(--fushi-continuous-height)`
// （`reader_content_styles.dart` 的 `_continuousLayoutCss` 竖排分支），于是 body
// 最底部那 15px 落在滚动条之下，末行文字被裁掉大半。
//
// 实测（Chromium 1200x800 + 竖排长文，复刻同一份 CSS）：
//   innerHeight=705 / documentElement.clientHeight=690 / 水平滚动条 15px
//   喂 705 → 文字底 705 > 可视 690（溢出）
//   喂 690 → 文字底 690（不溢出），再量一轮仍 690（不震荡）
//   内容短到没有滚动条 → clientHeight 回到 705（不误缩）
//
// 本测试两层：
//   ① 行为层——把**生产 JS** 里的 `_visibleViewportHeight` 抽出来在 node 真跑，
//      验证它取 clientHeight、并在未布局（clientHeight=0）时回退；
//   ② 源码层——`--fushi-continuous-height` 的每一次赋值都必须经过它（漏掉任何
//      一处，那条路径上的书就照旧被裁），且分页 shell 不得被误改。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

import '../helpers/source_guard.dart';

/// 从连续 shell 源码里抽出 `_visibleViewportHeight` 的**函数字面量**（含函数体），
/// 供 node 直接跑生产代码，而不是在测试里另抄一份。
String _extractVisibleViewportHeightFn(String shell) {
  const String marker = '_visibleViewportHeight: function(fallback) {';
  // 在**剥掉 JS 注释**的语料上定位：本函数上方的说明注释里就写着这个函数名，
  // 将来任何注释里出现同样的串都会让裸 indexOf 抠出一段假实现。maskJsComments
  // 逐字节等长，下标可直接回原串切片，拿到的仍是真实现。
  final String masked = maskJsComments(shell);
  final int start = masked.indexOf(marker);
  expect(start, greaterThan(0),
      reason: '_visibleViewportHeight 被改名/删除，本测试已失去锚点');
  final int braceIdx = masked.indexOf('{', start + marker.length - 1);
  int depth = 0;
  for (int i = braceIdx; i < masked.length; i++) {
    final String ch = masked[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return 'function(fallback) ${shell.substring(braceIdx, i + 1)}';
      }
    }
  }
  fail('_visibleViewportHeight 函数体没有闭合');
}

void main() {
  late String continuous;
  late String paginated;

  setUpAll(() {
    continuous = ReaderPaginationScripts.continuousShellSource();
    paginated = ReaderPaginationScripts.paginatedShellSource();
  });

  group('BUG-2013 行为：生产 JS 的 _visibleViewportHeight 在 node 真跑', () {
    test('取 clientHeight（扣掉滚动条），未布局时回退外框高度', () {
      final String fn = _extractVisibleViewportHeightFn(continuous);

      final Directory temp =
          Directory.systemTemp.createTempSync('fushi-bug2013-');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final File fnFile = File('${temp.path}/fn.json')
        ..writeAsStringSync(jsonEncode(<String, String>{'fn': fn}));

      final ProcessResult result = Process.runSync(
        'node',
        <String>['-e', _runner, fnFile.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      expect(result.exitCode, 0,
          reason: 'BUG-2013 runner 失败:\n'
              'stdout=${result.stdout}\nstderr=${result.stderr}');
      expect(result.stdout.toString().trim(), 'OK');
    });
  });

  group('BUG-2013 源码：--fushi-continuous-height 只有一个写入点且走可视高度', () {
    test('连续 shell 里该变量有且只有一处赋值，且经过 _visibleViewportHeight', () {
      // 语料先剥 JS 注释：说明注释里也写着这个变量名，不剥会假红；反过来
      // 「必须出现」型断言也会被注释喂成假绿。
      final String code = maskJsComments(continuous);
      // 允许换行/任意空白，避免 dart format 换行导致锚点漂移成假红。
      final RegExp anyAssign = RegExp(
          r"setProperty\(\s*'--fushi-continuous-height'\s*,\s*([^;]*?)\s*\+\s*'px'\s*\)",
          multiLine: true,
          dotAll: true);
      final List<RegExpMatch> assigns = anyAssign.allMatches(code).toList();

      expect(assigns, hasLength(1),
          reason: '这个变量必须只有 _applyContinuousHeight 一个写入点。多一处就意味着'
              '又出现了一条绕开可视高度的路径（BUG-2013 原状正是两处各写各的）；'
              '少一处说明写入点被删。');
      expect(assigns.single.group(1), contains('_visibleViewportHeight('),
          reason: '这处直接把视口外框高度（innerHeight / dartPageHeight / cssHeight）'
              '写进了 CSS，没扣水平滚动条 → 竖排书末行照旧被裁。'
              '实际写的是: ${assigns.single.group(1)}');
    });

    test('每个失效源都重算：initialize / updatePageSize / 换样式重锚两条分支', () {
      final String code = maskJsComments(continuous);
      expect(RegExp(r'_applyContinuousHeight\(').allMatches(code).length, 4,
          reason: '应有 4 处调用：initialize、updatePageSize，以及 beginStyleReanchor '
              '的两条分支。改取可视高度后这个量从「视口相关」变成「**内容**相关」'
              '（水平滚动条的有无由列数决定，而改字号就是改列数），换样式路径漏掉'
              '的话，放大字号后滚动条新出现的书末行照旧被裁、要等 resize 才自愈。'
              '数量变了必须回去复核失效源清单。');

      // 用 indexOf 切函数体，不用跨行正则：`\n  },` 这种锚点写进正则字面量太容易
      // 被转义/格式化搞坏，切片语义也更直白。
      final int rStart = code.indexOf('beginStyleReanchor: function');
      expect(rStart, greaterThan(0),
          reason: 'beginStyleReanchor 锚点丢失，本守卫已失效');
      final int rEnd = code.indexOf('\n  },', rStart);
      expect(rEnd, greaterThan(rStart),
          reason: 'beginStyleReanchor 函数体没有在预期缩进处闭合，本守卫已失效');
      final String body = code.substring(rStart, rEnd);
      expect(RegExp(r'_applyContinuousHeight\(').allMatches(body).length, 2,
          reason: 'beginStyleReanchor（改字号/换样式的唯一入口）的**两条**分支都要'
              '重算该变量——提前 return -1 的那条同样已经换了 CSS。只靠上面的总数'
              '断言会被「四次调用挤在 initialize 里」骗过。');
    });

    test('_visibleViewportHeight 读 clientHeight、能回退、并夹在外框高度以内', () {
      final String fn = _extractVisibleViewportHeightFn(continuous);
      expect(fn, contains('document.documentElement.clientHeight'),
          reason: 'clientHeight 是唯一扣掉滚动条的可视高度；换成 innerHeight / '
              'getBoundingClientRect 都会把滚动条那条算回去');
      expect(fn, contains('fallback'),
          reason: '未布局（clientHeight=0）时必须回退，否则 body 高度会塌成 0');
      expect(fn, contains('<= fallback'),
          reason: '必须夹在视口外框高度以内——可视内容高度按**定义**不可能超过外框'
              '高度，超出就说明读到的不是本次布局的值：iOS 上 \$_sharedInitViewport '
              '刚重建 meta[name=viewport]，BUG-1688 实测生效前 WKWebView 按默认 980 '
              'CSS px 布局（innerHeight=1743，而 Dart 权威值 667）；书自己没写 '
              'doctype 落 quirks 时同理。少了这个夹子，竖排 body 高度会爆到 2.6 倍，'
              '而 iOS 是 overlay 滚动条、本修复在那儿收益为零。');
    });

    test('分页 shell 不受影响（该变量只属于连续模式）', () {
      expect(paginated.contains('--fushi-continuous-height'), isFalse,
          reason: '分页模式用 --reader-viewport-height，不该出现连续模式的变量；'
              '出现了说明修复被误扩散到分页几何，会动 pageStep 不变式');
      expect(paginated.contains('_visibleViewportHeight'), isFalse,
          reason: '同上：分页模式的视口高度语义不同，不要顺手共享这个 helper');
      expect(paginated.contains('_applyContinuousHeight'), isFalse,
          reason: '同上：分页 shell 的 beginStyleReanchor 与连续 shell 各自一份，'
              '别把连续模式的写入点顺手抄过去');
    });
  });
}

const String _runner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}

// 生产函数字面量，原样求值——不在测试里另抄一份实现，否则抄的那份和生产代码
// 会漂开，测试就变成「测我自己抄的版本」。输入不是外部数据：它是本仓库
// ReaderPaginationScripts 生成的源码，与既有 reader_production_js_behavior_test
// 用的是同一套做法（同样 eval 生产 JS 片段）。
const visibleViewportHeight = eval('(' + data.fn + ')');

// 场景一：有水平滚动条（竖排连续的常态）。外框 705、可视 690、滚动条 15。
global.document = { documentElement: { clientHeight: 690 } };
let got = visibleViewportHeight.call(null, 705);
assert(got === 690,
  'clientHeight=690 时应返回 690（扣掉 15px 滚动条），实际 ' + got);

// 场景二：没有滚动条（内容短）。clientHeight 与外框一致，不得误缩。
global.document = { documentElement: { clientHeight: 705 } };
got = visibleViewportHeight.call(null, 705);
assert(got === 705, 'clientHeight=705 时应返回 705，实际 ' + got);

// 场景三：尚未布局，clientHeight=0 → 必须回退到外框高度，不能让 body 塌成 0。
global.document = { documentElement: { clientHeight: 0 } };
got = visibleViewportHeight.call(null, 705);
assert(got === 705, 'clientHeight=0 时应回退 705，实际 ' + got);

// 场景四：clientHeight 缺失（undefined）→ 同样回退。
global.document = { documentElement: {} };
got = visibleViewportHeight.call(null, 640);
assert(got === 640, 'clientHeight 缺失时应回退 640，实际 ' + got);

// 场景五（夹子）：clientHeight 超过外框高度 → 读到的不是本次布局的值，必须回退。
// iOS：meta viewport 重写生效前 WKWebView 按默认 980 CSS px 布局，BUG-1688 实测
// innerHeight=1743 而 Dart 权威值 667；书没写 doctype 落 quirks 时同理。
global.document = { documentElement: { clientHeight: 1743 } };
got = visibleViewportHeight.call(null, 667);
assert(got === 667,
  'clientHeight(1743) 超过外框(667) 时应回退 667，实际 ' + got);

// 场景六：正好等于外框高度（无滚动条）仍取实测值——夹子不得把等号一起挡掉，
// 否则「内容短到没有滚动条」的书会退化成永远走 fallback。
global.document = { documentElement: { clientHeight: 667 } };
got = visibleViewportHeight.call(null, 667);
assert(got === 667, 'clientHeight 等于外框时应返回 667，实际 ' + got);

console.log('OK');
''';
