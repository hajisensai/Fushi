import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String header =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();
  final String runner =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
  final String prefs =
      File('lib/src/models/preferences_repository.dart').readAsStringSync();
  final String channel =
      File('windows/runner/flutter_window.cpp').readAsStringSync();

  test('MethodChannel appearance fields are parsed into native style', () {
    for (final String field in <String>[
      'fontFamily',
      'fontPath',
      'letterSpacing',
      'lineHeight',
      'bold',
      'textAlignment',
      'verticalAlignment',
      'textColor',
      'bgColor',
      'outlineColor',
      'outlineWidth',
      'textPadding',
      'cornerRadius',
    ]) {
      expect(channel.contains('"$field"'), isTrue, reason: '$field 未接到 runner');
    }
  });

  test('imported fonts use a private DirectWrite collection with fallback', () {
    expect(header.contains('custom_font_collection_'), isTrue);
    expect(runner.contains('CreateFontFileReference'), isTrue);
    expect(runner.contains('AddFontFile'), isTrue);
    expect(runner.contains('CreateFontCollectionFromFontSet'), isTrue);
    expect(runner.contains('custom_font_collection_.Get()'), isTrue);
    expect(runner.contains('resolved_font_family_'), isTrue);
  });

  test('spacing and alignment stay on the shared hit-test text layout', () {
    expect(runner.contains('SetCharacterSpacing'), isTrue);
    expect(runner.contains('SetLineSpacing'), isTrue);
    expect(runner.contains('style_.text_alignment == 1'), isTrue);
    expect(runner.contains('text_layout_->HitTestPoint'), isTrue);
    expect(runner.contains('text_layout_->HitTestTextRange'), isTrue);
  });

  test('outline, padding and corner radius read user style fields', () {
    expect(runner.contains('style_.outline_color'), isTrue);
    expect(runner.contains('style_.outline_width'), isTrue);
    expect(runner.contains('style_.text_padding'), isTrue);
    expect(runner.contains('style_.corner_radius'), isTrue);
  });

  test('a corner radius of 0 really means 0 (no default-value sentinel)', () {
    // 圆角偏好的下限就是 0（直角）。绘制点如果把 0 当作「用平台默认」，用户把滑块
    // 拖到 0 什么都不会发生，而且现象上完全看不出原因。历史默认必须由 Style 的默认
    // 值承担，绘制点不得有 `corner_radius > 0 ? ... : 默认` 这种哨兵分支。
    expect(
      RegExp(r'style_\.corner_radius\s*>\s*0').hasMatch(runner),
      isFalse,
      reason: '0 是合法圆角取值，不能同时当作「用默认」的哨兵',
    );
    expect(
      header.contains('double corner_radius = 14.0;'),
      isTrue,
      reason: '历史默认 14dp 必须写在 Style 的默认值上',
    );
    expect(
      prefs.contains('galHookTextCornerRadiusMin = 0.0'),
      isTrue,
      reason: '偏好下限是 0，这条守卫的前提',
    );
  });
}
