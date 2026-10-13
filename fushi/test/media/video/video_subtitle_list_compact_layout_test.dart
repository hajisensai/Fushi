// 字幕列表侧栏：重开不重量行高（反馈 C9uvk6cMxF「打开就很卡」）、紧凑几何与底部
// 安全区（反馈 Lgp-nUrh6V）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:material_ui/material_ui.dart';

AudioCue _cue(int i) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line $i of the subtitle track'
  ..startMs = i * 3000
  ..endMs = i * 3000 + 2500
  ..audioFileIndex = 0;

const double _panelWidth = 420;

Widget _host(
  VideoPlayerController c, {
  required bool show,
  double bottomSafeInset = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Row(
        children: <Widget>[
          const Expanded(child: SizedBox()),
          if (show)
            SizedBox(
              width: _panelWidth,
              child: VideoSubtitleJumpPanel(
                layout: VideoSubtitleListLayout.m3e,
                controller: c,
                onTapCue: (_) {},
                onClose: () {},
                onCopyCue: (_) => true,
                onFavoriteCue: (_) async {},
                isCueFavorited: (_) => false,
                colorScheme: const ColorScheme.dark(),
                title: 'Subtitle list',
                emptyHint: 'empty',
                width: _panelWidth,
                bottomSafeInset: bottomSafeInset,
              ),
            ),
        ],
      ),
    ),
  );
}

void main() {
  setUp(videoSubtitleRowExtentCache.reset);

  testWidgets('收起再打开：整轨行高不再重新排版（C9uvk6cMxF）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 300; i++) _cue(i)]);
    // 播到中段：打开面板要定位到当前句，前面两百多行的行高都得量出来。
    c.debugSetPositionForTesting(250 * 3000 + 100);
    c.debugUpdateCueForPosition(250 * 3000 + 100);
    expect(c.currentCueIndex, 250);

    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final int firstOpen = videoSubtitleRowExtentCache.measurements;
    expect(firstOpen, greaterThanOrEqualTo(250), reason: '首开定位当前句要量到它');

    await tester.pumpWidget(_host(c, show: false));
    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      videoSubtitleRowExtentCache.measurements,
      firstOpen,
      reason: '同一排版环境下重开面板复用行高，不再把整轨重排一遍',
    );
  });

  testWidgets('排版环境变了（面板宽度）才作废行高', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 20; i++) _cue(i)]);
    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    final int before = videoSubtitleRowExtentCache.measurements;
    await tester.pumpWidget(_host(c, show: false));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 360,
              child: VideoSubtitleJumpPanel(
                layout: VideoSubtitleListLayout.m3e,
                controller: c,
                onTapCue: (_) {},
                onClose: () {},
                onCopyCue: (_) => true,
                onFavoriteCue: (_) async {},
                isCueFavorited: (_) => false,
                colorScheme: const ColorScheme.dark(),
                title: 'Subtitle list',
                emptyHint: 'empty',
                width: 360,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      videoSubtitleRowExtentCache.measurements,
      greaterThan(before),
      reason: '宽度变了，旧行高不能再用',
    );
  });

  testWidgets('时间戳列宽变了（<1h → ≥1h 视频）同文本也要重量行高', (tester) async {
    // 行高缓存跨面板、跨视频共享；正文可用宽 = 行宽 − 时间戳列宽 − …，而时间戳列宽
    // 随「这条轨有没有小时级时间戳」变。两个视频的台词文本完全相同、只差时间戳列宽，
    // 旧签名（不含列宽）会把短视频量出的行高原样套给长视频——itemExtentBuilder 是
    // 硬约束，正文按更窄的宽度换行却拿着旧行高，被截断。
    final VideoPlayerController short = VideoPlayerController();
    addTearDown(short.dispose);
    short.setCues(<AudioCue>[for (int i = 0; i < 20; i++) _cue(i)]);
    await tester.pumpWidget(_host(short, show: true));
    await tester.pump();
    final int before = videoSubtitleRowExtentCache.measurements;
    expect(before, greaterThan(0));

    final VideoPlayerController long = VideoPlayerController();
    addTearDown(long.dispose);
    long.setCues(<AudioCue>[
      for (int i = 0; i < 20; i++) _cue(i),
      // 文本与上面某句相同（不引入新缓存键），只把轨拉过 1 小时、时间戳换宽列。
      _cue(19)
        ..sentenceIndex = 20
        ..startMs = 3600 * 1000
        ..endMs = 3600 * 1000 + 2500,
    ]);
    await tester.pumpWidget(_host(short, show: false));
    await tester.pumpWidget(_host(long, show: true));
    await tester.pump();
    expect(
      videoSubtitleRowExtentCache.measurements,
      greaterThan(before),
      reason: '时间戳列从窄列换成宽列，正文可用宽变了，旧行高不能再用',
    );
  });

  testWidgets('紧凑几何：行卡几乎贴满面板（Lgp-nUrh6V）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    final Rect panel = tester.getRect(find.byType(VideoSubtitleJumpPanel));
    final Rect row = tester.getRect(
      find
          .ancestor(
            of: find.text('line 0 of the subtitle track', findRichText: true),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    // 面板外边距 6 + 列表内边距 4：行卡两侧离面板边各 10。
    expect(row.left - panel.left, lessThanOrEqualTo(10.5));
    expect(panel.right - row.right, lessThanOrEqualTo(10.5));
  });

  testWidgets('底部安全区：列表铺到面板底，只在末尾补被遮的一截', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    await tester.pumpWidget(_host(c, show: true, bottomSafeInset: 34));
    await tester.pump();
    final ListView list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(VideoSubtitleJumpPanel),
        matching: find.byType(ListView),
      ),
    );
    final EdgeInsets padding = list.padding!.resolve(TextDirection.ltr);
    // 34 的安全区减去面板自己离底边的 6，再加列表本来的 8。
    expect(padding.bottom, 8 + 34 - 6);

    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    final ListView noInset = tester.widget<ListView>(
      find.descendant(
        of: find.byType(VideoSubtitleJumpPanel),
        matching: find.byType(ListView),
      ),
    );
    expect(noInset.padding!.resolve(TextDirection.ltr).bottom, 8);
  });
}
