import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

import '../helpers/source_guard.dart';

// BUG-2819：Mac / iOS 分页每章最后一页整体错开一个页边距、满行末字被切掉。
//
// WebKit 算多列 body 的滚动范围时不含行内方向末端的 padding（横排右边距、竖排下边距
// + 底部 chrome inset），物理终点比末页对齐位置少这一截，末页只能停在错位的物理
// 终点上（macOS 27 WKWebView 实测差值 = 右边距 55px / 下边距 + inset 60px）。修法在
// CSS 生成层：Apple 端分页给正文末尾补一个强制另起一栏的非零高空块，把滚动范围撑出
// 一整栏。WebKit 的滚动几何在 headless 测不了，守卫钉生成层的不变式：
//  - iOS / macOS × 横排 / 竖排的分页 CSS 里有一个 `body::after` 块，强制分栏、非零块尺寸
//    （0 高的块 WebKit 不为它另开一栏，实测无效）、`display: block`；
//  - 连续滚动 / VN 与 Blink 平台不发强制分栏（连续模式自己的 `body::after` 章末留白
//    不带分栏，不受影响）。

final RegExp _kBodyAfterBlock = RegExp(r'body::after\s*\{([^}]*)\}');

Future<String> _css({
  required TargetPlatform platform,
  required String writingMode,
  required String viewMode,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setWritingMode(writingMode);
  await settings.setViewMode(viewMode);
  debugDefaultTargetPlatformOverride = platform;
  try {
    return maskCssComments(ReaderContentStyles.css(settings: settings));
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 所有 `body::after` 块里有没有一个强制分栏的。
String? _columnBreakBodyAfter(String css) {
  for (final RegExpMatch m in _kBodyAfterBlock.allMatches(css)) {
    final String body = m.group(1)!;
    if (RegExp(r'break-before:\s*column').hasMatch(body)) return body;
  }
  return null;
}

void main() {
  group('BUG-2819 WebKit 分页末页够得着（末尾补一栏）', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.linux, // WPE WebKit
    ]) {
      for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
        test('${platform.name} $wm paginated: body::after 强制另起一栏且块尺寸非零',
            () async {
          final String css = await _css(
              platform: platform, writingMode: wm, viewMode: 'paginated');
          final String? block = _columnBreakBodyAfter(css);
          expect(block, isNotNull,
              reason: 'Apple 端分页必须在正文末尾补一栏，否则末页对齐位置超出 WebKit 滚动范围');
          expect(block, matches(RegExp(r'display:\s*block')));
          expect(block, matches(RegExp(r'content:\s*""')));
          final RegExpMatch? size =
              RegExp(r'block-size:\s*([\d.]+)px').firstMatch(block!);
          expect(size, isNotNull, reason: '要显式块尺寸');
          expect(double.parse(size!.group(1)!), greaterThan(0),
              reason: '0 高的块 WebKit 不为它另开一栏');
        });
      }
      for (final String vm in <String>['continuous', 'vn']) {
        test('${platform.name} $vm: 不发强制分栏（不经多列分页）', () async {
          for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
            final String css =
                await _css(platform: platform, writingMode: wm, viewMode: vm);
            expect(_columnBreakBodyAfter(css), isNull, reason: '$wm $vm');
          }
        });
      }
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.windows,
    ]) {
      test('${platform.name} paginated: Blink 滚动范围含末端 padding，不发', () async {
        for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
          final String css = await _css(
              platform: platform, writingMode: wm, viewMode: 'paginated');
          expect(_columnBreakBodyAfter(css), isNull, reason: wm);
        }
      });
    }
  });
}
