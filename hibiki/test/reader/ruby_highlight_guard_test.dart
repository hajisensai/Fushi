import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-110 回归守卫（源码扫描；`::highlight` 在真 WebView 内的 ruby 渲染 headless
/// 不可跑，故守结构契约）。
///
/// 现象：竖排书里有声书跟随高亮 / 查词高亮在带振假名（`<ruby>`）的字上出现一条
/// 深色横带遮住文字一部分。真机 `getClientRects` 证实：竖排下 `::highlight()` 把
/// `<ruby>` 基字矩形**重复绘制**（同一矩形出现两次），两层半透明背景叠加 → 变深。
///
/// 修复（移植 Hoshi-Reader-Android）：cue / 选区里位于 `<ruby>` 内的节点**不放进
/// `::highlight` range**，改把 `<ruby>` 元素本身收集起来、高亮时加 class
/// （`hoshi-sasayaki-ruby-active` / `hoshi-selection-ruby-active`），背景画在元素上
/// 只画一遍；普通文字仍走 `::highlight`。清除时移除 class。
///
/// 谁把 ruby 节点放回 `::highlight` range（删掉 rubyForNode 分流 / ruby class），
/// 本测试红。
void main() {
  final String pagination = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();
  final String selection = File(
    'lib/src/reader/reader_selection_scripts.dart',
  ).readAsStringSync();
  final String styles = File(
    'lib/src/reader/reader_content_styles.dart',
  ).readAsStringSync();

  group('BUG-110 ruby 高亮改元素 class（消竖排深色带）', () {
    test('sasayaki：ruby 节点分流出 ::highlight，改加 ruby class', () {
      expect(pagination, contains('cueRubyElements'),
          reason:
              'sasayaki 须用 cueRubyElements 单独存 <ruby> 元素，不混进 ::highlight range');
      expect(pagination, contains('rubyForNode'),
          reason: '须用 rubyForNode 判定节点是否在 <ruby> 内以分流');
      expect(pagination, contains('hoshi-sasayaki-ruby-active'),
          reason:
              'sasayaki 的 ruby 元素须用 class hoshi-sasayaki-ruby-active 高亮（单次绘背景）');
    });

    test('selection：ruby 节点分流出 ::highlight，改加 ruby class', () {
      expect(selection, contains('rubyForNode'),
          reason: '查词高亮须用 rubyForNode 分流 <ruby> 内节点');
      expect(selection, contains('hoshi-selection-ruby-active'),
          reason: '查词的 ruby 元素须用 class hoshi-selection-ruby-active 高亮');
      expect(selection, contains('clearSelectionRubyHighlights'),
          reason: '清除选区时须移除 ruby class，避免残留');
    });

    test('CSS：两个 ruby-active class 都有背景规则', () {
      expect(styles, contains('ruby.hoshi-sasayaki-ruby-active'),
          reason: 'reader CSS 须给 ruby.hoshi-sasayaki-ruby-active 设背景');
      expect(styles, contains('ruby.hoshi-selection-ruby-active'),
          reason: 'reader CSS 须给 ruby.hoshi-selection-ruby-active 设背景');
    });
  });

  // BUG-123：整块涂 <ruby> 背景会把 <rt> 振假名列/行一并涂上，令带 ruby 的字高亮
  // 比相邻无 ruby 的字更宽/更高（“双重高亮”）。修复＝用不透明阅读器背景色遮住
  // 选区 active ruby 的 rt/rp，使高亮只剩基字列。无头 Chromium 复现+验证；这里守
  // CSS 结构契约（删掉遮罩规则即红）。
  group('BUG-123 查词高亮不溢出到振假名列（rt 遮罩）', () {
    test('CSS：选区 active ruby 的 rt/rp 用阅读器背景色遮罩', () {
      expect(
        styles,
        contains('ruby.hoshi-selection-ruby-active > rt'),
        reason: '须给选区 active ruby 的 <rt> 设遮罩背景，挡住溢出到振假名列的高亮',
      );
      expect(
        styles,
        contains('ruby.hoshi-selection-ruby-active > rp'),
        reason: '<rp> 同样要遮罩（无 ruby 渲染回退括注）',
      );
      // 遮罩必须用不透明阅读器背景色（backgroundColor），半透明 selectionColor 挡不住。
      // 取 rt 选择器到声明块内 background-color 行，断言用的是 backgroundColor 插值。
      final int rtIdx = styles.indexOf('ruby.hoshi-selection-ruby-active > rt');
      final int bgIdx = styles.indexOf('background-color', rtIdx);
      final int lineEnd = styles.indexOf(';', bgIdx);
      final String maskDecl = styles.substring(bgIdx, lineEnd);
      expect(
        maskDecl.contains('colors.backgroundColor'),
        isTrue,
        reason: 'rt 遮罩须用不透明 backgroundColor，否则遮不住高亮 tint',
      );
    });
  });
}
