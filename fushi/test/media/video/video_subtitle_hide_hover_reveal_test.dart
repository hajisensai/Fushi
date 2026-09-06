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
///  ⑤ 主 / 副字幕各自独立（互不串显形态）；
///  ⑥ 拖拽调整模式内两种遮蔽都让位（与模糊严格对称，否则拖的是看不见的盒子）；
///  ⑦ 父级重建不清掉显形态（didUpdateWidget 的复位判据必须含隐藏）；
///  ⑧ registerHits 门控的另外两条通道——悬停查词内核 / 手柄选词光标（不经过显形热区）；
///  ⑨ 点击显形只豁免当前这句（触摸端没有 hover 可复位，必须有失效点）。
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

/// 该 widget 是否被 [ImageFiltered] 祖先包住（= 模糊态的视觉）。测试用的 cue 不带
/// ASS `\blur` 标记，故字幕树里唯一的 ImageFiltered 只可能是遮蔽层。
bool _blurredVisual(WidgetTester tester, Finder of) => tester
    .widgetList<ImageFiltered>(
        find.ancestor(of: of.first, matching: find.byType(ImageFiltered)))
    .isNotEmpty;

Future<void> _pump(
  WidgetTester tester,
  VideoPlayerController c, {
  bool subtitleHidden = false,
  bool secondaryHidden = false,
  bool blurEnabled = false,
  bool secondaryBlurEnabled = false,
  bool dragAdjustEnabled = false,
  bool hoverAutoLookupEnabled = false,
  VideoSubtitleHitTester? hitTester,
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
        secondaryBlurEnabled: secondaryBlurEnabled,
        dragAdjustEnabled: dragAdjustEnabled,
        hoverAutoLookupEnabled: hoverAutoLookupEnabled,
        hitTester: hitTester,
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
    testWidgets('subtitleHidden=true：字幕仍在树上，但被 Opacity(0) 遮住', (tester) async {
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

      expect(tapped, <String>['主'], reason: '显形后就是普通字幕，逐字查词照常');
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
  group('⑥ 拖拽调整模式内两种遮蔽都让位（与模糊严格对称）', () {
    // 既有契约：拖拽调整模式内字幕保持清晰便于对位（_wrapInteractive 对
    // dragAdjustEnabled 提前返回，模糊的 ImageFiltered 被跳过）。隐藏的视觉必须挂在
    // **同一层**（早退之后），否则拖拽模式内隐藏态仍然 Opacity(0)：用户拖一个看不见的
    // 盒子，连 _wrapDragAdjust 那圈「可拖指示边框」都被吞掉，而松手会真写入新位置——
    // 从「可见地坏」退化成「静默地改状态」。
    testWidgets('hidden + dragAdjustEnabled：字幕清晰可见（不是全透明的盒子）', (tester) async {
      final VideoPlayerController c = _controller(tester);

      await _pump(tester, c, subtitleHidden: true, dragAdjustEnabled: true);

      expect(find.text('主'), findsWidgets);
      expect(_obscured(tester, find.text('主')), isFalse,
          reason: '拖拽模式内必须能看见要拖的东西（松手真写字幕位置）');
    });

    testWidgets('blur + dragAdjustEnabled：不糊（对称基准，既有契约）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      c.debugSetIsPlayingForTesting(true);

      await _pump(tester, c, blurEnabled: true, dragAdjustEnabled: true);

      expect(_blurredVisual(tester, find.text('主')), isFalse,
          reason: '拖拽模式内模糊让位——隐藏必须与之严格对称');
    });

    testWidgets('hidden + 非拖拽模式：照常遮蔽（防「一刀关掉隐藏」式伪修复）', (tester) async {
      final VideoPlayerController c = _controller(tester);

      await _pump(tester, c, subtitleHidden: true);

      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '让位只对拖拽模式生效，平时该隐藏还得隐藏');
    });

    testWidgets('blur + 非拖拽模式：照常模糊（对称基准）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      c.debugSetIsPlayingForTesting(true);

      await _pump(tester, c, blurEnabled: true);

      expect(_blurredVisual(tester, find.text('主')), isTrue);
    });
  });

  group('⑦ 父级重建不清掉显形态（didUpdateWidget 判据必须含隐藏）', () {
    // 视频页每帧都在重建 overlay（播放位置 / 控制条 / 字号…）。didUpdateWidget 里的
    // 复位判据一旦漏掉 subtitleHidden，随便一次父级重建就把刚悬停出来的显形态清掉，
    // 用户表现为「鼠标放上去闪一下又没了」。这里用一个**与几何无关**的 prop
    // （hoverAutoLookupEnabled）触发重建，避免把 hover 位置一起改掉。
    testWidgets('主字幕：悬停显形后带不同 props 重建 → 仍显形', (tester) async {
      final VideoPlayerController c = _controller(tester);
      await _pump(tester, c, subtitleHidden: true);
      await _hoverOver(tester, find.text('主'));
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：已显形');

      await _pump(tester, c,
          subtitleHidden: true, hoverAutoLookupEnabled: true);

      expect(_obscured(tester, find.text('主')), isFalse,
          reason: '隐藏仍开着，父级重建不得复位显形态');
    });

    testWidgets('副字幕：悬停显形后带不同 props 重建 → 仍显形', (tester) async {
      final VideoPlayerController c = _controller(tester, secondary: '副');
      await _pump(tester, c, secondaryHidden: true);
      await _hoverOver(tester, find.text('副'));
      expect(_obscured(tester, find.text('副')), isFalse, reason: '前置：已显形');

      await _pump(tester, c,
          secondaryHidden: true, hoverAutoLookupEnabled: true);

      expect(_obscured(tester, find.text('副')), isFalse,
          reason: '副字幕与主字幕同构，判据同样必须含 secondaryHidden');
    });

    testWidgets('真把遮蔽关掉才复位显形态（反向守卫：复位路径没被焊死）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final List<String> tapped = <String>[];
      await _pump(tester, c,
          subtitleHidden: true,
          onCharTap: (String s, int i, Rect r, AudioCue cue) => tapped.add(s));
      // 用点击显形（不留鼠标指针，重开隐藏时不会被 onEnter 又显形一次）。
      await tester.tap(find.text('主').first, warnIfMissed: false);
      await tester.pump();
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：已显形');

      // 关掉隐藏 → 复位；再打开隐藏 → 又是遮蔽态（显形没有残留到下次开启）。
      await _pump(tester, c);
      await _pump(tester, c, subtitleHidden: true);

      expect(_obscured(tester, find.text('主')), isTrue,
          reason: '遮蔽真关掉时必须复位显形态，否则下次开启直接是显形的');
      expect(tapped, isEmpty, reason: '遮蔽态的点击只显形、不查词');
    });
  });

  group('⑧ 看不见的字不可查词：registerHits 的另外两条路径', () {
    // 组③ 的「点了不查词」其实是显形热区先把 tap 吃掉了，与 registerHits 无关。
    // registerHits 真正独占的是另外两条**不经过热区**的通道：
    //   · Shift-悬停 / 悬停即查词 → _charHitTest（VideoSubtitleHitTester.hitTest）
    //   · 手柄选词光标 → caretEntryCount / caretAnchorEntry / caretHitAt
    // 「看不见的字不可查词」这条安全属性只有在这里才有守卫。
    testWidgets('未显形：悬停查词内核与选词光标都取不到字符', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();

      await _pump(tester, c, subtitleHidden: true, hitTester: ht);

      final Offset p = tester.getCenter(find.text('主').first);
      expect(ht.hitTest(p), isNull, reason: '悬停查词不经过显形热区，只由 registerHits 门控');
      expect(ht.caretEntryCount(), 0, reason: '隐藏层的字符不该进登记表');
      expect(ht.caretAnchorEntry(), -1, reason: '选词光标无处可停（页面据此拒绝进入）');
    });

    testWidgets('显形后：两条通道都恢复（不是把查词永久关掉）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, c, subtitleHidden: true, hitTester: ht);

      await _hoverOver(tester, find.text('主'));
      expect(_obscured(tester, find.text('主')), isFalse, reason: '前置：已显形');

      final Offset p = tester.getCenter(find.text('主').first);
      expect(ht.hitTest(p)?.sentence, '主');
      expect(ht.caretEntryCount(), greaterThan(0));
      expect(ht.caretAnchorEntry(), greaterThanOrEqualTo(0));
    });

    testWidgets('不隐藏时两条通道本就可用（防恒真）', (tester) async {
      final VideoPlayerController c = _controller(tester);
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();

      await _pump(tester, c, hitTester: ht);

      expect(ht.hitTest(tester.getCenter(find.text('主').first))?.sentence, '主');
      expect(ht.caretAnchorEntry(), greaterThanOrEqualTo(0));
    });
  });

  group('⑨ 点击显形只豁免当前这句（触摸端的撤销手段）', () {
    // 显形热区在显形之后就撤下了（让位给逐字查词），触摸端又没有 hover 的 onExit——
    // 于是点击置起的显形态原本只能等「本层活动集为空」才复位。台词密集、没有字幕空档
    // 的片段里，一次误触就把遮蔽废到下一个空档，且用户没有任何点回去的手段。
    // 修法：点击显形与悬停显形分开记账，点击显形按「本层活动集换一轮」失效。
    testWidgets('点击显形后换下一条字幕 → 重新隐藏（无空档也能复位）', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      // A[0,2000) 紧接 B[2000,4000)：中间没有任何空档。
      c.setCues(<AudioCue>[_cue('甲', 0, 2000), _cue('乙', 2000, 4000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, c, subtitleHidden: true);

      await tester.tap(find.text('甲').first, warnIfMissed: false);
      await tester.pump();
      expect(_obscured(tester, find.text('甲')), isFalse, reason: '前置：点击显形');

      c.debugUpdateCueForPosition(3000);
      await _pump(tester, c, subtitleHidden: true);

      expect(find.text('乙'), findsWidgets, reason: '前置：已换到下一条');
      expect(_obscured(tester, find.text('乙')), isTrue,
          reason: '点击显形只豁免当前这句，下一句自动恢复隐藏');
    });

    testWidgets('悬停显形跨句不被误清（BUG-1068 的「真悬停仍显形」不回归）', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('甲', 0, 2000), _cue('乙', 2000, 4000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, c, subtitleHidden: true);

      await _hoverOver(tester, find.text('甲'));
      expect(_obscured(tester, find.text('甲')), isFalse, reason: '前置：悬停显形');

      c.debugUpdateCueForPosition(3000);
      await _pump(tester, c, subtitleHidden: true);

      expect(_obscured(tester, find.text('乙')), isFalse,
          reason: '鼠标还停在字幕上，换句不该把它变回看不见（悬停有自己的 onExit）');
    });
  });
}
