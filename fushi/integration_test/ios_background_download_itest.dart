// BUG-3887：iOS 词典包后台传输的真原生链路（系统后台 URLSession）。
//
// 在 iOS 模拟器 / 真机上跑，配合宿主侧的限速 HTTP 服务器（脚本见 PR 描述）：
//   flutter test integration_test/ios_background_download_itest.dart -d <udid> \
//     --dart-define=BG_DL_BASE=http://127.0.0.1:8765 \
//     --dart-define=BG_DL_TRANSPORT=native   # 或 dio（对照组）
//
// 「切到后台仍在下」的证据在宿主侧：本测试在大文件下载过程中打印 `BG_DL_GO_BACKGROUND`，
// 宿主脚本据此把别的 app 拉到前台、过一段时间再切回来，然后按服务器逐秒发送字节日志
// 判断后台窗口里传输有没有停。本测试只断言下载最终完整落盘、各失败形态的归因正确。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/ios_background_download.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const String _base = String.fromEnvironment('BG_DL_BASE');
const String _transportKind = String.fromEnvironment(
  'BG_DL_TRANSPORT',
  defaultValue: 'native',
);
const int _bigBytes = int.fromEnvironment(
  'BG_DL_BIG_BYTES',
  defaultValue: 60 * 1024 * 1024,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DictionaryDownloadTransport transport;

  setUpAll(() async {
    expect(_base, isNotEmpty, reason: '--dart-define=BG_DL_BASE 必填');
    final Directory support = await getApplicationSupportDirectory();
    tempDir = Directory('${support.path}/bg_dl_itest')
      ..createSync(recursive: true);
    transport = _transportKind == 'dio'
        ? dioDictionaryDownloadTransport
        : IosBackgroundDownloadTransport(
            proxy: () => IosBackgroundDownloadProxy.system,
          ).download;
    debugPrint('BG_DL_TRANSPORT=$_transportKind');
  });

  tearDownAll(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('保活通道在 iOS 上有原生侧（update / stop 不抛 MissingPlugin）', (
    WidgetTester tester,
  ) async {
    final DownloadKeepAlive keepAlive = createDownloadKeepAlive();
    expect(keepAlive, isA<ChannelDownloadKeepAlive>());
    await FushiKeepAliveProbe.roundTrip();
  });

  testWidgets('小文件：完整落盘，进度单调', (WidgetTester tester) async {
    final String dest = '${tempDir.path}/small.bin';
    final List<int> seen = <int>[];
    await transport(
      url: '$_base/small.bin',
      destPath: dest,
      onReceiveProgress: (int received, int total) => seen.add(received),
    );
    expect(File(dest).lengthSync(), 256 * 1024);
    for (int i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  testWidgets('404 → badResponse 带状态码（不换镜像）', (WidgetTester tester) async {
    Object? error;
    try {
      await transport(
        url: '$_base/missing.bin',
        destPath: '${tempDir.path}/missing.bin',
        onReceiveProgress: (_, _) {},
      );
    } catch (e) {
      error = e;
    }
    expect(error, isA<DioError>());
    expect((error! as DioError).response?.statusCode, 404);
    expect(isDictionaryTransportFailure(error), isFalse);
  });

  testWidgets('取消：以 cancel 结束（「取消不算失败」）', (WidgetTester tester) async {
    final CancelToken token = CancelToken();
    Object? error;
    final Future<void> running = transport(
      url: '$_base/big.bin',
      destPath: '${tempDir.path}/cancelled.bin',
      onReceiveProgress: (int received, int total) {
        if (received > 1024 * 1024 && !token.isCancelled) token.cancel('test');
      },
      cancelToken: token,
    ).catchError((Object e) => error = e);
    await running.timeout(const Duration(minutes: 2));
    expect(
      classifyDictionaryDownloadFailure(error!),
      DictionaryDownloadFailureKind.cancelled,
    );
  });

  testWidgets('大文件：下载中途切到后台，最终完整落盘', (WidgetTester tester) async {
    final String dest = '${tempDir.path}/big.bin';
    bool announced = false;
    final Stopwatch watch = Stopwatch()..start();
    await transport(
      url: '$_base/big.bin',
      destPath: dest,
      onReceiveProgress: (int received, int total) {
        if (!announced && received > 8 * 1024 * 1024) {
          announced = true;
          // 宿主脚本盯这一行。
          debugPrint('BG_DL_GO_BACKGROUND');
        }
      },
    ).timeout(const Duration(minutes: 10));
    debugPrint('BG_DL_BIG_DONE ms=${watch.elapsedMilliseconds}');
    expect(File(dest).lengthSync(), _bigBytes);
  }, timeout: const Timeout(Duration(minutes: 12)));
}

/// 直接对保活通道做一次 update / stop 往返：缺原生侧时 [ChannelDownloadKeepAlive]
/// 会吞掉 MissingPluginException，测不出来，所以这里绕过门面直接调通道。
abstract final class FushiKeepAliveProbe {
  static Future<void> roundTrip() async {
    await FushiChannels.downloadKeepAlive.invokeMethod<void>(
      'update',
      <String, Object?>{'title': 't', 'text': 'x', 'progress': -1},
    );
    await FushiChannels.downloadKeepAlive.invokeMethod<void>('stop');
  }
}
