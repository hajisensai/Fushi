// 窗口级系统材质（Windows 11 Mica / macOS vibrancy）与组件悬浮面材质解耦的守卫。
//
// 所有者 2026-10-13 拍板：Apple（Cupertino）设计系统组件悬浮面去玻璃改实色
// （`ThemeNotifier.glassMaterialTier` 钉成 off），但窗口级 Mica / vibrancy 保留。
// 回归原样：`main.dart` 曾按 `glassMaterialOf(context) != off` 决定要不要开 Mica，
// 材质档钉成 off 之后 Apple 用户的 Mica / vibrancy 被整体静默关掉——没有报错，
// 只有窗口背景从系统材质变成了实色。
//
// 这里钉三层：判据纯函数、BuildContext 版在「材质档 off 的 Apple 主题」下仍为
// true，以及 main.dart 真的接的是这条判据而不是组件材质档。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/system_transparency.dart';
import 'package:material_ui/material_ui.dart';

final ColorScheme _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

/// 在给定主题 / 增强对比度下取一次 [windowBackdropRequestedOf]。
Future<bool> _requestedUnder(
  WidgetTester tester, {
  required bool glassDesign,
  bool eink = false,
  bool highContrast = false,
}) async {
  bool? result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(highContrast: highContrast),
      child: Theme(
        data: buildFushiThemeData(
          scheme: _scheme,
          textTheme: Typography.material2021().black,
          eink: eink,
          // 与生产一致：Apple 设计系统的组件材质档已钉成 off。
          glass: FushiGlassMaterial.off,
          glassDesign: glassDesign,
        ),
        child: Builder(
          builder: (BuildContext context) {
            result = windowBackdropRequestedOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return result!;
}

void main() {
  tearDown(() {
    SystemTransparency.reduceTransparency.value = false;
  });

  test('判据只看设计系统 / 降低透明度 / 增强对比度', () {
    expect(
      fushiWindowBackdropRequested(
        glassDesign: true,
        reduceTransparency: false,
        highContrast: false,
      ),
      isTrue,
    );
    expect(
      fushiWindowBackdropRequested(
        glassDesign: false,
        reduceTransparency: false,
        highContrast: false,
      ),
      isFalse,
      reason: 'MD3 不开窗口材质',
    );
    expect(
      fushiWindowBackdropRequested(
        glassDesign: true,
        reduceTransparency: true,
        highContrast: false,
      ),
      isFalse,
      reason: '系统「降低透明度」关窗口材质',
    );
    expect(
      fushiWindowBackdropRequested(
        glassDesign: true,
        reduceTransparency: false,
        highContrast: true,
      ),
      isFalse,
      reason: '增强对比度关窗口材质',
    );
  });

  testWidgets('Apple 主题材质档为 off 时窗口材质仍请求开启', (WidgetTester tester) async {
    expect(await _requestedUnder(tester, glassDesign: true), isTrue);
  });

  testWidgets('MD3 / 墨水屏 / 增强对比度 / 降低透明度下不请求', (WidgetTester tester) async {
    expect(await _requestedUnder(tester, glassDesign: false), isFalse);
    expect(
      await _requestedUnder(tester, glassDesign: true, eink: true),
      isFalse,
      reason: '墨水屏下 isGlassDesign 恒 false',
    );
    expect(
      await _requestedUnder(tester, glassDesign: true, highContrast: true),
      isFalse,
    );
    SystemTransparency.reduceTransparency.value = true;
    expect(await _requestedUnder(tester, glassDesign: true), isFalse);
  });

  test('main.dart 的 setSystemBackdrop 接的是窗口材质判据，不是组件材质档', () {
    final String src = File('lib/main.dart').readAsStringSync();
    final int call = src.indexOf('WindowCaptionChannel.setSystemBackdrop(');
    expect(call, isNot(-1), reason: 'main.dart 必须下发系统窗口材质');
    final int end = src.indexOf(');', call);
    final String args = src.substring(call, end);
    expect(args, contains('mica: windowBackdropRequestedOf(context)'));
    expect(
      args,
      isNot(contains('glassMaterialOf')),
      reason: '组件材质档钉成 off 后，按它判会把 Apple 的 Mica / vibrancy 一起关掉',
    );
  });
}
