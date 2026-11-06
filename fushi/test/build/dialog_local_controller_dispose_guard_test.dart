import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-4219 守卫：函数里自己建的输入控制器（`TextEditingController` / `FocusNode` /
/// `ScrollController`）交给弹窗 / 底部弹层用，又在同一个函数里 `await` 完弹窗后
/// 自己 `dispose()`——这是错的：`await` 返回时弹窗还在播关闭动画、输入框还在重建，
/// 撞上「控制器已释放」异常并拖垮元素树（互联配对一成功就红屏）。
///
/// 正确做法：用 `showFushiTextInputDialog`，或把弹窗内容写成自己的 StatefulWidget，
/// 控制器放在它的 State 里、在 `State.dispose` 释放（路由真正移除时才会走到）。
void main() {
  test('lib/ 里没有「await 弹窗后立刻释放调用方自建控制器」', () {
    final RegExp decl = RegExp(
      r'^\s*(?:final|var|late final)?\s*'
      r'(?:(?:TextEditingController|FocusNode|ScrollController)\??\s+)?'
      r'(\w+)\s*=\s*(?:TextEditingController|FocusNode|ScrollController)\(',
    );
    final RegExp showsOverlay = RegExp(r'show\w*(?:Dialog|Sheet)\w*\s*[<(]');
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart')) continue;
      scanned++;
      final List<String> lines = e.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final RegExpMatch? m = decl.firstMatch(lines[i]);
        if (m == null) continue;
        final String name = m.group(1)!;
        // 字段（`_x = ...`）归所在 State 管，不在此列。
        if (name.startsWith('_')) continue;
        final RegExp disposeCall = RegExp(
          r'\b' + RegExp.escape(name) + r'\.dispose\(\)',
        );
        final int end = (i + 400).clamp(0, lines.length);
        for (int j = i + 1; j < end; j++) {
          if (!disposeCall.hasMatch(lines[j])) continue;
          final String body = lines.sublist(i, j).join('\n');
          if (showsOverlay.hasMatch(body) && body.contains('await')) {
            offenders.add('${e.path}:${j + 1} ($name)');
          }
          break;
        }
      }
    }
    expect(scanned, greaterThan(500), reason: '没扫到 lib/ 源码，守卫空转');
    expect(
      offenders,
      isEmpty,
      reason:
          '这些控制器在 await 弹窗后被调用方释放，关窗动画期间会撞上已释放异常；'
          '改用 showFushiTextInputDialog 或把控制器放进弹窗自己的 State：\n'
          '${offenders.join('\n')}',
    );
  });
}
