import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String header =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();
  final String runner =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
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
}
