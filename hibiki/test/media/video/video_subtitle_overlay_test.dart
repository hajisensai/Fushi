import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(String text) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch'
    ..sentenceIndex = 0
    ..textFragmentId = '#s1'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100); // 让 currentCue=该句
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('dynamic dodge of the bottom controls bar (TODO-129)', () {
    // 字幕字符底缘到容器底的距离 = bottomPadding + 控制条避让(可见时) + 字幕盒自身的
    // 垂直内 padding（实现细节，[EdgeInsets.symmetric(vertical: 6)] 的底部 6px）。守卫
    // 把这个固定偏移算进期望值，断言才精确锁定真正语义量（避让叠加 / 落回）。
    const double kBoxPadBottom = 6;
    double gapFromBottom(WidgetTester tester) {
      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text('A'));
      return overlayRect.bottom - charRect.bottom;
    }

    testWidgets(
        'no controlsVisible: subtitle sits at the user baseline (no dodge)',
        (tester) async {
      // 无控制条可见性（有声书 / 测试 / 无控制条场景）：字幕恒贴 bottomPadding 基线，
      // 不叠加任何避让（与历史像素级一致）。
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, bottomPadding: 75),
      );
      expect(gapFromBottom(tester), closeTo(75 + kBoxPadBottom, 0.5));
    });

    testWidgets(
        'controls visible -> subtitle lifts by exactly the controls reserve',
        (tester) async {
      // 控制条可见时字幕在用户基线之上额外上顶 [kVideoControlsBottomReserve]（进度条
      // 把字幕往上顶对应高度）。撤回修复（不读 controlsVisible / 不叠加 reserve）则
      // gap 仍是 75 < 期望 => 红。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 75,
          controlsVisible: visible,
        ),
      );
      // AnimatedPadding 动画到位。
      await tester.pumpAndSettle();
      expect(
        gapFromBottom(tester),
        closeTo(75 + kVideoControlsBottomReserve + kBoxPadBottom, 0.5),
        reason: '控制条可见时字幕应在基线 75 之上叠加 $kVideoControlsBottomReserve',
      );
    });

    testWidgets('controls hide -> subtitle drops back to the user baseline',
        (tester) async {
      // 控制条隐藏（visible 翻 false）：字幕落回 bottomPadding 基线，不再被避让恒抬高
      // （这正是反转 089「恒抬升」的核心：进度条不在时不留空白）。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 75,
          controlsVisible: visible,
        ),
      );
      await tester.pumpAndSettle();
      final double visibleGap = gapFromBottom(tester);
      expect(visibleGap,
          closeTo(75 + kVideoControlsBottomReserve + kBoxPadBottom, 0.5));

      visible.value = false;
      await tester.pumpAndSettle();
      final double hiddenGap = gapFromBottom(tester);
      expect(hiddenGap, closeTo(75 + kBoxPadBottom, 0.5),
          reason: '控制条隐藏后字幕应落回用户基线 75，不残留避让抬升');
      // 核心守卫（不依赖盒内 padding）：上顶增量恰为控制条避让量（进度条把字幕顶起对应
      // 高度）。撤回修复则差值为 0 => 红。
      expect(visibleGap - hiddenGap, closeTo(kVideoControlsBottomReserve, 0.5));
    });

    testWidgets(
        'manual lower bottomPadding stays the baseline the dodge stacks on',
        (tester) async {
      // 「除非用户手动调位置」：用户显式低位置（20px）是基线，控制条可见时避让叠加在
      // 其上（20 + reserve），隐藏时落回 20——手动位置永不被动态避让吞掉。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 20,
          controlsVisible: visible,
        ),
      );
      await tester.pumpAndSettle();
      // 控制条隐藏：尊重用户低位置（落进控制条区是用户的选择）。
      expect(gapFromBottom(tester), closeTo(20 + kBoxPadBottom, 0.5));

      visible.value = true;
      await tester.pumpAndSettle();
      // 控制条可见：避让叠加在用户基线 20 之上，不改写基线本身。
      expect(gapFromBottom(tester),
          closeTo(20 + kVideoControlsBottomReserve + kBoxPadBottom, 0.5));
    });
  });

  testWidgets('blur off: no ImageFiltered around subtitle', (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(
        tester, VideoSubtitleOverlay(controller: c, blurEnabled: false));
    expect(find.text('テ'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('blur on + playing: ImageFiltered wraps subtitle, revealed=false',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    c.debugSetIsPlayingForTesting(true); // 听力沉浸模糊只在播放中生效
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('blur on + playing + tap reveal: ImageFiltered gone after reveal',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    c.debugSetIsPlayingForTesting(true);
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.tap(find.byKey(const Key('video-subtitle-reveal')));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('appearance: custom font size applied', (tester) async {
    final VideoPlayerController c = _controllerWithCue('A');
    await _pump(
      tester,
      VideoSubtitleOverlay(controller: c, fontSize: 40),
    );
    final Text txt = tester.widget<Text>(find.text('A'));
    expect(txt.style?.fontSize, 40);
  });

  group('hitTester 按全局坐标反查字幕字符（点同句换词不恢复播放的基础）', () {
    testWidgets('命中字符返回正确的整句 + grapheme 下标 + 矩形', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      final Offset center = tester.getCenter(find.text('ス')); // grapheme 1
      final SubtitleCharHit? hit = ht.hitTest(center);
      expect(hit, isNotNull);
      expect(hit!.sentence, 'テスト');
      expect(hit.graphemeIndex, 1);
      expect(hit.charRect.contains(center), isTrue);
    });

    testWidgets('点字幕外的空白返回 null（barrier 据此走 dismiss）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      // 左上角远离底部居中的字幕。
      expect(ht.hitTest(const Offset(2, 2)), isNull);
    });

    testWidgets('模糊态（播放中）不反查（与点击不查词一致）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      c.debugSetIsPlayingForTesting(true); // 播放中才真模糊
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, hitTester: ht, blurEnabled: true),
      );

      final Offset center = tester.getCenter(find.text('ス'));
      expect(ht.hitTest(center), isNull);
    });

    testWidgets('无当前字幕句时返回 null', (tester) async {
      final VideoPlayerController c = VideoPlayerController(); // 无 cue
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      expect(ht.hitTest(const Offset(100, 100)), isNull);
    });
  });

  group('BUG-198 字幕字符层不吞鼠标 hover、tap 仍查词', () {
    testWidgets('字幕字符不再各自包 opaque GestureDetector（hover 透传）', (tester) async {
      // 旧实现每个字符包 HitTestBehavior.opaque 的 GestureDetector，吞掉指针
      // hover hit-test，盖在其下的 media_kit MouseRegion 收不到鼠标 → 鼠标移到
      // 字幕文字上控制条不再被唤起、光标被吃。根因修后字符层不得再有 opaque
      // GestureDetector；tap 命中统一交给一片 translucent GestureDetector。
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, onCharTap: (_, __, ___) {}),
      );
      final Iterable<GestureDetector> detectors =
          tester.widgetList<GestureDetector>(find.byType(GestureDetector));
      // 不允许任何 opaque GestureDetector（撤修复改回逐字符 opaque → 红）。
      for (final GestureDetector d in detectors) {
        expect(
          d.behavior,
          isNot(HitTestBehavior.opaque),
          reason: '字幕层出现 opaque GestureDetector，会吞 hover/光标（BUG-198 回归）',
        );
      }
      // 至少有一片 translucent 的 tap 层（承载查词）。
      expect(
        detectors.any((GestureDetector d) =>
            d.behavior == HitTestBehavior.translucent && d.onTapUp != null),
        isTrue,
        reason: '缺少 translucent 的字符 tap 层',
      );
    });

    testWidgets('tap 字幕字符仍触发 onCharTap（反查命中正确 grapheme）', (tester) async {
      String? tappedSentence;
      int? tappedIndex;
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _) {
            tappedSentence = s;
            tappedIndex = i;
          },
        ),
      );
      await tester.tapAt(tester.getCenter(find.text('ス'))); // grapheme 1
      await tester.pump();
      expect(tappedSentence, 'テスト');
      expect(tappedIndex, 1);
    });
  });

  group('BUG-199 听力沉浸模糊只在播放中、查词暂停保持清晰', () {
    testWidgets('播放中：ImageFiltered 模糊；暂停（查词）：清晰无模糊', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');

      // 播放中 → 模糊生效。
      c.debugSetIsPlayingForTesting(true);
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, blurEnabled: true),
      );
      expect(find.byType(ImageFiltered), findsOneWidget, reason: '播放中沉浸模式应模糊');

      // 暂停（查词必先暂停）→ 字幕清晰（撤 `&& isPlaying` → 仍模糊 → 红）。
      c.debugSetIsPlayingForTesting(false);
      await tester.pump();
      expect(find.byType(ImageFiltered), findsNothing,
          reason: '查词/暂停时字幕不该再被打码（BUG-199）');
    });
  });
}
