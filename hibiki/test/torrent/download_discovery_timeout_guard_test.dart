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
/// 修复：收敛成唯一常量 [kDownloadDiscoveryTimeout] 并放宽到 60s，
/// 同时把**连接建立**单独分层到 [kDownloadConnectionTimeout]——否则连不上
/// （墙外丢包 / 代理进程已退出，socket 层不会快速失败）的场景要空转满 60s，
/// 而 UI 等待期只有无进度、无取消的转圈，是比原 bug 更难受的体验倒退。
///
/// 本守卫钉三件事：
///   A. 整体超时不得被调回原来那种「直连口径」的短值。
///   B. 消费方不得再出现裸 `Duration(seconds: N)` 形式的 `.timeout(...)`，
///      否则常量就被架空了。
///   C. 建连超时必须真的挂到 client 上，且明显短于整体超时——
///      不能只留一个常量而没人消费，那样注释就又在说代码没做的事。
void main() {
  group('BUG-1141 下载发现链路超时（代理下 20s 太短）', () {
    test('A. 整体超时至少 60s，且是唯一真相源', () {
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
      // `.timeout(` 后面直接跟 Duration(...) 的写法即为漏网魔法数字。
      // `const` 可省，故设为可选——只匹配 `const Duration` 的正则会被
      // `.timeout(Duration(seconds: 20))` 轻易绕过。
      final RegExp bare = RegExp(r'\.timeout\(\s*(?:const\s+)?Duration\(');
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

    test('C. 建连超时已挂到 client 上，且明显短于整体超时', () {
      expect(
        kDownloadConnectionTimeout.inSeconds,
        lessThan(kDownloadDiscoveryTimeout.inSeconds),
        reason: '建连超时不短于整体超时就等于没分层',
      );
      expect(
        kDownloadConnectionTimeout.inSeconds,
        inInclusiveRange(5, 20),
        reason: '太短会误杀慢代理握手，太长就失去「连不上快速失败」的意义',
      );
      // 光有常量不算数——必须真的赋给 HttpClient，否则注释又在说代码没做的事。
      final File proxy =
          File('lib/src/media/torrent/download_network_proxy.dart');
      expect(proxy.existsSync(), isTrue);
      expect(
        RegExp(r'connectionTimeout\s*=\s*kDownloadConnectionTimeout')
            .hasMatch(proxy.readAsStringSync()),
        isTrue,
        reason: 'buildDownloadHttpClient 必须把 kDownloadConnectionTimeout '
            '赋给 HttpClient.connectionTimeout',
      );
    });
  });
}
