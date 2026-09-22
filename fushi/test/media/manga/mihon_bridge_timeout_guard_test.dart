import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

/// 守卫：Dart 侧放手的时刻必须**晚于**宿主自己的 OkHttp `callTimeout`。
///
/// 反过来（Dart 先放手）时，JVM / Android 宿主里那次请求还在跑，用户看到的却是一句
/// 无信息量的「桥超时」——真正的失败原因（HTTP 状态码、解析异常、是哪个 hoster 死了）
/// 永远到不了失败页。在线视频源取流是这条链路上最重的一步，此前桌面钉死的 45 秒比
/// 宿主 2 分钟的预算短得多，等于「点开必失败」（BUG-2617）。
///
/// 两端的宿主值各自从 Kotlin 源码里读出来比，而不是在测试里抄一份常数：抄的那份会
/// 和真值悄悄分家，正是这条守卫要防的事。
void main() {
  Duration callTimeoutOf(File file) {
    expect(file.existsSync(), isTrue, reason: '宿主网络层不在预期位置：${file.path}');
    final String text = file.readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'\.callTimeout\(\s*(\d+)\s*,\s*TimeUnit\.(MINUTES|SECONDS)\s*\)',
    ).firstMatch(text);
    expect(
      match,
      isNotNull,
      reason: '${file.path} 里找不到 callTimeout(...)；宿主换了写法就要同步本守卫',
    );
    final int value = int.parse(match!.group(1)!);
    return match.group(2) == 'MINUTES'
        ? Duration(minutes: value)
        : Duration(seconds: value);
  }

  final Map<String, File> hosts = <String, File>{
    '桌面 sidecar': File(
      '../third_party/m_extension_server/overlay/server/src/main/kotlin/'
      'eu/kanade/tachiyomi/network/NetworkHelper.kt',
    ),
    'Android 宿主': File(
      'android/app/src/main/kotlin/eu/kanade/tachiyomi/network/NetworkHelper.kt',
    ),
  };

  for (final MapEntry<String, File> host in hosts.entries) {
    test('${host.key}的 callTimeout 早于 Dart 的放手时刻', () {
      final Duration hostBudget = callTimeoutOf(host.value);
      expect(
        kMihonBridgeRequestTimeout,
        greaterThan(hostBudget),
        reason:
            '${host.key}给每次请求 ${hostBudget.inSeconds}s，Dart 只等 '
            '${kMihonBridgeRequestTimeout.inSeconds}s 就放手；宿主还没来得及报出真因',
      );
    });
  }

  test('两端宿主的 callTimeout 一致', () {
    final Duration desktop = callTimeoutOf(hosts['桌面 sidecar']!);
    final Duration android = callTimeoutOf(hosts['Android 宿主']!);
    expect(android, desktop, reason: '两端预算分家后，同一个源在桌面与手机上的失败时刻会对不上');
  });
}
