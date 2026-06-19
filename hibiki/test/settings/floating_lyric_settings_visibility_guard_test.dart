import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the settings-panel visibility of the desktop floating-subtitle
/// controls (TODO-038). The bug: the three floating-lyric items were gated to
/// `Platform.isAndroid`, so Windows desktop users — whose runner-owned strip is
/// fully supported — never saw the switch and the feature looked broken /
/// "permission gated". These guards pin that the gate now also allows Windows
/// while the unrelated Android-only `app_icon` picker stays Android-only.
void main() {
  late String schema;

  setUpAll(() {
    schema = File('lib/src/settings/settings_schema.dart').readAsStringSync();
  });

  /// Returns the slice of the schema for the settings item with [id], up to the
  /// next item id, so a `visible:` assertion is scoped to that one item.
  String itemBlock(String id) {
    final int start = schema.indexOf("id: '$id',");
    expect(start, isNot(-1), reason: 'Item $id must exist in the schema.');
    final int next = schema.indexOf("id: '", start + 5);
    return next == -1 ? schema.substring(start) : schema.substring(start, next);
  }

  group('floating-lyric settings visibility', () {
    const List<String> floatingIds = <String>[
      'listening.floating_lyric',
      'listening.floating_lyric_font_size',
      // TODO-576: 背景透明度滑杆也要跟字号一样在 Windows 桌面可见。
      'listening.floating_lyric_bg_opacity',
      'listening.floating_lyric_click_lookup',
    ];

    for (final String id in floatingIds) {
      test('$id is visible on Windows desktop, not Android-only', () {
        final String block = itemBlock(id);
        expect(
          block.contains('Platform.isAndroid || Platform.isWindows'),
          isTrue,
          reason: '$id must be visible on Android and Windows '
              '(the desktop strip is supported).',
        );
        expect(
          RegExp(r'visible:\s*\(_\)\s*=>\s*Platform\.isAndroid,')
              .hasMatch(block),
          isFalse,
          reason: '$id must not be gated to Android only.',
        );
      });
    }

    test('app_icon picker stays Android-only (unrelated gate untouched)', () {
      final String block = itemBlock('appearance.app_icon');
      expect(
        RegExp(r'visible:\s*\(_\)\s*=>\s*Platform\.isAndroid,').hasMatch(block),
        isTrue,
        reason: 'app_icon is a genuinely Android-only picker; do not widen it.',
      );
      expect(block.contains('Platform.isWindows'), isFalse);
    });
  });
}
