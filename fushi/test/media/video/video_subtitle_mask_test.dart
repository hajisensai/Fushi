import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_mask.dart';

VideoPlayerController _controller() => VideoPlayerController()
  ..debugVideoWidthOverride = 1920
  ..debugVideoHeightOverride = 1080;

Widget _host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: SizedBox(width: 800, height: 600, child: child),
);

const ValueKey<String> _blur = ValueKey<String>('video-subtitle-mask-blur');
const ValueKey<String> _solid = ValueKey<String>('video-subtitle-mask-solid');

void main() {
  group('VideoSubtitleMaskConfig JSON', () {
    test('round-trips every field', () {
      const VideoSubtitleMaskConfig c = VideoSubtitleMaskConfig(
        enabled: true,
        rect: Rect.fromLTWH(0.1, 0.7, 0.5, 0.2),
        style: VideoSubtitleMaskStyle.solid,
        strength: 0.4,
      );
      expect(VideoSubtitleMaskConfig.fromJson(c.toJson()), c);
    });

    test('empty / broken / partial input falls back to defaults', () {
      expect(
        VideoSubtitleMaskConfig.fromJson(null),
        const VideoSubtitleMaskConfig(),
      );
      expect(
        VideoSubtitleMaskConfig.fromJson('{not json'),
        const VideoSubtitleMaskConfig(),
      );
      expect(
        VideoSubtitleMaskConfig.fromJson('[1,2]'),
        const VideoSubtitleMaskConfig(),
      );
      final VideoSubtitleMaskConfig partial = VideoSubtitleMaskConfig.fromJson(
        '{"enabled":true,"style":"bogus","strength":7}',
      );
      expect(partial.enabled, isTrue);
      expect(partial.rect, VideoSubtitleMaskConfig.kDefaultRect);
      expect(partial.style, VideoSubtitleMaskStyle.blur);
      expect(partial.strength, 1.0);
    });
  });

  group('clampVideoSubtitleMaskRect', () {
    test('keeps size and shifts back inside the frame', () {
      final Rect r = clampVideoSubtitleMaskRect(
        const Rect.fromLTWH(0.8, 0.95, 0.4, 0.1),
      );
      expect(r.width, closeTo(0.4, 1e-9));
      expect(r.height, closeTo(0.1, 1e-9));
      expect(r.right, closeTo(1.0, 1e-9));
      expect(r.bottom, closeTo(1.0, 1e-9));
    });

    test('enforces the minimum size and caps at the full frame', () {
      final Rect tiny = clampVideoSubtitleMaskRect(
        const Rect.fromLTWH(0.5, 0.5, 0, 0.001),
      );
      expect(tiny.width, closeTo(kVideoSubtitleMaskMinFraction, 1e-9));
      expect(tiny.height, closeTo(kVideoSubtitleMaskMinFraction, 1e-9));
      final Rect huge = clampVideoSubtitleMaskRect(
        const Rect.fromLTWH(-1, -1, 3, 3),
      );
      expect(huge, const Rect.fromLTWH(0, 0, 1, 1));
    });
  });

  group('content rect / fraction mapping', () {
    test('contain letterboxes a 16:9 frame in a 4:3 view', () {
      final Rect content = videoSubtitleMaskContentRect(
        frame: const Size(1920, 1080),
        view: const Size(800, 600),
        fit: BoxFit.contain,
      );
      expect(content.left, closeTo(0, 1e-6));
      expect(content.width, closeTo(800, 1e-6));
      expect(content.height, closeTo(450, 1e-6));
      expect(content.top, closeTo(75, 1e-6));
      // 底部遮布落在画面内容区底部，而不是视口底部的黑边里。
      final Rect px = videoSubtitleMaskFractionToView(
        const Rect.fromLTWH(0, 0.9, 1, 0.1),
        content,
      );
      expect(px.bottom, closeTo(525, 1e-6));
      expect(px.top, closeTo(480, 1e-6));
    });

    test('unknown frame size falls back to the whole view', () {
      expect(
        videoSubtitleMaskContentRect(
          frame: null,
          view: const Size(640, 360),
          fit: BoxFit.contain,
        ),
        const Rect.fromLTWH(0, 0, 640, 360),
      );
    });
  });

  group('VideoSubtitleMaskLayer', () {
    Future<void> pump(
      WidgetTester tester,
      VideoPlayerController c,
      VideoSubtitleMaskConfig config,
      ValueNotifier<Rect?> draft,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          VideoSubtitleMaskLayer(
            controller: c,
            fit: BoxFit.contain,
            config: config,
            draftRect: draft,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('disabled: draws nothing', (WidgetTester tester) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(null);
      addTearDown(draft.dispose);
      await pump(tester, c, const VideoSubtitleMaskConfig(), draft);
      expect(find.byKey(_blur), findsNothing);
      expect(find.byKey(_solid), findsNothing);
    });

    testWidgets('blur sits inside the letterboxed picture, not the black bar', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(null);
      addTearDown(draft.dispose);
      await pump(
        tester,
        c,
        const VideoSubtitleMaskConfig(
          enabled: true,
          rect: Rect.fromLTWH(0, 0.9, 1, 0.1),
        ),
        draft,
      );
      expect(find.byKey(_solid), findsNothing);
      // 16:9 进 800×600：画面 y ∈ [75, 525]，遮布占画面最下 10% = [480, 525]。
      final Rect r = tester.getRect(find.byKey(_blur));
      expect(r.top, closeTo(480, 0.5));
      expect(r.bottom, closeTo(525, 0.5));
      expect(r.width, closeTo(800, 0.5));
    });

    testWidgets('solid uses strength as opacity', (WidgetTester tester) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(null);
      addTearDown(draft.dispose);
      await pump(
        tester,
        c,
        const VideoSubtitleMaskConfig(
          enabled: true,
          style: VideoSubtitleMaskStyle.solid,
          strength: 0.5,
        ),
        draft,
      );
      expect(find.byKey(_blur), findsNothing);
      final DecoratedBox box = tester.widget<DecoratedBox>(find.byKey(_solid));
      final Color color = (box.decoration as BoxDecoration).color!;
      expect(color.a, closeTo(0.5, 0.01));
    });

    testWidgets('a draft rect shows the mask even while disabled', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController c = _controller();
      addTearDown(c.dispose);
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(
        const Rect.fromLTWH(0.5, 0.5, 0.5, 0.5),
      );
      addTearDown(draft.dispose);
      await pump(tester, c, const VideoSubtitleMaskConfig(), draft);
      final Rect r = tester.getRect(find.byKey(_blur));
      expect(r.left, closeTo(400, 0.5));
      expect(r.top, closeTo(300, 0.5));
    });
  });

  testWidgets('edit layer: drag moves the draft, release commits', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final VideoPlayerController c = _controller();
    addTearDown(c.dispose);
    final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(
      const Rect.fromLTWH(0.2, 0.5, 0.4, 0.2),
    );
    addTearDown(draft.dispose);
    final List<Rect> committed = <Rect>[];
    await tester.pumpWidget(
      _host(
        VideoSubtitleMaskEditLayer(
          controller: c,
          fit: BoxFit.contain,
          config: const VideoSubtitleMaskConfig(),
          draftRect: draft,
          onCommit: committed.add,
        ),
      ),
    );
    // 画面 800×450：右移 80px = 0.1，下移 45px = 0.1。
    await tester.drag(
      find.byKey(const ValueKey<String>('video-subtitle-mask-move')),
      const Offset(80, 45),
    );
    await tester.pump();
    expect(committed, hasLength(1));
    expect(committed.single.left, closeTo(0.3, 0.02));
    expect(committed.single.top, closeTo(0.6, 0.02));
    expect(committed.single.width, closeTo(0.4, 1e-9));

    // 拖右下角缩放：尺寸变、左上角不动。
    await tester.drag(
      find.byKey(const ValueKey<String>('video-subtitle-mask-bottomRight')),
      const Offset(-80, -45),
    );
    await tester.pump();
    expect(committed.last.left, closeTo(committed.first.left, 1e-9));
    expect(committed.last.width, closeTo(0.3, 0.02));
  });
}
