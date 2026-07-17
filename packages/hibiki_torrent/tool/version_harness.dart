// 端到端工具链证明 harness（阶段1a）。
//
// 用法：dart run tool/version_harness.dart <hibiki_torrent_ffi.dll 绝对路径>
// 缺省参数时按平台默认名从系统搜索路径加载。
//
// 经 DynamicLibrary 加载 native/hibiki_torrent 构建出的库 → 调
// ht_libtorrent_version() 打印 libtorrent 真实版本号 → 建/销毁一个空壳
// session。全部成功即证明 libtorrent 构建 → C ABI → Dart FFI 链路打通。

import 'dart:ffi';
import 'dart:io';

import 'package:hibiki_torrent/hibiki_torrent.dart';

void main(List<String> args) {
  final String? path = args.isNotEmpty ? args.first : null;
  final EmbeddedTorrentEngine engine =
      EmbeddedTorrentEngine.open(libraryPath: path);

  final String version = engine.libtorrentVersion();
  stdout.writeln('libtorrent version: $version');
  if (version.isEmpty) {
    stderr.writeln('FAIL: empty version string');
    exit(1);
  }

  final Pointer<Void> session = engine.createSession();
  stdout.writeln('session handle: $session');
  engine.destroySession(session);
  stdout.writeln('session destroyed OK');

  stdout.writeln('PASS: libtorrent -> C ABI -> Dart FFI walking skeleton');
}
