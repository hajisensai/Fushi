import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2871：macOS 查词浮层右侧整条白色竖条。
///
/// 上游 flutter_inappwebview_macos 1.1.2 的 `transparentBackground: true` 只把
/// `underPageBackgroundColor` 设成 `.clear`，没关 WKWebView 自己的
/// `drawsBackground`——WKWebView 照旧在页面底下铺一层系统默认底色（浅色外观下
/// 是白色）。查词浮层的 html 背景只铺内容区，popup.css 的 8px 经典
/// `::-webkit-scrollbar` 槽位轨道透明，槽位里透出来的正是这层白底。
///
/// 修复是 `ci/patches/hosted/flutter_inappwebview_macos-1.1.2/` 的整文件覆盖补丁，
/// Swift 不在任何 Dart 测试的编译面上，所以用源码扫描钉住三件事：
///   1. 锁定版本与补丁目录同号（版本一漂，apply-patches.sh 只告警跳过，修复静默失效）；
///   2. 补丁在初始化与 setSettings 两条路径上都把 drawsBackground 关掉；
///   3. 查词浮层 WebView 仍然走 transparentBackground: true（补丁的消费方）。
void main() {
  /// 测试 cwd 恒为 `fushi/`，仓库根是它的父目录。
  final Directory repoRoot = Directory.current.parent;
  const String version = '1.1.2';
  const String patchFile =
      'ci/patches/hosted/flutter_inappwebview_macos-$version/'
      'macos/Classes/InAppWebView/InAppWebView.swift';

  String read(String relative) => File(
    '${repoRoot.path}/$relative',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test(
    'pubspec.lock pins flutter_inappwebview_macos to the patched version',
    () {
      final RegExpMatch? m = RegExp(
        r'flutter_inappwebview_macos:\n(?:\s{4}.*\n)*?\s{4}version: "([^"]+)"',
      ).firstMatch(read('pubspec.lock'));
      expect(
        m,
        isNotNull,
        reason: 'flutter_inappwebview_macos must stay in the root pubspec.lock',
      );
      expect(
        m!.group(1),
        version,
        reason:
            '锁定版本变了：把 ci/patches/hosted/flutter_inappwebview_macos-*'
            ' 移到新版本号并核对上游是否已修，否则补丁被跳过、白条回归',
      );
    },
  );

  test('init path turns drawsBackground off for transparentBackground', () {
    final String source = read(patchFile);
    final int start = source.indexOf('if settings.transparentBackground {');
    expect(
      start,
      isNot(-1),
      reason: 'init 路径必须按 transparentBackground 分支（BUG-2871）',
    );
    final String block = source.substring(start, start + 400);
    expect(block, contains('setValue(false, forKey: "drawsBackground")'));
    expect(block, contains('underPageBackgroundColor = .clear'));
  });

  test(
    'setSettings keeps drawsBackground in sync with transparentBackground',
    () {
      final String source = read(patchFile);
      final int setSettings = source.indexOf('func setSettings(');
      expect(setSettings, isNot(-1));
      final String body = source.substring(setSettings);
      expect(
        body,
        contains(
          'setValue(!newSettings.transparentBackground, forKey: "drawsBackground")',
        ),
        reason: '运行时切换 transparentBackground 也必须同步 drawsBackground',
      );
    },
  );

  test('lookup popup WebView still requests a transparent background', () {
    final String source = read(
      'fushi/lib/src/pages/implementations/dictionary_popup_webview.dart',
    );
    expect(source, contains('transparentBackground: true'));
  });
}
