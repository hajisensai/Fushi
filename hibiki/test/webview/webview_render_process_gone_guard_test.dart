import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 源码守卫：`lib/` 下**每一处** WebView 构造都必须传非 null 的
/// `onRenderProcessGone`。
///
/// ## 为什么「传了这个参数」本身就是被守的语义（不是摆设式字面量断言）
///
/// Android 上一个 WebView 的 HTML 渲染跑在独立的 chromium renderer 子进程里。系统
/// 内存紧张时会把它回收掉。此时
/// `third_party/flutter_inappwebview_android/.../InAppWebViewClientCompat.java`
/// 的 `onRenderProcessGone` 决定后果：
///
/// ```java
/// if (webView.customSettings.useOnRenderProcessGone && webView.channelDelegate != null) {
///   webView.channelDelegate.onRenderProcessGone(didCrash, rendererPriorityAtExit);
///   return true;                                     // 自报接管，只白屏
/// }
/// return super.onRenderProcessGone(view, detail);    // 默认动作：杀掉整个 app 进程
/// ```
///
/// Java 侧是**发完事件立刻 `return true`**，而 Dart 回调签名是 `void` —— 返回值
/// 回不到 Java。所以回调体里写什么完全不影响存活，唯一决定「app 是否被系统连坐
/// 杀掉」的就是**这个参数是不是 null**：
/// `third_party/flutter_inappwebview_android/lib/src/in_app_webview/in_app_webview.dart:444`
/// （headless 侧 `headless_in_app_webview.dart:380`）在
/// `params.onRenderProcessGone != null && settings.useOnRenderProcessGone == null`
/// 时把 `useOnRenderProcessGone` 自动推成 true，从而走进上面那个 `return true`。
///
/// 于是本守卫的两条断言都是**真语义**而非拼写：
/// 1. 每处构造都有非 null 的 `onRenderProcessGone`；
/// 2. 没有哪一处把 `useOnRenderProcessGone` 显式写成 `false` —— 那是唯一一种
///    「回调传了、Java 侧依然回落 `super`」的写法，会让第 1 条变成假绿。
///
/// ## 判据不从被守对象推导
///
/// 宿主集合由**正向规则**发现（扫全 `lib/`，找以独立标识符身份出现的
/// `InAppWebView(` / `HeadlessInAppWebView(` 构造），不是照抄一份已知文件清单；
/// 新增第 N+1 处会被自动纳入。窗口由括号配对给出（[enclosingCall]），与缩进、
/// 参数顺序、参数多少无关。发现数为 0 或少于当前已知的 6 处一律 fail —— 重构把
/// 构造点搬走时守卫要红，而不是静默空跑。
void main() {
  const List<String> constructorNames = <String>[
    'InAppWebView',
    'HeadlessInAppWebView',
  ];

  // 当前 lib/ 下的实际构造点数（main.dart 预热 + 阅读器 + 漫画 + 词典弹窗 +
  // Lapis 预览 + 有声书剪辑离屏）。少于这个数说明发现规则锚不上目标了。
  const int knownHostCount = 6;

  final List<String> anchorErrors = <String>[];
  final List<_WebViewHost> hosts =
      _discoverHosts(constructorNames, anchorErrors);

  test('lib/ 下能发现 WebView 构造点（发现规则本身不许空跑）', () {
    expect(
      anchorErrors,
      isEmpty,
      reason: '括号配对回溯没落在被找的构造器上，窗口锚歪了，'
          '后面的参数断言不可信：\n${anchorErrors.join('\n')}',
    );
    expect(
      hosts,
      isNotEmpty,
      reason: '一处 InAppWebView 构造都没扫到，说明发现规则失效（包名/构造器改了？），'
          '此时后面的逐处断言会全部空转成假绿',
    );
    expect(
      hosts.length,
      greaterThanOrEqualTo(knownHostCount),
      reason: '已知 $knownHostCount 处 WebView 构造点，现在只发现 ${hosts.length} 处：'
          '要么构造点被搬走/改名（发现规则要跟着更新），要么真的被删了。'
          '发现到的：${hosts.map((_WebViewHost h) => h.where).join(', ')}',
    );
  });

  test('每一处 WebView 构造都传了非 null 的 onRenderProcessGone', () {
    final List<String> offenders = <String>[];
    for (final _WebViewHost host in hosts) {
      final String? value =
          _topLevelNamedArgument(host.call.text, 'onRenderProcessGone');
      if (value == null) {
        offenders.add('${host.where} —— 没有 onRenderProcessGone 参数');
        continue;
      }
      if (value.isEmpty || value == 'null') {
        offenders.add('${host.where} —— onRenderProcessGone 传了 `$value`');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Android 上没接管 renderer 死亡 = 系统把整个 app 进程一起杀掉'
          '（InAppWebViewClientCompat.onRenderProcessGone 回落 super）。'
          '救命动作就是传一个非 null 回调，处置逻辑收在 '
          'lib/src/webview/webview_death_guard.dart 的 WebViewDeathGuard。'
          '未接管的构造点：\n${offenders.join('\n')}',
    );
  });

  test('没有哪一处把 useOnRenderProcessGone 显式关成 false', () {
    final List<String> offenders = <String>[];
    for (final _WebViewHost host in hosts) {
      final String masked = maskCommentsAndStrings(host.call.text);
      final RegExp disabled = RegExp(
        r'(?<![A-Za-z0-9_$])useOnRenderProcessGone\s*:\s*false',
      );
      if (disabled.hasMatch(masked)) {
        offenders.add(host.where);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '把 useOnRenderProcessGone 写成 false 会让 Java 侧无视已传的回调、'
          '回落 super（= 杀 app），上一条断言随即变成假绿。'
          '默认不写即可：in_app_webview.dart:444 会在回调非 null 时自动推成 true。'
          '违规处：${offenders.join(', ')}',
    );
  });
}

class _WebViewHost {
  _WebViewHost({required this.where, required this.call});

  /// `路径:行号 构造器名` —— 断言失败时直接指出是哪一处。
  final String where;
  final EnclosingCall call;
}

/// 发现规则跑在 `main()` 体内（测试注册前），所以这里**不能**调 [expect]
/// （会抛 `OutsideTestException`）；锚歪的情况收进 [anchorErrors]，由第一个测试断言。
List<_WebViewHost> _discoverHosts(
  List<String> constructorNames,
  List<String> anchorErrors,
) {
  final List<_WebViewHost> hosts = <_WebViewHost>[];
  final List<File> files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String source = file.readAsStringSync();
    // 先做词法掩码再找：注释里写着 `InAppWebView(` 不算构造点。掩码等长，
    // 下标可直接回原串取切片。
    final String masked = maskCommentsAndStrings(source);
    for (final String name in constructorNames) {
      // allowNamedConstructor: false —— 只认裸构造。负向后顾保证
      // `HeadlessInAppWebView(` 不会被 `InAppWebView` 这条规则重复命中。
      final RegExp pattern = identifierCall(name, allowNamedConstructor: false);
      for (final RegExpMatch match in pattern.allMatches(masked)) {
        final EnclosingCall call = enclosingCall(source, match.end);
        // 防锚歪：括号回溯拿到的必须就是这个构造器本身。
        if (call.name != name) {
          anchorErrors.add(
            '${file.path} 里 $name 的括号配对回溯拿到了 `${call.name}`',
          );
          continue;
        }
        final int line =
            '\n'.allMatches(source.substring(0, call.start)).length + 1;
        hosts.add(_WebViewHost(
          where: '${file.path.replaceAll(r'\', '/')}:$line $name',
          call: call,
        ));
      }
    }
  }
  return hosts;
}

/// 取 [callText] 这次调用**自身实参表**（深度 1）上名为 [label] 的命名参数值。
///
/// 深度用 `(` `[` `{` 三种括号计数（泛型 `<>` 不影响括号深度，所以不用管），
/// 因此嵌套 widget 里同名的参数不会被误当成本次调用的参数。找不到返回 null。
String? _topLevelNamedArgument(String callText, String label) {
  final String masked = maskCommentsAndStrings(callText);
  final int open = masked.indexOf('(');
  if (open < 0) return null;
  final RegExp pattern = RegExp(
    r'(?<![A-Za-z0-9_$])' + RegExp.escape(label) + r'\s*:',
  );
  for (final RegExpMatch match in pattern.allMatches(masked)) {
    if (match.start < open) continue;
    if (_bracketDepth(masked, open, match.start) != 1) continue;
    int i = match.end;
    int depth = 0;
    while (i < masked.length) {
      final String c = masked[i];
      if (c == '(' || c == '[' || c == '{') {
        depth++;
      } else if (c == ')' || c == ']' || c == '}') {
        if (depth == 0) break;
        depth--;
      } else if (c == ',' && depth == 0) {
        break;
      }
      i++;
    }
    return callText.substring(match.end, i).trim();
  }
  return null;
}

int _bracketDepth(String masked, int from, int to) {
  int depth = 0;
  for (int i = from; i < to; i++) {
    final String c = masked[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    }
  }
  return depth;
}
