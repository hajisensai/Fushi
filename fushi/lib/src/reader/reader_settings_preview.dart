/// 阅读设置侧板顶部的「实时预览」卡（2026-10 侧板重设计）。
///
/// 改字号 / 字重 / 行高 / 排版方向 / 主题时，用户此前只能关掉面板看正文才知道
/// 效果（面板本身就压着正文的一半）。预览卡用阅读纸色与正文色画一段样文，随设置
/// 即时变化（字号、行高走隐式动画，时长取 [FushiMotion]，墨水屏 / 减弱动态效果
/// 下瞬时到位）。
///
/// 它只是**示意**：字号按 [kReaderPreviewFontScale] 缩小（正文 30px 的字塞进
/// 400px 宽的面板只放得下一行），竖排用逐字分列近似（Flutter 没有原生竖排），
/// 真实排版仍以正文 WebView 为准。纯展示，不进焦点遍历。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';

/// 预览字号相对正文字号的缩放。
const double kReaderPreviewFontScale = 0.6;

/// 预览卡固定高度（逻辑 px）：字号变化不推动下方设置行上下跳。
const double kReaderPreviewHeight = 128;

/// 竖排时的预览卡高度。横排的 128 只够竖排每列放两三个字，整段样文被切成
/// 「れた / かと / んと」这种两字一列的碎片、读起来像乱序（2026-10-09 桌面反馈）；
/// 竖排加高到能放下一个短句的列高。
const double kReaderPreviewVerticalHeight = 208;

/// 竖排预览每列至少放下的字数（样文首句「吾輩は猫である。」正好 8 个字）。列高
/// 按当前字号放不下时，按预览框实际高度缩小预览字号（不低于 10）。
const int kReaderPreviewMinCharsPerColumn = 8;

/// 竖排预览的排布（纯函数，供测试）：在 [width] × [height] 的框里、首选字号
/// [preferredFontSize] 下，返回实际字号、每列字数与能放下的列数。
///
/// 字号先按「每列至少 [kReaderPreviewMinCharsPerColumn] 个字」收小（下限 10），
/// 列数按框宽算；样文从第一个字开始自右向左排，放不下的尾部截掉，而不是让
/// 开头被挤出框外。
({double fontSize, int perColumn, int columns}) readerPreviewVerticalLayout({
  required double width,
  required double height,
  required double preferredFontSize,
  required double lineHeight,
}) {
  const double advance = 1.15;
  double size = preferredFontSize;
  if (height / (size * advance) < kReaderPreviewMinCharsPerColumn) {
    size = (height / (kReaderPreviewMinCharsPerColumn * advance)).clamp(
      10.0,
      preferredFontSize,
    );
  }
  final int perColumn = (height / (size * advance)).floor().clamp(1, 1 << 20);
  final double gap = size * (lineHeight.clamp(1.0, 3.0) - 1);
  final double columnWidth = size * 1.1;
  final int columns = ((width + gap) / (columnWidth + gap)).floor().clamp(
    1,
    1 << 20,
  );
  return (fontSize: size, perColumn: perColumn, columns: columns);
}

/// 预览样文的显示字号（纯函数，供测试）：正文字号 × [kReaderPreviewFontScale]，
/// 夹在 10–30 之间（极端字号下仍能看出「变大 / 变小」而不撑破卡片）。
double readerPreviewFontSize(double readerFontSize) =>
    (readerFontSize * kReaderPreviewFontScale).clamp(10.0, 30.0);

/// 预览样文的显示字重：CSS 100–900 → 最接近的 [FontWeight]。
FontWeight readerPreviewFontWeight(double weight) {
  final int index = ((weight.clamp(100, 900) / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}

class ReaderSettingsPreviewCard extends StatelessWidget {
  const ReaderSettingsPreviewCard({
    super.key,
    required this.sample,
    required this.background,
    required this.foreground,
    required this.readerFontSize,
    required this.lineHeight,
    required this.fontWeight,
    required this.vertical,
    this.label,
  });

  /// 样文（日文，随 i18n 给出）。
  final String sample;

  /// 阅读纸色 / 正文色（取阅读器当前主题解析结果，不是 app 主题）。
  final Color background;
  final Color foreground;

  /// 正文的真实值（未缩放）。
  final double readerFontSize;
  final double lineHeight;
  final double fontWeight;

  /// 竖排（vertical-rl）。
  final bool vertical;

  /// 左上角小标签（「预览」）。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // 在环境文字样式上合并（保留字体族 / 字形回退），只覆盖预览要表达的维度。
    final TextStyle style = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: readerPreviewFontSize(readerFontSize),
        height: lineHeight.clamp(1.0, 3.0),
        fontWeight: readerPreviewFontWeight(fontWeight),
        color: foreground,
      ),
    );
    final Widget text = vertical
        ? _VerticalSample(sample: sample, style: style, duration: duration)
        : AnimatedDefaultTextStyle(
            duration: duration,
            curve: FushiMotion.standard,
            style: style,
            child: Text(sample, overflow: TextOverflow.fade),
          );
    return ExcludeFocus(
      child: Semantics(
        container: true,
        label: label,
        child: AnimatedContainer(
          key: const ValueKey<String>('reader_settings_preview'),
          duration: duration,
          curve: FushiMotion.standard,
          height: vertical
              ? kReaderPreviewVerticalHeight
              : kReaderPreviewHeight,
          decoration: BoxDecoration(
            color: background,
            borderRadius: fushiNeutralBlockRadius(context),
            border: Border.all(color: foreground.withValues(alpha: 0.12)),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                top: label == null ? 0 : 18,
                child: ClipRect(child: text),
              ),
              if (label != null)
                Positioned(
                  top: 0,
                  left: vertical ? 0 : null,
                  right: vertical ? null : 0,
                  child: Text(
                    label!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.55),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖排近似：逐字自上而下成列、列自右向左排（vertical-rl）。按预览框实际尺寸
/// 排（[readerPreviewVerticalLayout]）：从第一个字开始，每列放满再换下一列，
/// 放不下的尾部截掉。
class _VerticalSample extends StatelessWidget {
  const _VerticalSample({
    required this.sample,
    required this.style,
    required this.duration,
  });

  final String sample;
  final TextStyle style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final ({double fontSize, int perColumn, int columns}) layout =
            readerPreviewVerticalLayout(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              preferredFontSize: style.fontSize ?? 14,
              lineHeight: style.height ?? 1.5,
            );
        final double size = layout.fontSize;
        final double gap = size * ((style.height ?? 1.5).clamp(1.0, 3.0) - 1);
        final List<String> chars = <String>[
          for (final int rune in sample.runes) String.fromCharCode(rune),
        ];
        final List<Widget> columns = <Widget>[];
        for (int c = 0; c < layout.columns; c++) {
          final int start = c * layout.perColumn;
          if (start >= chars.length) break;
          final int end = (start + layout.perColumn).clamp(0, chars.length);
          if (c > 0) columns.add(SizedBox(width: gap));
          columns.add(
            SizedBox(
              width: size * 1.1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final String ch in chars.sublist(start, end))
                    Text(ch, textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }
        return AnimatedDefaultTextStyle(
          key: const ValueKey<String>('reader_settings_preview_vertical'),
          duration: duration,
          curve: FushiMotion.standard,
          style: style.copyWith(fontSize: size, height: 1.15),
          child: ClipRect(
            child: OverflowBox(
              alignment: AlignmentDirectional.topEnd,
              maxHeight: double.infinity,
              child: Row(
                textDirection: TextDirection.rtl,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: columns,
              ),
            ),
          ),
        );
      },
    );
  }
}
