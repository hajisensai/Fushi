import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/fake_just_audio.dart';

/// 歌词模式是独立模式（2026-11-10 所有者拍板）：进歌词时 reader 把控制器的正文面
/// 脱开（[AudiobookPlayerController.setReaderDetached]）。脱开期间正文停在原地——
/// 控制器不拽正文视口、不请正文跨章；当前句照常推进（歌词层与歌词模式的按句统计
/// 都靠它）。取代 10-04 的「覆盖层期间正文强制跟随」（`setReaderFollowOverride`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('脱开：播放中也不 reveal 正文，撤销后恢复', () async {
    final AudiobookPlayerController c = await _controller();
    addTearDown(c.dispose);
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.shouldRevealCurrentCue, isTrue, reason: '前提：正常跟随在 reveal');

    c.setReaderDetached(true);
    expect(c.readerDetached, isTrue);
    expect(c.shouldRevealCurrentCue, isFalse);
    expect(c.followAudio.value, isTrue, reason: '不改用户的「跟随音频」开关');

    c.setReaderDetached(false);
    expect(c.shouldRevealCurrentCue, isTrue);
    await c.pause();
  });

  test('脱开：句子走进别的章不请正文跨章，当前句照常推进', () async {
    final AudiobookPlayerController c = await _controller(
      cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
    );
    addTearDown(c.dispose);
    final List<int> crossed = <int>[];
    c.onCrossChapter = crossed.add;
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await c.pause();
    c.setReaderDetached(true);

    c.debugUpdateCueForPosition(2500);

    expect(c.currentCue?.startMs, 2000, reason: '歌词模式靠它换行 / 按句入账');
    expect(crossed, isEmpty, reason: '正文停着，不换章');
  });

  test('脱开：显式跳句（含跨章）不登记正文 reveal、不跨章', () async {
    final AudiobookPlayerController c = await _controller(
      cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
    );
    addTearDown(c.dispose);
    final List<int> crossed = <int>[];
    c.onCrossChapter = crossed.add;
    c.debugUpdateCueForPosition(1500);
    c.setReaderDetached(true);

    await c.skipToNextCue();

    expect(c.currentCue?.startMs, 2000);
    expect(c.consumeExplicitNavigationReveal(), isFalse);
    expect(crossed, isEmpty);
  });

  test('脱开：翻开「跟随音频」不请正文跨章，一次性回中旗仍给歌词层', () async {
    final AudiobookPlayerController c = await _controller(
      cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
    );
    addTearDown(c.dispose);
    final List<int> crossed = <int>[];
    c.onCrossChapter = crossed.add;
    c.followAudio.value = false;
    c.debugUpdateCueForPosition(2500);
    c.setReaderDetached(true);
    c.consumeForceReveal();

    c.setFollowAudio(true);

    expect(crossed, isEmpty, reason: '开关在歌词模式只管歌词列表自己滚不滚');
    expect(c.consumeForceReveal(), isTrue, reason: '歌词层读这枚旗把当前行滚回居中（BUG-757）');
  });

  test('进歌词那一刻在途的跨章守卫随脱开放掉（不会再有正文回执来清它）', () async {
    final AudiobookPlayerController c = await _controller(
      cues: <AudioCue>[_cue(0), _cue(1000), _cue(2000, section: 13)],
    );
    addTearDown(c.dispose);
    final List<int> crossed = <int>[];
    c.onCrossChapter = crossed.add;
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await c.pause();
    // 走进第 13 章：发出跨章、守卫竖起，当前句冻结等正文回执。
    c.debugUpdateCueForPosition(2500);
    expect(crossed, <int>[13], reason: '前提：正文面在场时会请正文跨章');

    c.setReaderDetached(true);
    c.debugUpdateCueForPosition(500);

    expect(c.currentCue?.startMs, 0, reason: '守卫已放，当前句不再冻结');
  });
}

Future<AudiobookPlayerController> _controller({List<AudioCue>? cues}) async {
  final AudiobookPlayerController c = await loadFakeAudiobookController();
  c.setChapterCues(cues ?? <AudioCue>[_cue(0), _cue(1000), _cue(2000)]);
  c.getCurrentReaderSection = () => 12;
  c.onCrossChapter = (_) {};
  c.debugUpdateCueForPosition(500);
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
