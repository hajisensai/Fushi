import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2584：「查词浮层子项必须接对话框隐藏计数」这条缝的**收口守卫**。
///
/// 历史上同一条缝被分三次发现、每次只补一处，因为每次都拿「当次症状的判据」划范围：
/// - BUG-797 / BUG-1040 修弹窗层（`parkedPopupLayer` 的 `visible`），判据是「**平台视图
///   airspace**」；
/// - BUG-1327 修整屏 dismiss barrier（`shouldShowLookupDismissBarrier`），判据是
///   「**命中测试**」；
/// - BUG-1364 修搜索期占位卡——它既不是平台视图也不是 barrier，前两次的视野都不覆盖它。
///
/// 三个判据互不包含，中间必然漏缝。本守卫改用一个**与症状无关**的判据：
///
///   查词浮层 `Stack` 的**每一个直接子项**，都必须能顺着调用链走到对话框隐藏计数
///   （`_popupHidingDialogDepth` / `lookupPopupHiddenByDialog`）。
///
/// 「能走到」是真的顺着源码求出来的（下面的不动点），不是白名单：
/// 1. 宿主集合由**正向规则**发现——`lib/` 下所有 `with DictionaryPageMixin` 的文件。
///    新加宿主自动进范围，且与「被守的子项集合」无关（不是取反算出来的，不会因为被测
///    范围放宽就缩成空集）。
/// 2. 每个宿主里，浮层 children 列表用**结构锚点**定位：包含 `…entries.length; i++)`
///    这个弹窗层循环的那个列表字面量（每个浮层的存在理由就是画弹窗层）。
/// 3. 列表按括号配对切成顶层元素，逐个判定：要么它的 `if` 条件引用了计数，要么它调用的
///    构造/方法在不动点里被判为「可达计数」。都不是就红。
///
/// 不用编译期约束（例如让子项走一个必须传入计数的公共基类）的理由：这些子项**必须**用
/// 两套互斥的让位机制——原生平台视图（弹窗层 WebView）无视 `Opacity`/`IgnorePointer`，
/// 只能靠 [parkedPopupLayer] 停到屏外；纯 Flutter 子项（占位卡 / barrier）反过来不能停
/// 屏外（会改变布局槽位），只能 `Visibility` / 不挂。一个"必传计数"的公共基类没法同时
/// 承载这两种让位语义，硬合会退化成"基类只存字段、让位仍靠各子类自觉"，守不住任何东西。
/// 真正的单一入口已经在 `DictionaryPageMixin` 里（PR#688 的占位卡改一处覆盖四宿主），
/// 本守卫钉的是**入口外面**那一层：宿主自己往 Stack 里塞的东西。
///
/// 反例（本守卫必须红）：往任一宿主的浮层 Stack 里加一个不接计数的新子项。
/// 变异实测记录见 PR 描述。
// ---------------------------------------------------------------------------
// 判据里唯一的"魔法字符串"：对话框隐藏计数自身的两个名字。
// ---------------------------------------------------------------------------

/// 计数的私有字段名（`DictionaryPageMixin` 内部）与它的 `@protected` 读取器。
/// 子项的让位条件必须最终引用其中之一。
const List<String> _kGateTokens = <String>[
  '_popupHidingDialogDepth',
  'lookupPopupHiddenByDialog',
];

/// 必须被发现到的已知宿主（防守卫塌成空集 / 静默漏扫）。
/// 只作**下界**：新宿主自动进范围，不需要往这里加。
const List<String> _kKnownHosts = <String>[
  'lib/src/media/audiobook/floating_lyric_lookup_host.dart',
  'lib/src/pages/implementations/home_dictionary_page.dart',
  'lib/src/pages/implementations/popup_dictionary_page.dart',
  'lib/src/pages/implementations/texthooker_page.dart',
  'lib/src/pages/implementations/video_hibiki_page.dart',
];

const String _kMixinPath =
    'lib/src/pages/implementations/dictionary_page_mixin.dart';
const String _kPopupLayerPath =
    'lib/src/pages/implementations/dictionary_popup_layer.dart';

/// `with … DictionaryPageMixin …`（注释里的同名文本不算数——先掩码再匹配）。
final RegExp _kWithMixin = RegExp(
  r'(?<![A-Za-z0-9_$])with(?![A-Za-z0-9_$])[^{;]*(?<![A-Za-z0-9_$])'
  r'DictionaryPageMixin(?![A-Za-z0-9_$])',
);

/// 弹窗层循环 `for (int i = 0; i < <ctrl>.entries.length; i++)` 的结构锚点。
final RegExp _kEntriesLoop = RegExp(r'\.entries\.length\s*;\s*i\s*\+\+\s*\)');

/// `Widget foo(` / `List<Widget> foo(` 声明。
final RegExp _kWidgetMethodDecl = RegExp(
  r'(?<![A-Za-z0-9_$])(?:Widget|List<Widget>)\s+(_?[A-Za-z][A-Za-z0-9_]*)\s*\(',
);

/// 直接调用（排除 `x.foo(`，那是别的对象的方法，不在本文件的方法表里）。
final RegExp _kDirectCall =
    RegExp(r'(?<![A-Za-z0-9_$.])(_?[A-Za-z][A-Za-z0-9_]*)\s*\(');

String _read(String path) => File(path).readAsStringSync();

/// `lib/` 下所有 `with DictionaryPageMixin` 的文件（正斜杠相对路径，已排序）。
List<String> _discoverHosts() {
  final List<String> hits = <String>[];
  for (final FileSystemEntity e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final String raw = e.readAsStringSync();
    // 先做廉价子串预筛（lib/ 上千个文件，逐个词法掩码太慢），命中再掩码复核。
    if (!raw.contains('DictionaryPageMixin')) continue;
    if (!_kWithMixin.hasMatch(maskComments(raw))) continue;
    hits.add(e.path.replaceAll(r'\', '/'));
  }
  hits.sort();
  return hits;
}

/// 名字 → 方法体（原文切片）。同名取首个声明。
///
/// 不用 `methodBody`：那个 helper 每次调用都要把整份源码重新词法掩码一遍，而
/// `video_hibiki_page.dart` 一个文件就有几十个 `Widget` 方法（250KB × 几十次）。
/// 这里把掩码结果复用，配对逻辑与 `methodBody` 一致（先配平参数表圆括号，再配花括号），
/// 另外多认一种 `methodBody` 不支持的形态：箭头体 `=> …;`。
Map<String, String> _widgetMethodBodies(String src, String structural) {
  final Map<String, String> bodies = <String, String>{};
  for (final RegExpMatch m in _kWidgetMethodDecl.allMatches(structural)) {
    final String name = m.group(1)!;
    if (bodies.containsKey(name)) continue;
    // m.end 落在参数表左括号之后，深度已为 1。
    int depth = 1;
    int afterParams = -1;
    for (int i = m.end; i < structural.length; i++) {
      if (structural[i] == '(') depth++;
      if (structural[i] == ')') {
        depth--;
        if (depth == 0) {
          afterParams = i + 1;
          break;
        }
      }
    }
    if (afterParams < 0) continue;
    int j = afterParams;
    while (j < structural.length && structural[j].trim().isEmpty) {
      j++;
    }
    if (j >= structural.length) continue;
    if (structural.startsWith('=>', j)) {
      final int semi = structural.indexOf(';', j);
      if (semi < 0) continue;
      bodies[name] = src.substring(m.start, semi + 1);
      continue;
    }
    if (structural[j] != '{') continue; // 抽象声明 `Widget foo();` 等，无体。
    int braces = 0;
    for (int i = j; i < structural.length; i++) {
      if (structural[i] == '{') braces++;
      if (structural[i] == '}') {
        braces--;
        if (braces == 0) {
          bodies[name] = src.substring(m.start, i + 1);
          break;
        }
      }
    }
  }
  return bodies;
}

/// 不动点：方法体里直接出现计数 ⇒ 可达；调用了另一个可达的方法 ⇒ 也可达。
///
/// 这一步是本守卫**不是白名单**的关键：`_buildNestedPopupLayer` 这类宿主薄转发器之所以
/// 算过，是因为它真的调到了带计数的 `buildNestedPopupLayer`，而不是因为名字被登记过。
Set<String> _gateReachable(Map<String, String> bodies) {
  // 注释里写着 `_popupHidingDialogDepth` 不算数（本仓守卫的老坑）：先掩码再判。
  final Map<String, String> masked = <String, String>{
    for (final MapEntry<String, String> e in bodies.entries)
      e.key: maskComments(e.value),
  };
  final Set<String> reachable = <String>{};
  for (final MapEntry<String, String> e in masked.entries) {
    if (_kGateTokens.any(e.value.contains)) reachable.add(e.key);
  }
  bool changed = true;
  while (changed) {
    changed = false;
    for (final MapEntry<String, String> e in masked.entries) {
      if (reachable.contains(e.key)) continue;
      for (final RegExpMatch m in _kDirectCall.allMatches(e.value)) {
        final String callee = m.group(1)!;
        if (callee == e.key || !reachable.contains(callee)) continue;
        reachable.add(e.key);
        changed = true;
        break;
      }
    }
  }
  return reachable;
}

/// 从 [index] 往回找**未配对的左方括号**（即包住它的那个列表字面量的开头）。
int _enclosingListOpen(String structural, int index, String label) {
  int depth = 0;
  for (int i = index - 1; i >= 0; i--) {
    final String c = structural[i];
    if (c == ']') {
      depth++;
    } else if (c == '[') {
      if (depth == 0) return i;
      depth--;
    }
  }
  fail('$label：弹窗层循环不在任何列表字面量里（找不到未配对的 `[`）');
}

int _matchingListClose(String structural, int open, String label) {
  int depth = 0;
  for (int i = open; i < structural.length; i++) {
    if (structural[i] == '[') depth++;
    if (structural[i] == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  fail('$label：浮层 children 列表的方括号不配对');
}

/// 定位宿主的浮层 children 列表：包含弹窗层循环、且写成 `<Widget>[` 的列表字面量。
///
/// 只认显式 `<Widget>[`（五个宿主今天全是这个写法）。这既排掉了非 widget 列表里同名的
/// `.entries.length` 循环，也让"漏认"变成**红**而不是静默跳过：宿主一个都没匹配上会
/// 直接 fail，不会悄悄扫了 0 个子项还全绿。
List<int> _overlayListOpens(String structural, String label) {
  final Set<int> opens = <int>{};
  bool sawLoop = false;
  for (final RegExpMatch loop in _kEntriesLoop.allMatches(structural)) {
    sawLoop = true;
    final int open = _enclosingListOpen(structural, loop.start, label);
    int i = open - 1;
    while (i >= 0 && structural[i].trim().isEmpty) {
      i--;
    }
    if (i >= 7 && structural.substring(i - 7, i + 1) == '<Widget>') {
      opens.add(open);
    }
  }
  if (opens.isEmpty) {
    fail('$label：找不到浮层 children 列表（包含 `…entries.length; i++)` 的 '
        '`<Widget>[` 字面量${sawLoop ? "；有循环但外层列表不是 `<Widget>[`" : ""}）。'
        '查词浮层的存在理由就是画弹窗层，找不到说明宿主结构变了——必须调整本守卫的锚点，'
        '而不是让它静默跳过这个宿主');
  }
  return opens.toList()..sort();
}

/// 按括号配对把列表字面量切成**顶层元素**（原文切片）。
List<String> _topLevelElements(
    String src, String structural, int open, String label) {
  final int close = _matchingListClose(structural, open, label);
  final List<String> parts = <String>[];
  int depth = 0;
  int start = open + 1;
  for (int i = start; i < close; i++) {
    final String c = structural[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      parts.add(src.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(src.substring(start, close));
  return parts
      .map((String p) => p.trim())
      .where((String p) => maskComments(p).trim().isNotEmpty)
      .toList();
}

/// 一个顶层元素的判定结果。
class _ChildVerdict {
  const _ChildVerdict({required this.ok, required this.why});

  final bool ok;
  final String why;
}

/// 剥掉 `if (...)` / `for (...)` 头部，收集 `if` 条件，返回剩下的 widget 表达式。
_ChildVerdict _judgeChild(String element, Set<String> reachable) {
  String rest = maskComments(element).trim();
  final List<String> conditions = <String>[];
  while (true) {
    final RegExpMatch? head = RegExp(r'^(if|for)\s*\(').firstMatch(rest);
    if (head == null) break;
    final int openP = rest.indexOf('(');
    int depth = 0;
    int closeP = -1;
    for (int i = openP; i < rest.length; i++) {
      if (rest[i] == '(') depth++;
      if (rest[i] == ')') {
        depth--;
        if (depth == 0) {
          closeP = i;
          break;
        }
      }
    }
    if (closeP < 0) {
      return const _ChildVerdict(ok: false, why: '`if`/`for` 头部圆括号不配对');
    }
    if (head.group(1) == 'if') {
      conditions.add(rest.substring(openP + 1, closeP));
    }
    rest = rest.substring(closeP + 1).trim();
  }
  for (final String cond in conditions) {
    if (_kGateTokens.any(cond.contains)) {
      return const _ChildVerdict(ok: true, why: '显示条件引用了对话框隐藏计数');
    }
  }
  final RegExpMatch? callee =
      RegExp(r'^(_?[A-Za-z][A-Za-z0-9_]*)').firstMatch(rest);
  final String name = callee?.group(1) ?? '<非标识符表达式>';
  if (reachable.contains(name)) {
    return _ChildVerdict(ok: true, why: '`$name` 顺调用链接到对话框隐藏计数');
  }
  return _ChildVerdict(
    ok: false,
    why: '`$name` 既没在显示条件里引用对话框隐藏计数，'
        '其调用链也走不到 ${_kGateTokens.join(" / ")}',
  );
}

void main() {
  final String mixinSrc = _read(_kMixinPath);
  final Map<String, String> mixinBodies =
      _widgetMethodBodies(mixinSrc, maskCommentsAndStrings(mixinSrc));

  group('查词浮层子项 × 对话框隐藏计数（TODO-2584 收口守卫）', () {
    final List<String> hosts = _discoverHosts();

    test('宿主发现规则不得塌成空集', () {
      for (final String known in _kKnownHosts) {
        expect(hosts, contains(known),
            reason: '正向发现规则（`with DictionaryPageMixin`）漏掉了已知宿主 $known；'
                '守卫范围一旦缩水，后面每条断言都会静默变成"没什么可查"');
      }
    });

    test('每个宿主的浮层 children 逐项都能走到对话框隐藏计数', () {
      int totalChildren = 0;
      final List<String> failures = <String>[];
      for (final String host in hosts) {
        final String src = _read(host);
        final String structural = maskCommentsAndStrings(src);
        final Map<String, String> bodies = <String, String>{
          ...mixinBodies,
          // 宿主自身的方法优先（薄转发器 `_buildNestedPopupLayer` 等同名覆盖）。
          ..._widgetMethodBodies(src, structural),
        };
        final Set<String> reachable = _gateReachable(bodies);
        for (final int open in _overlayListOpens(structural, host)) {
          final List<String> children =
              _topLevelElements(src, structural, open, host);
          expect(children, isNotEmpty, reason: '$host：浮层 children 列表被切成空');
          totalChildren += children.length;
          for (final String child in children) {
            final _ChildVerdict verdict = _judgeChild(child, reachable);
            if (verdict.ok) continue;
            final String head = maskComments(child)
                .split('\n')
                .map((String l) => l.trim())
                .firstWhere((String l) => l.isNotEmpty, orElse: () => child);
            failures.add('$host\n    子项: $head\n    原因: ${verdict.why}');
          }
        }
      }
      expect(
        failures,
        isEmpty,
        reason: '查词浮层子树整体排在 `showAppDialog` 推的路由之上（根 Overlay / 根 '
            'builder），对话框打开期间**每个**子项都必须让位——漏一个就是 BUG-797 / '
            '1040 / 1327 / 1364 再来一次。修法二选一：\n'
            '  ① 把子项收进 `DictionaryPageMixin` 的构建方法，在那里与 '
            '`_popupHidingDialogDepth == 0` 相与（占位卡 / 弹窗层的做法）；\n'
            '  ② 子项的显示条件里显式与 `!lookupPopupHiddenByDialog` 相与'
            '（barrier 的做法）。\n未通过项：\n${failures.join("\n")}',
      );
      expect(totalChildren, greaterThanOrEqualTo(10),
          reason: '五个宿主今天共 12 个浮层子项；切出的子项数骤降说明列表锚点漂了，'
              '守卫在对着空气跑');
    });

    test('不动点真的解析出了两个共享构建方法（否则"可达"是假的）', () {
      final Set<String> reachable = _gateReachable(mixinBodies);
      expect(reachable, contains('buildNestedPopupLayer'),
          reason: '弹窗层构建方法必须自带 `_popupHidingDialogDepth` 判据');
      expect(reachable, contains('buildPopupLoadingPlaceholder'),
          reason: '搜索期占位卡构建方法必须自带 `_popupHidingDialogDepth` 判据'
              '（BUG-1364）');
    });

    test('barrier 判据函数真的用了传进去的 hiddenByDialog', () {
      // 宿主侧只证明"计数被传进去了"，用没用得看被调函数自己——不补这条，
      // 把 `shouldShowLookupDismissBarrier` 的实现改成忽略该参数，上面全绿。
      final String src = _read(_kPopupLayerPath);
      final String masked = maskComments(src);
      final int start = masked.indexOf('bool shouldShowLookupDismissBarrier(');
      expect(start, greaterThanOrEqualTo(0),
          reason: '找不到 barrier 判据函数（注释里的同名文本不算）');
      final int end = masked.indexOf(';', start);
      expect(end, greaterThan(start));
      expect(src.substring(start, end), contains('!hiddenByDialog'),
          reason: 'BUG-1327：对话框打开时一律不挂 barrier');
    });
  });
}
