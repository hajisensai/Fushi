import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 自更新升级点守卫（源码扫描）：把扩展版本检查从「仅查词后被动比对」升级为「启动即主动
/// 检查」。此前 app 升级当天用户若不划词，浏览器里的弹窗逻辑一直停在旧版；现在扩展 SW
/// 每次启动都主动打 /api/extension/status 取当前内置指纹，走同一个 maybeSelfReload 自更新。
/// 该请求同时刷新 app 侧扩展 last-seen（连接检测据此判断「插件已正常启用」）。
void main() {
  group('extension startup version check', () {
    late String bg;

    setUpAll(() {
      bg = File('assets/browser_extension/background.js').readAsStringSync();
    });

    test('background.js 定义启动版本检查函数', () {
      expect(bg, contains('async function checkVersionOnStartup'),
          reason: '必须有启动版本检查函数');
      // 主动打状态端点（不再依赖用户查词）。
      expect(bg, contains("fetch(base + '/api/extension/status'"),
          reason: '启动检查必须打 /api/extension/status 取当前内置指纹');
      // 拿到状态响应后走同一个自更新入口。
      final int fn = bg.indexOf('async function checkVersionOnStartup');
      final String body = bg.substring(fn, fn + 700);
      expect(body, contains('maybeSelfReload(status)'),
          reason: '启动检查必须调用 maybeSelfReload 完成自更新');
    });

    test('SW 启动 + onStartup + onInstalled 三处都触发启动检查', () {
      expect(RegExp(r'checkVersionOnStartup\(\);').hasMatch(bg), isTrue,
          reason: 'SW 顶层每次唤醒都主动检查一次');
      expect(bg, contains('chrome.runtime.onStartup.addListener'),
          reason: '浏览器启动时检查');
      expect(bg, contains('chrome.runtime.onInstalled.addListener'),
          reason: '安装/更新时检查');
    });

    test('server /api/extension/status 回带 extensionBuild', () {
      final String src =
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync();
      // 状态端点回带当前内置扩展指纹（供启动检查比对）；null 时省略字段（向后兼容）。
      expect(
          src,
          contains(
              "if (extensionBuild != null) 'extensionBuild': extensionBuild"),
          reason: '状态端点必须条件回带 extensionBuild 指纹');
    });
  });
}
