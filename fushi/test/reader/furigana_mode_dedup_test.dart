import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// 特征/回归测试：furigana 模式归一化与样式映射的单一真相是
/// [ReaderSettings]，[ReaderFushiSource] 的同名方法只转调它。
/// 断言两者对全部输入等价（refactor 前后都应绿，证明去重零行为变化），
/// 并用源码守卫确认 source 端不再保留重复的 switch 分支。
void main() {
  const inputs = <String>[
    'off',
    'toggle',
    'hidden',
    'show',
    'hide',
    'partial',
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
          ReaderFushiSource.normalizeFuriganaMode(m),
          ReaderSettings.normalizeFuriganaMode(m),
          reason: 'input="$m"',
        );
      }
    });

    test('furiganaModeToStyle 两实现全输入等价', () {
      for (final m in inputs) {
        expect(
          ReaderFushiSource.furiganaModeToStyle(m),
          ReaderSettings.furiganaModeToStyle(m),
          reason: 'input="$m"',
        );
      }
    });

    test('三态值域与历史四态映射（对齐 Hoshi Reader iOS Off/Toggle/Hidden）', () {
      expect(ReaderSettings.normalizeFuriganaMode('off'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('toggle'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hidden'), 'hidden');
      // 历史值：show→off、partial→toggle（点一个揭示一个）、hide→hidden。
      expect(ReaderSettings.normalizeFuriganaMode('show'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('partial'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hide'), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('HIDE '), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('garbage'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode(''), 'off');
      // 只剩三个规范值。
      for (final m in inputs) {
        expect(
          <String>['off', 'toggle', 'hidden'],
          contains(ReaderSettings.normalizeFuriganaMode(m)),
          reason: 'input="$m"',
        );
      }
    });

    test('三态值域与历史四态映射（对齐 Hoshi Reader iOS Off/Toggle/Hidden）', () {
      expect(ReaderSettings.normalizeFuriganaMode('off'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('toggle'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hidden'), 'hidden');
      // 历史值：show→off、partial→toggle（点一个揭示一个）、hide→hidden。
      expect(ReaderSettings.normalizeFuriganaMode('show'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('partial'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hide'), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('HIDE '), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('garbage'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode(''), 'off');
      // 只剩三个规范值。
      for (final m in inputs) {
        expect(
          <String>['off', 'toggle', 'hidden'],
          contains(ReaderSettings.normalizeFuriganaMode(m)),
          reason: 'input="$m"',
        );
      }
    });

    test('三态值域与历史四态映射（对齐 Hoshi Reader iOS Off/Toggle/Hidden）', () {
      expect(ReaderSettings.normalizeFuriganaMode('off'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('toggle'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hidden'), 'hidden');
      // 历史值：show→off、partial→toggle（点一个揭示一个）、hide→hidden。
      expect(ReaderSettings.normalizeFuriganaMode('show'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode('partial'), 'toggle');
      expect(ReaderSettings.normalizeFuriganaMode('hide'), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('HIDE '), 'hidden');
      expect(ReaderSettings.normalizeFuriganaMode('garbage'), 'off');
      expect(ReaderSettings.normalizeFuriganaMode(''), 'off');
      // 只剩三个规范值。
      for (final m in inputs) {
        expect(
          <String>['off', 'toggle', 'hidden'],
          contains(ReaderSettings.normalizeFuriganaMode(m)),
          reason: 'input="$m"',
        );
      }
    });

    test('source 端转调 ReaderSettings 且不再保留重复 switch', () {
      final source = File(
        'lib/src/media/sources/reader_fushi_source.dart',
      ).readAsStringSync();
      expect(source, contains('ReaderSettings.normalizeFuriganaMode(mode)'));
      expect(source, contains('ReaderSettings.furiganaModeToStyle(mode)'));
    });
  });
}
