import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_music_library.dart';

typedef _ApiC = Int32 Function();
typedef _ApiDart = int Function();
typedef _Bin1C =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin1Dart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _InstallC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _InstallDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _OpenC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _OpenDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _StepC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _StepDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CheckUrlC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Int32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CheckUrlDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin2C =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin2Dart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

class _PluginBindings {
  _PluginBindings(this._lib) {
    try {
      apiVersion = _lib.library.lookupFunction<_ApiC, _ApiDart>(
        'ffm_plugin_api_version',
      );
      inspect = _lib.library.lookupFunction<_Bin1C, _Bin1Dart>(
        'ffm_plugin_inspect',
      );
      verify = _lib.library.lookupFunction<_Bin1C, _Bin1Dart>(
        'ffm_plugin_verify',
      );
      install = _lib.library.lookupFunction<_InstallC, _InstallDart>(
        'ffm_plugin_install',
      );
      open = _lib.library.lookupFunction<_OpenC, _OpenDart>('ffm_plugin_open');
      step = _lib.library.lookupFunction<_StepC, _StepDart>('ffm_plugin_step');
      checkUrls = _lib.library.lookupFunction<_CheckUrlC, _CheckUrlDart>(
        'ffm_plugin_check_urls',
      );
      close = _lib.library.lookupFunction<_CloseC, _CloseDart>(
        'ffm_plugin_close',
      );
      vault = _lib.library.lookupFunction<_Bin2C, _Bin2Dart>(
        'ffm_plugin_vault',
      );
    } on ArgumentError catch (e) {
      throw _lib.missingSymbols('plugin', e);
    }
  }

  final FushiMusic _lib;
  late final _ApiDart apiVersion;
  late final _Bin1Dart inspect;
  late final _Bin1Dart verify;
  late final _InstallDart install;
  late final _OpenDart open;
  late final _StepDart step;
  late final _CheckUrlDart checkUrls;
  late final _CloseDart close;
  late final _Bin2Dart vault;

  static _PluginBindings? _instance;
  static _PluginBindings get instance =>
      _instance ??= _PluginBindings(FushiMusic.instance);

  /// 跑一次调用：分配输出指针，取回 JSON 并释放 Rust 缓冲区。
  Map<String, Object?> callJson(
    String what,
    int Function(Arena arena, Pointer<Pointer<Uint8>> out, Pointer<Size> len)
    body,
  ) => using((Arena arena) {
    final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
    final Pointer<Size> len = arena<Size>();
    out.value = nullptr;
    len.value = 0;
    final int rc = body(arena, out, len);
    final Uint8List bytes = out.value == nullptr
        ? Uint8List(0)
        : Uint8List.fromList(out.value.asTypedListOutOfLine(len.value));
    if (out.value != nullptr) _lib.freeBytes(out.value, len.value);
    if (rc != FfmStatus.ok) {
      throw StateError('$what failed with status $rc');
    }
    return (jsonDecode(utf8.decode(bytes)) as Map<Object?, Object?>)
        .cast<String, Object?>();
  });
}

Pointer<Uint8> _copyIn(Uint8List bytes, Allocator alloc) {
  final Pointer<Uint8> p = alloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 插件运行时的同步 FFI 入口（`native/fushi_music/src/plugin`）。返回 JSON 对象；校验 / 加载
/// 失败时对象里带 `error`（不是异常）。会执行 JS 或读写插件目录的调用用 [MusicPluginNativeAsync]。
abstract final class MusicPluginNative {
  /// 本平台的原生库是否带插件运行时（iOS 伞形库不带：缺符号即不支持）。
  static bool get isSupported {
    try {
      _PluginBindings.instance;
      return true;
    } on FushiMusicUnavailableError {
      return false;
    }
  }

  static int get apiVersion => _PluginBindings.instance.apiVersion();

  static Map<String, Object?> inspect(Uint8List zip) {
    final _PluginBindings b = _PluginBindings.instance;
    return b.callJson(
      'ffm_plugin_inspect',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
          b.inspect(_copyIn(zip, a), zip.length, out, len),
    );
  }

  static Map<String, Object?> verify(String dir) {
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List d = utf8.encode(dir);
    return b.callJson(
      'ffm_plugin_verify',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
          b.verify(_copyIn(d, a), d.length, out, len),
    );
  }

  static Map<String, Object?> install(
    Uint8List zip,
    String root,
    String digest,
  ) {
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List r = utf8.encode(root);
    final Uint8List d = utf8.encode(digest);
    return b.callJson(
      'ffm_plugin_install',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) => b.install(
        _copyIn(zip, a),
        zip.length,
        _copyIn(r, a),
        r.length,
        _copyIn(d, a),
        d.length,
        out,
        len,
      ),
    );
  }

  /// 建实例：成功时 `handle` 非 0（原生指针地址，可跨 isolate 传递）。
  static ({int handle, Map<String, Object?> summary}) open(
    String dir,
    int budgetMs,
  ) {
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List d = utf8.encode(dir);
    int handle = 0;
    final Map<String, Object?> summary = b.callJson('ffm_plugin_open', (
      Arena a,
      Pointer<Pointer<Uint8>> out,
      Pointer<Size> len,
    ) {
      final Pointer<Pointer<Void>> h = a<Pointer<Void>>();
      h.value = nullptr;
      final int rc = b.open(_copyIn(d, a), d.length, budgetMs, h, out, len);
      handle = h.value.address;
      return rc;
    });
    return (handle: handle, summary: summary);
  }

  static Map<String, Object?> step(int handle, String opsJson) {
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List o = utf8.encode(opsJson);
    return b.callJson(
      'ffm_plugin_step',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) => b.step(
        Pointer<Void>.fromAddress(handle),
        _copyIn(o, a),
        o.length,
        out,
        len,
      ),
    );
  }

  /// 按插件网络授权批量核对地址（一次 FFI）：同序返回规范化 URL，不在授权内的为 null。
  static List<String?> checkUrls(
    int handle,
    List<String> urls, {
    required bool media,
  }) {
    if (urls.isEmpty) return const <String?>[];
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List u = utf8.encode(jsonEncode(urls));
    final Map<String, Object?> r = b.callJson(
      'ffm_plugin_check_urls',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) => b.checkUrls(
        Pointer<Void>.fromAddress(handle),
        _copyIn(u, a),
        u.length,
        media ? 1 : 0,
        out,
        len,
      ),
    );
    return <String?>[
      for (final Object? x in r['urls']! as List<Object?>) x as String?,
    ];
  }

  /// 凭据保险库（`native/fushi_music/src/plugin/vault.rs`）：[op] =
  /// `{"op":"get"|"set"|"remove"|"clear","plugin":id,"key"?,"value"?}`。
  static Map<String, Object?> vault(String root, Map<String, Object?> op) {
    final _PluginBindings b = _PluginBindings.instance;
    final Uint8List r = utf8.encode(root);
    final Uint8List o = utf8.encode(jsonEncode(op));
    return b.callJson(
      'ffm_plugin_vault',
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
          b.vault(_copyIn(r, a), r.length, _copyIn(o, a), o.length, out, len),
    );
  }

  static void close(int handle) {
    if (handle == 0) return;
    _PluginBindings.instance.close(Pointer<Void>.fromAddress(handle));
  }
}

/// 后台 isolate 版本：哈希校验、解压与执行 JS 都可能超过 1 ms，不放 UI isolate。
/// 句柄是原生指针地址，同一句柄的调用由 [MusicPluginInstance] 串行化。
abstract final class MusicPluginNativeAsync {
  static Future<Map<String, Object?>> inspect(Uint8List zip) =>
      Isolate.run(() => MusicPluginNative.inspect(zip));

  static Future<Map<String, Object?>> verify(String dir) =>
      Isolate.run(() => MusicPluginNative.verify(dir));

  static Future<Map<String, Object?>> install(
    Uint8List zip,
    String root,
    String digest,
  ) => Isolate.run(() => MusicPluginNative.install(zip, root, digest));

  static Future<({int handle, Map<String, Object?> summary})> open(
    String dir,
    int budgetMs,
  ) => Isolate.run(() => MusicPluginNative.open(dir, budgetMs));

  static Future<Map<String, Object?>> step(int handle, String opsJson) =>
      Isolate.run(() => MusicPluginNative.step(handle, opsJson));

  /// 保险库读写（Windows 上每次经 DPAPI 解封数据密钥，放后台 isolate）。
  static Future<Map<String, Object?>> vault(
    String root,
    Map<String, Object?> op,
  ) => Isolate.run(() => MusicPluginNative.vault(root, op));
}
