// BUG-2540：`\fax`/`\fay` 切变曾用 setEntry 直接改 (0,1)/(1,0)，把 rotateZ 已写入的
// ±sin θ 整个覆盖——带 `\frz` 的招牌一加 `\fax` 就既不是旋转也不是切变，手写字歪斜。
// libass `calc_transform_matrix`：先切变再旋转（R·Shear）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(String raw) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 1280, playResY: 720);
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

void main() {
  test('assShearMatrix：x\' = x + fax·y，y\' = y + fay·x', () {
    final Matrix4 m = assShearMatrix(0.3, -0.2);
    expect(m.entry(0, 1), 0.3);
    expect(m.entry(1, 0), -0.2);
    expect(m.entry(0, 0), 1);
    expect(m.entry(1, 1), 1);
  });

  testWidgets(r'\frz30\fax0.3：招牌变换 = R(-30°)·Shear(0.3)，旋转项不被切变覆盖',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final VideoPlayerController c = VideoPlayerController()
      ..debugVideoWidthOverride = 1280
      ..debugVideoHeightOverride = 720;
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[_cue(r'{\an7\pos(200,200)\frz30\fax0.3}看')]);
    c.debugUpdateCueForPosition(1000);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
        ),
      ),
    ));
    await tester.pump();

    final Iterable<Transform> ancestors = tester.widgetList<Transform>(
      find.ancestor(of: find.text('看').first, matching: find.byType(Transform)),
    );
    final Transform t = ancestors.firstWhere(
        (Transform x) => x.transform.entry(1, 0).abs() > 0.1,
        orElse: () => throw StateError('未找到旋转 Transform'));
    final Matrix4 m = t.transform;
    // Flutter rotateZ(-30°) = [[cos, sin],[-sin, cos]]（θ 取负），右乘 Shear[[1,fax],[0,1]]。
    final double cs = math.cos(math.pi / 6);
    final double sn = math.sin(math.pi / 6);
    expect(m.entry(0, 0), closeTo(cs, 0.02));
    expect(m.entry(1, 0), closeTo(-sn, 0.02), reason: '旋转反对角项必须保留');
    expect(m.entry(0, 1), closeTo(cs * 0.3 + sn, 0.02),
        reason: '(0,1) = R·Shear 的合成项，不是裸 fax');
    expect(m.entry(1, 1), closeTo(-sn * 0.3 + cs, 0.02));
  });
}
