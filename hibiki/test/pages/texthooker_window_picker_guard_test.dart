import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1049 的静态守卫：捕获目标的窗口选择器必须把 **Hibiki 自己启动的游戏**当成
/// 已选中的那一项。
///
/// 用户实测：从 Hibiki 启动游戏后点「捕获目标」条，弹出的窗口列表把游戏和一屏无关
/// 窗口平铺在一起、没有任何预选，等于让用户替 app 认它刚拉起来的进程。
///
/// 这条路径没法用 widget 测试可移植地覆盖：选择器首行就是 `Platform.isWindows` 门
/// （非 Windows CI 直接短路），窗口列表来自静态 `WindowCaptureChannel`，会话又是
/// 单例。故在源码层锁住修复结构。
///
/// **锚点为什么不写死方法名**：「列窗口给用户挑」与「挑完之后怎么处置」一度挤在
/// `_pickExternalWindow` 一个方法里；「附着到已在运行的游戏」（PR#724）要用同一份
/// 列表配另一种处置，选择器 UI 因此被提到独立的 `_showExternalWindowPicker`。守卫
/// 原先焊在 `_pickExternalWindow` 的方法体上，这次拆分一落地三条断言就整体飘进只剩
/// 处置逻辑的旧方法里，全部转红——看起来像功能坏了，实际是守卫塌了。所以两处窗口
/// 都改用**语义判据**认，拆分前后两种结构都守得住：
/// - 选择器 = 真的建了 `showAppDialog<ExternalWindowInfo>` 的那个方法；
/// - 处置 = 真的调 `_session.bindWindow(` 的那个方法。
/// 认不出来一律 `fail`，绝不静默锚到别处。
void main() {
  final String source = File(
    'lib/src/pages/implementations/texthooker_page.dart',
  ).readAsStringSync();

  /// 候选签名按「拆分后 → 拆分前」排，命中后还要用语义判据复核，序号本身不作数。
  const List<String> pickerCandidates = <String>[
    'Future<ExternalWindowInfo?> _showExternalWindowPicker()',
    'Future<void> _pickExternalWindow()',
  ];

  /// 窗口选择器 UI 所在方法的方法体（惰性求值：`expect` / `fail` 只能在 test 里调）。
  String pickerBody() {
    for (final String signature in pickerCandidates) {
      if (!containsCodeLine(source, signature)) continue;
      final String body = methodBody(source, signature);
      if (containsCodeLine(body, 'showAppDialog<ExternalWindowInfo>')) {
        return body;
      }
    }
    fail('找不到承载窗口选择器对话框（showAppDialog<ExternalWindowInfo>）的方法。'
        '候选签名：${pickerCandidates.join(' / ')}。'
        '选择器又被挪走了就把新签名加进候选表，别删断言。');
  }

  /// 截出「把窗口列表排好序」那条语句的原文：从声明锚点起，按括号配对找到语句
  /// 结尾的 `;`。用**语句边界**而不是定长字符窗口——多写一行属性就漂出窗口、
  /// 或反过来把下一条语句读进来，两个方向都会让断言指向错误的对象。
  ///
  /// 断言必须关在这条语句里：`w.pid == gamePid` 这种短锚点在整个方法体上做子串
  /// 匹配会被同一方法里 `trailing: ... window.pid == gamePid` 的**更长标识符**
  /// 喂成假绿（`window.pid` 的尾巴就是 `w.pid`）——排序真被改坏了守卫照样绿，
  /// 本次变异实测抓到的就是这一条。
  String orderingStatement(String body) {
    const String anchor = 'final List<ExternalWindowInfo> ordered =';
    final String structural = maskCommentsAndStrings(body);
    final int start = structural.indexOf(anchor);
    if (start < 0) {
      fail('选择器里找不到窗口排序语句的锚点：$anchor。'
          '排序被挪走或改名了就更新锚点，别删断言。');
    }
    int depth = 0;
    for (int i = start; i < structural.length; i++) {
      final String c = structural[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth--;
      if (c == ';' && depth == 0) return body.substring(start, i + 1);
    }
    fail('窗口排序语句没有以 `;` 收口（括号不配对）：$anchor');
  }

  /// 「挑完窗口之后怎么处置」所在方法的方法体：绑定意图那一路。
  String bindIntentBody() {
    const String signature = 'Future<void> _pickExternalWindow()';
    expect(containsCodeLine(source, signature), isTrue,
        reason: '绑定意图入口 $signature 不见了，选回已绑定窗口的 no-op 守卫无处可锚');
    final String body = methodBody(source, signature);
    expect(containsCodeLine(body, '_session.bindWindow('), isTrue,
        reason: '$signature 必须是把选择结果交给 bindWindow 的那一路，'
            '否则下面的 no-op 判据锚错了对象');
    return body;
  }

  test('窗口列表按会话 gamePid 把当前游戏排到最前', () {
    final String body = pickerBody();
    expect(containsCodeLine(body, '_session.state.gamePid'), isTrue,
        reason: '会话已经知道自己启动的游戏 pid，选择器必须用上它');
    // 列表是「命中 gamePid 的一段」+「其余」两段拼起来的，且命中的那段必须在前。
    final String ordering = maskComments(orderingStatement(body));
    final int matching = ordering.indexOf('pid == gamePid');
    final int rest = ordering.indexOf('pid != gamePid');
    expect(matching, isNonNegative,
        reason: '排序语句里必须有一段按 `pid == gamePid` 挑出当前游戏的窗口');
    expect(rest, isNonNegative,
        reason: '排序语句里必须有互补的一段按 `pid != gamePid` 收尾其余窗口');
    expect(matching, lessThan(rest),
        reason: 'Hibiki 启动的游戏窗口应排在列表最前，命中段必须拼在其余段之前');
  });

  test('当前游戏那一项预置焦点（打开即选中、回车即绑）', () {
    // 只断言「出现过 autofocus:」不够：把它写成常量 false 或挂到无关那一行，
    // 焦点驱动照样丢。这里取实参表达式本身，要求它由会话认定的游戏 pid 决定。
    final List<String> values = namedArgumentValues(pickerBody(), 'autofocus');
    expect(values, isNotEmpty,
        reason: 'BUG-1049：列表项必须有 autofocus，打开即落在正确窗口上、回车就绑');
    expect(values.any((String v) => v.contains('gamePid')), isTrue,
        reason: '预置焦点必须落在会话认定的游戏窗口那一行，'
            '而不是列表第一项或某个常量；实参现在是：${values.join(' | ')}');
  });

  test('选回已绑定的窗口是 no-op，不重启会话', () {
    // bindWindow 在捕获模式下会 startAttachedCapture 重启整条会话（launch 会话
    // 会退化成 attach，正在跑的 engine hook 与已收台词一起丢）。
    final String body = bindIntentBody();
    final String masked = maskComments(body);
    // 判据是「和当前已绑定窗口的 hwnd 比中了就直接 return」，与写成局部变量还是
    // 直接读会话无关：`) return;` 与 `) { return; }` 两种落地形态都认。
    final RegExpMatch? guard = RegExp(
      r'picked\.hwnd\s*==\s*([\w.?]+)\s*\)\s*\{?\s*return\s*;',
    ).firstMatch(masked);
    expect(guard, isNotNull,
        reason: '选回已绑定窗口必须立刻 return，不能落到 _session.bindWindow(');
    final String boundExpr = guard!.group(1)!;
    final bool readsSessionBound =
        boundExpr.contains('_session.state.boundWindow?.hwnd') ||
            RegExp('${RegExp.escape(boundExpr)}\\s*=\\s*'
                    r'_session\.state\.boundWindow\?\.hwnd')
                .hasMatch(masked);
    expect(readsSessionBound, isTrue,
        reason: '比较的右侧必须真的是会话当前已绑定窗口的 hwnd，'
            '现在比的是 `$boundExpr`');
  });
}
