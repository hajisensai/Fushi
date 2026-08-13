import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// TODO-2838：视频字幕垂直位置增强——主字幕顶部锚定 + 位置上限 400 + 拖拽可视化调整。
///
/// 分五层验证：
///  ① 统一锚定解析纯函数 [resolveLayerForcedAnchor]：用户锚定 / ASS 自带位置 / 副字幕
///     自动对侧的优先级。
///  ② 拖拽落点解析纯函数 [resolveDragAdjustDrop]：上/下半屏定锚、中线连续、clamp 0..400。
///  ③ [VideoSubtitleStyle] 持久化：锚定字段 round-trip + 旧 blob（无字段）向后兼容。
///  ④ overlay 真几何：主字幕顶锚渲染在顶部（padding = 离顶距离）、控制条可见时避让
///     top reserve；主顶锚时副字幕自动落到底部（对侧规则）。
///  ⑤ 拖拽模式交互：模式内 tap 不再触发查词、拖拽松手回报锚定 + 距离、退出后查词恢复。
AudioCue _cue(String text, {int startMs = 0, int endMs = 5000}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = '#s1'
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100);
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('① resolveLayerForcedAnchor 统一锚定解析', () {
    test('主层默认（底锚、无 ASS 位置）→ null（历史底部基线路径）', () {
      expect(
        resolveLayerForcedAnchor(
          isSecondary: false,
          userAnchor: null,
          mainUserAnchor: SubtitleLayerVAnchor.bottom,
          ownNonBottom: false,
        ),
        isNull,
      );
    });

    test('主层用户顶锚（无 ASS 位置）→ 强制顶', () {
      expect(
        resolveLayerForcedAnchor(
          isSecondary: false,
          userAnchor: SubtitleLayerVAnchor.top,
          mainUserAnchor: SubtitleLayerVAnchor.top,
          ownNonBottom: false,
        ),
        SubtitleLayerVAnchor.top,
      );
    });

    test('ASS 自带非底位置优先于用户锚定（respectAssStyle 开时各遵其位）', () {
      // 尊重 ASS 模式下 \pos/\an 招牌若被用户锚定压平到同一顶部盒会互相叠印，
      // 故自带位置组不强制。纯字幕模式 markup 恒空、用户锚定事实上最高优先。
      expect(
        resolveLayerForcedAnchor(
          isSecondary: false,
          userAnchor: SubtitleLayerVAnchor.top,
          mainUserAnchor: SubtitleLayerVAnchor.top,
          ownNonBottom: true,
        ),
        isNull,
      );
      expect(
        resolveLayerForcedAnchor(
          isSecondary: true,
          userAnchor: SubtitleLayerVAnchor.bottom,
          mainUserAnchor: SubtitleLayerVAnchor.bottom,
          ownNonBottom: true,
        ),
        isNull,
      );
    });

    test('副层自动（null）：取主层对侧——主底→副顶（历史），主顶→副底（防同点叠印）', () {
      expect(
        resolveLayerForcedAnchor(
          isSecondary: true,
          userAnchor: null,
          mainUserAnchor: SubtitleLayerVAnchor.bottom,
          ownNonBottom: false,
        ),
        SubtitleLayerVAnchor.top,
        reason: '主底锚时副字幕自动置顶 = 历史行为',
      );
      expect(
        resolveLayerForcedAnchor(
          isSecondary: true,
          userAnchor: null,
          mainUserAnchor: SubtitleLayerVAnchor.top,
          ownNonBottom: false,
        ),
        SubtitleLayerVAnchor.bottom,
        reason: '主顶锚时副字幕自动落底，双层各占一边不叠印',
      );
    });

    test('副层显式锚定直接生效（拖拽落点写入后不再自动对侧）', () {
      expect(
        resolveLayerForcedAnchor(
          isSecondary: true,
          userAnchor: SubtitleLayerVAnchor.bottom,
          mainUserAnchor: SubtitleLayerVAnchor.bottom,
          ownNonBottom: false,
        ),
        SubtitleLayerVAnchor.bottom,
      );
    });
  });

  group('② resolveDragAdjustDrop 拖拽落点解析', () {
    test('盒中心在上半屏 → 顶锚 + 离顶距离（盒顶到顶边）', () {
      final ({SubtitleLayerVAnchor anchor, double padding}) r =
          resolveDragAdjustDrop(
              boxTop: 100, boxHeight: 40, containerHeight: 600);
      expect(r.anchor, SubtitleLayerVAnchor.top);
      expect(r.padding, 100);
    });

    test('盒中心在下半屏 → 底锚 + 离底距离（盒底到底边）', () {
      final ({SubtitleLayerVAnchor anchor, double padding}) r =
          resolveDragAdjustDrop(
              boxTop: 500, boxHeight: 40, containerHeight: 600);
      expect(r.anchor, SubtitleLayerVAnchor.bottom);
      expect(r.padding, 600 - 500 - 40);
    });

    test('屏幕中线连续：盒中心恰在中线时顶距 == 底距（拖过中线不跳变）', () {
      // 盒中心 = 300（= 600/2），boxTop = 280，boxH = 40：
      // 顶距 = 280，底距 = 600 - 280 - 40 = 280。两分支数值相等。
      final ({SubtitleLayerVAnchor anchor, double padding}) atMid =
          resolveDragAdjustDrop(
              boxTop: 280, boxHeight: 40, containerHeight: 600);
      expect(atMid.padding, 280);
      // 中线上方一像素 → 顶锚；下方一像素 → 底锚；padding 差 1（连续）。
      final ({SubtitleLayerVAnchor anchor, double padding}) above =
          resolveDragAdjustDrop(
              boxTop: 279, boxHeight: 40, containerHeight: 600);
      final ({SubtitleLayerVAnchor anchor, double padding}) below =
          resolveDragAdjustDrop(
              boxTop: 281, boxHeight: 40, containerHeight: 600);
      expect(above.anchor, SubtitleLayerVAnchor.top);
      expect(above.padding, 279);
      expect(below.anchor, SubtitleLayerVAnchor.bottom);
      expect(below.padding, 279);
    });

    test('clamp 进 [0, kVideoSubtitleMaxPadding]：拖出屏 → 0，超上限 → 400', () {
      expect(
        resolveDragAdjustDrop(boxTop: -50, boxHeight: 40, containerHeight: 600)
            .padding,
        0,
      );
      expect(
        resolveDragAdjustDrop(
                boxTop: 1500, boxHeight: 40, containerHeight: 2000)
            .padding,
        kVideoSubtitleMaxPadding,
        reason: '底锚离底 460 超上限，夹到 400',
      );
    });
  });

  group('③ VideoSubtitleStyle 锚定持久化', () {
    test('round-trip：mainAnchor=top + secondaryAnchor=bottom 编解码不变', () {
      final VideoSubtitleStyle s = VideoSubtitleStyle.defaults.copyWith(
        mainAnchor: SubtitleLayerVAnchor.top,
        secondaryAnchor: SubtitleLayerVAnchor.bottom,
        bottomPadding: 320,
      );
      final VideoSubtitleStyle back =
          VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
      expect(back.mainAnchor, SubtitleLayerVAnchor.top);
      expect(back.secondaryAnchor, SubtitleLayerVAnchor.bottom);
      expect(back.bottomPadding, 320);
    });

    test('旧 blob（无锚定字段）→ 主底锚 / 副自动（向后兼容，零迁移）', () {
      const String legacy =
          '{"_v":2,"fontSize":36,"bottomPadding":75,"backgroundOpacity":0}';
      final VideoSubtitleStyle s = VideoSubtitleStyle.decode(legacy);
      expect(s.mainAnchor, SubtitleLayerVAnchor.bottom);
      expect(s.secondaryAnchor, isNull);
    });

    test('未知锚定值 → 回退默认（主底锚 / 副自动），不炸不钉死', () {
      const String weird =
          '{"_v":2,"fontSize":36,"bottomPadding":75,"backgroundOpacity":0,'
          '"mainAnchor":"middle","secondaryAnchor":42}';
      final VideoSubtitleStyle s = VideoSubtitleStyle.decode(weird);
      expect(s.mainAnchor, SubtitleLayerVAnchor.bottom);
      expect(s.secondaryAnchor, isNull);
    });

    test('bottomPadding 解码上限 = kVideoSubtitleMaxPadding（400），不再是 240', () {
      const String high =
          '{"_v":2,"fontSize":36,"bottomPadding":399,"backgroundOpacity":0}';
      expect(VideoSubtitleStyle.decode(high).bottomPadding, 399);
      const String over =
          '{"_v":2,"fontSize":36,"bottomPadding":9999,"backgroundOpacity":0}';
      expect(VideoSubtitleStyle.decode(over).bottomPadding,
          kVideoSubtitleMaxPadding);
    });
  });

  group('④ overlay 真几何：主字幕顶锚', () {
    // 字幕盒自身的垂直内 padding（EdgeInsets.symmetric(vertical: 6) 的顶部 6px）。
    const double kBoxPadTop = 6;

    double gapFromTop(WidgetTester tester, String text) {
      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text(text).first);
      return charRect.top - overlayRect.top;
    }

    double gapFromBottom(WidgetTester tester, String text) {
      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text(text).first);
      return overlayRect.bottom - charRect.bottom;
    }

    testWidgets('mainAnchor=top：主字幕渲染在顶部，bottomPadding 语义 = 离顶距离',
        (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('A');
      addTearDown(c.dispose);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 50,
          mainAnchor: SubtitleLayerVAnchor.top,
        ),
      );
      expect(gapFromTop(tester, 'A'), closeTo(50 + kBoxPadTop, 0.5),
          reason: '顶锚时主字幕顶缘离顶 = 用户位置（+盒内 padding），镜像副字幕置顶路径');
    });

    testWidgets('mainAnchor=top + 控制条可见：避让 controlsTopReserve（取下限）',
        (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('A');
      addTearDown(c.dispose);
      final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
      addTearDown(visible.dispose);
      const double kTopReserve = 300;
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 12,
          mainAnchor: SubtitleLayerVAnchor.top,
          controlsVisible: visible,
          controlsTopReserve: kTopReserve,
        ),
      );

      double maxAnimatedTop() => tester
          .widgetList<AnimatedPadding>(find.byType(AnimatedPadding))
          .map((AnimatedPadding p) => p.padding.resolve(TextDirection.ltr).top)
          .fold<double>(0, (double a, double b) => b > a ? b : a);

      expect(maxAnimatedTop(), 12, reason: '控制条隐藏：贴用户基线');
      visible.value = true;
      await tester.pump();
      expect(maxAnimatedTop(), kTopReserve,
          reason: '控制条可见：顶锚主字幕下移到顶栏下方（BUG-1069 同契约）');
    });

    testWidgets('mainAnchor=top 时副字幕自动落底（对侧规则，不与主字幕同点叠印）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主')]);
      c.setSecondaryCues(<AudioCue>[_cue('副')]);
      c.debugUpdateCueForPosition(100);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 50,
          secondaryBottomPadding: 80,
          mainAnchor: SubtitleLayerVAnchor.top,
        ),
      );
      expect(gapFromTop(tester, '主'), closeTo(50 + kBoxPadTop, 0.5),
          reason: '主字幕在顶');
      expect(gapFromBottom(tester, '副'), closeTo(80 + kBoxPadTop, 0.5),
          reason: '副字幕自动对侧落底，吃自己的基线');
    });

    testWidgets('默认（mainAnchor=bottom）外观与历史像素级一致（零破坏守卫）',
        (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('A');
      addTearDown(c.dispose);
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, bottomPadding: 75),
      );
      expect(gapFromBottom(tester, 'A'), closeTo(75 + kBoxPadTop, 0.5),
          reason: '不传锚定 = 历史底部基线');
    });
  });

  group('⑤ 拖拽调整模式', () {
    testWidgets('模式内 tap 字幕不再触发查词；退出后恢复', (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      addTearDown(c.dispose);
      int taps = 0;
      Widget overlay({required bool dragMode}) => VideoSubtitleOverlay(
            controller: c,
            dragAdjustEnabled: dragMode,
            onCharTap: (String s, int i, Rect r, AudioCue cue) => taps++,
            onDragAdjustEnd: (
                {required bool isSecondary,
                required SubtitleLayerVAnchor anchor,
                required double padding}) {},
          );

      await _pump(tester, overlay(dragMode: true));
      await tester.tapAt(tester.getCenter(find.text('ス').first));
      await tester.pump();
      expect(taps, 0, reason: '拖拽模式内指针面让给拖拽，点字不查词');

      // 退出模式：同一棵树换参重建（State 保留），查词恢复。
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: overlay(dragMode: false))));
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.text('ス').first));
      await tester.pump();
      expect(taps, 1, reason: '退出拖拽模式后查词手势恢复');
    });

    testWidgets('竖直拖到顶部：实时预览 + 松手回报 top 锚 + clamp 后距离',
        (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      addTearDown(c.dispose);
      bool? endIsSecondary;
      SubtitleLayerVAnchor? endAnchor;
      double? endPadding;
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          bottomPadding: 75,
          dragAdjustEnabled: true,
          onDragAdjustEnd: (
              {required bool isSecondary,
              required SubtitleLayerVAnchor anchor,
              required double padding}) {
            endIsSecondary = isSecondary;
            endAnchor = anchor;
            endPadding = padding;
          },
        ),
      );

      // 从字幕中心一路拖到屏幕外上方：盒顶 < 0 → clamp 0 → 顶锚贴顶。
      final Offset start = tester.getCenter(find.text('ス').first);
      final TestGesture g = await tester.startGesture(start);
      await g.moveBy(const Offset(0, -1000));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(endIsSecondary, isFalse);
      expect(endAnchor, SubtitleLayerVAnchor.top);
      expect(endPadding, 0, reason: '拖出顶边 clamp 到 0（贴顶）');

      // 预览已生效：字幕盒贴顶渲染（离顶 = 0 + 盒内 padding 6）。
      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text('テ').first);
      expect(charRect.top - overlayRect.top, closeTo(6, 0.5),
          reason: '松手后预览保留在落点（顶锚 0 + 盒内 6px）');
    });

    testWidgets('拖拽模式内字幕盒显示可拖指示边框', (WidgetTester tester) async {
      final VideoPlayerController c = _controllerWithCue('A');
      addTearDown(c.dispose);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          dragAdjustEnabled: true,
          onDragAdjustEnd: (
              {required bool isSecondary,
              required SubtitleLayerVAnchor anchor,
              required double padding}) {},
        ),
      );
      final bool hasBorder = tester
          .widgetList<Container>(find.byType(Container))
          .any((Container w) {
        final Decoration? d = w.foregroundDecoration;
        return d is BoxDecoration && d.border != null;
      });
      expect(hasBorder, isTrue, reason: '模式内字幕盒需有可拖指示（边框）');
    });
  });
}
