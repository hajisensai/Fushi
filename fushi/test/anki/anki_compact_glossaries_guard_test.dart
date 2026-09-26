import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// issue #1432 源码守卫：制卡「紧凑释义」开关只在 Dart 侧落地。
///
/// 根因是 popup.js 导出释义时判断 `window.compactGlossariesAnki`，而生产代码从来
/// 没有给它赋值——开关是死的。修复把样式挪到握着 `AnkiSettings` 的制卡后端，在
/// payload 进 handlebar 渲染之前注入（`compactAnkiGlossaryHtml` /
/// `compactAnkiGlossaryMap`）。这里锁住两件事：
///  1. 三份 popup.js 里不再出现那个无人赋值的全局（再加回来又是一个死开关）；
///  2. 每个重建 `AnkiMiningPayload` 的制卡后端都经紧凑样式 helper 传释义，
///     不再原样透传 `payload.glossary` / `glossaryFirst` / `singleGlossaries`。
///
/// flutter test cwd 是 fushi 包根。
void main() {
  const List<String> popupMirrors = <String>[
    'assets/popup/popup.js',
    'assets/browser_extension/vendor/popup.js',
    '../tools/browser-extension/vendor/popup.js',
  ];

  test('popup.js 三份镜像不再读无人赋值的 compactGlossariesAnki', () {
    for (final String path in popupMirrors) {
      final String src = File(path).readAsStringSync();
      expect(src, isNot(contains('compactGlossariesAnki')), reason: path);
      expect(src, isNot(contains('COMPACT_GLOSSARIES_ANKI')), reason: path);
    }
  });

  test('制卡后端重建 payload 时释义一律经紧凑样式 helper', () {
    final RegExp rawPassThrough = RegExp(
      r'\b(glossary|glossaryFirst|singleGlossaries):\s*payload\.'
      r'(glossary|glossaryFirst|singleGlossaries),',
    );
    final List<String> roots = <String>['lib', '../packages/fushi_anki/lib'];
    final List<String> offenders = <String>[];
    for (final String root in roots) {
      for (final FileSystemEntity f in Directory(
        root,
      ).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String src = f.readAsStringSync();
        if (rawPassThrough.hasMatch(src)) offenders.add(f.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件原样透传了释义字段，绕过了「紧凑释义」开关（issue #1432）；'
          '改用 compactAnkiGlossaryHtml / compactAnkiGlossaryMap',
    );

    for (final String path in <String>[
      '../packages/fushi_anki/lib/src/base_anki_repository.dart',
      'lib/src/anki/ankimobile_repository.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(
        'compactAnkiGlossaryHtml('.allMatches(src),
        hasLength(2),
        reason: '$path：{glossary} 与 {glossary-first} 两个字段',
      );
      expect(src, contains('compactAnkiGlossaryMap('), reason: path);
      expect(
        src,
        contains('settings.compactGlossaries'),
        reason: '$path：开关必须取自本次制卡的 AnkiSettings',
      );
    }
  });
}
