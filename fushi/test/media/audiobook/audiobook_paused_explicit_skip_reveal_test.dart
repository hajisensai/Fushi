import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/fake_just_audio.dart';
import '../../helpers/source_guard.dart';

/// 反馈 yk2XDOGh-H（BUG-3830）：有声书暂停时用户**显式**跳句（上一句 / 下一句按钮、
/// 快捷键、音量键句子导航），阅读器视口要跟到目标句（必要时翻页 / 跨章）；被动的
/// 进度更新仍不拽视口（BUG-2961 / BUG-2781）。
///
/// 判据只有一处：控制器把「这一句是显式跳过来的」登记一次，reader 的 `_onCueChanged`
/// 读 [AudiobookPlayerController.consumeExplicitNavigationReveal] 决定 reveal。reveal
/// 交给 `AudiobookBridge.highlight(reveal:)`，翻页（paginated）/ 滚动（continuous）/
/// 视觉小说（vn）三种 view mode 的 JS 都只按这个参数决定是否把目标句带进视口、
/// 自身不看播放态——所以判据与 view mode 无关，下面的「三种 view mode」守卫钉住这一点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// reader `_onCueChanged` 的替身：每次通知读一次一次性 reveal 登记，记下
  /// （当前句起点, 是否 reveal）。
  List<({int? cueStartMs, bool reveal})> attachReaderProbe(
    AudiobookPlayerController c,
  ) {
    final List<({int? cueStartMs, bool reveal})> seen =
        <({int? cueStartMs, bool reveal})>[];
    c.addListener(() {
      seen.add((
        cueStartMs: c.currentCue?.startMs,
        reveal: c.consumeExplicitNavigationReveal() || c.shouldRevealCurrentCue,
      ));
    });
    return seen;
  }

  group('暂停中显式跳句：视口跟过去一次', () {
    test('下一句：落定那次通知 reveal 到目标句，且只 reveal 一次', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      final List<({int? cueStartMs, bool reveal})> seen = attachReaderProbe(c);

      await c.skipToNextCue();

      expect(c.isPlaying, isFalse, reason: '前提：跳句不改变暂停态');
      expect(c.currentCue?.startMs, 2000);
      expect(
        seen.where((({int? cueStartMs, bool reveal}) e) => e.reveal),
        <({int? cueStartMs, bool reveal})>[(cueStartMs: 2000, reveal: true)],
        reason: '目标句 reveal 恰好一次（翻页 / 滚动 / VN 翻屏由 JS 按 reveal 落实）',
      );
      expect(
        c.consumeExplicitNavigationReveal(),
        isFalse,
        reason: '一次性：之后的通知（暂停 / 播放切换等）不再拽视口',
      );
      expect(c.shouldRevealCurrentCue, isFalse, reason: '被动跟随判据不变');
    });

    test('上一句、跳 N 句、跳到第 N 句同样放行', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      final List<({int? cueStartMs, bool reveal})> seen = attachReaderProbe(c);

      await c.skipToPrevCue();
      await c.skipByCues(2);
      await c.skipToCueIndex(0);

      expect(
        seen
            .where((({int? cueStartMs, bool reveal}) e) => e.reveal)
            .map((({int? cueStartMs, bool reveal}) e) => e.cueStartMs),
        <int>[0, 2000, 0],
      );
    });

    test('被动进度更新（暂停中 cue 变化）不 reveal', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      final List<({int? cueStartMs, bool reveal})> seen = attachReaderProbe(c);

      c.debugUpdateCueForPosition(2500);

      expect(c.currentCue?.startMs, 2000);
      expect(seen, isNotEmpty, reason: '前提：cue 变化确实通知了 reader');
      expect(
        seen.any((({int? cueStartMs, bool reveal}) e) => e.reveal),
        isFalse,
        reason: 'BUG-2961：暂停态被动更新不拽视口',
      );
    });

    test('按位置 / 收藏 / 书签定位音频（skipToCue 不带 revealReader）不 reveal', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      final List<({int? cueStartMs, bool reveal})> seen = attachReaderProbe(c);

      await c.skipToCue(_cue(2000));

      expect(c.currentCue?.startMs, 2000);
      expect(
        seen.any((({int? cueStartMs, bool reveal}) e) => e.reveal),
        isFalse,
      );
    });

    test('跟随音频关：显式跳句也不拽视口', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      c.followAudio.value = false;
      final List<({int? cueStartMs, bool reveal})> seen = attachReaderProbe(c);

      await c.skipToNextCue();

      expect(c.currentCue?.startMs, 2000);
      expect(
        seen.any((({int? cueStartMs, bool reveal}) e) => e.reveal),
        isFalse,
      );
    });

    test('跳句后用户手动翻页：登记作废，不会迟到地拽回', () async {
      final AudiobookPlayerController c = await _pausedController();
      addTearDown(c.dispose);
      // 不挂 reader 替身：模拟登记还没被消费时用户先手动翻页。
      await c.skipToNextCue();
      c.noteManualReaderNavigation();
      expect(c.consumeExplicitNavigationReveal(), isFalse);
    });

    test('目标句在别的章：暂停中、本会话没按过播放也跨章跟过去', () async {
      final AudiobookPlayerController c = await _pausedController(
        cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
        played: false,
      );
      addTearDown(c.dispose);
      expect(c.hasPlayedOnce, isFalse, reason: '前提：本会话没按过播放');
      final List<int> crossed = <int>[];
      c.onCrossChapter = crossed.add;

      await c.skipToNextCue();

      expect(crossed, <int>[13], reason: '正文跨章到目标句所在章（落地即定位到该句）');
      expect(
        c.consumeExplicitNavigationReveal(),
        isFalse,
        reason: '跨章落地负责定位，一次性 reveal 不留给落地之后的通知',
      );
    });

    test('被动的跨章判据不变：不带 revealReader 的定位暂停中且没按过播放不跨章', () async {
      final AudiobookPlayerController c = await _pausedController(
        cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
        played: false,
      );
      addTearDown(c.dispose);
      final List<int> crossed = <int>[];
      c.onCrossChapter = crossed.add;

      await c.skipToCue(_cue(2000, section: 13));

      expect(crossed, isEmpty, reason: 'BUG-069 的 hasPlayedOnce 守卫对非导航定位照旧');
    });
  });

  group('三种 view mode 共用同一判据（源码守卫）', () {
    test('reader 把显式导航 reveal 合进唯一的 reveal 参数交给桥', () {
      final String src = maskComments(
        File(
          'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
        ).readAsStringSync(),
      );
      final String body = methodBody(src, 'void _onCueChanged()');
      expect(
        body,
        contains('controller.consumeExplicitNavigationReveal()'),
        reason: '每次通知读一次（一次性登记）',
      );
      expect(
        compactCode(body),
        contains(
          compactCode(
            'forceReveal || navigationReveal || controller.shouldRevealCurrentCue',
          ),
        ),
      );
      expect(compactCode(body), contains(compactCode('reveal: reveal,')));
    });

    test('翻页 / 滚动（同一个分页脚本对象）与 VN 的高亮入口只按 reveal 参数带进视口', () {
      final String pagination = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
      final String vn = File(
        'lib/src/reader/reader_visual_novel_scripts.dart',
      ).readAsStringSync();
      for (final ({String mode, String src, String signature}) entry
          in <({String mode, String src, String signature})>[
            (
              mode: 'paginated + continuous',
              src: pagination,
              signature: 'highlightSentenceAudioCue: function(cueId, reveal)',
            ),
            (
              mode: 'vn',
              src: vn,
              signature:
                  'highlightSentenceAudioCue: function(cue, reveal, pauseEnabled, fromChapterStart)',
            ),
          ]) {
        final int at = entry.src.indexOf(entry.signature);
        expect(at, greaterThanOrEqualTo(0), reason: '${entry.mode} 入口签名变了');
        final String body = balancedBlockFrom(
          entry.src,
          at,
          lexicon: SourceLexicon.js,
          what: '${entry.mode} highlightSentenceAudioCue',
        );
        expect(
          body,
          contains('reveal'),
          reason: '${entry.mode} 按 reveal 决定带进视口',
        );
        for (final String banned in <String>[
          'playing',
          'paused',
          'isPlaying',
        ]) {
          expect(
            body,
            isNot(contains(banned)),
            reason: '${entry.mode} 不得自己再按播放态挡 reveal（判据只在 Dart 一处）',
          );
        }
      }
    });
  });
}

/// 暂停中、跟随开、当前句 = 1000 的控制器（reader 当前章 12）。[played] 为 true 时
/// 先播过一次再暂停（hasPlayedOnce）。
Future<AudiobookPlayerController> _pausedController({
  List<AudioCue>? cues,
  bool played = true,
}) async {
  final AudiobookPlayerController c = await loadFakeAudiobookController();
  c.setChapterCues(cues ?? <AudioCue>[_cue(0), _cue(1000), _cue(2000)]);
  c.getCurrentReaderSection = () => 12;
  c.onCrossChapter = (_) {};
  if (played) {
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await c.pause();
  }
  c.debugUpdateCueForPosition(1500);
  expect(c.currentCue?.startMs, 1000, reason: '前提：当前句就位');
  expect(c.isPlaying, isFalse, reason: '前提：暂停中');
  expect(c.followAudio.value, isTrue, reason: '前提：跟随音频开');
  c.consumeForceReveal();
  c.consumeExplicitNavigationReveal();
  return c;
}

AudioCue _cue(int startMs, {int section = 12}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-$section'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: startMs ~/ 100,
      normCharEnd: startMs ~/ 100 + 5,
    )
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
}
