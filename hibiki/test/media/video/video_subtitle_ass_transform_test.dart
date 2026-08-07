import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// TODO-1374：ASS 招牌类变换标签 `\frz` 旋转 / `\fscx`\`\fscy`(+`\t`) 缩放 / `\move` 运动。
/// 取自真实「双语.ass」的 `Scr` 招牌行。全部只影响画面装饰字（非对话查词）。
void main() {
  group('parser：\\frz / \\fscx\\fscy / \\t / \\move', () {
    test('\\frz + \\pos：旋转角解析，pos 保留，无缩放/运动', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\fs40\c&H311C23&\3c&HFDF9FD&\bord3\frz349.7\pos(354.169,265.845)}題',
        playResX: 1280,
        playResY: 720,
      );
      expect(m.rotationDeg, closeTo(349.7, 1e-6));
      expect(m.posFraction, isNotNull);
      expect(m.scale, isNull);
      expect(m.move, isNull);
      expect(m.plainText, '題');
    });

    test('\\fscy10 + \\t(18,226,\\fscy100)：缩放动画 from 0.1 → to 1.0，t=18..226',
        () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\fs40\bord3\pos(219,330)\fscy10\t(18,226,\fscy100)}生',
        playResX: 1280,
        playResY: 720,
      );
      final SubtitleScale? s = m.scale;
      expect(s, isNotNull);
      expect(s!.fromY, closeTo(0.1, 1e-9));
      expect(s.toY, closeTo(1.0, 1e-9));
      expect(s.fromX, 1.0);
      expect(s.isAnimated, isTrue);
      expect(s.t1Ms, 18);
      expect(s.t2Ms, 226);
      // 动画中点(t=122)纵向缩放约 (0.1+1.0)/2=0.55。
      final (double, double) mid = s.scaleAt(122, 5000);
      expect(mid.$2, closeTo(0.55, 0.02));
    });

    test('\\fscx60 + \\frz242.7 + \\move(...,23,3901)：静态横缩放 + 旋转 + 运动', () {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\c&H6064AD&\fscx60\frz242.7\move(555.514,287.987,618.545,287.987,23,3901)}止',
        playResX: 1280,
        playResY: 720,
      );
      expect(m.rotationDeg, closeTo(242.7, 1e-6));
      expect(m.scale, isNotNull);
      expect(m.scale!.fromX, closeTo(0.6, 1e-9));
      expect(m.scale!.isAnimated, isFalse); // 无 \t，静态缩放
      final SubtitleMove? mv = m.move;
      expect(mv, isNotNull);
      expect(mv!.x1Fraction, closeTo(555.514 / 1280, 1e-9));
      expect(mv.x2Fraction, closeTo(618.545 / 1280, 1e-9));
      expect(mv.t1Ms, 23);
      expect(mv.t2Ms, 3901);
      // 运动中点(相对起点 elapsed=(23+3901)/2=1962)横坐标在起止之间。
      final SubtitlePos p = mv.posAt(1962, 5000);
      expect(p.xFraction, greaterThan(mv.x1Fraction));
      expect(p.xFraction, lessThan(mv.x2Fraction));
    });

    test('respectAssStyle 语义无关：解析恒产出（渲染层按开关消费）', () {
      final SubtitleMarkup m = parseSubtitleMarkup(r'{\frz45}x');
      expect(m.rotationDeg, 45);
    });
  });

  group('render：\\frz 旋转招牌包 Transform（respectAssStyle 门控）', () {
    AudioCue rotatedSign() {
      final SubtitleMarkup m = parseSubtitleMarkup(
        r'{\frz30\pos(640,360)}看板',
        playResX: 1280,
        playResY: 720,
      );
      return AudioCue()
        ..bookKey = 'b'
        ..chapterHref = 'c'
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = m.plainText
        ..markup = m
        ..startMs = 0
        ..endMs = 5000;
    }

    Future<VideoPlayerController> pump(WidgetTester tester,
        {required bool respect}) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[rotatedSign()]);
      c.debugUpdateCueForPosition(1000);
      await tester.pumpWidget(MaterialApp(
        // 关调试横幅：它是一个 45° 旋转 Transform，会污染 [hasRotation] 扫描。
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child:
                VideoSubtitleOverlay(controller: c, respectAssStyle: respect),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    bool hasRotation(WidgetTester tester) {
      // 只看**包住字幕字符**的 Transform（find.ancestor），排除树里其它无关 Transform
      // （如某些框架 45° 旋转装饰）。旋转判据：左上 2x2 有显著反对角（\frz30 → sin30=0.5，
      // 阈值 0.1 远高于数值噪声）。
      final Iterable<Transform> ancestors = tester.widgetList<Transform>(
        find.ancestor(
            of: find.text('看').first, matching: find.byType(Transform)),
      );
      for (final Transform t in ancestors) {
        final Matrix4 m = t.transform;
        if ((m.entry(0, 1)).abs() > 0.1 || (m.entry(1, 0)).abs() > 0.1) {
          return true;
        }
      }
      return false;
    }

    testWidgets('respectAssStyle ON：招牌被旋转（存在旋转 Transform）',
        (WidgetTester tester) async {
      await pump(tester, respect: true);
      expect(find.text('看'), findsNWidgets(2)); // stroke+fill
      expect(hasRotation(tester), isTrue, reason: '\\frz30 应产出旋转 Transform');
    });

    testWidgets('respectAssStyle OFF：不旋转（历史行为，无旋转 Transform）',
        (WidgetTester tester) async {
      await pump(tester, respect: false);
      // 默认外观(OFF)=单层 fill+柔和阴影(PR#23/BUG-323)，无 stroke 层，故 1 个候选
      expect(find.text('看'), findsNWidgets(1));
      expect(hasRotation(tester), isFalse, reason: '关开关时忽略 \\frz，不旋转');
    });
  });
}
