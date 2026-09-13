import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2235：遮蔽字幕在**查词浮层的「重播本句」**期间又被遮回去。
///
/// 用户诉求原话：「隐藏字幕、暂停、查词点重播按钮会让字幕隐藏」。
///
/// 根因：BUG-2198 把「遮蔽让位」的判据统一成了 `!revealed && controller.isPlaying`，
/// 而 `isPlaying` 只是「用户已经停下来在看这句」的**近似**。查词浮层顶栏的「重播本句」
/// （`video_fushi/lookup_favorite.part.dart` 的 `_replayLookupCue` → `replayCue`）会把
/// 播放拉起来，于是查词刚让位的字幕在重播那几秒当场消失——用户正对着浮层核对原句。
/// 且同一条门还门控着 `registerHits`：遮回去的同时字符也不再可点，浮层里换词都点不到。
///
/// 修法：让位的真值改成「用户在看」= 暂停 **或** 查词浮层还开着
/// （[VideoSubtitleOverlay.lookupPopupVisible] ← 页面 `_hasVisiblePopup`）。判据仍只有
/// 一份，模糊 / 隐藏、主 / 副字幕共用。
///
/// 分两层验证：
///  ① overlay 真行为——播放中 + 浮层可见 = 不遮蔽；浮层关掉立刻遮回去（防「一刀关掉遮蔽」
///     式伪修复）；模糊 / 副字幕同一条门；显形期间字符照常登记查词命中。
///  ② 接线守卫（源码扫描）——layout 必须把 `_hasVisiblePopup` 传进 overlay，且重播确实
///     会起播（本 bug 成立的前提，改掉重播语义时本条提醒同步复核）。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

/// 该 widget 是否被某个 `opacity == 0` 的 [Opacity] 祖先包住（= 布局在、不绘制）。
bool _obscured(WidgetTester tester, Finder of) => tester
    .widgetList<Opacity>(
        find.ancestor(of: of.first, matching: find.byType(Opacity)))
    .any((Opacity o) => o.opacity == 0);

/// 该 widget 是否被 [ImageFiltered] 祖先包住（= 模糊态的视觉）。测试 cue 不带 ASS
/// `\blur`，字幕树里唯一的 ImageFiltered 只可能是遮蔽层。
bool _blurred(WidgetTester tester, Finder of) => tester
    .widgetList<ImageFiltered>(
        find.ancestor(of: of.first, matching: find.byType(ImageFiltered)))
    .isNotEmpty;

/// 重播中的控制器：**正在播放**（这正是本 bug 的触发条件——暂停态早被 BUG-2198 覆盖）。
VideoPlayerController _playingController(
  WidgetTester tester, {
  String main = '主',
  String? secondary,
}) {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(<AudioCue>[_cue(main, 0, 6000)]);
  if (secondary != null) {
    c.setSecondaryCues(<AudioCue>[_cue(secondary, 0, 6000)]);
  }
  c.debugUpdateCueForPosition(1000);
  c.debugSetIsPlayingForTesting(true);
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c, {
  bool subtitleHidden = false,
  bool secondaryHidden = false,
  bool blurEnabled = false,
  bool lookupPopupVisible = false,
  void Function(
          String sentence, int graphemeIndex, Rect charRect, AudioCue cue)?
      onCharTap,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        subtitleHidden: subtitleHidden,
        secondaryHidden: secondaryHidden,
        blurEnabled: blurEnabled,
        lookupPopupVisible: lookupPopupVisible,
        onCharTap: onCharTap,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('BUG-2235 ① 查词浮层开着时遮蔽让位（哪怕在播放）', () {
    testWidgets('hidden + 播放中 + 浮层可见：字幕可见（重播本句不再把它遮回去）', (tester) async {
      final VideoPlayerController c = _playingController(tester);

      await _pump(tester, c, subtitleHidden: true, lookupPopupVisible: true);

      expect(find.text('主'), findsWidgets);
      expect(_obscured(tester, find.text('主')), isFalse,
          reason: '查词会话期间字幕恒定让位——重播起播不是「用户不看了」');
    });

    testWidgets('hidden + 播放中 + 浮层已关：照常遮蔽（防一刀关掉遮蔽的伪修复）', (tester) async {
      final VideoPlayerController c = _playingController(tester);

      await _pump(tester, c, subtitleHidden: true);

      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '让位只在查词会话内；关栈恢复播放后该遮还得遮');
    });

    testWidgets('关掉浮层的那一帧立刻遮回去（同一 controller 仍在播）', (tester) async {
      final VideoPlayerController c = _playingController(tester);

      await _pump(tester, c, subtitleHidden: true, lookupPopupVisible: true);
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：查词中可见');

      await _pump(tester, c, subtitleHidden: true);

      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '关栈 = 查词结束，遮蔽下一帧自动回来（不靠复位显形态）');
    });

    testWidgets('blur 走同一条门：播放中 + 浮层可见不糊（模糊 / 隐藏对称）', (tester) async {
      final VideoPlayerController c = _playingController(tester);

      await _pump(tester, c, blurEnabled: true, lookupPopupVisible: true);

      expect(_blurred(tester, find.text('主')), isFalse,
          reason: '两种视觉共用一条判据，不得再长出第二份');
    });

    testWidgets('blur + 浮层已关：照常模糊（对称基准）', (tester) async {
      final VideoPlayerController c = _playingController(tester);

      await _pump(tester, c, blurEnabled: true);

      expect(_blurred(tester, find.text('主')), isTrue);
    });

    testWidgets('副字幕同一条门：播放中 + 浮层可见时也让位', (tester) async {
      final VideoPlayerController c =
          _playingController(tester, secondary: '副');

      await _pump(tester, c,
          subtitleHidden: true,
          secondaryHidden: true,
          lookupPopupVisible: true);

      expect(_obscured(tester, find.text('副')), isFalse,
          reason: '副字幕的遮蔽与主字幕共用「用户在看」判据');
      expect(_obscured(tester, find.text('主')), isFalse);
    });

    testWidgets('让位期间字符照常可点选查词（registerHits 同一条门）', (tester) async {
      final VideoPlayerController c = _playingController(tester);
      final List<String> taps = <String>[];

      await _pump(
        tester,
        c,
        subtitleHidden: true,
        lookupPopupVisible: true,
        onCharTap: (String sentence, int index, Rect rect, AudioCue cue) =>
            taps.add('$sentence@$index'),
      );
      await tester.tap(find.text('主').first, warnIfMissed: false);
      await tester.pump();

      expect(taps, isNotEmpty, reason: '看得见就必须点得到——浮层里换词全靠这条命中登记');
    });
  });

  group('BUG-2235 ② 接线守卫（源码扫描）', () {
    String readSrc(String path) => File(path).readAsStringSync();

    test('layout 把查词浮层可见性传进字幕 overlay', () {
      final String src =
          readSrc('lib/src/pages/implementations/video_fushi/layout.part.dart');
      expect(src, contains('lookupPopupVisible: _hasVisiblePopup'),
          reason: 'overlay 侧修好了但页面不传 = 用户侧毫无变化');
    });

    test('查词浮层「重播本句」确实会起播（本 bug 成立的前提）', () {
      final String src = readSrc(
          'lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart');
      expect(src, contains('_replayLookupCue'));
      expect(src, contains('controller.replayCue(cue)'),
          reason: '重播语义若改动，需同步复核「查词中让位」这条门是否仍必要');
    });
  });
}
