import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  ).readAsStringSync();

  for (final String method in <String>[
    '_refreshProgress',
    '_syncPositionFromWebViewProgress',
  ]) {
    test('$method rejects a snapshot completed after navigation or reload', () {
      final int start = source.indexOf('Future<void> $method() async {');
      expect(start, isNonNegative);
      final int parse = source.indexOf(
        'parseReaderStableProgressDetails(result)',
        start,
      );
      expect(parse, greaterThan(start));
      final String beforeParse = source.substring(start, parse);
      final int request = beforeParse.indexOf(
        'await controller.evaluateJavascript(',
      );
      expect(request, isNonNegative);
      expect(
        beforeParse.indexOf('final int chapter = _currentChapter;'),
        inInclusiveRange(0, request - 1),
      );
      expect(
        beforeParse.indexOf('final int generation = _navigateGeneration;'),
        inInclusiveRange(0, request - 1),
      );
      expect(
        beforeParse.indexOf(
          'final InAppWebViewController controller = _controller!;',
        ),
        inInclusiveRange(0, request - 1),
      );
      // These must be checked after the async request, before any parsing,
      // fallback UI, restore anchor, ledger or persistence writes.
      final String afterRequest = beforeParse.substring(request);
      // controller 那条钉不变式而不是写法：`_controller != controller` 后来改成
      // `!identical(controller, _controller)`（同一判据、更严——还排除了被重写的
      // `==`），字面量守卫当场变红而接线一点没断。
      expect(
        afterRequest,
        anyOf(
          contains('_controller != controller'),
          matches(RegExp(r'identical\(\s*controller\s*,\s*_controller\s*\)')),
          matches(RegExp(r'identical\(\s*_controller\s*,\s*controller\s*\)')),
        ),
        reason: '必须比较 controller 与 _controller（换了 WebView 的快照要丢掉）',
      );
      // 同理，这两对也只钉「被比较过」——`!=` 两侧顺序被翻过（语义完全相同）。
      for (final List<String> pair in <List<String>>[
        <String>['_navigateGeneration', 'generation'],
        <String>['_currentChapter', 'chapter'],
      ]) {
        expect(
          afterRequest,
          matches(RegExp('(${pair[0]}\\s*!=\\s*${pair[1]}'
              '|${pair[1]}\\s*!=\\s*${pair[0]})')),
          reason: '必须比较 ${pair[0]} 与 ${pair[1]}（导航/换章后的快照要丢掉）',
        );
      }
      for (final String condition in <String>[
        '!mounted',
        '_restoreInFlight',
        '_lyricsMode',
        // BUG-2399 起加入这道闸：内容还没就绪时晚到的快照同样不得写进恢复锚。
        // 两个入口（_refreshProgress / _syncPositionFromWebViewProgress）都要有，
        // 只补一处等于漏的那条路照样能污染恢复锚。
        '_readerContentReady',
      ]) {
        expect(afterRequest, contains(condition));
      }
      // 立即早退：闸的条件列表收尾之后必须紧跟 return，中间不许夹任何写操作。
      // 原来钉的是含具体缩进的整段字面量，往闸里加一条判据就红——而不变式
      //（判完即 return）一点没变。改成钉结构。
      expect(
        afterRequest,
        matches(RegExp(r'\)\s*\{\s*return;\s*\}')),
        reason: '闸判完必须立刻 return，不能先写恢复锚/账本再判',
      );
    });
  }
}
