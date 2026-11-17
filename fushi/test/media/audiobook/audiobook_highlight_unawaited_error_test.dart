import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

/// 只实现 `evaluateJavascript` 的假 WebView 控制器：记下每次送进来的脚本；
/// [failure] 非空时模拟「WebView 正在销毁 / 换文档」——平台调用以异步错误收场。
class _RecordingWebViewController implements InAppWebViewController {
  _RecordingWebViewController({this.failure});

  final StateError? failure;
  final List<String> sources = <String>[];

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    sources.add(source);
    final StateError? error = failure;
    if (error != null) throw error;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AudioCue _sentenceCue() => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = SubtitleRematchCodec.encodeHit(
    sectionIndex: 0,
    normCharStart: 0,
    normCharEnd: 5,
  )
  ..text = 'あいうえお'
  ..startMs = 0
  ..endMs = 1000
  ..audioFileIndex = 0;

void main() {
  group('放飞的 AudiobookBridge.highlight 的错误出口（BUG-4811）', () {
    test('接了 logHighlightError：抛错不成为未处理的异步错误，记进错误日志', () async {
      final List<Object> uncaught = <Object>[];
      final int before = ErrorLogService.instance.entries.length;
      final StateError failure = StateError('webview disposed');

      await runZonedGuarded<Future<void>>(() async {
        unawaited(
          AudiobookBridge.highlight(
            _RecordingWebViewController(failure: failure),
          ).catchError(AudiobookBridge.logHighlightError),
        );
        unawaited(
          AudiobookBridge.highlight(
            _RecordingWebViewController(failure: failure),
            cue: _sentenceCue(),
            reveal: false,
          ).catchError(AudiobookBridge.logHighlightError),
        );
        // 让两条被放飞的 Future 跑完。
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (Object error, StackTrace stack) => uncaught.add(error));

      expect(uncaught, isEmpty, reason: '放飞的高亮 Future 必须接住错误');
      final List<ErrorLogEntry> logged = ErrorLogService.instance.entries
          .sublist(before);
      expect(logged.length, 2);
      for (final ErrorLogEntry entry in logged) {
        expect(entry.source, 'AudiobookBridge.highlight');
        expect(entry.error, contains('webview disposed'));
      }
    });

    test('对照：裸放飞的同一个失败会变成未处理的异步错误', () async {
      final List<Object> uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        // 故意裸调——这正是修复前 _onCueChanged 的写法。
        // ignore: unawaited_futures, discarded_futures
        AudiobookBridge.highlight(
          _RecordingWebViewController(failure: StateError('webview disposed')),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (Object error, StackTrace stack) => uncaught.add(error));
      expect(uncaught.length, 1);
    });
  });

  group('reader 的 cue 变更回调（源码守卫，BUG-4811）', () {
    // `_onCueChanged` 是播放器监听的同步回调，页面私有、要真 InAppWebView 才能
    // 行为驱动；这里钉调用点：audiobook.part.dart 里每一处 highlight 调用要么被
    // await，要么紧跟 `.catchError(AudiobookBridge.logHighlightError)`。
    //
    // 语料先过 `maskComments`（行注释 + 块注释换成等长空白，下标与原文一致）：
    // 注释里提到的 `AudiobookBridge.highlight(` 不算调用点，注释里的
    // `.catchError(...)` 字面量也不能冒充已接错误处理。
    final String source = maskComments(
      File(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    const String call = 'AudiobookBridge.highlight(';
    const String handler = '.catchError(AudiobookBridge.logHighlightError)';

    /// [open]（指向 `(`）配对的 `)` 之后的下标。调用实参里没有带括号的字符串字面量。
    int afterMatchingParen(int open) {
      int depth = 0;
      for (int i = open; i < source.length; i++) {
        final String ch = source[i];
        if (ch == '(') depth++;
        if (ch == ')' && --depth == 0) return i + 1;
      }
      return -1;
    }

    final List<int> callSites = <int>[
      for (final Match m in RegExp(RegExp.escape(call)).allMatches(source))
        m.start,
    ];

    test('调用点可定位（守卫不因改名而空转）', () {
      expect(callSites.length, 3);
    });

    test('每一处放飞的 highlight 都接了 logHighlightError', () {
      final List<String> bare = <String>[];
      for (final int at in callSites) {
        final int lineStart = source.lastIndexOf('\n', at) + 1;
        final bool awaited = source
            .substring(lineStart, at)
            .trimLeft()
            .startsWith('await ');
        final int end = afterMatchingParen(at + call.length - 1);
        expect(end, greaterThan(at));
        final bool handled = source.startsWith(handler, end);
        if (!awaited && !handled) {
          bare.add(
            'line ${'\n'.allMatches(source.substring(0, at)).length + 1}',
          );
        }
      }
      expect(
        bare,
        isEmpty,
        reason: '裸放飞的 highlight 会把 WebView 销毁中的异常变成未处理的异步错误',
      );
    });
  });
}
