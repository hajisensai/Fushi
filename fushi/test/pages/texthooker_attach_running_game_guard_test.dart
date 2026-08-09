// 「附着到已在运行的游戏」一级入口的源码接线守卫。
//
// 背景：injector 的 `--pid` attach 与 GalHookSessionController.startAttachedCapture
// 的完整注入编排一直都在，但唯一 UI 入口是「更多」溢出菜单里那个叫「外部窗口挖矿」的
// 模式开关——名字看不出是「附着到已经在跑的游戏」，用户只能每次都让 Hibiki 把游戏拉起来
// 才能捕获。这里钉住三条：
//  ① 工具栏一级按钮存在（与「启动并捕获」并列，不再退回溢出菜单）；
//  ② 附着动作直接走 startAttachedCapture，**不得**改回「bindWindow +
//     setExternalWindowMode」两步拼装——那两个方法各自都会在另一半就位时触发
//     startAttachedCapture，连着调会起两次会话，第二次把第一次刚装好的 engine hook
//     和已收台词一起丢掉；
//  ③ 已在捕获同一窗口时是 no-op，不重启会话。
//
// 守卫读源码字符串而不 import 页面：按钮只在 Platform.isWindows 下构建，而 CI 单测门跑
// 在 Linux 上，widget 渲染断言在那里恒为空。
//
// 注意：② 的断言必须只看**方法体**，不能扫全文件——本文件与页面 dartdoc 里都写着
// 「setExternalWindowMode」这些词用于解释为什么不能那么写，扫全文件会让守卫恒绿。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取 [signature]（须一路匹配到方法体的开花括号）对应的方法体，用于把断言限制在实现内，
/// 避开 dartdoc 里为解释反例而出现的同名符号。
///
/// 用花括号配对而不是「找同缩进的 `\n  }`」：带命名参数的签名本身就跨行且含 `{...}`
/// （如 `_buildToolbarActions(BuildContext context, {required bool embedded})`），
/// 缩进猜测会把参数列表的闭合当成方法结束，取到空体让所有断言恒绿。
String _methodBody(String src, RegExp signature) {
  final Match? match = signature.firstMatch(src);
  expect(match, isNotNull, reason: '未找到方法签名：${signature.pattern}');
  final int bodyStart = match!.end;
  int depth = 1;
  int i = bodyStart;
  while (i < src.length && depth > 0) {
    final String c = src[i];
    if (c == '{') depth++;
    if (c == '}') depth--;
    i++;
  }
  expect(depth, 0, reason: '${signature.pattern} 的方法体花括号未闭合');
  return src.substring(bodyStart, i - 1);
}

final RegExp _toolbarSig =
    RegExp(r'List<Widget> _buildToolbarActions\([\s\S]*?\)\s*\{');
final RegExp _attachSig =
    RegExp(r'Future<void> _attachToRunningGame\(\)\s*async\s*\{');
final RegExp _pickSig =
    RegExp(r'Future<void> _pickExternalWindow\(\)\s*async\s*\{');

void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/texthooker_page.dart')
          .readAsStringSync();

  group('附着到运行中的游戏：一级入口存在', () {
    test('工具栏有 attach 按钮且接到 _attachToRunningGame', () {
      final String toolbar = _methodBody(pageSrc, _toolbarSig);
      expect(toolbar.contains('t.game_attach_and_capture'), isTrue,
          reason: '附着入口必须是工具栏一级按钮，不能退回「更多」溢出菜单');
      expect(toolbar.contains('onTap: _attachToRunningGame'), isTrue,
          reason: 'attach 按钮必须接到附着动作');
      expect(toolbar.contains('t.game_launch_and_capture'), isTrue,
          reason: '「启动并捕获」仍须并列存在——两条起点都是主路径');
    });

    test('附着动作有独立方法', () {
      expect(
        RegExp(r'Future<void> _attachToRunningGame\(\) async \{')
            .hasMatch(pageSrc),
        isTrue,
        reason: '附着动作须是独立方法，便于工具栏与后续入口共用',
      );
    });
  });

  group('附着动作不得退回双启动拼装', () {
    test('方法体直接调 startAttachedCapture', () {
      final String body = _methodBody(pageSrc, _attachSig);
      expect(body.contains('startAttachedCapture('), isTrue,
          reason: '附着必须一步起会话');
    });

    test('方法体不得出现 bindWindow / setExternalWindowMode', () {
      final String body = _methodBody(pageSrc, _attachSig);
      expect(body.contains('setExternalWindowMode'), isFalse,
          reason: 'bindWindow 与 setExternalWindowMode 各自都会触发 '
              'startAttachedCapture，拼装会起两次会话并丢掉已装好的 hook');
      expect(body.contains('bindWindow'), isFalse,
          reason: '同上：附着路径不经绑定方法，startAttachedCapture 自己会把 '
              'externalWindowMode / boundWindow / gamePid 一次设对');
    });

    test('已在捕获同一窗口时不重启会话', () {
      final String body = _methodBody(pageSrc, _attachSig);
      expect(body.contains('state.isActive'), isTrue, reason: '须先判当前是否已在捕获');
      expect(body.contains('boundWindow?.hwnd == picked.hwnd'), isTrue,
          reason: '选回正在捕获的同一窗口必须 no-op，否则重启会丢已收台词');
    });
  });

  group('选择器只负责选，处置交调用方', () {
    test('存在只返回选中窗口的 picker', () {
      expect(
        RegExp(r'Future<ExternalWindowInfo\?> _showExternalWindowPicker\(\)')
            .hasMatch(pageSrc),
        isTrue,
        reason: '「附着并捕获」与「绑定窗口」对同一份列表有两种后续处置，'
            '把处置塞进选择器会逼出模式参数',
      );
    });

    test('_pickExternalWindow 仍走绑定路径（旧入口行为不变）', () {
      final String body = _methodBody(pageSrc, _pickSig);
      expect(body.contains('_showExternalWindowPicker()'), isTrue,
          reason: '旧入口复用同一个选择器');
      expect(body.contains('_session.bindWindow(picked)'), isTrue,
          reason: '旧入口语义是「绑定」，不得改成直接起捕获');
    });
  });
}
