import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-1068：听力沉浸模糊在字幕间隙后锁死显形，不再变回模糊。
///
/// 复现机制：悬停某条字幕显形（onEnter → _setRevealed(true)）后，字幕进入无字幕间隙，
/// 该层整体从树上卸载（build 返回 SizedBox.shrink），承载 hover 的 MouseRegion 随之
/// 卸载——onExit 不会对已卸载的 MouseRegion 派发，`_revealed` 锁死为 true。于是下一条
/// 字幕即便鼠标早已离开也直接清晰显示（用户报「鼠标挪开了还没变模糊」）。
///
/// 修复：某层活动集为空时在 build 里兜底复位该层显形态，不依赖 onExit。
///
/// 断言代理：字幕是逐字符渲染的（无单个 Text('AAA')），故用「揭开热区」——模糊态才建的
/// `Key('video-subtitle-reveal')` GestureDetector——作为「当前该层是否模糊」的可断言标志：
/// 存在=模糊，不存在=已显形（或该层无字幕）。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

Finder get _revealHotZone => find.byKey(const Key('video-subtitle-reveal'));

Future<void> _pumpAt(
    WidgetTester tester, VideoPlayerController c, int posMs) async {
  c.debugUpdateCueForPosition(posMs);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(controller: c, blurEnabled: true),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('间隙后下一条字幕恢复模糊（不残留上一条的显形态）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    // 播放中，模糊才生效（BUG-199 门）。
    c.debugSetIsPlayingForTesting(true);
    // 字幕 A [0,2000)，间隙 [2000,4000)，字幕 B [4000,6000)。
    c.setCues(<AudioCue>[_cue('AAA', 0, 2000), _cue('BBB', 4000, 6000)]);

    // ① 字幕 A：开着模糊 → 揭开热区存在（同时证明 cue A 已激活）。
    await _pumpAt(tester, c, 1000);
    expect(_revealHotZone, findsOneWidget, reason: '播放中开模糊，A 应模糊（有揭开热区）');

    // ② 点揭开热区显形 A（触摸点击不残留鼠标指针，纯粹置 _revealed=true）。
    await tester.tap(_revealHotZone);
    await tester.pump();
    expect(_revealHotZone, findsNothing, reason: '显形后揭开热区消失，A 变清晰');

    // ③ 进入无字幕间隙：整层卸载，承载 hover 的 MouseRegion 一并消失（onExit 不派发）。
    await _pumpAt(tester, c, 3000);
    expect(_revealHotZone, findsNothing, reason: '间隙内两层皆空，不渲染字幕层');

    // ④ 下一条字幕 B：必须重新模糊——揭开热区应再次出现。
    // 回归前：_revealed 锁死 true，B 直接清晰（此断言 findsOneWidget 失败）。
    await _pumpAt(tester, c, 5000);
    expect(_revealHotZone, findsOneWidget,
        reason: 'BUG-1068：鼠标未回到字幕上，B 应恢复模糊而非残留 A 的显形态');
  });
}
