import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1034：字幕列表行高由 `ListView.itemExtentBuilder` **硬约束**，行高算少一点点，
/// 换行后的末行就被直接裁掉（用户截图里当前播放行第二行的「ら」只露上半截）。
///
/// 守卫的是「测量与渲染同源」这件事本身：
/// 1. 行内文本的实际渲染高度不得小于它按同样宽度/样式重新排版所需的高度（= 没被裁）；
/// 2. 文本列的实际渲染宽度必须等于纯函数 [subtitleRowTextWidth] 给出的值（行高测量正是
///    按这个宽度排版的，二者漂开就会重演裁剪）；
/// 3. 收藏行的左侧竖色条不许挤占文本列宽度（否则收藏行按无色条宽度测量 → 又偏小）。
AudioCue _cue(int i, int startMs, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = startMs + 1500
  ..audioFileIndex = 0;

/// [textScaler] 模拟系统字体缩放 / 应用内「界面大小」：真实布局会随之放大，旧的按字符数
/// 估算行高的实现完全忽略它，于是行高照未缩放算、文字被裁——这正是用户遇到的场景。
Widget _wrap(Widget child, {TextScaler textScaler = TextScaler.noScaling}) =>
    MaterialApp(
      builder: (BuildContext context, Widget? inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: inner!,
      ),
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

/// 面板默认字号 14、默认缩放档 1.0。
const double _kFontSize = 14;
const double _kPanelWidth = 320;

/// 一条必然换行的长句：测试字体下全角字宽 = 字号，文本列约 160px → 每行约 11 字，
/// 24 字必须排到 3 行。旧的「按字符数估算行高」实现只算 2 行，末行被裁。
const String _kLongCue = '私がサボってたこともナイショにしておねがいします';

/// 该行渲染出的字幕文本（[RichText]）。
Finder _cueTextFinder(String text) => find.text(text, findRichText: true);

double _requiredTextHeight(WidgetTester tester, Finder finder) {
  final RichText rich = tester.widget<RichText>(finder);
  final BuildContext context = tester.element(finder);
  final RenderBox box = tester.renderObject<RenderBox>(finder);
  final TextPainter painter = TextPainter(
    text: rich.text,
    textAlign: TextAlign.start,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: null,
  );
  try {
    painter.layout(maxWidth: box.size.width);
    return painter.height;
  } finally {
    painter.dispose();
  }
}

Widget _panel({
  required VideoPlayerController controller,
  bool Function(AudioCue cue)? isCueFavorited,
  int fontScaleIndex = 1,
}) =>
    VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (_) {},
      onClose: () {},
      onCopyCue: (_) {},
      onFavoriteCue: (_) async {},
      isCueFavorited: isCueFavorited ?? (_) => false,
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
      fontSize: _kFontSize,
      width: _kPanelWidth,
      initialFontScaleIndex: fontScaleIndex,
    );

/// 该行的行盒（[_buildRow] 里承载背景 / 收藏色条 / 上下内缩的那个 [Container]），
/// 高度 = `ListView.itemExtentBuilder` 给出的行高。
double _rowHeight(WidgetTester tester, String text) => tester
    .renderObject<RenderBox>(
      find
          .ancestor(
            of: _cueTextFinder(text),
            matching: find.byType(Container),
          )
          .first,
    )
    .size
    .height;

double _textHeight(WidgetTester tester, String text) =>
    tester.renderObject<RenderBox>(_cueTextFinder(text)).size.height;

void main() {
  group('BUG-1034 字幕列表行高', () {
    for (final TextScaler scaler in <TextScaler>[
      TextScaler.noScaling,
      TextScaler.linear(1.3),
    ]) {
      testWidgets('换行的长句不被 itemExtent 裁掉末行（textScaler=$scaler）', (
        WidgetTester tester,
      ) async {
        final VideoPlayerController controller = VideoPlayerController();
        addTearDown(controller.dispose);
        controller.setCues(<AudioCue>[
          _cue(0, 0, _kLongCue),
          _cue(1, 20000, 'バレちゃうかもね'),
        ]);

        await tester.pumpWidget(_wrap(
          _panel(controller: controller),
          textScaler: scaler,
        ));
        await tester.pump();

        final Finder longRow = _cueTextFinder(_kLongCue);
        expect(longRow, findsOneWidget);
        final RenderBox textBox = tester.renderObject<RenderBox>(longRow);
        final double required = _requiredTextHeight(tester, longRow);
        // 样例必须真的多行，否则守卫失去意义。
        expect(
          required,
          greaterThan(scaler.scale(_kFontSize) * 1.25 * 2),
          reason: '测试样例必须换行到 3 行以上',
        );
        expect(
          textBox.size.height,
          greaterThanOrEqualTo(required - 0.5),
          reason: '字幕末行被行高裁掉（BUG-1034）',
        );
      });
    }

    testWidgets('文本列渲染宽度 == subtitleRowTextWidth（测量与渲染同源）', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, _kLongCue)]);

      await tester.pumpWidget(_wrap(_panel(controller: controller)));
      await tester.pump();

      final RenderBox textBox =
          tester.renderObject<RenderBox>(_cueTextFinder(_kLongCue));
      final double expected = subtitleRowTextWidth(
        rowWidth: _kPanelWidth,
        effectiveFontSize: _kFontSize,
        timestampColumnWidth: subtitleTimestampColumnWidth(_kFontSize, false),
      );
      expect(
        textBox.size.width,
        closeTo(expected, 0.5),
        reason: '行高按 subtitleRowTextWidth 排版，渲染宽度必须与之一致',
      );
    });

    // BUG-1997：桌面端每个列表右侧常驻一条覆盖式滚动条（不占布局、且吞点击）。
    // 最右一列是星标按钮，行右内缩只有 4px，星标图标盒离面板右缘 6px —— 被盖住
    // 一半还点不动。行必须给滚动条让出 gutter。
    //
    // 纯几何断言：flutter_test 默认 platform 是 android，不会自动包 Scrollbar，
    // 所以这里不依赖「真渲染出一条滚动条」，只断言让位的距离够。
    testWidgets('GUARD: 最右侧星标按钮为滚动条让出 gutter（BUG-1997）', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, _kLongCue)]);

      await tester.pumpWidget(_wrap(_panel(controller: controller)));
      await tester.pump();

      // 量**可点区域**（InkResponse）而不是 Icon：被滚动条吞掉的是命中测试，而
      // Icon 的 rect 不含按钮自身那 2px padding —— 拿 Icon 量会多出 2px 余量，
      // 把 gutter 去掉这条守卫照样绿（空转）。
      final Finder starButton = find.ancestor(
        of: find.byIcon(Icons.star_border).first,
        matching: find.byType(InkResponse),
      );
      expect(starButton, findsOneWidget);
      final Rect buttonRect = tester.getRect(starButton);
      final Rect panelRect = tester.getRect(
        find.byType(VideoSubtitleJumpPanel),
      );

      expect(
        panelRect.right - buttonRect.right,
        greaterThanOrEqualTo(kSubtitleRowScrollbarGutter),
        reason: '星标可点区域右缘到面板右缘的距离必须 ≥ 滚动条通道宽度，'
            '否则滚动条盖住它并吞掉点击',
      );
    });

    testWidgets('收藏行的左侧竖色条不挤占文本列宽度', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, _kLongCue),
        _cue(1, 20000, 'バレちゃうかもね'),
      ]);

      await tester.pumpWidget(_wrap(_panel(controller: controller)));
      await tester.pump();
      final double plainWidth =
          tester.renderObject<RenderBox>(_cueTextFinder(_kLongCue)).size.width;

      await tester.pumpWidget(_wrap(_panel(
        controller: controller,
        isCueFavorited: (AudioCue cue) => cue.text == _kLongCue,
      )));
      await tester.pump();
      final double favoritedWidth =
          tester.renderObject<RenderBox>(_cueTextFinder(_kLongCue)).size.width;

      expect(
        favoritedWidth,
        closeTo(plainWidth, 0.5),
        reason: '收藏色条挤窄文本列会让行高偏小并重演裁剪（BUG-1034）',
      );
    });
  });

  /// BUG-2057：字幕列表行高曾有一条保底下界 `56 * 字号档`。56 是 asbplayer 版列表最初的
  /// **固定**行高（`static const double _itemExtent = 56`），BUG-1034 改自适应行高时把它
  /// 留成了下界——于是默认字号下 1 行（16+17.5=33.5）和 2 行（16+35=51）双双被抬到 56，
  /// 两种行一样高、单行行里六成是空白。英文译文最常只占 1 行，用户看到的就是
  /// 「英语的上下间距特别高」。
  ///
  /// 守卫的是行高的**几何契约本身**：
  /// `行高 == kSubtitleRowPaddingVertical + max(文本, 时间戳单行, 动作图标)`。
  /// 三个分量全部取自真实渲染，不复刻实现里的常量；任何形式的保底下界（56、48、
  /// 按档缩放的都算）都会让最矮的那行对不上而变红。
  group('BUG-2057 行高只由内容决定（无保底下界）', () {
    for (final int scaleIndex in <int>[0, 1, 4]) {
      testWidgets('行高 == 内缩 + 内容高（字号档下标 $scaleIndex）', (
        WidgetTester tester,
      ) async {
        // 第一遍只为量出该档位的真实排版尺度：行内字号 + 文本列宽。测试字体 Ahem
        // 每个字符宽 = 字号，据此造出恰好 1 / 2 / 3 行的样例，不写死行数。
        final VideoPlayerController probe = VideoPlayerController();
        addTearDown(probe.dispose);
        probe.setCues(<AudioCue>[_cue(0, 0, 'あ')]);
        await tester.pumpWidget(_wrap(
          _panel(controller: probe, fontScaleIndex: scaleIndex),
        ));
        await tester.pump();

        final RichText probeRich =
            tester.widget<RichText>(_cueTextFinder('あ'));
        final double rowFontSize = probeRich.text.style!.fontSize!;
        final double textColumnWidth =
            tester.renderObject<RenderBox>(_cueTextFinder('あ')).size.width;
        final int perLine = (textColumnWidth / rowFontSize).floor();
        expect(perLine, greaterThan(2), reason: '文本列窄到造不出多行样例');

        const String oneLine = 'あ';
        final String twoLines = 'い' * (perLine + 1);
        final String threeLines = 'う' * (2 * perLine + 1);

        final VideoPlayerController controller = VideoPlayerController();
        addTearDown(controller.dispose);
        controller.setCues(<AudioCue>[
          _cue(0, 0, oneLine),
          _cue(1, 4000, twoLines),
          _cue(2, 8000, threeLines),
        ]);
        await tester.pumpWidget(_wrap(
          _panel(controller: controller, fontScaleIndex: scaleIndex),
        ));
        await tester.pump();

        // 样例真的分别是 1 / 2 / 3 行，否则这条守卫失去意义。
        final double line = _textHeight(tester, oneLine);
        expect(_textHeight(tester, twoLines), closeTo(line * 2, 0.5));
        expect(_textHeight(tester, threeLines), closeTo(line * 3, 0.5));

        // 行内另两个子项的**真实**渲染高度（Row 高度 = 子项高度最大值）。
        final double timestampHeight =
            tester.renderObject<RenderBox>(find.text('0:00')).size.height;
        final double actionsHeight = tester
            .renderObject<RenderBox>(find.ancestor(
              of: find.byIcon(Icons.play_arrow).first,
              matching: find.byType(InkResponse),
            ))
            .size
            .height;

        for (final String text in <String>[oneLine, twoLines, threeLines]) {
          final double content = math.max(
            _textHeight(tester, text),
            math.max(timestampHeight, actionsHeight),
          );
          expect(
            _rowHeight(tester, text),
            closeTo(kSubtitleRowPaddingVertical + content, 0.5),
            reason: '行高必须等于「上下内缩 + 内容」，不许有保底下界把矮行撑高'
                '（BUG-2057：单行英文译文上下留白特别大）',
          );
        }

        // 用户可见的症状：曾经 1 行和 2 行的行一样高。
        expect(
          _rowHeight(tester, oneLine),
          lessThan(_rowHeight(tester, twoLines)),
          reason: '1 行的行必须比 2 行的行矮',
        );
        expect(
          _rowHeight(tester, twoLines),
          lessThan(_rowHeight(tester, threeLines)),
        );
      });
    }
  });
}
