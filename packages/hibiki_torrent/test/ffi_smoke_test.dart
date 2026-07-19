// hibiki_torrent FFI 冒烟测试（阶段1a walking skeleton）。
//
// 经 DynamicLibrary 加载 native/hibiki_torrent 构建出的库，调
// ht_libtorrent_version() 断言拿到非空版本串，并验证 session 生命周期。
//
// 库路径解析：环境变量 HIBIKI_TORRENT_LIB > 平台默认名（系统搜索路径）。
// 库不存在时整组 skip —— CI/未构建环境不因缺 DLL 而红，符合仓库既有 FFI
// 打包守卫「有则测、无则跳」的姿态。

import 'dart:ffi';
import 'dart:io';

import 'package:hibiki_torrent/hibiki_torrent.dart';
import 'package:test/test.dart';

String? _resolveLibPath() {
  final String? env = Platform.environment['HIBIKI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null; // fall back to platform-default open()
}

void main() {
  final String? explicit = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    try {
      return EmbeddedTorrentEngine.open(libraryPath: explicit);
    } on ArgumentError {
      return null; // DynamicLibrary.open 找不到库
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();

  test('ht_libtorrent_version returns a non-empty semver-ish string', () {
    final String version = engine!.libtorrentVersion();
    expect(version, isNotEmpty);
    // libtorrent 版本形如 "2.0.11.0"：至少含一个点。
    expect(version, contains('.'));
  }, skip: engine == null ? 'hibiki_torrent_ffi native lib not built' : null);

  test('session create/destroy round-trips', () {
    final Pointer<Void> session = engine!.createSession();
    expect(session, isNot(equals(nullptr)));
    engine.destroySession(session);
  }, skip: engine == null ? 'hibiki_torrent_ffi native lib not built' : null);
}
