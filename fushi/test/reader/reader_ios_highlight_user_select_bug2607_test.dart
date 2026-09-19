import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2607：iOS 触屏阅读器里查词 / 长按划选 / 收藏句 / 搜索高亮全部不画。
///
/// 根因：TODO-1279 为消除触屏双选区，在 `@media (pointer: coarse)` 下对
/// `html, body, body *` 全量 `user-select: none`。WebKit 对 user-select:none 的文字
/// **不绘制任何 `::highlight()`**（Playwright WebKit 探针：同一条 Range 在裸段落像素
/// 命中 0.559，加 user-select:none 后 0.000，祖先 none / 元素 text 回到 0.559，
/// `-webkit-touch-callout:none` 单独存在不影响）。阅读器所有 CSS Custom Highlight
/// 层（`fushi-selection` / `fushi-hl-*` / `fushi-search`）在 iOS 上因此一律不可见；
/// 有声书当前句是元素 class 背景，不受影响，所以用户看到的是「有声书划句只剩手柄」。
///
/// 修法：iOS 的这条 CSS 只留 `-webkit-touch-callout: none`，「不让长按建原生选区」
/// 改由 WKWebView 原生开关 `WKPreferences.isTextInteractionEnabled = false` 承担
/// （`InAppWebViewSettings.isTextInteractionEnabled`）；其它平台 CSS 不变。
///
/// 覆盖边界：本文件钉「iOS CSS 不含 user-select:none」「非 iOS 仍含」「阅读器 WebView
/// 在 iOS 关 isTextInteractionEnabled」三条静态契约。WebKit 真绘制行为无法在 flutter
/// test 里验，真机证据见 bug 文件。
void main() {
  Future<ReaderSettings> defaultSettings() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  /// 只截 `@media (pointer: coarse)` 块，避免被文件里别处（注释、其它选择器）的
  /// 同名片段假阳性命中。
  String coarseBlock(String css) {
    final int start = css.indexOf('@media (pointer: coarse)');
    expect(start, isNonNegative, reason: '触屏门控块整个没了');
    final int end = css.indexOf('\n}\n', start);
    expect(end, greaterThan(start));
    return css.substring(start, end + 3);
  }

  group('BUG-2607 iOS 触屏高亮不画', () {
    test(
      'iOS：触屏块不得再写 user-select:none（WebKit 不画 ::highlight），保留 touch-callout',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
        });
        final ReaderSettings settings = await defaultSettings();
        final String block = coarseBlock(
          ReaderContentStyles.css(settings: settings),
        );
        expect(
          block,
          isNot(contains('user-select')),
          reason:
              'iOS 上 user-select:none 会让 WebKit 不绘制任何 ::highlight()——'
              '查词/划选/收藏/搜索高亮全部消失（BUG-2607）',
        );
        expect(block, contains('-webkit-touch-callout: none'));
      },
    );

    test(
      'Android：触屏块仍带 user-select:none（Blink 照画 ::highlight，1279 不回归）',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
        });
        final ReaderSettings settings = await defaultSettings();
        final String block = coarseBlock(
          ReaderContentStyles.css(settings: settings),
        );
        expect(block, contains('-webkit-user-select: none !important'));
        expect(block, contains('user-select: none !important'));
        expect(block, contains('-webkit-touch-callout: none'));
      },
    );

    test('阅读器 WebView 在 iOS 关掉原生文本交互（原生选区改由平台开关压）', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('isTextInteractionEnabled: !isIOSPlatform'),
        reason:
            'iOS 撤掉 CSS user-select:none 后，原生长按选区只剩这个开关在压；'
            '没有它 1279 的双选区会在 iOS 复活',
      );
    });
  });
}
