import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-350 守卫：三省堂等词典的 pitch inline SVG 不独占行，依赖 popup.css 里
/// `.gloss-image-scroll` 的 `display: inline-block`（若改回 `block`，inline pitch SVG
/// 会被推成独占行 = 复现 TODO-350）。此前只有 JS 守卫
/// (test/utils/misc/popup_asset_behavior_test.js) 断言该不变量，但 JS 守卫不进 CI
/// （CI 只跑 flutter test 的 .dart），改回 block 时 CI 仍假绿。本 Dart 守卫在 CI 真跑。
void main() {
  test(
    'popup.css .gloss-image-scroll keeps display:inline-block + overflow-x:auto (TODO-350)',
    () {
      final String css = File('assets/popup/popup.css').readAsStringSync();
      final RegExpMatch? rule =
          RegExp(r'\.gloss-image-scroll\s*\{([^}]*)\}').firstMatch(css);
      expect(rule, isNotNull,
          reason: '.gloss-image-scroll 规则块应存在于 assets/popup/popup.css');
      final String body = rule!.group(1)!;
      expect(
        RegExp(r'display\s*:\s*inline-block').hasMatch(body),
        isTrue,
        reason:
            'TODO-350: pitch SVG 不独占行需 display:inline-block；改回 block 会让三省堂音调标记独占行',
      );
      expect(
        RegExp(r'overflow-x\s*:\s*auto').hasMatch(body),
        isTrue,
        reason: '宽图横向滚动容器需保留 overflow-x:auto',
      );
    },
  );
}
