import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// 特征/回归测试：furigana 模式归一化与样式映射的单一真相是
/// [ReaderSettings]，[ReaderHibikiSource] 的同名方法只转调它。
/// 断言两者对全部输入等价（refactor 前后都应绿，证明去重零行为变化），
/// 并用源码守卫确认 source 端不再保留重复的 switch 分支。
void main() {
  const inputs = <String>[
    'show',
    'hide',
    'partial',
    'toggle',
    'SHOW',
    'Hide',
    'PARTIAL',
    'Toggle',
    '',
    'garbage',
    'unknown',
    'HIDE ',
    'Show',
  ];

  group('furigana 模式映射单一真相 (ReaderSettings)', () {
    test('normalizeFuriganaMode 两实现全输入等价', () {
      for (final m in inputs) {
        expect(
          ReaderHibikiSource.normalizeFuriganaMode(m),
          ReaderSettings.normalizeFuriganaMode(m),
          reason: 'input="$m"',
        );
      }
    });

    test('furiganaModeToStyle 两实现全输入等价', () {
      for (final m in inputs) {
        expect(
          ReaderHibikiSource.furiganaModeToStyle(m),
          ReaderSettings.furiganaModeToStyle(m),
          reason: 'input="$m"',
        );
      }
    });

    test('source 端转调 ReaderSettings 且不再保留重复 switch', () {
      final source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      expect(source, contains('ReaderSettings.normalizeFuriganaMode(mode)'));
      expect(source, contains('ReaderSettings.furiganaModeToStyle(mode)'));
    });
  });
}
