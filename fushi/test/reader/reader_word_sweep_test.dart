import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_word_sweep.dart';
import 'package:fushi/src/reader/reader_word_sweep.dart';
import 'package:fushi/src/reader/reader_word_sweep_scripts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';

import '../helpers/source_guard.dart';

/// 阅读器「整句扫词」（拍板台 5H922XeDHM，照视频页 word_sweep 契约）。
///
/// 三层：① 纯逻辑（码元 ↔ grapheme 折算、游标推进、选区对齐）；② WebView 侧 JS 经
/// node 真执行（取句 / 可见 / 会话 / 映射，harness 见同目录 .js）；③ 接线源码守卫——
/// 派发顺序这类「单测全绿但通道静默失效」的不变式。
void main() {
  List<String> fixedWords(String text) {
    // 「今日は|天気|が|いい|。」——确定性分词，不依赖词典引擎。
    const List<String> words = <String>['今日は', '天気', 'が', 'いい', '。'];
    expect(words.join(), text);
    return words;
  }

  const String sentence = '今日は天気がいい。';

  group('纯逻辑', () {
    test('前进从首词起、句尾循环；后退首次落在末词', () {
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fixedWords,
      );
      final List<int> stops = <int>[0, 1, 2, 3, 4, 5, 6, 7];
      ReaderWordSweepStop? stop = resolveReaderWordSweepStop(
        text: sentence,
        tokens: tokens,
        index: -1,
        forward: true,
        stops: stops,
      );
      expect(stop, (tokenIndex: 0, unit: 0));
      stop = resolveReaderWordSweepStop(
        text: sentence,
        tokens: tokens,
        index: 3,
        forward: true,
        stops: stops,
      );
      // 「。」不是停靠点 → 跳过它循环回句首。
      expect(stop, (tokenIndex: 0, unit: 0));
      stop = resolveReaderWordSweepStop(
        text: sentence,
        tokens: tokens,
        index: -1,
        forward: false,
        stops: stops,
      );
      expect(stop, (tokenIndex: 3, unit: 6));
    });

    test('词首不可见时停在词内第一个可见字；整词不可见则跳过', () {
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        sentence,
        tokenize: fixedWords,
      );
      // 「天」不可见、「気」可见；「が」整词不可见。
      final List<int> stops = <int>[0, 1, 2, 4, 6, 7];
      final ReaderWordSweepStop? second = resolveReaderWordSweepStop(
        text: sentence,
        tokens: tokens,
        index: 0,
        forward: true,
        stops: stops,
      );
      expect(second, (tokenIndex: 1, unit: 4));
      final ReaderWordSweepStop? third = resolveReaderWordSweepStop(
        text: sentence,
        tokens: tokens,
        index: 1,
        forward: true,
        stops: stops,
      );
      expect(third, (tokenIndex: 3, unit: 6));
    });

    test('代理对：码元下标折算不错位', () {
      const String text = '𠮟る。叱る';
      List<String> words(String t) => <String>['𠮟る', '。', '叱る'];
      final List<SubtitleSweepToken> tokens = buildSubtitleSweepTokens(
        text,
        tokenize: words,
      );
      // 𠮟 占码元 0..1，る=2，。=3，叱=4，る=5。
      final ReaderWordSweepStop? stop = resolveReaderWordSweepStop(
        text: text,
        tokens: tokens,
        index: 0,
        forward: true,
        stops: const <int>[0, 2, 4, 5],
      );
      expect(stop, (tokenIndex: 2, unit: 4));
      expect(readerWordSweepTokenAt(tokens, text, 1), 0);
      expect(readerWordSweepTokenAt(tokens, text, 5), 2);
    });

    test('整句无停靠点：null，游标不动', () {
      final ReaderWordSweepSession session = ReaderWordSweepSession(
        tokenize: fixedWords,
      );
      expect(
        session.advance(
          const ReaderWordSweepSentence(
            id: 1,
            text: sentence,
            stops: <int>[],
            at: -1,
          ),
          forward: true,
        ),
        isNull,
      );
      expect(session.index, -1);
    });

    test('会话：同句继续、换句重来、弹窗选区对齐游标', () {
      final ReaderWordSweepSession session = ReaderWordSweepSession(
        tokenize: fixedWords,
      );
      const List<int> stops = <int>[0, 1, 2, 3, 4, 5, 6, 7];
      ReaderWordSweepStop? step(int id, {int at = -1, bool forward = true}) =>
          session.advance(
            ReaderWordSweepSentence(
              id: id,
              text: sentence,
              stops: stops,
              at: at,
            ),
            forward: forward,
          );
      expect(step(1)?.tokenIndex, 0);
      expect(step(1)?.tokenIndex, 1);
      // 用户点了「いい」（码元 6）→ 下一按从它之后，即循环回首词。
      expect(step(1, at: 6)?.tokenIndex, 0);
      // 选区在「天気」→ 上一词是「今日は」。
      expect(step(1, at: 3, forward: false)?.tokenIndex, 0);
      // 会话号变了 = 换句：从头开始。
      expect(step(2)?.tokenIndex, 0);
    });

    test('parseSentence：JSON 串 / 空 / 非法', () {
      final ReaderWordSweepSentence? parsed =
          ReaderWordSweepScripts.parseSentence(
            '{"id":3,"text":"ab","stops":[0,1],"at":-1}',
          );
      expect(parsed?.id, 3);
      expect(parsed?.text, 'ab');
      expect(parsed?.stops, <int>[0, 1]);
      expect(parsed?.at, -1);
      expect(ReaderWordSweepScripts.parseSentence(null), isNull);
      expect(ReaderWordSweepScripts.parseSentence('null'), isNull);
      expect(ReaderWordSweepScripts.parseSentence('{oops'), isNull);
      expect(ReaderWordSweepScripts.parseSentence('{"id":1}'), isNull);
    });
  });

  test('WebView 侧 JS 行为（node 真执行 source()）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_word_sweep_',
    );
    final File js = File('${tmp.path}/word_sweep.js');
    js.writeAsStringSync(ReaderWordSweepScripts.source());
    try {
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>['test/reader/reader_word_sweep_behavior_test.js'],
        environment: <String, String>{'FUSHI_READER_WORD_SWEEP_JS': js.path},
      );
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  group('接线', () {
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String caret = File(
      'lib/src/pages/implementations/reader_fushi/caret.part.dart',
    ).readAsStringSync();
    final String part = File(
      'lib/src/pages/implementations/reader_fushi/word_sweep.part.dart',
    ).readAsStringSync();
    final String webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();
    final String lyrics = File(
      'lib/src/pages/implementations/reader_fushi/lyrics.part.dart',
    ).readAsStringSync();

    test('执行体：唯一派发点 + 光标激活时让位 + 不碰光标状态', () {
      final String body = maskComments(
        methodBody(part, 'bool _runReaderWordSweepAction('),
      );
      expect(body.contains('ShortcutAction.readerLookupNextWord'), isTrue);
      expect(body.contains('ShortcutAction.readerLookupPrevWord'), isTrue);
      final String sweep = maskComments(
        methodBody(part, 'Future<void> _sweepReaderWord('),
      );
      expect(containsCodeLine(sweep, 'if (_caretActive) return;'), isTrue);
      for (final String forbidden in <String>[
        '_enterCaret(',
        '_runCaretAction(',
        '_caretSurface =',
        'fushiCaret',
      ]) {
        expect(
          sweep.contains(forbidden),
          isFalse,
          reason: '扫词不得进光标 / 改光标状态（$forbidden）',
        );
      }
      expect(
        maskComments(page + caret).contains('_sweepReaderWord('),
        isFalse,
        reason: '各通道只能经 _runReaderWordSweepAction 派发',
      );
    });

    test('键盘 / 手柄 / 鼠标共用的执行体开头先分流扫词', () {
      final String body = maskComments(
        methodBody(caret, 'KeyEventResult _executeShortcutAction('),
      );
      final int sweep = body.indexOf('_runReaderWordSweepAction(action)');
      final int switchAt = body.indexOf('switch (action)');
      expect(sweep, greaterThanOrEqualTo(0));
      expect(switchAt, greaterThan(sweep));
    });

    test('弹窗回传 token：扫词排在基类「关弹窗」之前，且两动作在转发表里', () {
      final String body = maskComments(
        methodBody(page, 'bool onDictionaryPopupInputToken('),
      );
      final int sweep = body.indexOf('_runReaderWordSweepAction(action)');
      final int base = body.indexOf('super.onDictionaryPopupInputToken(token)');
      expect(sweep, greaterThanOrEqualTo(0));
      expect(base, greaterThan(sweep), reason: '否则弹窗一持焦，扫词键就退化成关弹窗');
      final String forwarded = maskComments(
        methodBody(
          page,
          'Set<ShortcutAction> get dictionaryPopupForwardedActions',
        ),
      );
      expect(forwarded.contains('ShortcutAction.readerLookupNextWord'), isTrue);
      expect(forwarded.contains('ShortcutAction.readerLookupPrevWord'), isTrue);
    });

    test('正文引擎与歌词文档都注入扫词脚本', () {
      expect(
        maskComments(webview).contains('ReaderWordSweepScripts.source()'),
        isTrue,
      );
      expect(
        maskComments(lyrics).contains('ReaderWordSweepScripts.source()'),
        isTrue,
      );
    });

    test('默认空绑定（三平台），属 reader scope', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        final Map<ShortcutAction, ShortcutBindingSet> map =
            ShortcutDefaults.forPlatform(platform);
        for (final ShortcutAction action in <ShortcutAction>[
          ShortcutAction.readerLookupNextWord,
          ShortcutAction.readerLookupPrevWord,
        ]) {
          expect(action.scope, ShortcutScope.reader);
          final ShortcutBindingSet set = map[action]!;
          expect(set.keyboardBindings, isEmpty);
          expect(set.gamepadBindings, isEmpty);
          expect(set.mouseBindings, isEmpty);
        }
      }
    });
  });
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
