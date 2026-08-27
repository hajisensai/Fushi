// BUG-1878：查词弹窗底色必须跟随当前主题的 MD3 `scheme.surface`。
//
// 2026-08-23 的「对齐 Niratan」把 popupCardSurface 钉成了纯白 #FFFFFF /
// 纯黑 #000000（Niratan 自己的色彩体系），于是弹窗与它贴着的阅读器、视频页、
// 设置页底色割裂——用户反馈「背景颜色不对，之前抄的时候抄过头了」。
//
// 这是真行为测试（直接调 helper），不是源码扫描：纯白/纯黑一旦被写回来，
// tinted seed 主题下的断言立刻红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/popup_theme_css.dart';

void main() {
  // MD3 种子色主题：surface 带色调，天然不等于纯白/纯黑。
  final ColorScheme light = ColorScheme.fromSeed(
      seedColor: const Color(0xFF386A58), brightness: Brightness.light);
  final ColorScheme dark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF386A58), brightness: Brightness.dark);

  test('前置：种子主题的 surface 确实是 tinted（否则本文件的断言无意义）', () {
    // 没有这一条，「不等于纯白」可能只是因为 fromSeed 恰好也给了纯白 —— 那样
    // 下面的测试即使 helper 写死纯白也照样绿（假绿）。
    expect(light.surface, isNot(const Color(0xFFFFFFFF)),
        reason: 'MD3 浅色 surface 应带种子色调');
    expect(dark.surface, isNot(const Color(0xFF000000)),
        reason: 'MD3 深色 surface 应带种子色调');
  });

  test('浅色主题：卡面取 scheme.surface，不是纯白', () {
    expect(popupCardSurface(scheme: light), light.surface);
  });

  test('深色主题：卡面取 scheme.surface，不是纯黑', () {
    expect(popupCardSurface(scheme: dark), dark.surface);
  });

  test('用户指定的词典底色 override 仍然优先于主题 surface', () {
    const Color override = Color(0xFF112233);
    expect(popupCardSurface(scheme: light, override: override), override);
    expect(popupCardSurface(scheme: dark, override: override), override);
  });

  test('注入 CSS 的 --background-color / --fushi-card-bg-rgb 跟着走主题色', () {
    final Map<String, String> vars = buildPopupThemeCssVars(
      scheme: dark,
      backgroundColor: popupCardSurface(scheme: dark),
      surfaceContainerHigh: dark.surfaceContainerHigh,
      dictionaryColumns: 1,
    );
    expect(vars['--background-color'], cssRgb(dark.surface));
    expect(vars['--fushi-card-bg-rgb'], cssRgbTriplet(dark.surface));
    expect(vars['--background-color'], isNot('rgb(0, 0, 0)'),
        reason: '弹窗底色不得回到 Niratan 的纯黑');
  });
}
