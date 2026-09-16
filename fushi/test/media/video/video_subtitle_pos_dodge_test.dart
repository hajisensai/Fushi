// BUG-2537：`\pos` / `\move` 定位字幕**不随控制条显隐移动**。
//
// 历史（BUG-1332）让 `\pos` 盒与锚点分支共用「盒底探进控制条带就上抬」的避让契约，
// 代价是招牌 / OP 逐字歌词随控制条显隐上下跳，还会把落在鼠标停放点的招牌盒再挪一次
// 而自激唤起控制条。2026-09-14 所有者拍板：非标（定位）字幕是作者按画面内容摆的，
// mpv/libass 也从不因 OSC 显隐挪动它们；避让只留给锚点对白（[_paddingFor]）。
// 本组测试钉死：绝对定位盒逐像素等于作者位，控制条可见与否一律不参与。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  // 片源真值：\pos(461,672) 在 1280x720 画布（672/720 = 93.3%，正是进度条那一条）。
  const Offset opCharPos = Offset(461 / 1280 * 1920, 672 / 720 * 1080);
  const Size charBox = Size(57, 57);

  group('resolveAbsoluteCueOffset：纯锚点换算', () {
    test('\\an7 顶锚：盒左上角就落在 \\pos 上', () {
      final Offset o = resolveAbsoluteCueOffset(
          pos: opCharPos, child: charBox, anchorFx: 0, anchorFy: 0);
      expect(o.dy, closeTo(1008, 0.01));
      expect(o.dx, closeTo(461 / 1280 * 1920, 0.01));
    });

    test('\\an2 底居中：锚点比例参与换算', () {
      final Offset o = resolveAbsoluteCueOffset(
          pos: const Offset(960, 500),
          child: const Size(400, 60),
          anchorFx: 0.5,
          anchorFy: 1);
      expect(o.dx, closeTo(960 - 200, 0.01));
      expect(o.dy, closeTo(500 - 60, 0.01));
    });

    test('水平坐标恒为作者位——横向出屏另有根因（\\fn@ 竖排字体），不得用钳制掩盖', () {
      final Offset o = resolveAbsoluteCueOffset(
        pos: const Offset(10 / 1280 * 1920, 360 / 720 * 1080),
        child: const Size(700, 57),
        anchorFx: 0.5,
        anchorFy: 1,
      );
      expect(o.dx, closeTo(10 / 1280 * 1920 - 350, 0.01),
          reason: 'x 必须原样透传（含负值）');
    });
  });

  group('BUG-2537 widget：控制条可见时 \\pos 字幕一动不动', () {
    AudioCue posCue() {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\an7\pos(461,672)}手',
          playResX: 1280, playResY: 720);
      return AudioCue()
        ..bookKey = 'b'
        ..chapterHref = 'c'
        ..sentenceIndex = 0
        ..textFragmentId = '[data-cue-id="0"]'
        ..text = m.plainText
        ..markup = m
        ..startMs = 0
        ..endMs = 5000
        ..audioFileIndex = 0;
    }

    Future<Rect> pumpAndMeasure(WidgetTester tester,
        {required bool controlsVisible}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final VideoPlayerController c = VideoPlayerController()
        ..debugVideoWidthOverride = 1920
        ..debugVideoHeightOverride = 1080;
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[posCue()]);
      c.debugUpdateCueForPosition(1000);
      final ValueNotifier<bool> visible = ValueNotifier<bool>(controlsVisible);
      addTearDown(visible.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1920,
            height: 1080,
            child: VideoSubtitleOverlay(
              controller: c,
              respectAssStyle: true,
              controlsVisible: visible,
              controlsBottomReserve: 200,
              controlsTopReserve: 60,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return tester.getRect(find.text('手').first);
    }

    testWidgets('控制条隐藏 / 可见两态下字符矩形逐像素相同（作者位）',
        (WidgetTester tester) async {
      final Rect hidden = await pumpAndMeasure(tester, controlsVisible: false);
      final Rect shown = await pumpAndMeasure(tester, controlsVisible: true);
      expect(shown.top, closeTo(hidden.top, 0.01),
          reason: '\\pos 招牌不得随控制条上抬（BUG-2537）');
      expect(shown.left, closeTo(hidden.left, 0.01));
      // 且确实落在进度条带内（盒底 > 1080-200）：避让若还在，这里必然被抬走。
      expect(shown.bottom, greaterThan(1080 - 200),
          reason: '样本本就探进控制条带，是避让会命中的形状');
    });
  });

  group('源码守卫：\\pos 分支不得重新接上控制条避让', () {
    final String src = File('lib/src/media/video/video_subtitle_overlay.dart')
        .readAsStringSync();

    test('\\pos 分支仍走 _absolutePositioned（\\an 锚点要子盒真实尺寸）', () {
      final int branch = src.indexOf('final Offset? posScreen = _posScreen(');
      expect(branch, greaterThanOrEqualTo(0));
      final int branchEnd = src.indexOf('    // 无 \\pos：', branch);
      expect(branchEnd, greaterThan(branch));
      final String body = src.substring(branch, branchEnd);
      expect(body, contains('_absolutePositioned('));
      expect(body, isNot(contains('FractionalTranslation')));
    });

    test('resolveAbsoluteCueOffset 不再读控制条 reserve / 可见度', () {
      final int fn = src.indexOf('Offset resolveAbsoluteCueOffset(');
      expect(fn, greaterThanOrEqualTo(0));
      final int fnEnd = src.indexOf('class _AbsoluteCueLayoutDelegate', fn);
      expect(fnEnd, greaterThan(fn));
      final String body = src.substring(fn, fnEnd);
      expect(body, isNot(contains('bottomReserve')));
      expect(body, isNot(contains('topReserve')));
      expect(body, isNot(contains('dodgeProgress')));
    });
  });
}
