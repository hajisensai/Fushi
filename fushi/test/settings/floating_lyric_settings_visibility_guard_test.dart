import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the settings-panel visibility of the desktop floating-subtitle
/// controls (TODO-038). The bug: the three floating-lyric items were gated to
/// `Platform.isAndroid`, so Windows desktop users — whose runner-owned strip is
/// fully supported — never saw the switch and the feature looked broken /
/// "permission gated". These guards pin that the gate now also allows Windows.
/// The `app_icon` picker likewise now allows Windows (runtime window/taskbar
/// icon switching — preset + custom image), so its gate widened from
/// Android-only too.
void main() {
  late String schema;

  setUpAll(() {
    // TODO-586　floating_lyric 四项搬到 listening 领域文件，app_icon 在 appearance
    // 领域文件；itemBlock 只按 id 切片，把两份源拼接即可保持各 item 块独立可断言。
    final String listeningSrc = File(
      'lib/src/settings/settings_schema_listening.dart',
    ).readAsStringSync();
    final String appearanceSrc = File(
      'lib/src/settings/settings_schema_appearance.dart',
    ).readAsStringSync();
    schema = '$listeningSrc\n$appearanceSrc';
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
      'listening.floating_lyric_text_opacity',
      'listening.floating_lyric_button_bg_opacity',
      'listening.floating_lyric_corner_radius',
      'listening.floating_lyric_width',
      'listening.floating_lyric_visible_lines',
      'listening.floating_lyric_color_text',
      'listening.floating_lyric_color_background',
      // TODO-576: 背景透明度滑杆也要跟字号一样在 Windows 桌面可见。
      'listening.floating_lyric_bg_opacity',
      'listening.floating_lyric_click_lookup',
    ];

    for (final String id in floatingIds) {
      test('$id is visible on Windows desktop, not Android-only', () {
        final String block = itemBlock(id);
        // 总开关内联写判据；其余参数项统一走 _floatingLyricOn（下面单独钉它
        // 的定义同时放行两端并跟随开关）。
        expect(
          block.contains('Platform.isAndroid || Platform.isWindows') ||
              block.contains('visible: _floatingLyricOn,'),
          isTrue,
          reason:
              '$id must be visible on Android and Windows '
              '(the desktop strip is supported).',
        );
        expect(
          RegExp(
            r'visible:\s*\(_\)\s*=>\s*Platform\.isAndroid,',
          ).hasMatch(block),
          isFalse,
          reason: '$id must not be gated to Android only.',
        );
      });
    }

    test(
      'the enable switch stays reachable while styling follows enabled state',
      () {
        final String switchBlock = itemBlock('listening.floating_lyric');
        final String switchVisibility = switchBlock.substring(
          switchBlock.indexOf('visible:'),
          switchBlock.indexOf('value:'),
        );
        expect(
          switchVisibility,
          isNot(contains('showFloatingLyric')),
          reason:
              'The switch must remain reachable after disabling the feature.',
        );
        for (final String id in floatingIds.skip(1)) {
          expect(
            itemBlock(id).contains('visible: _floatingLyricOn,'),
            isTrue,
            reason:
                '$id is a feature parameter; evaluate enabled state at render time.',
          );
        }
        final int gate = schema.indexOf(
          'bool _floatingLyricOn(SettingsContext c)',
        );
        expect(gate, greaterThan(0));
        final String gateBody = schema.substring(
          gate,
          schema.indexOf(';', gate),
        );
        expect(gateBody, contains('Platform.isAndroid || Platform.isWindows'));
        expect(gateBody, contains('c.appModel.showFloatingLyric'));
      },
    );

    test('app_icon picker is visible on Android and Windows', () {
      final String block = itemBlock('appearance.app_icon');
      expect(
        block.contains('Platform.isAndroid || Platform.isWindows'),
        isTrue,
        reason:
            'app_icon picker now supports Windows runtime icon switching '
            '(preset + custom image), so its gate widened from Android-only.',
      );
      // Must not be regated to Android-only.
      expect(
        RegExp(r'visible:\s*\(_\)\s*=>\s*Platform\.isAndroid,').hasMatch(block),
        isFalse,
        reason: 'app_icon must not be gated to Android only.',
      );
    });
  });
}
