import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1483 守卫：Windows 装进不可写目录（如 Program Files）后，WebView2 的
/// 默认用户数据目录（exe 旁 `<exe>.WebView2`）建不出来 → 每次启动弹
/// 「无法创建数据目录」且阅读器/查词 WebView 整体不可用。
///
/// 修复契约分三段，缺一不可，各自用源码扫描钉住：
/// 1. runner 在引擎起来之前探测 exe 旁可写性，不可写时把
///    FUSHI_WEBVIEW2_USER_DATA_FOLDER 指到 %LOCALAPPDATA%（可写时不设，
///    存量安装 profile 位置不变）；
/// 2. fork 的两个 WebView2 环境创建点仍以该环境变量为覆盖入口（否则 runner
///    设了也没人读，回退静默失效）；
/// 3. 安装器在选目录页做写入预检，不再让 lowest 权限安装装到复制阶段才
///    蹦 Error 5。
void main() {
  group('BUG-1483 WebView2 user-data fallback on read-only install dir', () {
    final String mainCpp = File('windows/runner/main.cpp').readAsStringSync();
    final String installerIss =
        File('windows/installer/fushi.iss').readAsStringSync();

    test('runner probes exe-dir writability and falls back to LOCALAPPDATA',
        () {
      // 回退函数存在，且尊重已设变量（itest harness 隔离，TODO-1003）。
      expect(mainCpp, contains('EnsureWritableWebView2UserDataFolder'),
          reason: '不可写安装目录的 WebView2 数据目录回退函数被移除。');
      expect(
          mainCpp,
          contains(
              'GetEnvironmentVariableW(L"FUSHI_WEBVIEW2_USER_DATA_FOLDER"'),
          reason: '回退前必须先尊重 harness 已显式设置的隔离目录。');
      // 真探测（探针文件）而不是猜 ACL。
      expect(mainCpp, contains('.fushi-webview2-write-probe'),
          reason: '可写性必须用探针文件实测，不能按路径字符串猜。');
      // 回退目标基于 LOCALAPPDATA，并真正写回环境变量供 fork 读取。
      expect(
          mainCpp,
          contains(
              'SetEnvironmentVariableW(L"FUSHI_WEBVIEW2_USER_DATA_FOLDER"'),
          reason: '不可写时必须把回退目录写回环境变量，否则 fork 读不到。');
      expect(mainCpp, contains('L"LOCALAPPDATA"'),
          reason: '回退目录必须落在用户可写的 LOCALAPPDATA 下。');
    });

    test('fallback runs before the Flutter engine window is created', () {
      final int callIndex =
          mainCpp.indexOf('  EnsureWritableWebView2UserDataFolder();');
      final int engineIndex = mainCpp.indexOf('FlutterWindow window(project);');
      expect(callIndex, isNot(-1), reason: 'wWinMain 必须调用回退函数（只有定义没有调用等于没修）。');
      expect(engineIndex, isNot(-1));
      expect(callIndex, lessThan(engineIndex),
          reason: '必须在 Flutter engine（进而 WebView2 环境）创建之前决定数据目录。');
    });

    test('fork environment sites still honor the override env var', () {
      final String inAppWebView = File(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      ).readAsStringSync();
      final String webViewEnvironment = File(
        '../packages/flutter_inappwebview_windows/windows/webview_environment/webview_environment.cpp',
      ).readAsStringSync();
      expect(inAppWebView, contains('FUSHI_WEBVIEW2_USER_DATA_FOLDER'),
          reason: 'fork 默认环境点不读该变量的话，runner 的回退会静默失效。');
      expect(webViewEnvironment, contains('FUSHI_WEBVIEW2_USER_DATA_FOLDER'),
          reason: 'fork 自定义环境点不读该变量的话，runner 的回退会静默失效。');
    });

    test('installer preflights write access on the directory page', () {
      expect(installerIss, contains('InstallDirWritable'),
          reason: '安装器必须在选目录页预检可写性，而不是复制阶段才报 Error 5。');
      expect(installerIss, contains('wpSelectDir'),
          reason: '预检必须挂在选目录页的 NextButtonClick 上。');
      expect(installerIss, contains('.fushi-setup-write-test'),
          reason: '预检必须用探针文件实测写入，不能只判目录存在性。');
      expect(installerIss, contains('NextButtonClick'),
          reason: '没有 NextButtonClick 钩子，预检函数只是死代码。');
    });
  });
}
