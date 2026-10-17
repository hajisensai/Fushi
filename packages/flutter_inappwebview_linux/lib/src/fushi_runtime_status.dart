import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Fushi：WPE WebKit 后端在本机是否真的加载成功。
///
/// runner 只链接薄注册层（`linux/fushi_wpe_loader.cc`），真正的实现库
/// `libflutter_inappwebview_linux_wpe.so` 在注册时 dlopen：系统没装 WPE WebKit、
/// 或 bundle 是在没有 WPE 开发包的机器上编的（实现库根本没产出），都只会让
/// WebView 不可用而不会让整个 app 起不来。这里把那次加载的结果交给 Dart，好让
/// 每个 WebView 位置显示「缺什么、装什么」，而不是一个永远空白的平台视图。
class LinuxWebViewRuntimeStatus {
  const LinuxWebViewRuntimeStatus({required this.available, this.error = ''});

  /// 实现库已加载、各 channel 已注册。
  final bool available;

  /// 加载失败时 `dlerror()` 的原文（通常是缺哪个 .so），或薄注册层探测到
  /// 「不允许非特权 user namespace」时的说明（WPE 的 bubblewrap 沙箱要它）。
  final String error;

  /// 失败原因是 user namespace 受限而不是没装 WPE（见 fushi_wpe_loader.cc）。
  bool get isUserNamespaceRestriction =>
      !available && error.contains('user namespaces');
}

class LinuxWebViewRuntime {
  LinuxWebViewRuntime._();

  static const MethodChannel _channel = MethodChannel(
    'fushi/flutter_inappwebview_linux/runtime',
  );

  static LinuxWebViewRuntimeStatus? _cached;
  static Future<LinuxWebViewRuntimeStatus>? _pending;

  /// 已查询过时的同步结果；未查询时为 null。
  static LinuxWebViewRuntimeStatus? get cached => _cached;

  /// 查询一次并缓存（进程内结果不会变：实现库只在引擎注册插件时加载一次）。
  static Future<LinuxWebViewRuntimeStatus> status() {
    final LinuxWebViewRuntimeStatus? hit = _cached;
    if (hit != null) return Future<LinuxWebViewRuntimeStatus>.value(hit);
    return _pending ??= _query();
  }

  static Future<LinuxWebViewRuntimeStatus> _query() async {
    LinuxWebViewRuntimeStatus result;
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMapMethod<Object?, Object?>('status');
      result = LinuxWebViewRuntimeStatus(
        available: raw?['available'] == true,
        error: (raw?['error'] as String?) ?? '',
      );
    } on MissingPluginException catch (e) {
      // 薄注册层本身没注册：bundle 与插件不配套。
      result = LinuxWebViewRuntimeStatus(available: false, error: '$e');
    }
    _cached = result;
    return result;
  }

  /// 测试用：清掉进程内缓存。
  @visibleForTesting
  static void debugReset() {
    _cached = null;
    _pending = null;
  }

  /// headless 用：后端不可用时抛出带原因的异常，而不是让
  /// `createHeadlessWebView` 的 MissingPluginException 从深处冒出来。
  static Future<void> ensureAvailable() async {
    final LinuxWebViewRuntimeStatus s = await status();
    if (!s.available) throw LinuxWebViewUnavailableException(s.error);
  }
}

class LinuxWebViewUnavailableException implements Exception {
  const LinuxWebViewUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => LinuxWebViewRuntimeStatus(
            available: false,
            error: reason,
          ).isUserNamespaceRestriction
      ? 'LinuxWebViewUnavailableException: $reason'
      : 'LinuxWebViewUnavailableException: WPE WebKit backend is not available '
          '($reason). Install WPE WebKit 2.x from your distribution '
          '(e.g. Debian/Ubuntu: libwpewebkit-2.0-1 + libwpebackend-fdo-1.0-1; '
          'Fedora: wpewebkit; Arch: wpewebkit).';
}

/// 平台视图位置的占位：后端不可用时显示原因与安装方法。
class LinuxWebViewUnavailablePlaceholder extends StatelessWidget {
  const LinuxWebViewUnavailablePlaceholder({super.key, required this.status});

  final LinuxWebViewRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          status.isUserNamespaceRestriction
              ? 'Web view unavailable: ${status.error}'
              : 'Web view unavailable: WPE WebKit is not installed.\n'
                    'Install WPE WebKit 2.x (Debian/Ubuntu: libwpewebkit-2.0-1 '
                    'libwpebackend-fdo-1.0-1 · Fedora/Arch: wpewebkit) and '
                    'restart.\n${status.error}',
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
        ),
      ),
    );
  }
}
