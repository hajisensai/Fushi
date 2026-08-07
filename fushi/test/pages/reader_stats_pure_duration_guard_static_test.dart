import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_fushi_page_source_corpus.dart';

/// BUG-1107 源码扫描守卫：阅读统计「速度爆表」三段根因的形态锁定。
///
/// 断点 A（时长丢失）：EPUB 的 `_flushReadingStats` 旧守卫
/// `_sessionCharsRead <= 0 || _book == null` 拒写纯时长行——dispose 时最后一段
/// 无新字数 / 歌词·听书全程不计字 ⇒ 时长蒸发。PDF / 漫画都允许 `charsRead: 0`
/// 纯时长行，只有 EPUB 口径分叉。守卫锁定新形式：无书才拒；无新字数时只要有
/// 已确认时长（>=1s）也落库。
///
/// 断点 B（幻象字数）：水位播种必须与真实恢复锚（`_initialCharOffset`）同源
/// （经 [computeCharWatermark]），且显式跳句（skipToCue 漏斗）必须经
/// `onExplicitCueJump` 抬水位——两处退回旧形式都会让首个进度回调把跳过的正文
/// 误计成新读字数。
void main() {
  final String corpus = readReaderPageSource();

  group('断点 A：_flushReadingStats 允许纯时长行', () {
    String flush() => _functionSource(
          corpus,
          '  Future<void> _flushReadingStats() async {',
          '\n}\n',
        );

    test('旧「必须有字数」守卫不得回归', () {
      expect(
        flush(),
        isNot(contains('if (_sessionCharsRead <= 0 || _book == null) return;')),
        reason: '旧守卫拒写纯时长行：dispose 最后一段 / 歌词·听书模式的时长会整段蒸发'
            '（BUG-1107 断点 A）',
      );
    });

    test('新守卫：无书才拒；无新字数但有已确认时长（>=1s）仍落库', () {
      expect(flush(), contains('if (_book == null) return;'));
      expect(
        flush(),
        contains('if (_sessionCharsRead <= 0 && _sessionReadingMs < 1000) '
            'return;'),
        reason: '纯时长行（charsRead: 0）必须能落库，与 PDF/漫画口径对齐',
      );
    });
  });

  group('断点 B：水位与恢复锚同源 + 显式跳句抬水位', () {
    test('恢复完成播种水位必须经 computeCharWatermark（带 _initialCharOffset）', () {
      // 旧形式 `_absoluteCharPosition(_initialProgress)` 在 charAnchor 恢复
      // （progress 被强制 0.0）时把水位播在章首 → 首个进度回调把章内前缀整段
      // 误计成新读字数。
      expect(
        corpus,
        contains('charOffset: _initialCharOffset,'),
        reason: '水位播种必须消费真实恢复锚 _initialCharOffset',
      );
      expect(
        corpus,
        isNot(contains(
            'sessionWatermarkAfterRestore(\n      _sessionMaxAbsoluteChars,\n'
            '      _absoluteCharPosition(_initialProgress),')),
        reason: '不得退回只看 _initialProgress 的旧播种形式（BUG-1107 断点 B）',
      );
    });

    test('reader 实现 onExplicitCueJump → 抬水位（跳过的段落不算已读）', () {
      expect(corpus, contains('void _handleExplicitCueJump(AudioCue cue)'));
      final String handler = _functionSource(
        corpus,
        '  void _handleExplicitCueJump(AudioCue cue) {',
        '\n  }\n',
      );
      expect(
        handler,
        contains('sessionWatermarkAfterRestore('),
        reason: '显式跳句必须以只升不降语义抬统计水位',
      );
    });

    test('控制器 skipToCue 漏斗在物理 seek 前回调 onExplicitCueJump', () {
      final String controller = File(
        '../packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String skipToCue = _functionSource(
        controller,
        '  Future<void> skipToCue(AudioCue cue) async {',
        '\n  /// 播放指定 cue 单句后暂停',
      );
      final int jumpIdx = skipToCue.indexOf('onExplicitCueJump?.call(cue);');
      final int seekIdx = skipToCue.indexOf('_player.seek(');
      expect(jumpIdx, isNonNegative,
          reason: 'skipToCue 是所有显式句子跳转的唯一漏斗，必须报 onExplicitCueJump');
      expect(seekIdx, isNonNegative);
      expect(
        jumpIdx,
        lessThan(seekIdx),
        reason: '水位必须在 seek 落地触发的进度回调之前就位',
      );
    });

    test('session attach/detach 双向接线 onExplicitCueJump', () {
      final String session =
          File('lib/src/media/audiobook/audiobook_session.dart')
              .readAsStringSync()
              .replaceAll('\r\n', '\n');
      expect(
        session,
        contains('controller.onExplicitCueJump = reader.onExplicitCueJump;'),
        reason: 'attachReader 必须接线，否则底栏/通知/音量键跳句不抬水位',
      );
      expect(
        session,
        contains('controller.onExplicitCueJump = null;'),
        reason: 'detachReader 必须卸线，防悬垂回调',
      );
    });
  });
}

/// 从 [start] 标记切到其后的第一个 [end] 标记（与
/// `reader_paginate_lyrics_guard_static_test.dart` 同范式）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
