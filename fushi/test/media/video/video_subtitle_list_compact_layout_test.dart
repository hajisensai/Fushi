// 字幕列表侧栏：重开不重量行高（反馈 C9uvk6cMxF「打开就很卡」）、贴边几何与系统
// 安全区（反馈 Lgp-nUrh6V；2026-10-14 iOS 横屏右侧空一大块、四周圆角浪费空间）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
  EdgeInsets safeAreaInsets = EdgeInsets.zero,
  double panelWidth = _panelWidth,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Row(
        children: <Widget>[
          const Expanded(child: SizedBox()),
          if (show)
            SizedBox(
              width: panelWidth + safeAreaInsets.right,
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
                width: panelWidth,
                safeAreaInsets: safeAreaInsets,
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

  testWidgets('贴边几何：面板无外边距，行只留列表内边距（Lgp-nUrh6V）', (tester) async {
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
    // 面板贴边、不留外边距：行两侧只剩列表内边距 6。
    expect(row.left - panel.left, lessThanOrEqualTo(6.5));
    expect(panel.right - row.right, lessThanOrEqualTo(6.5));
    // 表面铺满整列，不是缩在列里的圆角卡片。
    final Rect surface = tester.getRect(
      find.byKey(const ValueKey<String>('video-subtitle-jump-panel-surface')),
    );
    expect(surface, panel);
  });

  testWidgets('页头只两行：无标题 / 图标，关闭键与工具按钮同一行（2026-10-14）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    expect(find.text('Subtitle list'), findsNothing, reason: '不再画标题');
    expect(find.byIcon(FushiIcons.subtitles), findsNothing, reason: '不再画徽标');
    final Rect close = tester.getRect(find.byIcon(FushiIcons.close));
    final Rect search = tester.getRect(find.byIcon(FushiIcons.search));
    expect(close.center.dy, closeTo(search.center.dy, 0.5));
    // 第二行是「全部 / 收藏」分段，紧接着就是列表：首行字幕离面板顶不超过
    // 两行控件（48 命中区 + 40）加上下内边距与行距。
    final Rect panel = tester.getRect(find.byType(VideoSubtitleJumpPanel));
    final Rect firstRow = tester.getRect(
      find.text('line 0 of the subtitle track', findRichText: true),
    );
    expect(firstRow.top - panel.top, lessThan(132));
  });

  testWidgets('页头工具按钮：宽面板全部平铺且命中区 >=48；窄面板放不下才收进「⋯」（不缩小按钮）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    const Key moreKey = ValueKey<String>('video-subtitle-list-header-more');
    Size hitSizeOf(IconData icon) => tester.getSize(
      find
          .ancestor(of: find.byIcon(icon), matching: find.byType(IconButton))
          .first,
    );

    await tester.pumpWidget(_host(c, show: true));
    await tester.pump();
    expect(find.byKey(moreKey), findsNothing, reason: '420 宽放得下，不该收起');
    expect(find.byIcon(FushiIcons.remove), findsOneWidget, reason: '字号步进器平铺');
    expect(hitSizeOf(FushiIcons.search).shortestSide, greaterThanOrEqualTo(48));

    await tester.pumpWidget(_host(c, show: false));
    await tester.pumpWidget(_host(c, show: true, panelWidth: 280));
    await tester.pump();
    expect(find.byKey(moreKey), findsOneWidget, reason: '280 宽放不下，字号步进器收进「⋯」');
    expect(find.byIcon(FushiIcons.remove), findsNothing);
    expect(
      hitSizeOf(FushiIcons.search).shortestSide,
      greaterThanOrEqualTo(48),
      reason: '收起的是低优先级动作，剩下的按钮命中区不缩水',
    );
    // 「⋯」紧贴在关闭键左边、不压它。
    expect(
      tester.takeException(),
      isNull,
      reason: '280 宽两行页头都不得右溢（含「全部 / 收藏」分段）',
    );
    final Rect more = tester.getRect(find.byKey(moreKey));
    final Rect close = tester.getRect(find.byIcon(FushiIcons.close));
    expect(more.right, lessThanOrEqualTo(close.left));
    expect(more.width, greaterThanOrEqualTo(48));
  });

  testWidgets('右侧 / 顶部安全区：底色铺进安全区，只有内容让位', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    await tester.pumpWidget(
      _host(
        c,
        show: true,
        safeAreaInsets: const EdgeInsets.only(top: 20, right: 47),
      ),
    );
    await tester.pump();
    final Rect panel = tester.getRect(find.byType(VideoSubtitleJumpPanel));
    final Rect surface = tester.getRect(
      find.byKey(const ValueKey<String>('video-subtitle-jump-panel-surface')),
    );
    // iOS 横屏刘海在右：底色一路铺到屏幕右缘，不再空出一条黑。
    expect(surface, panel);
    expect(panel.width, _panelWidth + 47);
    final Rect row = tester.getRect(
      find
          .ancestor(
            of: find.text('line 0 of the subtitle track', findRichText: true),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    // 行让开右侧安全区，宽度仍是内容宽减两侧列表内边距。
    expect(panel.right - row.right, closeTo(47 + 6, 0.5));
    expect(row.width, closeTo(_panelWidth - 12, 0.5));
    expect(row.top - panel.top, greaterThanOrEqualTo(20));
  });

  testWidgets('底部安全区：列表铺到面板底，只在末尾补被遮的一截', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(<AudioCue>[for (int i = 0; i < 5; i++) _cue(i)]);
    await tester.pumpWidget(
      _host(c, show: true, safeAreaInsets: const EdgeInsets.only(bottom: 34)),
    );
    await tester.pump();
    final ListView list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(VideoSubtitleJumpPanel),
        matching: find.byType(ListView),
      ),
    );
    final EdgeInsets padding = list.padding!.resolve(TextDirection.ltr);
    // 面板贴底：整段 34 的安全区补在列表末尾，再加列表本来的 8。
    expect(padding.bottom, 8 + 34);

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
