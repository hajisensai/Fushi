import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/hibiki_torrent_bindings.dart';

/// 内置 libtorrent 引擎的 Dart 侧薄封装（阶段1a walking skeleton）。
///
/// 现在只暴露版本查询与 session 生命周期空壳，用于证明工具链打通；阶段1b
/// 会在此之上实现 `TorrentBackend`（磁力/元数据/文件优先级/边下边播）。
class EmbeddedTorrentEngine {
  EmbeddedTorrentEngine._(this._bindings);

  final HibikiTorrentBindings _bindings;

  /// 加载本地原生库并构造引擎。[libraryPath] 显式指定 DLL/so/dylib 绝对路径
  /// （standalone 构建产物或 harness 传入）；缺省按平台默认名从系统搜索路径找。
  factory EmbeddedTorrentEngine.open({String? libraryPath}) {
    final DynamicLibrary lib = libraryPath != null
        ? DynamicLibrary.open(libraryPath)
        : _openByPlatformDefault();
    return EmbeddedTorrentEngine._(HibikiTorrentBindings(lib));
  }

  static DynamicLibrary _openByPlatformDefault() {
    if (Platform.isWindows) return DynamicLibrary.open('hibiki_torrent_ffi.dll');
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libhibiki_torrent_ffi.dylib');
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return DynamicLibrary.open('libhibiki_torrent_ffi.so');
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    throw UnsupportedError(
        'hibiki_torrent: unsupported platform ${Platform.operatingSystem}');
  }

  /// libtorrent 运行时版本串（如 "2.0.11.0"）。
  String libtorrentVersion() {
    final Pointer<Char> p = _bindings.ht_libtorrent_version();
    if (p == nullptr) return '';
    return p.cast<Utf8>().toDartString();
  }

  /// 创建一个空壳 session 句柄；失败返回 [nullptr]。
  Pointer<Void> createSession() => _bindings.ht_session_create();

  /// 销毁 session 句柄（[nullptr] 为 no-op）。
  void destroySession(Pointer<Void> session) =>
      _bindings.ht_session_destroy(session);
}
