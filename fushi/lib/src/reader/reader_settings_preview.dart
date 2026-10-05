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

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';

/// 预览字号相对正文字号的缩放。
const double kReaderPreviewFontScale = 0.6;

/// 预览卡固定高度（逻辑 px）：字号变化不推动下方设置行上下跳。
const double kReaderPreviewHeight = 128;

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
    final TextStyle style = TextStyle(
      fontSize: readerPreviewFontSize(readerFontSize),
      height: lineHeight.clamp(1.0, 3.0),
      fontWeight: readerPreviewFontWeight(fontWeight),
      color: foreground,
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
          height: kReaderPreviewHeight,
          decoration: BoxDecoration(
            color: background,
            borderRadius: fushiNeutralBlockRadius(context),
            border: Border.all(
              color: foreground.withValues(alpha: 0.12),
            ),
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

/// 竖排近似：逐字自上而下成列、列自右向左排（vertical-rl）。
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
    final double fontSize = style.fontSize ?? 14;
    final double columnGap = fontSize * ((style.height ?? 1.5) - 1);
    return AnimatedDefaultTextStyle(
      duration: duration,
      curve: FushiMotion.standard,
      style: style.copyWith(height: 1.15),
      child: Wrap(
        direction: Axis.vertical,
        textDirection: TextDirection.rtl,
        runSpacing: columnGap,
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          for (final int rune in sample.runes)
            Text(String.fromCharCode(rune)),
        ],
      ),
    );
  }
}
