import 'package:flutter/gestures.dart';
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
      // BUG-321/TODO-569：每字 stroke+fill 双层，取 .first（两层同几何）。
      final Rect charRect = tester.getRect(find.text('A').first);
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

    // 取一个明确低于避让高的基线（与具体 reserve 数值解耦，TODO-171 把 reserve 从 98
    // 降到 56 后，默认基线 75 已高于 reserve，故验证「抬到 reserve」的几何前提必须用低
    // 于 reserve 的基线才成立）。低 1px 保证 < reserve 且与其联动。
    const double lowBaseline = kVideoControlsBottomReserve - 1;

    testWidgets('controls visible -> 基线低于避让高时字幕底缘抬到避让高（骑进度条上缘）',
        (tester) async {
      // 控制条可见时字幕底缘 = max(bottomPadding, reserve)：基线 < 避让高，故抬到 reserve
      // 恰骑进度条上缘（避开进度条又不飞）。撤回成旧的加法（基线 + reserve，凭空多抬一个
      // 基线、把字幕顶进画面中上部 = 用户报「进度条出来把字幕往上顶太高很怪」）则 gap 远
      // 大于 reserve => 红。撤回成完全不避让则 gap=基线 < reserve => 红。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: lowBaseline,
          controlsVisible: visible,
        ),
      );
      // AnimatedPadding 动画到位。
      await tester.pumpAndSettle();
      expect(
        gapFromBottom(tester),
        closeTo(kVideoControlsBottomReserve + kBoxPadBottom, 0.5),
        reason: '控制条可见时字幕底缘应骑到进度条上缘（max(基线, 避让 $kVideoControlsBottomReserve)），'
            '不再凭空多抬一个基线（TODO-161/171）',
      );
    });

    testWidgets('controls hide -> subtitle drops back to the user baseline',
        (tester) async {
      // 控制条隐藏（visible 翻 false）：字幕落回 bottomPadding 基线，不再被避让恒抬高
      // （这正是反转 089「恒抬升」的核心：进度条不在时不留空白）。用低于 reserve 的基线，
      // 可见时才有抬升、隐藏才有落差可断言。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: lowBaseline,
          controlsVisible: visible,
        ),
      );
      await tester.pumpAndSettle();
      final double visibleGap = gapFromBottom(tester);
      // 可见：底缘对避让高取下限 = max(基线, reserve) = reserve（基线低于 reserve）。
      expect(visibleGap,
          closeTo(kVideoControlsBottomReserve + kBoxPadBottom, 0.5));

      visible.value = false;
      await tester.pumpAndSettle();
      final double hiddenGap = gapFromBottom(tester);
      expect(hiddenGap, closeTo(lowBaseline + kBoxPadBottom, 0.5),
          reason: '控制条隐藏后字幕应落回用户基线，不残留避让抬升');
      // 核心守卫（不依赖盒内 padding）：上顶增量 = 取下限差（避让高 - 基线 = 1px），
      // 不是整段避让高 reserve——后者是旧的加法 bug（凭空多抬一个基线，TODO-161）。
      expect(visibleGap - hiddenGap,
          closeTo(kVideoControlsBottomReserve - lowBaseline, 0.5));
    });

    testWidgets('manual low bottomPadding: 隐藏尊重低位，可见取下限躲进度条（不叠加飞走）',
        (tester) async {
      // 用户显式低位置（20px）< 避让高（56）：隐藏时尊重 20（贴底是用户的选择），可见时
      // max(20, 56) = 56 恰躲开进度条——不是 20+56=76 的加法叠加（那会把低位用户的字幕
      // 也顶飞，TODO-161）。
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
      // 控制条隐藏：尊重用户低位置。
      expect(gapFromBottom(tester), closeTo(20 + kBoxPadBottom, 0.5));

      visible.value = true;
      await tester.pumpAndSettle();
      // 控制条可见：对避让高取下限 = max(20, 56) = 56（躲进度条），非 20+56。
      expect(gapFromBottom(tester),
          closeTo(kVideoControlsBottomReserve + kBoxPadBottom, 0.5));
    });

    testWidgets('manual high bottomPadding stays verbatim (基线 > 避让则取基线，不被改写)',
        (tester) async {
      // 用户显式高位置（200px）> 避让高：取下限 max(200, 56) = 200，可见 / 隐藏都用 200
      // ——高位用户已在进度条之上，避让不该把它再往上推或往下拉，尊重原值。
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 200,
          controlsVisible: visible,
        ),
      );
      await tester.pumpAndSettle();
      // 可见：max(200, 56) = 200。
      expect(gapFromBottom(tester), closeTo(200 + kBoxPadBottom, 0.5));

      visible.value = false;
      await tester.pumpAndSettle();
      // 隐藏：仍 200（基线）。
      expect(gapFromBottom(tester), closeTo(200 + kBoxPadBottom, 0.5));
    });

    group('TODO-364 字幕避让方向始终跟随单一真相源（不反相）', () {
      // 根因守卫（消费侧）：字幕避让只读 controlsVisible 这一个 notifier，padding 方向必须
      // 与该 notifier 的真实值单调对应——可见=抬到 reserve、隐藏=落回基线，任意快速翻转
      // 序列都不出现「方向反」（避让目标恒等于 notifier 当前值，无独立计时/取反旁路）。
      // 视频页根因（镜像 + 第二个 Timer 相位反）由 video_subtitle_push_up_guard_test.dart
      // 锁结构、需真机验观感；本测试锁定 overlay 对单一真相源的方向一致性。
      const double lowBaselineForDodge = kVideoControlsBottomReserve - 1;

      double dodgeGap(WidgetTester tester) => gapFromBottom(tester);

      testWidgets('显示→隐藏→显示：每一步方向都跟随 notifier，不反相', (tester) async {
        final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
        addTearDown(visible.dispose);
        final VideoPlayerController c = _controllerWithCue('A');
        await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            bottomPadding: lowBaselineForDodge,
            controlsVisible: visible,
          ),
        );
        await tester.pumpAndSettle();
        // 初始隐藏：贴基线。
        final double hidden0 = dodgeGap(tester);
        expect(hidden0, closeTo(lowBaselineForDodge + kBoxPadBottom, 0.5));

        // 显示：抬到 reserve（> 基线）——方向「上」。
        visible.value = true;
        await tester.pumpAndSettle();
        final double shown1 = dodgeGap(tester);
        expect(
            shown1, closeTo(kVideoControlsBottomReserve + kBoxPadBottom, 0.5));
        expect(shown1, greaterThan(hidden0),
            reason: '显示时字幕必须上抬（gap 变大），不能反向下落');

        // 隐藏：落回基线（< reserve）——方向「下」。
        visible.value = false;
        await tester.pumpAndSettle();
        final double hidden2 = dodgeGap(tester);
        expect(hidden2, closeTo(lowBaselineForDodge + kBoxPadBottom, 0.5));
        expect(hidden2, lessThan(shown1), reason: '隐藏时字幕必须下落（gap 变小），不能反向上抬');

        // 再显示：再次上抬，方向与第一次一致（不因前序操作而反相）。
        visible.value = true;
        await tester.pumpAndSettle();
        final double shown3 = dodgeGap(tester);
        expect(shown3, closeTo(shown1, 0.5),
            reason: '同一真相源同一值必须给出同一避让位置（无相位漂移）');
      });

      testWidgets('动画途中翻回（并发操作）：避让目标恒等于 notifier 最终值，不残留反向', (tester) async {
        // 模拟「进度条起来途中又来一次操作把它按下去」：上抬动画未结束就把 notifier 翻回
        // 隐藏，最终必须停在隐藏基线（跟随真相源最终值），不会卡在反向的上抬位置。
        final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
        addTearDown(visible.dispose);
        final VideoPlayerController c = _controllerWithCue('A');
        await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            bottomPadding: lowBaselineForDodge,
            controlsVisible: visible,
          ),
        );
        await tester.pumpAndSettle();

        // 开始上抬，只推进一帧（动画进行中）。
        visible.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        // 动画途中翻回隐藏（并发操作）。
        visible.value = false;
        await tester.pumpAndSettle();
        // 最终停在隐藏基线，跟随真相源最终值（不卡在上抬的反向位置）。
        expect(
            dodgeGap(tester), closeTo(lowBaselineForDodge + kBoxPadBottom, 0.5),
            reason: '并发翻回后避让目标必须跟随 notifier 最终值（隐藏=基线），不反相残留');
      });
    });

    group('BUG-238 视频页传入真实几何 reserve（盖过被抬高的移动进度条）', () {
      // 视频页移动端实际传入的 reserve ≈ 进度条上缘高度（基线 + 按钮行 + 间距 + 热区，
      // ×缩放），远大于默认基线 75。旧默认常量 56 < 75 → max(75,56)=75 把字幕留在进度条
      // 下面被遮（用户报「只动一点点」=实际 0）。本组用「显式大 reserve」复刻视频页接线，
      // 断言字幕真正被抬过进度条；并验证 reserve 越大（界面放大）抬得越高。
      const double mobileReserveAt1x = 140; // 24 + 56 + 8 + 52（与页面几何一致）。
      const double mobileReserveAt2x = 256; // 24 + (56+8+52)*2。

      testWidgets(
          'controls visible + 真实 reserve(140) > 默认基线 75：字幕抬到 reserve（盖过进度条）',
          (tester) async {
        // 根因守卫：默认基线 75 + 真实移动 reserve 140 → max(75,140)=140，字幕底缘抬到
        // 进度条上缘（盖过被抬高的移动进度条）。撤回 reserve 到旧常量 56 → max(75,56)=75
        // < 140，字幕停在 75 被遮（「只动一点点」）→ 红。
        final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
        addTearDown(visible.dispose);
        final VideoPlayerController c = _controllerWithCue('A');
        await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            bottomPadding: 75, // 默认基线。
            controlsVisible: visible,
            controlsBottomReserve: mobileReserveAt1x,
          ),
        );
        await tester.pumpAndSettle();
        // 字幕底缘抬到 reserve 140，严格高于默认基线 75（真正盖过进度条）。
        expect(gapFromBottom(tester),
            closeTo(mobileReserveAt1x + kBoxPadBottom, 0.5));
        expect(gapFromBottom(tester), greaterThan(75 + kBoxPadBottom),
            reason: '控制条可见时字幕底缘必须严格高于默认基线 75 才不被进度条遮（根因）');
      });

      testWidgets('controls hide + 真实 reserve(140)：字幕落回默认基线 75（不残留避让）',
          (tester) async {
        final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
        addTearDown(visible.dispose);
        final VideoPlayerController c = _controllerWithCue('A');
        await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            bottomPadding: 75,
            controlsVisible: visible,
            controlsBottomReserve: mobileReserveAt1x,
          ),
        );
        await tester.pumpAndSettle();
        final double visibleGap = gapFromBottom(tester);
        expect(visibleGap, closeTo(mobileReserveAt1x + kBoxPadBottom, 0.5));

        visible.value = false;
        await tester.pumpAndSettle();
        // 隐藏：落回默认基线 75（= bottomPadding，无避让残留）。
        expect(gapFromBottom(tester), closeTo(75 + kBoxPadBottom, 0.5),
            reason: '控制条隐藏后字幕落回 bottomPadding 基线');
      });

      testWidgets('reserve 随界面放大（256 > 140）：字幕抬得更高（避让随缩放）', (tester) async {
        // 界面放大后控制条变高，视频页传入更大的 reserve（256），字幕避让随之抬得更高。
        // 旧常量 56 恒定不随缩放、放大后仍盖不住 → 红。
        final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
        addTearDown(visible.dispose);
        final VideoPlayerController c = _controllerWithCue('A');
        await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            bottomPadding: 75,
            controlsVisible: visible,
            controlsBottomReserve: mobileReserveAt2x,
          ),
        );
        await tester.pumpAndSettle();
        expect(gapFromBottom(tester),
            closeTo(mobileReserveAt2x + kBoxPadBottom, 0.5));
        expect(mobileReserveAt2x, greaterThan(mobileReserveAt1x),
            reason: '界面放大后 reserve 必须更大（避让随缩放）');
      });
    });
  });

  testWidgets('blur off: no ImageFiltered around subtitle', (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(
        tester, VideoSubtitleOverlay(controller: c, blurEnabled: false));
    // 双层：stroke + fill 两个 Text（BUG-321/TODO-569）。
    expect(find.text('テ'), findsNWidgets(2));
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

  group('TODO-301/BUG-267 favorited current cue shows a star marker', () {
    testWidgets('isCueFavorited true -> filled star icon rendered', (
      tester,
    ) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          isCueFavorited: (_) => true,
        ),
      );
      // Revert the marker / pass isCueFavorited:false -> findsNothing -> red.
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('isCueFavorited false -> no star marker (pixel-identical)', (
      tester,
    ) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          isCueFavorited: (_) => false,
        ),
      );
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('isCueFavorited null -> no star marker (no data source)', (
      tester,
    ) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      expect(find.byIcon(Icons.star), findsNothing);
    });
  });

  testWidgets('appearance: custom font size applied', (tester) async {
    final VideoPlayerController c = _controllerWithCue('A');
    await _pump(
      tester,
      VideoSubtitleOverlay(controller: c, fontSize: 40),
    );
    // 取填充层（foreground==null）断言字号（BUG-321/TODO-569 双层）。
    final Text txt = tester
        .widgetList<Text>(find.text('A'))
        .firstWhere((Text t) => t.style?.foreground == null);
    expect(txt.style?.fontSize, 40);
  });

  group('hitTester 按全局坐标反查字幕字符（点同句换词不恢复播放的基础）', () {
    testWidgets('命中字符返回正确的整句 + grapheme 下标 + 矩形', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      final Offset center =
          tester.getCenter(find.text('ス').first); // grapheme 1
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

      final Offset center = tester.getCenter(find.text('ス').first);
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
      await tester.tapAt(tester.getCenter(find.text('ス').first)); // grapheme 1
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

  group('BUG-284 hover 字幕盒回报 onHoverChanged（页面据此唤回光标 + 续命控制条）', () {
    testWidgets('鼠标进 / 出字幕盒分别回调 true / false', (tester) async {
      final VideoPlayerController c = _controllerWithCue('A');
      final List<bool> events = <bool>[];
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onHoverChanged: events.add,
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      // 移到字幕字符上 → onHoverChanged(true)。
      await gesture.moveTo(tester.getCenter(find.text('A').first));
      await tester.pump();
      expect(events, contains(true),
          reason: '鼠标进字幕盒应回报 hover=true（页面据此唤回光标，BUG-284）');

      // 移出到角落 → onHoverChanged(false)。
      await gesture.moveTo(const Offset(2, 2));
      await tester.pump();
      expect(events.last, isFalse, reason: '鼠标出字幕盒应回报 hover=false');
    });

    testWidgets('注册 onHoverChanged 才挂字幕盒 hover 追踪（非 blur 基线对照）',
        (tester) async {
      // 对照同一非 blur 布局：注册 onHoverChanged 比不注册多出恰一个用于追踪字幕盒
      // hover 的 MouseRegion（仅 hover 需要时才挂，否则透传 box，保外观零变化，BUG-284）。
      final VideoPlayerController c1 = _controllerWithCue('A');
      await _pump(tester, VideoSubtitleOverlay(controller: c1));
      final int baseline = find.byType(MouseRegion).evaluate().length;

      final VideoPlayerController c2 = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c2, onHoverChanged: (_) {}),
      );
      final int withHover = find.byType(MouseRegion).evaluate().length;

      expect(withHover, baseline + 1,
          reason: '注册 onHoverChanged 应恰多挂一个字幕盒 hover MouseRegion；'
              '不注册时透传 box 不引入额外层（外观零变化）');
    });
  });
}
