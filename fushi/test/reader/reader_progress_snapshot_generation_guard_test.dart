import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 进度快照的取样与「JS 往返之后这份快照还作不作数」的闸只有一份：
/// `_takeStableProgressSnapshot`。两个入口（`_refreshProgress` 实时采样、
/// `_syncPositionFromWebViewProgress` 退出 / 切后台实时读）都只经它取样。
///
/// 原先两个入口各抄一套六条件闸，本守卫按方法名在两个方法体里各找一遍——只补一处
/// 的回归能被抓到，但判据本身仍是两份。现在钉的是：
/// 1. 共用函数里判据齐全、位置对（取样前记身份，取样后、返回前判）；
/// 2. 两个入口都经它取样，且自己不再直接向 WebView 要 `stableProgressInvocation`
///    （否则就又多出一条没有闸的路）；
/// 3. 两个入口在拿到 `null` 时先 return，之后才解析 / 写任何状态。
void main() {
  final String source = File(
    'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  ).readAsStringSync();

  const String takeSignature =
      'Future<Object?> _takeStableProgressSnapshot(String errorSource) async {';

  group('_takeStableProgressSnapshot：唯一取样口', () {
    final String code = maskComments(methodBody(source, takeSignature));
    final int request = code.indexOf('await controller.evaluateJavascript(');

    test('向 WebView 要的是 stableProgressInvocation，且只要一次', () {
      expect(request, isNonNegative);
      expect(
        'x$code'.split('evaluateJavascript(').length - 1,
        1,
        reason: '一次取样对应一次闸；多一次 eval 就多一段没被闸住的往返',
      );
      expect(
        code.substring(request),
        contains('ReaderPaginationScripts.stableProgressInvocation()'),
      );
    });

    test('取样之前记下 controller / 代际 / 章号', () {
      final String before = code.substring(0, request);
      expect(
        before,
        contains('final InAppWebViewController? controller = _controller;'),
      );
      expect(before, contains('final int generation = _navigateGeneration;'));
      expect(before, contains('final int chapter = _currentChapter;'));
    });

    test('evaluateJavascript 有错误边界，fail-open 且按调用方给的 source 记日志', () {
      final int tryIdx = code.indexOf('try {');
      final int catchIdx = code.indexOf('} catch (e, stack) {');
      expect(tryIdx, isNonNegative);
      expect(request, greaterThan(tryIdx));
      expect(catchIdx, greaterThan(request));
      expect(
        compactCode(code),
        contains('ErrorLogService.instance.log(errorSource,e,stack);'),
        reason: '报废 controller 上的 eval 会抛：不得变成未捕获异步错误，也不得吞成静默',
      );
    });

    test('取样之后、返回结果之前把过期快照丢掉', () {
      final int returnResult = code.lastIndexOf('return result;');
      expect(returnResult, greaterThan(request));
      final String gate = code.substring(request, returnResult);
      // controller 那条钉不变式而不是写法：`!=` 与 `identical` 判的是同一件事。
      expect(
        gate,
        anyOf(
          contains('_controller != controller'),
          matches(RegExp(r'identical\(\s*controller\s*,\s*_controller\s*\)')),
          matches(RegExp(r'identical\(\s*_controller\s*,\s*controller\s*\)')),
        ),
        reason: '必须比较 controller 与 _controller（换了 WebView 的快照要丢掉）',
      );
      // 这两对只钉「被比较过」——`!=` 两侧顺序无关。
      for (final List<String> pair in <List<String>>[
        <String>['_navigateGeneration', 'generation'],
        <String>['_currentChapter', 'chapter'],
      ]) {
        expect(
          gate,
          matches(
            RegExp(
              '(${pair[0]}\\s*!=\\s*${pair[1]}'
              '|${pair[1]}\\s*!=\\s*${pair[0]})',
            ),
          ),
          reason: '必须比较 ${pair[0]} 与 ${pair[1]}（导航/换章后的快照要丢掉）',
        );
      }
      for (final String condition in <String>[
        '!mounted',
        '_restoreInFlight',
        // BUG-2399：内容还没就绪时晚到的快照同样不得写进恢复锚。
        '!_readerContentReady',
      ]) {
        expect(gate, contains(condition));
      }
      // 闸判完必须立刻交回 null，中间不许夹任何写操作。
      expect(
        gate,
        matches(RegExp(r'\)\s*\{\s*return null;\s*\}\s*$')),
        reason: '闸与 `return result;` 之间不得有别的语句',
      );
    });

    test('自己不写任何进度 / 恢复锚 / 账本状态', () {
      for (final String write in <String>[
        '_lastProgressSection',
        '_lastProgressValue',
        '_lastProgressCharOffset',
        '_adoptLiveProgressAsRestoreAnchor',
        '_readLedger',
        '_persistPosition',
        '_debouncedSavePosition',
      ]) {
        expect(
          containsIdentifier(code, write),
          isFalse,
          reason: '取样口只取样；$write 属于调用方',
        );
      }
    });
  });

  for (final String method in <String>[
    '_refreshProgress',
    '_syncPositionFromWebViewProgress',
  ]) {
    test('$method 只经 _takeStableProgressSnapshot 取样，null 先早退', () {
      final String code = maskComments(
        methodBody(source, 'Future<void> $method() async {'),
      );
      final int take = code.indexOf('await _takeStableProgressSnapshot(');
      expect(take, isNonNegative, reason: '$method 必须经共用取样口');
      expect(
        containsIdentifierCall(code, 'evaluateJavascript'),
        isFalse,
        reason: '$method 不得再自己向 WebView 取样——那条路没有闸',
      );
      expect(
        containsIdentifier(code, 'stableProgressInvocation'),
        isFalse,
        reason: '同上',
      );
      final int parse = code.indexOf(
        'parseReaderStableProgressDetails(result)',
      );
      expect(parse, greaterThan(take));
      // 取样之后、解析之前：null（被闸丢弃 / eval 失败 / JS 早退）必须先 return，
      // 之间不得出现任何进度 / 恢复锚 / 账本写入。
      final String between = code.substring(take, parse);
      expect(
        between,
        matches(RegExp(r'if \(result == null\) \{\s*return;\s*\}')),
        reason: '拿到 null 必须立刻 return',
      );
      for (final String write in <String>[
        '_lastProgressSection',
        '_lastProgressValue',
        '_lastProgressCharOffset',
        '_adoptLiveProgressAsRestoreAnchor',
        '_readLedger',
        '_applyImagePageProgressFallback',
      ]) {
        expect(
          containsIdentifier(between, write),
          isFalse,
          reason: '$write 不得出现在早退之前',
        );
      }
    });
  }

  test('入口前置条件各归各：歌词闸只属于 _refreshProgress', () {
    final String refresh = methodBody(
      source,
      'Future<void> _refreshProgress() async {',
    );
    expect(
      containsCodeLine(
        refresh,
        'if (_controller == null || _restoreInFlight || _lyricsMode) return;',
      ),
      isTrue,
    );
    final String refreshCode = maskComments(refresh);
    // 取样在飞期间进了歌词模式：晚到的正文快照不得 arrive。
    expect(
      refreshCode.indexOf(
        'if (_lyricsMode) return;',
        refreshCode.indexOf('await _takeStableProgressSnapshot('),
      ),
      isNonNegative,
    );
    final String sync = methodBody(
      source,
      'Future<void> _syncPositionFromWebViewProgress() async {',
    );
    expect(
      compactCode(maskComments(sync)),
      contains(
        'if(_controller==null||!_readerContentReady||_restoreInFlight){return;}',
      ),
    );
  });
}
