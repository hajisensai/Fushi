import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/torrent/download_network_proxy.dart';

/// BUG-1141：用户报：挂着代理搜 Nyaa，「发现」页只出
/// `TimeoutException after 0:00:20.000000: Future not completed` + 「请点重试」。
///
/// 根因不是网络断，是发现链路（AniList / Nyaa / Jimaku）三家都在墙外，`auto`
/// 代理模式下解析系统代理 + 建隧道 + TLS 握手叠起来常常超过 20s，而这 20s 是
/// 按直连拍脑袋定的，且以魔法数字散落在 8 个调用点（对话框 5 处 + 订阅检查 3 处），
/// 调一次要改八处，必然漂。
///
/// 修复：收敛成唯一常量 [kDownloadDiscoveryTimeout] 并放宽到 60s。
/// 本守卫钉两件事：
///   A. 常量本身不得被调回原来那种「直连口径」的短值。
///   B. 两个消费方不得再出现裸 `Duration(seconds: N)` 形式的 `.timeout(...)`，
///      否则常量就被架空了。
void main() {
  group('BUG-1141 下载发现链路超时（代理下 20s 太短）', () {
    test('A. 共享常量至少 60s，且是唯一真相源', () {
      expect(
        kDownloadDiscoveryTimeout.inSeconds,
        greaterThanOrEqualTo(60),
        reason: '代理链路握手 + TLS 常年超 20s；调短会把本来能成功的搜索掐断',
      );
    });

    test('B. 消费方全部走常量，不留裸 Duration 超时', () {
      const List<String> consumers = <String>[
        'lib/src/pages/implementations/anime_download_dialog.dart',
        'lib/src/media/torrent/anime_download_subscription.dart',
      ];
      // `.timeout(` 后面直接跟 const Duration(...) 的写法即为漏网魔法数字。
      final RegExp bare = RegExp(r'\.timeout\(\s*const\s+Duration\(');
      for (final String path in consumers) {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: '找不到 $path（文件被移动？）');
        final String src = file.readAsStringSync();
        expect(
          bare.hasMatch(src),
          isFalse,
          reason: '$path 里还有裸 Duration 超时；应改用 kDownloadDiscoveryTimeout',
        );
        expect(
          src.contains('kDownloadDiscoveryTimeout'),
          isTrue,
          reason: '$path 应该消费共享超时常量',
        );
      }
    });
  });
}
