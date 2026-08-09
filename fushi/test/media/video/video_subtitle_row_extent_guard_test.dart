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
  bool withSelectionControls = false,
  bool Function(AudioCue cue)? isCueFavorited,
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
      isCueSelectedForCard: withSelectionControls ? (_) => false : null,
      onToggleCueSelection: withSelectionControls ? (_) {} : null,
    );

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
          _panel(controller: controller, withSelectionControls: true),
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

      for (final bool withSelection in <bool>[false, true]) {
        await tester.pumpWidget(_wrap(
          _panel(controller: controller, withSelectionControls: withSelection),
        ));
        await tester.pump();

        final RenderBox textBox =
            tester.renderObject<RenderBox>(_cueTextFinder(_kLongCue));
        final double expected = subtitleRowTextWidth(
          rowWidth: _kPanelWidth,
          effectiveFontSize: _kFontSize,
          timestampColumnWidth: subtitleTimestampColumnWidth(_kFontSize, false),
          hasSelectionControls: withSelection,
        );
        expect(
          textBox.size.width,
          closeTo(expected, 0.5),
          reason: '行高按 subtitleRowTextWidth 排版，渲染宽度必须与之一致'
              '（withSelection=$withSelection）',
        );
      }
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
}
