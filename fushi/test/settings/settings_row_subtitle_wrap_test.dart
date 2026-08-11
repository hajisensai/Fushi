import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

import '../widgets/widget_test_helpers.dart';

// BUG-1537 regression（用户实报：设置行「描述显示不全」）。
//
// BUG-1184 把 [AdaptiveSettingsRow.subtitleMaxLines] 的默认从 3 行改成 null
// （= 不钳行数），但说明文字的 Text 仍恒传 `overflow: TextOverflow.ellipsis`，
// 注释里假设「ellipsis 只在显式传有限 maxLines 时才生效」。该假设是错的：
// Flutter/Skia 里 ellipsis 配 maxLines: null 会把整段压成**单行** + 省略号
// （同一段文字 clip 排 8 行、ellipsis 只排 1 行），于是说明文字从 3 行退化到
// 1 行，比修复前更糟——视频快捷设置里「字幕遮蔽」「尊重字幕自带样式」等长说明
// 全部只剩开头一行加「…」。
//
// 关键：这个 bug **抓不到属性层**——`Text.maxLines` 属性本身就是 null（"正确"），
// 坏的是渲染结果。所以守卫必须断言 RenderParagraph 的真实行数。
const String _longSubtitle = '选择听力练习时如何遮蔽字幕：关闭、模糊（悬停或点击显形）或隐藏。'
    '关闭则完全按播放器默认行为显示字幕，不做任何遮挡处理。';

/// 取说明文字那一段的 RenderParagraph（内容即 [_longSubtitle]）。
RenderParagraph _subtitleParagraph(WidgetTester tester) {
  return tester.renderObject<RenderParagraph>(find.text(_longSubtitle));
}

/// 实际渲染出的行数。[RenderParagraph] 不暴露行度量，用「不换行时的高度」当单行
/// 高度基准，除到的比值即行数（同一段文字、同一样式，两者行高一致）。
int _renderedLineCount(RenderParagraph paragraph) {
  final double lineHeight = paragraph.getMinIntrinsicHeight(double.infinity);
  expect(lineHeight, greaterThan(0));
  return (paragraph.size.height / lineHeight).round();
}

Future<void> _pumpRow(
  WidgetTester tester, {
  int? subtitleMaxLines,
}) async {
  await tester.pumpWidget(
    buildTestApp(
      MediaQuery(
        data: const MediaQueryData(size: Size(360, 720)),
        child: SizedBox(
          width: 360,
          child: AdaptiveSettingsRow(
            title: '字幕遮蔽',
            subtitle: _longSubtitle,
            icon: Icons.blur_on_outlined,
            showIcon: true,
            subtitleMaxLines: subtitleMaxLines,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'a long settings subtitle wraps to every line instead of being ellipsized '
    'to one (BUG-1537)',
    (WidgetTester tester) async {
      await _pumpRow(tester);

      final RenderParagraph paragraph = _subtitleParagraph(tester);
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '说明文字的唯一职责就是解释配置项，截断即失效：默认必须整段显示。'
            '恒传 TextOverflow.ellipsis 会让 maxLines:null 退化成单行截断。',
      );
      expect(
        _renderedLineCount(paragraph),
        greaterThan(1),
        reason: '360dp 窄行里这段说明放不下一行，必须换行而不是被省略号吃掉；'
            '渲染成 1 行即说明 ellipsis 又在 maxLines:null 下生效了',
      );
    },
  );

  testWidgets(
    'an explicit subtitleMaxLines still clamps with an ellipsis (BUG-1537 '
    '未破坏密度敏感调用点)',
    (WidgetTester tester) async {
      await _pumpRow(tester, subtitleMaxLines: 2);

      final RenderParagraph paragraph = _subtitleParagraph(tester);
      expect(_renderedLineCount(paragraph), 2);
      expect(
        paragraph.didExceedMaxLines,
        isTrue,
        reason: '显式传有限值的调用点（列表密度敏感处）必须保持钳行 + 省略号',
      );
    },
  );
}
