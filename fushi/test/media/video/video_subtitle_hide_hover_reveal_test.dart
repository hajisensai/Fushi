import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 遮蔽模式「隐藏」的显形通道：**隐藏的字幕也要能鼠标放上去看一眼**。
///
/// 用户诉求原话：「字幕隐藏了，鼠标放上去怎么让他显示啊」→「隐藏也能鼠标放上去显示」。
///
/// 根因（修前）：隐藏与模糊虽同属遮蔽（[VideoSubtitleObscureMode]），实现却是两条完全
/// 不同的路径——模糊「渲染 + 高斯滤镜」，隐藏「build 期把活动集清空」。清空之后屏幕上
/// 没有任何 widget，承载显形的 [MouseRegion] / 点击热区随之不存在，于是隐藏态**结构上**
/// 不可能响应悬停：不是回调没接上，是没有几何可悬停。
///
/// 修法：两种遮蔽统一成一条路径「照常布局 + 遮蔽视觉 + 共享显形状态机」。隐藏的视觉是
/// [Opacity] 为 0（不绘制、但布局与命中几何照旧），于是模糊那套显形通道原样对隐藏生效。
///
/// 本文件按「真行为」验证，不做源码扫描：
///  ① 隐藏态保留几何但不绘制（悬停显形的前提）；
///  ② 桌面悬停显形 / 移开复原；
///  ③ 移动端点击热区显形（无 OS hover 时的唯一通道）；
///  ④ 未显形时看不见的字不可查词（registerHits 门），显形后恢复可查词；
///  ⑤ 主 / 副字幕各自独立（互不串显形态）。
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
/// 隐藏态的判据只能是这个：断言「找不到文本」恰恰是被修掉的旧实现。
bool _obscured(WidgetTester tester, Finder of) => tester
    .widgetList<Opacity>(
        find.ancestor(of: of.first, matching: find.byType(Opacity)))
    .any((Opacity o) => o.opacity == 0);

VideoPlayerController _controller(WidgetTester tester,
    {String main = '主', String? secondary}) {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(<AudioCue>[_cue(main, 0, 6000)]);
  if (secondary != null) {
    c.setSecondaryCues(<AudioCue>[_cue(secondary, 0, 6000)]);
  }
  c.debugUpdateCueForPosition(1000);
  return c;
}

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c, {
  bool subtitleHidden = false,
  bool secondaryHidden = false,
  void Function(String sentence, int graphemeIndex, Rect charRect, AudioCue cue)?
      onCharTap,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        subtitleHidden: subtitleHidden,
        secondaryHidden: secondaryHidden,
        onCharTap: onCharTap,
      ),
    ),
  ));
  await tester.pump();
}

/// 造一个鼠标指针并停到 [target] 上（桌面悬停）。返回的 gesture 可继续 moveTo 移开。
Future<TestGesture> _hoverOver(WidgetTester tester, Finder target) async {
  final TestGesture gesture =
      await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(() => gesture.removePointer());
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target.first));
  await tester.pump();
  return gesture;
}

void main() {
  group('① 隐藏态保留几何但不绘制（显形的前提）', () {
    testWidgets('subtitleHidden=true：字幕仍在树上，但被 Opacity(0) 遮住',
        (tester) async {
      final VideoPlayerController c = _controller(tester);

      await _pump(tester, c, subtitleHidden: true);

      // 关键回归守卫：修前这里是 findsNothing（活动集被清空）。保留几何是悬停显形的
      // 前提，一旦有人为了「省一点绘制」把它改回清空，本条立刻红。
      expect(find.text('主'), findsWidgets,
          reason: '隐藏态必须保留几何，否则鼠标无处可悬停（本 bug 的根因）');
      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '隐藏态的视觉是 Opacity(0)：用户看不见');
    });

    testWidgets('subtitleHidden=false：没有任何 Opacity(0) 遮蔽层（外观零变化）',
        (tester) async {
      final VideoPlayerController c = _controller(tester);

      await _pump(tester, c);

      expect(find.text('主'), findsWidgets);
      expect(_obscured(tester, find.text('主')), isFalse,
          reason: '不遮蔽时不得平白多出透明层');
    });

    testWidgets('暂停时隐藏依然生效（不吃 isPlaying 门，与模糊不同）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      expect(c.isPlaying, isFalse, reason: '前置：本用例未起播');

      await _pump(tester, c, subtitleHidden: true);

      // 模糊有 BUG-199 的「暂停时清晰」，隐藏没有——否则一暂停字幕就自己冒出来。
      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '暂停不该让隐藏的字幕自己显形');
    });
  });

  group('② 桌面悬停显形 / 移开复原', () {
    testWidgets('鼠标移到隐藏的字幕上 → 显形', (tester) async {
      final VideoPlayerController c = _controller(tester);
      await _pump(tester, c, subtitleHidden: true);
      expect(_obscured(tester, find.text('主')), isTrue, reason: '前置：先是隐藏的');

      await _hoverOver(tester, find.text('主'));

      expect(_obscured(tester, find.text('主')), isFalse,
          reason: '悬停即显形——这正是用户要的行为');
    });

    testWidgets('鼠标移开 → 恢复隐藏', (tester) async {
      final VideoPlayerController c = _controller(tester);
      await _pump(tester, c, subtitleHidden: true);

      final TestGesture gesture = await _hoverOver(tester, find.text('主'));
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：已显形');

      await gesture.moveTo(Offset.zero);
      await tester.pump();

      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '移开复原（显形是临时的，不是把隐藏关掉）');
    });
  });

  group('③ 移动端点击显形（无 OS hover 时的唯一通道）', () {
    testWidgets('点隐藏的字幕 → 显形，且不误触发查词', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final List<String> tapped = <String>[];
      await _pump(tester, c,
          subtitleHidden: true,
          onCharTap: (String s, int i, Rect r, AudioCue cue) => tapped.add(s));

      await tester.tap(find.text('主').first, warnIfMissed: false);
      await tester.pump();

      expect(_obscured(tester, find.text('主')), isFalse, reason: '点击显形');
      expect(tapped, isEmpty,
          reason: '看不见的字不可查词：未显形时不登记命中（registerHits=false）');
    });
  });

  group('④ 显形前后的查词命中登记', () {
    testWidgets('显形后字符恢复可查词（不是永久关掉查词）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final List<String> tapped = <String>[];
      await _pump(tester, c,
          subtitleHidden: true,
          onCharTap: (String s, int i, Rect r, AudioCue cue) => tapped.add(s));

      // 先悬停显形（此时 registerHits 恢复 true、遮蔽热区也已撤下）。
      await _hoverOver(tester, find.text('主'));
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：已显形');

      await tester.tap(find.text('主').first, warnIfMissed: false);
      await tester.pump();

      expect(tapped, <String>['主'],
          reason: '显形后就是普通字幕，逐字查词照常');
    });
  });

  group('⑤ 主 / 副字幕显形态互相独立', () {
    testWidgets('悬停副字幕只显形副字幕，主字幕仍隐藏', (tester) async {
      final VideoPlayerController c = _controller(tester, secondary: '副');
      await _pump(tester, c, subtitleHidden: true, secondaryHidden: true);
      expect(_obscured(tester, find.text('主')), isTrue, reason: '前置：主隐藏');
      expect(_obscured(tester, find.text('副')), isTrue, reason: '前置：副隐藏');

      await _hoverOver(tester, find.text('副'));

      expect(_obscured(tester, find.text('副')), isFalse, reason: '副字幕显形');
      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '主字幕不该被副字幕的悬停带出来（两层各有独立 reveal 态）');
    });
  });
}
