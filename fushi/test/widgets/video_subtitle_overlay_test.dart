import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = t
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  testWidgets('renders current cue as tappable chars; fires onCharTap',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000), _cue('world', 2000, 3000)]);

    String? tappedSentence;
    int? tappedIndex;
    Rect? tappedRect;
    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      onCharTap: (String s, int i, Rect rect) {
        tappedSentence = s;
        tappedIndex = i;
        tappedRect = rect;
      },
    )));

    c.debugUpdateCueForPosition(500);
    await tester.pump();
    // 'hello' 拆成逐字符可点；默认统一外观每字渲染成**单层** fill Text（Niratan 软投影，
    // 非 respectAssStyle 路径），故每个唯一字符出现 1 个 Text，重复字符 'l'（2 次）共 2 个。
    expect(find.text('h'), findsOneWidget);
    expect(find.text('e'), findsOneWidget);
    expect(find.text('l'), findsNWidgets(2));

    await tester.tap(find.text('e'));
    expect(tappedSentence, 'hello');
    expect(tappedIndex, 1); // 'e' 是第 1 个 grapheme
    // 浮层定位用：被点字符报告非零屏幕矩形（弹窗据此定位到字符附近）。
    expect(tappedRect, isNotNull);
    expect(tappedRect, isNot(Rect.zero));
    expect(tappedRect!.width, greaterThan(0));
    expect(tappedRect!.height, greaterThan(0));

    c.debugUpdateCueForPosition(2500);
    await tester.pump();
    expect(find.text('w'), findsOneWidget);
    expect(find.text('h'), findsNothing);
  });

  testWidgets('renders nothing when no current cue', (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000)]);
    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(controller: c)));
    await tester.pump();
    expect(find.text('h'), findsNothing); // 未推进位置，无 current cue
  });

  testWidgets(
      'default uniform look: single fill Text + soft drop shadow (Niratan), no stroke layer',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('A', 0, 1000)]);
    const Color themedSubtitleColor = Color(0xFF00AA88);

    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      fontSize: 36,
      textColor: themedSubtitleColor,
      fontWeight: 500,
      shadowColor: const Color(0xFF224466),
      shadowThickness: 6,
      backgroundColor: const Color(0xFF6688AA),
      backgroundOpacity: 0,
      bottomPadding: 75,
      fontFamily: 'ReaderFont',
      // respectAssStyle 默认 false → 默认统一外观（软投影）。
    )));

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    final DecoratedBox box = tester.widget(find.byType(DecoratedBox));
    final BoxDecoration decoration = box.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);

    // 抄 Niratan：默认（非 respectAssStyle）字幕每字渲染成**单层** fill Text + 一枚柔和
    // drop shadow（放弃 BUG-323 的双层硬描边）。单层软投影（仅一份拷贝、向下 1px 偏移）
    // 不会重现 BUG-222/323 的 8 层模糊 glyph 拷贝残留黑字。
    final List<Text> texts = tester.widgetList<Text>(find.text('A')).toList();
    expect(texts.length, 1, reason: '默认外观 = 单层 fill Text（无描边层）');

    final Text fill = texts.single;
    // fill 层：正文色 / 字号 / 字重 / 字体如实，无 foreground（非描边）。
    expect(fill.style!.foreground, isNull);
    expect(fill.style!.color, themedSubtitleColor);
    expect(fill.style!.fontSize, 36);
    expect(fill.style!.fontWeight, FontWeight.w500);
    expect(fill.style!.fontFamily, 'ReaderFont');

    // 柔和投影：单枚 Shadow，色==shadowColor、模糊半径==shadowThickness、向下偏移 1px
    // （对应 Niratan `.shadow(color:.black.opacity(0.9), radius:r, y:1)`）。
    final List<Shadow> shadows = fill.style!.shadows!;
    expect(shadows.length, 1, reason: '单层柔和投影，不是 8 向伪描边');
    expect(shadows.single.color, const Color(0xFF224466));
    expect(shadows.single.blurRadius, 6);
    expect(shadows.single.offset, const Offset(0, 1));
  });

  testWidgets('thickness<=0 renders single fill Text with no shadow',
      (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('A', 0, 1000)]);

    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(
      controller: c,
      shadowColor: const Color(0xFF224466),
      shadowThickness: 0, // 关阴影：单层 fill、无投影。
    )));
    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 关阴影 → 单层 fill Text，无投影（无多余层、无残影）。
    final List<Text> texts = tester.widgetList<Text>(find.text('A')).toList();
    expect(texts.length, 1);
    expect(texts.single.style!.foreground, isNull);
    expect(texts.single.style!.shadows, anyOf(isNull, isEmpty));
  });
}
