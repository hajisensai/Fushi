import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反馈 C9wcnKaPq_：纯转录（合成）有声书里点一下句子既弹词典又跳到这句播放。
///
/// 根因：`audiobook_bridge.dart` 给合成书的 `[data-cue-id]` 挂了 document 级左键
/// `click` → `onCueTap` → `playCueAndContinue`，与查词桥（onTextSelected）同一次
/// 点击并行触发。拍板（方案 a）：合成书与 EPUB 书交互一致——左键 / 单击只查词；
/// 跳到点击句只走位置型入口：鼠标中键（`onPointerSeek` → `cueIdAtPoint`），触屏
/// 长按句子 → 选区操作条「从此句播放」。
///
/// 这些守卫钉住三件事：左键跳句桥不得回来；合成书仍能被中键反查命中；触屏入口在。
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// [src] 中从 [startMarker] 起、到其后第一个 [endMarker] 为止的片段。
  String slice(String src, String startMarker, String endMarker) {
    final int start = src.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
    final int end = src.indexOf(endMarker, start + startMarker.length);
    expect(end, greaterThan(start), reason: '找不到 $startMarker 之后的 $endMarker');
    return src.substring(start, end);
  }

  group('左键 / 单击不再跳句（只查词）', () {
    test('有声书桥脚本不再给 [data-cue-id] 挂 click → onCueTap', () {
      final String bridge = read(
        'lib/src/media/audiobook/audiobook_bridge.dart',
      );
      expect(
        bridge.contains("callHandler('onCueTap'"),
        isFalse,
        reason: '左键点句跳播会与查词同一次点击并行触发（C9wcnKaPq_）',
      );
      expect(bridge.contains('_cueClickFn'), isFalse);
      expect(bridge.contains('__fushiCueClickBound'), isFalse);
    });

    test('阅读器不再注册 onCueTap 桥', () {
      final String webview = read(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      );
      expect(webview.contains("handlerName: 'onCueTap'"), isFalse);
    });
  });

  group('中键跳句对合成书仍然有效', () {
    test('cueIdAtPoint 首支就认合成书的 [data-cue-id]', () {
      final String js = read('lib/src/reader/reader_pagination_scripts.dart');
      final String body = slice(js, 'cueIdAtPoint: function(x, y) {', '\n  },');
      final int sid = body.indexOf("closest('[data-cue-id]')");
      final int caret = body.indexOf('getCaretRange');
      expect(sid, greaterThanOrEqualTo(0));
      expect(caret, greaterThan(sid), reason: '[data-cue-id] 必须先于 caret 反查');
    });

    test('onPointerSeek 的位置型分支走 _seekToClickedSentence', () {
      final String webview = read(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      );
      final String handler = slice(
        webview,
        "handlerName: 'onPointerSeek'",
        'hostOwnsWebViewPointerInput',
      );
      expect(
        handler,
        contains('isSeekToClickedSentenceButton(registry, button)'),
      );
      expect(handler, contains('_seekToClickedSentence(x, y)'));
    });
  });

  group('触屏跳句：长按选区操作条「从此句播放」', () {
    final String chrome = read(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    );

    test('操作条在有音频时给出「从此句播放」项', () {
      final String bar = slice(
        chrome,
        'Widget _buildSelectionActionBar(',
        '\n  Future<void> _runSelectionAction(',
      );
      expect(
        bar,
        matches(
          RegExp(
            r'if \(hasAudio\)\s*item\(\s*FushiIcons\.playCircle,\s*'
            r"t\.play_from_cue,\s*'playFromSentence',?\s*\)",
          ),
        ),
      );
    });

    test("'playFromSentence' 动作交给 _playFromSelectionSentence", () {
      final String run = slice(
        chrome,
        'Future<void> _runSelectionAction(',
        '\n  Future<void> _clearReaderAppSelection(',
      );
      final String branch = slice(run, "case 'playFromSentence':", 'return;');
      expect(branch, contains('_playFromSelectionSentence(data)'));
    });

    test('从此句播放与查词状态共用同一份 cue 解析，并调 playCueAndContinue', () {
      final String play = slice(
        chrome,
        'Future<void> _playFromSelectionSentence(',
        '\n  }\n',
      );
      expect(play, contains('_cueForSelectionData(data)'));
      expect(play, contains('controller.playCueAndContinue(cue)'));
      expect(
        play,
        contains('t.audiobook_play_from_selection_no_cue'),
        reason: '解析不到句子必须提示，不得静默无反应',
      );

      final String fill = slice(
        chrome,
        'Future<void> _fillLookupStateFromSelectionData(',
        '_cachedSelectionRange =',
      );
      expect(fill, contains('_lookupCue = _cueForSelectionData(data);'));

      final String tapLookup = read(
        'lib/src/pages/implementations/reader_fushi/lookup.part.dart',
      );
      expect(
        tapLookup,
        contains('_lookupCue = _cueForSelectionData(data);'),
        reason: 'tap 查词也必须走同一份 cue 解析，不得再各写一份三级回退',
      );

      final String resolve = slice(
        chrome,
        'AudioCue? _cueForSelectionData(ReaderSelectionData data) {',
        '\n  }\n',
      );
      final int payload = resolve.indexOf('cueForPointerPayload(');
      final int offset = resolve.indexOf('_findCueForOffset(');
      final int sentence = resolve.indexOf('_findCueForSentence(');
      expect(payload, greaterThanOrEqualTo(0));
      expect(offset, greaterThan(payload), reason: 'cue 身份优先于坐标反查');
      expect(sentence, greaterThan(offset), reason: '文本匹配是最后一级回退');
    });
  });
}
