import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-926 守卫：视频卡封面区必须锁定精确 16:9。
///
/// 根因：封面此前用 `Expanded` 吃掉「cell 高 − 下方文字块实际高度」的剩余，而文字块
/// 高度随标题行数 / 有无观看进度浮动，文字不足时多出的空间灌进封面区、使其高于
/// 16:9，16:9 封面 `BoxFit.contain` 后上下留空隙（标题短或无进度时才现，「时有时无」）。
/// 修复：封面 Stack 改由 `AspectRatio(aspectRatio: 16 / 9)` 包裹，与文字长短彻底解耦；
/// 文字块下移进 `Expanded`（占封面下方剩余固定高度，ellipsis 内收）。
///
/// 这是源码扫描守卫——封面是 UI 渲染难做像素断言，故锚定到两张视频卡（本地
/// `_buildCard` + 远端 `_buildRemoteVideoCard`）的函数体，断言封面被 16:9 AspectRatio
/// 锁定、且不得回退到 `Expanded(child: Stack(...))` 的浮动比例写法。
void main() {
  const String path = 'lib/src/pages/implementations/home_video_page.dart';

  test('video card covers are pinned to a 16:9 AspectRatio (no gap) — BUG-926',
      () {
    final String source = File(path).readAsStringSync();

    final Map<String, String> bodies = <String, String>{
      '_buildCard': _functionSource(source, 'Widget _buildCard('),
      '_buildRemoteVideoCard':
          _functionSource(source, 'Widget _buildRemoteVideoCard('),
    };

    // 封面 Stack 直接被 Expanded 包裹 = 比例随剩余空间浮动的回归写法（BUG-926 根因）。
    final RegExp expandedCover =
        RegExp(r'Expanded\(\s*child: Stack\(\s*fit: StackFit\.expand');

    for (final MapEntry<String, String> entry in bodies.entries) {
      final String name = entry.key;
      final String body = entry.value;

      expect(
        body,
        contains('aspectRatio: 16 / 9'),
        reason: '$name 的封面必须用 AspectRatio(aspectRatio: 16 / 9) 锁定精确 16:9，'
            '标准 16:9 封面才不留空隙',
      );
      expect(
        body,
        isNot(contains(expandedCover)),
        reason: '$name 封面不得用 Expanded(child: Stack(...)) 包裹——比例会随下方'
            '文字块高度浮动、把空隙灌回封面区（BUG-926 回归）',
      );
    }
  });
}

/// 截取从 [startToken] 起到下一个顶层 `  Widget xxx(` 方法定义之前的源码片段。
String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
