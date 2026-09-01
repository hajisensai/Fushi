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

/// 从连续 shell 源码里抽出 `_visibleViewportHeight` 的**函数字面量**（含函数体），
/// 供 node 直接跑生产代码，而不是在测试里另抄一份。
String _extractVisibleViewportHeightFn(String shell) {
  const String marker = '_visibleViewportHeight: function(fallback) {';
  final int start = shell.indexOf(marker);
  expect(start, greaterThan(0),
      reason: '_visibleViewportHeight 被改名/删除，本测试已失去锚点');
  final int braceIdx = shell.indexOf('{', start + marker.length - 1);
  int depth = 0;
  for (int i = braceIdx; i < shell.length; i++) {
    final String ch = shell[i];
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

  group('BUG-2013 源码：--fushi-continuous-height 的每次赋值都走可视高度', () {
    test('连续 shell 里该变量的赋值一处不漏地经过 _visibleViewportHeight', () {
      // 允许换行/任意空白，避免 dart format 换行导致锚点漂移成假红。
      final RegExp anyAssign = RegExp(
          r"setProperty\(\s*'--fushi-continuous-height'\s*,\s*([^;]*?)\s*\+\s*'px'\s*\)",
          multiLine: true,
          dotAll: true);
      final List<RegExpMatch> assigns =
          anyAssign.allMatches(continuous).toList();

      expect(assigns, hasLength(2),
          reason: '连续 shell 应有且只有两处赋值（initialize / updatePageSize）；'
              '数量变了说明新增或删除了赋值点，本守卫需要同步复核');

      for (final RegExpMatch m in assigns) {
        expect(m.group(1), contains('_visibleViewportHeight('),
            reason: '这处直接把视口外框高度（innerHeight / dartPageHeight / '
                'cssHeight）写进了 CSS，没扣水平滚动条 → 该路径上的竖排书'
                '末行照旧被裁。实际写的是: ${m.group(1)}');
      }
    });

    test('_visibleViewportHeight 确实读 documentElement.clientHeight', () {
      final String fn = _extractVisibleViewportHeightFn(continuous);
      expect(fn, contains('document.documentElement.clientHeight'),
          reason: 'clientHeight 是唯一扣掉滚动条的可视高度；换成 innerHeight / '
              'getBoundingClientRect 都会把滚动条那条算回去');
      expect(fn, contains('fallback'),
          reason: '未布局（clientHeight=0）时必须回退，否则 body 高度会塌成 0');
    });

    test('分页 shell 不受影响（该变量只属于连续模式）', () {
      expect(paginated.contains('--fushi-continuous-height'), isFalse,
          reason: '分页模式用 --reader-viewport-height，不该出现连续模式的变量；'
              '出现了说明修复被误扩散到分页几何，会动 pageStep 不变式');
      expect(paginated.contains('_visibleViewportHeight'), isFalse,
          reason: '同上：分页模式的视口高度语义不同，不要顺手共享这个 helper');
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

console.log('OK');
''';
