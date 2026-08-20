import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 字幕换行宽度必须锚在**视频内容矩形**，不能锚在容器。
///
/// 用户实测：1440p 显示器放 1080p 视频，窗口保持 1080p 大小时字幕排版正常，**一最大化
/// 就变**（多断出一行）。根因是两个基准不同源——字号锚在 fit:contain 后的视频内容矩形高
/// （`_assFontScale`，与 mpv/libass 同口径），换行可用宽度却锚在容器宽。pillarbox（窗口
/// 比视频扁）下字号 ∝ 容器高、可用宽 ∝ 容器宽，于是**换行容量 ∝ 窗口宽高比**：一行「刚好
/// 塞满」的字幕，窗口宽高比一变就被推过阈值。
///
/// 这里钉的不变式：**视频内容矩形不变时，容器宽怎么变，断行位置都不许变。**
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

/// pump 一个 16:9 视频的字幕层，容器宽由 [width] 给、高固定。
///
/// 高固定 + 视频比固定 ⇒ fit:contain 后的**视频内容矩形完全相同**（pillarbox 档：
/// 内容高 = 容器高，内容宽 = 容器高 × 16/9 ≈ 355.6px），只有左右黑边宽度随容器变。
Future<void> _pumpPillarbox(
  WidgetTester tester,
  String text, {
  required double width,
  double height = 200,
  double fontSize = 20,
}) async {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: VideoSubtitleOverlay(controller: c, fontSize: fontSize),
        ),
      ),
    ),
  ));
  await tester.pump();
}

/// 按渲染几何重建可视行（同 video_subtitle_word_wrap_test 的做法）：收集所有单字符
/// Text 的全局 topLeft，按 dy 分行、行内按 dx 排序拼接。
List<String> _visualLines(WidgetTester tester) {
  final Iterable<Element> elements = find
      .descendant(
          of: find.byType(VideoSubtitleOverlay), matching: find.byType(Text))
      .evaluate();
  final List<({double dy, double dx, String ch})> glyphs =
      <({double dy, double dx, String ch})>[];
  for (final Element e in elements) {
    final Text t = e.widget as Text;
    final String? s = t.data;
    if (s == null || s.isEmpty) continue;
    final RenderObject? ro = e.renderObject;
    if (ro is! RenderBox || !ro.hasSize) continue;
    final Offset p = ro.localToGlobal(Offset.zero);
    glyphs.add((dy: p.dy, dx: p.dx, ch: s));
  }
  glyphs.sort((({double dy, double dx, String ch}) a,
      ({double dy, double dx, String ch}) b) {
    final int byY = a.dy.compareTo(b.dy);
    return byY != 0 ? byY : a.dx.compareTo(b.dx);
  });
  final List<String> lines = <String>[];
  double? lineY;
  StringBuffer buf = StringBuffer();
  for (final ({double dy, double dx, String ch}) g in glyphs) {
    if (lineY == null || (g.dy - lineY).abs() > 1.0) {
      if (buf.isNotEmpty) lines.add(buf.toString());
      buf = StringBuffer();
      lineY = g.dy;
    }
    buf.write(g.ch);
  }
  if (buf.isNotEmpty) lines.add(buf.toString());
  return lines;
}

void main() {
  group('换行宽度锚在视频内容矩形，不随窗口宽高比变', () {
    // 16:9 视频 + 200px 高 ⇒ 内容宽恒 ≈355.6px，两个容器宽都远大于它（都是 pillarbox）。
    const String text = 'aaa bbb ccc ddd eee fff ggg';

    // 宽度都必须 <= 测试窗口宽（默认 800）：Center 给的是 loose 约束，
    // SizedBox(width: 1000) 会被 constrain 成 800，算出来的黑边宽度就对不上了。
    testWidgets('容器从 500px 拉宽到 760px，断行位置一字不变', (WidgetTester tester) async {
      await _pumpPillarbox(tester, text, width: 500);
      final List<String> narrow = _visualLines(tester);

      await _pumpPillarbox(tester, text, width: 760);
      final List<String> wide = _visualLines(tester);

      expect(narrow.length, greaterThan(1),
          reason: '前提：这句话在 355.6px 的视频内容宽里必须真的会换行，否则本测试空转');
      expect(wide, narrow,
          reason: '修复前换行宽度 = 容器宽，拉宽窗口会把断行位置整个挪走——'
              '这正是用户报的「窗口一最大化字幕排版就变」');
    });

    testWidgets('字幕不排进左右黑边：整行水平范围落在视频内容矩形内', (WidgetTester tester) async {
      const double width = 760;
      await _pumpPillarbox(tester, text, width: width);

      final Iterable<Element> elements = find
          .descendant(
              of: find.byType(VideoSubtitleOverlay),
              matching: find.byType(Text))
          .evaluate();
      final RenderBox overlay =
          tester.renderObject<RenderBox>(find.byType(VideoSubtitleOverlay));
      final double overlayLeft = overlay.localToGlobal(Offset.zero).dx;
      // 内容宽 = 200 × 16/9；左右黑边各 (760 - 内容宽) / 2。
      const double contentWidth = 200 * 16 / 9;
      const double sideBar = (width - contentWidth) / 2;

      double minDx = double.infinity;
      double maxDx = -double.infinity;
      for (final Element e in elements) {
        final RenderObject? ro = e.renderObject;
        if (ro is! RenderBox || !ro.hasSize) continue;
        final double left = ro.localToGlobal(Offset.zero).dx - overlayLeft;
        minDx = left < minDx ? left : minDx;
        final double right = left + ro.size.width;
        maxDx = right > maxDx ? right : maxDx;
      }
      expect(minDx, greaterThanOrEqualTo(sideBar - 1),
          reason: '字幕左缘不得越过左黑边——字幕属于画面，不属于窗口');
      expect(maxDx, lessThanOrEqualTo(width - sideBar + 1),
          reason: '字幕右缘不得越过右黑边');
    });
  });
}
