// BUG-4852：弹幕滚动的每一帧只该改位置，不该重画已在屏上的弹幕文本，也不该连带
// 重画同一画面上的其它东西。
//
// 弹幕文本带两层模糊阴影；Impeller 的模糊文字缓存以「录制出来的那个 TextFrame」为
// 键，文本一重录 picture，这条弹幕的阴影就要重做离屏模糊。咬住两条性质：
//  1. 弹幕滚动的帧里，弹幕层与同层兄弟（视频页上的控制条、字幕等）都不重新 paint
//     文本——弹幕层自成重绘边界，位置变化只落在图层偏移上；
//  2. 队首弹幕出列后，其余弹幕仍由原来那个 RenderParagraph 渲染、也不重画（按弹幕
//     身份对位；修前按列表位置对位，队首一出列，后面每条都换成下一条的文本重排重画，
//     同屏几十条时就是每次出列整屏阴影全部重做）。
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_overlay.dart';
import 'package:material_ui/material_ui.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
  startMs: startMs,
  text: text,
  mode: VideoDanmakuMode.scroll,
  colorArgb: 0xFFFFFFFF,
);

/// [body] 期间 [RenderParagraph] 真正执行 paint 的次数（重绘边界内没脏的段落不算）。
Future<int> _paragraphPaints(Future<void> Function() body) async {
  debugProfilePaintsEnabled = true;
  FlutterTimeline.debugCollectionEnabled = true;
  try {
    FlutterTimeline.debugReset();
    await body();
    return FlutterTimeline.debugCollect()
        .getAggregated('RenderParagraph')
        .count;
  } finally {
    FlutterTimeline.debugCollectionEnabled = false;
    debugProfilePaintsEnabled = false;
  }
}

double _left(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dx;

void main() {
  late int positionMs;

  Future<void> pumpOverlay(
    WidgetTester tester,
    List<VideoDanmakuItem> items,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            // 与视频页同构：弹幕层和别的覆盖层（控制条、字幕）是同一个 Stack 的兄弟。
            child: Stack(
              children: <Widget>[
                const Positioned(left: 8, bottom: 8, child: Text('sibling')),
                Positioned.fill(
                  child: VideoDanmakuOverlay(
                    items: items,
                    enabled: true,
                    maxActive: 20,
                    positionMs: () => positionMs,
                    isPlaying: () => true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 播放器时钟每 200ms 前进一格，中间按 16ms 一帧推进。
  Future<void> advance(WidgetTester tester, int ms) async {
    for (int t = 0; t < ms; t += 16) {
      if (t % 192 == 0) positionMs += 192;
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('scrolling frames move danmaku without repainting its text', (
    WidgetTester tester,
  ) async {
    positionMs = 1000;
    await pumpOverlay(tester, <VideoDanmakuItem>[
      _item(0, 'first comment'),
      _item(200, 'second comment'),
      _item(400, 'third comment'),
    ]);
    expect(find.text('third comment'), findsOneWidget);

    final double leftBefore = _left(tester, 'second comment');
    final RenderParagraph paragraphBefore = tester.renderObject(
      find.text('second comment'),
    );

    final int paints = await _paragraphPaints(() => advance(tester, 600));

    expect(
      _left(tester, 'second comment'),
      lessThan(leftBefore - 10),
      reason: '弹幕必须真的在滚动，否则下面的「没重画」是空转',
    );
    expect(
      paints,
      0,
      reason: '滚动只改位置：弹幕文本与同层兄弟文本都不该重新 paint（重录 picture 会让 Impeller 的模糊阴影缓存失效）',
    );
    expect(
      identical(
        tester.renderObject(find.text('second comment')),
        paragraphBefore,
      ),
      isTrue,
    );
  });

  testWidgets("head danmaku leaving does not reassign the survivors' text", (
    WidgetTester tester,
  ) async {
    positionMs = 7400;
    await pumpOverlay(tester, <VideoDanmakuItem>[
      _item(0, 'leaving first'),
      _item(1000, 'survivor one'),
      _item(2000, 'survivor two'),
    ]);
    expect(find.text('leaving first'), findsOneWidget);

    final RenderParagraph one = tester.renderObject(find.text('survivor one'));
    final RenderParagraph two = tester.renderObject(find.text('survivor two'));

    final int paints = await _paragraphPaints(() => advance(tester, 1000));
    expect(find.text('leaving first'), findsNothing, reason: '队首弹幕应已滚完出列');

    expect(
      identical(tester.renderObject(find.text('survivor one')), one),
      isTrue,
      reason: '队首出列后其余弹幕按下标错配，每个 RenderParagraph 都换成下一条的文本重排',
    );
    expect(
      identical(tester.renderObject(find.text('survivor two')), two),
      isTrue,
    );
    expect(paints, 0, reason: '队首出列不该让其余弹幕重画');
  });
}
