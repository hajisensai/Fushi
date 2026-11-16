import 'dart:io';

import 'package:test/test.dart';

/// 禁止「零尺寸菜单锚点」（BUG-4715）：`MenuAnchor` / `FushiMenuAnchor` 的锚点
/// 本身是 `SizedBox.shrink()`、再由别处的按钮经 MenuController 打开——菜单从
/// 那个零尺寸盒子弹出，与真正点下去的按钮对不上（库页「排序」菜单曾叠在页头
/// 动作组右下角，排序按钮不在最右端时菜单就偏到别处）。
///
/// 红了：菜单要么直接包住触发它的按钮（`builder` / `child` 就是按钮），要么
/// 触发者可能被卸载（页头动作收进 ⋯）时用 `FushiHeaderMenuAnchor` +
/// `FushiHeaderMenuController`，弹出位置跟着触发控件走。
void main() {
  test('判据自校验：认得零尺寸锚点，不误伤正常锚点', () {
    const List<String> zeroSize = <String>[
      'FushiMenuAnchor(controller: c, menuChildren: <Widget>[], '
          'child: const SizedBox.shrink(),)',
      'MenuAnchor(\n  menuChildren: <Widget>[a(b(c))],\n  '
          'child: SizedBox.shrink(),\n)',
    ];
    for (final String snippet in zeroSize) {
      expect(zeroSizeMenuAnchors(snippet), hasLength(1), reason: snippet);
    }
    const List<String> healthy = <String>[
      'FushiMenuAnchor(menuChildren: <Widget>[], builder: (c, m, _) => btn)',
      // 嵌套在菜单项里的 shrink 不是锚点本身。
      'MenuAnchor(menuChildren: <Widget>[Item(child: const SizedBox.shrink())],'
          ' child: IconButton(onPressed: f, icon: i))',
      'FushiHeaderMenuAnchor(controller: c, menuChildren: x)',
      'MyMenuAnchorish(child: const SizedBox.shrink())',
    ];
    for (final String snippet in healthy) {
      expect(zeroSizeMenuAnchors(snippet), isEmpty, reason: snippet);
    }
  });

  test('lib/ 里没有零尺寸菜单锚点', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String source = entity.readAsStringSync();
      for (final int offset in zeroSizeMenuAnchors(source)) {
        final int line = '\n'.allMatches(source.substring(0, offset)).length;
        offenders.add('${entity.path.replaceAll(r'\', '/')}:${line + 1}');
      }
    }
    expect(offenders, isEmpty, reason: '零尺寸菜单锚点：\n${offenders.join('\n')}');
  });
}

/// `MenuAnchor(` / `FushiMenuAnchor(` 调用的**顶层**实参里 `child:` 是零尺寸
/// 盒子的，返回调用起点偏移。嵌套在其他实参（菜单项等）里的 `child:` 不算。
List<int> zeroSizeMenuAnchors(String source) {
  final RegExp call = RegExp(r'(?<![A-Za-z0-9_])(?:Fushi)?MenuAnchor\(');
  final RegExp zeroChild = RegExp(
    r'^\s*child:\s*(?:const\s+)?SizedBox\.shrink\(\)\s*$',
  );
  final List<int> hits = <int>[];
  for (final RegExpMatch m in call.allMatches(source)) {
    int depth = 1;
    final StringBuffer topLevel = StringBuffer();
    for (int i = m.end; i < source.length && depth > 0; i++) {
      final String ch = source[i];
      if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ')' || ch == ']' || ch == '}') {
        depth--;
        if (depth == 0) break;
      }
      // 顶层实参之间的分隔记成换行，便于逐个实参匹配；嵌套内容不记。
      if (depth == 1) {
        topLevel.write(ch == ',' ? '\n' : ch);
      } else if (depth == 2 && (ch == '(' || ch == '[' || ch == '{')) {
        topLevel.write(ch);
      }
    }
    final bool zero = topLevel
        .toString()
        .split('\n')
        .any((String arg) => zeroChild.hasMatch(arg));
    if (zero) hits.add(m.start);
  }
  return hits;
}
