import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2889 — WS_EX_NOACTIVATE 只挡**鼠标**点击激活。触摸 / 触控笔按下另发
/// WM_POINTERACTIVATE（DefWindowProc 回 PA_ACTIVATE），窗口照样变前台。盖在游戏上的
/// 划词条 / 工具条一被手指点到，游戏就失去前台，宿主「点卡外吞点击」随之失效
/// （BUG-2788 同一个坑，那次只修了查词卡）。
///
/// 这里不按文件点名，而是扫 runner 里**每一个** `CreateWindowEx` 调用：扩展样式字面量
/// 含 WS_EX_NOACTIVATE、又不是命中测试恒穿透（WS_EX_TRANSPARENT）的窗口，所在文件
/// 必须把两条激活请求一起交给共用策略 `OverlayNoActivateReply`。以后新加的覆盖窗口
/// 自动落进扫描面。扩展样式写成变量的（主窗口测试模式 `ex_style`）不在此列；
/// 系统 tooltip 类不收指针输入，也不在此列。
const String _runner = 'windows/runner';

/// 从 `(` 之后起，取前 [count] 个顶层逗号分隔的实参。
List<String> _leadingArgs(String src, int openParen, int count) {
  final List<String> args = <String>[];
  int depth = 0;
  final StringBuffer cur = StringBuffer();
  for (int i = openParen + 1; i < src.length && args.length < count; i++) {
    final String c = src[i];
    if (c == '(') depth++;
    if (c == ')') {
      if (depth == 0) {
        args.add(cur.toString().trim());
        break;
      }
      depth--;
    }
    if (c == ',' && depth == 0) {
      args.add(cur.toString().trim());
      cur.clear();
      continue;
    }
    cur.write(c);
  }
  return args;
}

/// 扩展样式实参是同文件里的无参 helper（查词卡的 `OverlayCreateExStyle()`）时，
/// 换成那个函数体原文再判，免得样式一抽成函数就悄悄掉出扫描面。
String _resolveStyleHelper(String src, String arg) {
  final RegExpMatch? call = RegExp(r'^(\w+)\(\)$').firstMatch(arg);
  if (call == null) return arg;
  final RegExpMatch? def = RegExp(
    '\\b${call.group(1)}\\(\\)\\s*(?:const\\s*)?(?:noexcept\\s*)?\\{',
  ).firstMatch(src);
  if (def == null) return arg;
  final int end = src.indexOf('\n}\n', def.end);
  return src.substring(def.start, end < 0 ? src.length : end);
}

final RegExp _sharedReply = RegExp(
  r'case WM_POINTERACTIVATE:\s*case WM_MOUSEACTIVATE:\s*'
  r'return OverlayNoActivateReply\(message\);',
);

void main() {
  final List<File> sources = Directory(_runner)
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.cpp'))
      .toList();

  /// 文件名 → 该文件里需要不激活回复的窗口（扩展样式实参原文）。
  Map<String, List<String>> overlayWindows() {
    final Map<String, List<String>> out = <String, List<String>>{};
    final RegExp call = RegExp(r'CreateWindowExW?\(');
    for (final File f in sources) {
      final String src = maskComments(
        f.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final RegExpMatch m in call.allMatches(src)) {
        final List<String> args = _leadingArgs(src, m.end - 1, 2);
        if (args.length < 2) continue;
        final String ex = _resolveStyleHelper(src, args[0]);
        if (!ex.contains('WS_EX_NOACTIVATE')) continue;
        if (ex.contains('WS_EX_TRANSPARENT')) continue;
        if (args[1].contains('TOOLTIPS_CLASS')) continue;
        out.putIfAbsent(f.uri.pathSegments.last, () => <String>[]).add(ex);
      }
    }
    return out;
  }

  test('扫描面非空：至少认出划词条、工具条、查词卡与悬浮球', () {
    final Set<String> files = overlayWindows().keys.toSet();
    expect(
      files,
      containsAll(<String>[
        'floating_lyric_window.cpp',
        'hook_toolbar_window.cpp',
        'global_lookup_window.cpp',
        'floating_ball_window.cpp',
        'attached_text_surface_window.cpp',
      ]),
    );
  });

  test('每个不激活覆盖窗：触摸 / 触控笔按下也走 OverlayNoActivateReply', () {
    final List<String> missing = <String>[];
    overlayWindows().forEach((String file, List<String> styles) {
      final String src = File(
        '$_runner/$file',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      if (!_sharedReply.hasMatch(src) ||
          !src.contains('#include "window_activation_policy.h"')) {
        missing.add('$file（${styles.join(' ; ')}）');
      }
    });
    expect(
      missing,
      isEmpty,
      reason:
          '这些窗口被手指点到会抢走前台：缺 '
          'case WM_POINTERACTIVATE: case WM_MOUSEACTIVATE: '
          'return OverlayNoActivateReply(message);',
    );
  });

  test('runner 里不再有只挡鼠标的裸 MA_NOACTIVATE 回复', () {
    final List<String> offenders = <String>[
      for (final File f in sources)
        if (maskComments(
          f.readAsStringSync(),
        ).contains('return MA_NOACTIVATE;'))
          f.uri.pathSegments.last,
    ];
    expect(
      offenders,
      isEmpty,
      reason: '只回 MA_NOACTIVATE 时 WM_POINTERACTIVATE 仍落 DefWindowProc',
    );
  });
}
