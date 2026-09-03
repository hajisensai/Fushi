import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// 设备冒烟：证明随包的内置 libtorrent 引擎在 Android 上**真能加载并干活**——
/// `libfushi_torrent_ffi.so` 经 jniLibs 随包（vcpkg android triplet 静态链
/// libtorrent/boost/openssl），按名 `DynamicLibrary.open` 命中 nativeLibraryDir。
/// 三层递进：加载 → 版本串（C ABI 往返）→ 建 session + make_torrent（真实
/// libtorrent 逻辑跑通，非仅符号存在）。
///
/// 在真机/模拟器跑（构建机需先跑 native/fushi_torrent/build_android_so 产出
/// 对应 ABI 的 .so，缺 .so 时本用例会明确失败——那正是「包不完整」的信号）：
///   flutter test integration_test/embedded_torrent_engine_smoke_test.dart -d <id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('libfushi_torrent_ffi.so 可加载且 libtorrent 版本可读', (tester) async {
    final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.open();
    final String version = engine.libtorrentVersion();
    expect(version, isNotEmpty, reason: 'ht_libtorrent_version 必须返回版本串');
    expect(version, startsWith('2.'),
        reason: '选型钉 libtorrent 2.x，实际: $version');
  });

  testWidgets('session 建得起来且 make_torrent 真跑通', (tester) async {
    final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.open();
    final Directory tmp = await getTemporaryDirectory();
    final Directory dir = await Directory(
      '${tmp.path}/embedded_torrent_smoke',
    ).create(recursive: true);
    final File content = File('${dir.path}/payload.bin');
    await content.writeAsBytes(List<int>.generate(4096, (int i) => i % 251));
    final String outTorrent = '${dir.path}/payload.torrent';
    try {
      final FtAddResult made = engine.makeTorrent(
        contentPath: content.path,
        outTorrentPath: outTorrent,
      );
      expect(made.ok, isTrue, reason: 'make_torrent 失败: ${made.error}');
      expect(File(outTorrent).existsSync(), isTrue);

      // 回环监听 session：能建、能拿到系统分配端口、能销毁，即证明
      // boost.asio / openssl 静态链路在设备上完好。
      final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
        engine,
        listenInterfaces: '127.0.0.1:0',
      );
      expect(session, isNotNull, reason: 'session 创建失败');
      expect(session!.listenPort, greaterThan(0));
      session.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
