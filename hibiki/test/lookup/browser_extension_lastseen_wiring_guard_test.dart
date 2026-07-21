import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 扩展连接探活（last-seen）接线守卫（源码扫描）：安装页的「验证插件已正常启用」连接检测
/// 依赖一条链路——扩展打本机 server 任一端点 → server 回调 onExtensionSeen → app 记录
/// last-seen 时间戳 → 页面据此判断已连上。缺任一段，连接检测都恒为「未检测到」。
void main() {
  group('extension last-seen wiring', () {
    test('yomitan server 在扩展端点命中时回调 onExtensionSeen', () {
      final String src =
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync();
      // 探活端点集合含状态与查词（扩展启动打状态、使用时打查词，都应刷新 last-seen）。
      expect(src, contains("'/api/extension/status',"));
      expect(src, contains("'/api/lookup/dictionary',"));
      // 命中即回调。
      expect(src, contains('if (_kExtensionSeenPaths.contains(path)) {'),
          reason: '扩展端点命中必须触发 onExtensionSeen 回调');
      expect(src, contains('_onExtensionSeen?.call();'));
    });

    test('manager 把 onExtensionSeen 透传给 server', () {
      final String src = File('lib/src/sync/yomitan_api_server_manager.dart')
          .readAsStringSync();
      expect(src, contains('void Function()? onExtensionSeen'));
      expect(src, contains('onExtensionSeen: _onExtensionSeen'));
    });

    test('AppModel 接线 onExtensionSeen 刷新 last-seen 时间戳', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(
          RegExp(r'onExtensionSeen:\s*\(\)\s*=>\s*\n?\s*'
                  r'_browserExtensionLastSeenAt\s*=\s*DateTime\.now\(\)')
              .hasMatch(src),
          isTrue,
          reason: 'onExtensionSeen 必须刷新 _browserExtensionLastSeenAt');
      // 页面读取用的公开 getter 必须存在。
      expect(src, contains('DateTime? get browserExtensionLastSeenAt'));
      expect(src, contains('String? get browserExtensionBuild'));
    });
  });
}
