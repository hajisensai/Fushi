import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// BUG-1107 源码扫描守卫：阅读统计「速度爆表」三段根因的形态锁定。
///
/// 断点 A（时长丢失）：EPUB 的 `_flushReadingStats` 旧守卫
/// `_sessionCharsRead <= 0 || _book == null` 拒写纯时长行——dispose 时最后一段
/// 无新字数 / 歌词·听书全程不计字 ⇒ 时长蒸发。v92 起时长与字数进**同一段**
/// （`StudyClock`，同 uid 一行），页面侧不再持有 `_sessionCharsRead` 之类的会话累计
/// 器，也不存在任何「拒写」路径：`_flushReadingStats` 只结算时钟。守卫锁定这个
/// 形态：函数体只含 `_studyClock?.flushNow()`、没有按字数早退；三个阅读器都不再
/// 出现 `_sessionCharsRead`。
///
/// 断点 B（幻象字数）：字数只经 `ReadUnitLedger`（翻走即计 + 会话并集）记账——
/// `_refreshProgress` 只 `arrive` 当前可见区间，恢复完成**不播种**，标量水位 / 速度
/// 封顶的符号一个都不许回潮；显式跳句（skipToCue 漏斗）必须经 `onExplicitCueJump`
/// → `_readLedger.leave()`，让跳过的正文从未成为当前单元。退回任一旧形式都会让
/// 首个进度回调把跳过的正文误计成新读字数。
void main() {
  final String corpus = readReaderPageSource();

  group('断点 A：_flushReadingStats 不按字数拒写（时长与字数同段）', () {
    String flush() => _functionSource(
      maskComments(
        File(
          'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n'),
      ),
      '  Future<void> _flushReadingStats() async {',
      '\n  }\n',
    );

    test('旧「必须有字数」守卫不得回归', () {
      final String body = flush();
      expect(
        body,
        isNot(contains('_sessionCharsRead')),
        reason:
            '旧守卫拒写纯时长行：dispose 最后一段 / 歌词·听书模式的时长会整段蒸发'
            '（BUG-1107 断点 A）',
      );
      expect(body, isNot(contains('charsRead <= 0')));
      expect(
        body,
        isNot(contains('return')),
        reason: '没有任何早退：时长与字数同一段，flush 只能是结算时钟',
      );
    });

    test('新形态：函数体只委托 StudyClock.flushNow', () {
      expect(
        flush(),
        contains('await _studyClock?.flushNow();'),
        reason: '时长与字数记在同一段，flush = 结算时钟当前窗口并绝对值落库',
      );
    });

    test('三个阅读器都不再持有会话字数累计器', () {
      final String epub = maskComments(corpus);
      final String pdf = maskComments(
        File(
          'lib/src/pages/implementations/reader_pdf_page.dart',
        ).readAsStringSync(),
      );
      final String manga = maskComments(
        File(
          'lib/src/media/manga/reader/manga_fushi_page.dart',
        ).readAsStringSync(),
      );
      for (final (String name, String src) in <(String, String)>[
        ('epub', epub),
        ('pdf', pdf),
        ('manga', manga),
      ]) {
        expect(
          src,
          isNot(contains('_sessionCharsRead')),
          reason: '$name：会话字数累计器已废，字数直接进 StudyClock 段',
        );
      }
    });
  });

  group('断点 B：字数只经 ReadUnitLedger，恢复不播种，显式跳句 leave', () {
    final String masked = maskComments(corpus);

    test('_refreshProgress 只经 _readLedger.arrive( 记字', () {
      final String body = _functionSource(
        masked,
        '  Future<void> _refreshProgress() async {',
        '\n  }\n',
      );
      expect(
        body,
        contains('_readLedger.arrive('),
        reason: '当前可见区间必须交给账本，翻走时才结算',
      );
      expect(
        body,
        isNot(contains('addChars(')),
        reason: '_refreshProgress 不得绕过账本直接记字（到达即计 / 水位增量都是旧形态）',
      );
    });

    test('_onRestoreComplete 不播种任何水位', () {
      final String body = _functionSource(
        masked,
        '  void _onRestoreComplete() {',
        '\n  }\n',
      );
      for (final String stale in <String>[
        'sessionWatermarkAfterRestore(',
        'computeCharWatermark(',
        '_sessionMaxAbsoluteChars',
        '_readChargeCreditMilliChars',
        '_lastWatermarkAdvanceAt',
      ]) {
        expect(body, isNot(contains(stale)), reason: '恢复完成播种 = 旧标量水位形态');
      }
      expect(
        body,
        isNot(contains('_readLedger.')),
        reason: '恢复完成不碰账本：离开在 _beginNavigation / 同章跳转入口 leave（BUG-2225）',
      );
    });

    test('标量水位 / 速度封顶符号不得回潮（掩码后全语料）', () {
      for (final String stale in <String>[
        '_sessionMaxAbsoluteChars',
        'accumulateSessionChars',
        'computeCharWatermark',
        'kMaxReadCharsPerSecond',
        'sessionWatermarkAfterRestore',
        'restoreSeedResetsReadCharge',
      ]) {
        expect(
          masked,
          isNot(contains(stale)),
          reason: '$stale 属于已拆除的标量水位 + 令牌桶（BUG-1107 / BUG-2206 的结构性根因）',
        );
      }
    });

    test('reader 实现 onExplicitCueJump → _readLedger.leave()（跳过的段落不算已读）', () {
      expect(masked, contains('void _handleExplicitCueJump(AudioCue cue)'));
      final String handler = _functionSource(
        masked,
        '  void _handleExplicitCueJump(AudioCue cue) {',
        '\n  }\n',
      );
      expect(
        handler,
        contains('_readLedger.leave();'),
        reason: '显式跳句必须结算当前页并清空当前单元，落点页只是「到达」',
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
      expect(
        jumpIdx,
        isNonNegative,
        reason: 'skipToCue 是所有显式句子跳转的唯一漏斗，必须报 onExplicitCueJump',
      );
      expect(seekIdx, isNonNegative);
      expect(jumpIdx, lessThan(seekIdx), reason: '水位必须在 seek 落地触发的进度回调之前就位');
    });

    test('session attach/detach 双向接线 onExplicitCueJump', () {
      final String session = File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
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
