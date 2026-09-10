import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_proxy_policy_server.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';

class AndroidMihonRuntime extends MihonBridgeRuntime
    implements CancellableMihonRuntime, ChallengeMihonRuntime {
  AndroidMihonRuntime({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('app.fushi.reader/mihon');

  final MethodChannel _channel;
  int _imageRequestSequence = 0;
  MihonProxyPolicyServer? _proxyPolicy;
  Future<void>? _proxyConfiguration;

  Future<void> _configureProxyPolicy() async {
    final Random random = Random.secure();
    final String token = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final MihonProxyPolicyServer server = await MihonProxyPolicyServer.start(
      token,
    );
    try {
      final Uri relay = await ensureAppChallengeProxyEndpoint();
      await _channel
          .invokeMethod<void>('configureProxyPolicy', <String, Object?>{
        'port': server.port,
        'token': token,
        'challengeProxyEndpoint': relay.toString(),
      });
      _proxyPolicy = server;
    } on Object {
      await server.close();
      _proxyConfiguration = null;
      rethrow;
    }
  }

  @override
  Future<void> solveCloudflare(Uri uri, {String? userAgent}) =>
      _invokeVoid('solveCloudflare', <String, Object?>{
        'url': uri.toString(),
        if (userAgent != null) 'userAgent': userAgent,
      });

  @override
  Future<MihonCapabilities> getCapabilities() async =>
      MihonCapabilities.fromJson(
        await _invokeMap('capabilities', const <String, Object?>{}),
      );

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async =>
      MihonExtensionInspection.fromJson(
        await _invokeMap('inspectExtension', <String, Object?>{
          'apkPath': apkPath,
        }),
      );

  @override
  Future<String> installPrivateExtension(String apkPath) async {
    final Map<String, Object?> response = await _invokeMap(
      'installPrivateExtension',
      <String, Object?>{'apkPath': apkPath},
    );
    return response['apkPath']! as String;
  }

  @override
  Future<void> uninstallPrivateExtension(String packageName) => _invokeVoid(
        'uninstallPrivateExtension',
        <String, Object?>{'packageName': packageName},
      );

  /// Android 刻意忽略 [source]：这边 cookie 的唯一所有者是系统 `CookieManager`，
  /// 扩展的 okhttp 经 `AndroidCookieJar` 直接读它，宿主不需要（也不该）再注一遍。
  /// 桌面端才需要按源注入，见 [MihonBridgeRuntime.invokeBridge] 的说明。
  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) =>
      _invoke<Object?>('invoke', <String, Object?>{
        'packageName': extension.packageName,
        'apkPath': extension.apkPath,
        'method': method,
        ...arguments,
      });

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) =>
      fetchImageRequest(
        extension,
        source,
        page,
        requestId: 'direct-${_imageRequestSequence++}',
        preferences: preferences,
      );

  @override
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Uint8List? bytes = await _invoke<Uint8List>(
      'fetchImage',
      <String, Object?>{
        'requestId': requestId,
        'packageName': extension.packageName,
        'apkPath': extension.apkPath,
        'sourceId': source.id,
        'page': <String, Object?>{
          'index': page.index,
          'url': page.url,
          'imageUrl': page.imageUrl,
        },
        'preferences': mihonBridgePreferences(source, preferences),
      },
    );
    if (bytes == null || bytes.isEmpty) {
      throw const MihonRuntimeException(
        'EMPTY_IMAGE',
        'Mihon source returned an empty image',
      );
    }
    return bytes;
  }

  @override
  Future<void> cancelImageRequests(Iterable<String> requestIds) => _invokeVoid(
        'cancelImageRequests',
        <String, Object?>{'requestIds': requestIds.toList(growable: false)},
      );

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Uint8List? bytes =
        await _invoke<Uint8List>('fetchSourceImage', <String, Object?>{
      'packageName': extension.packageName,
      'apkPath': extension.apkPath,
      'sourceId': source.id,
      'url': url,
      'preferences': mihonBridgePreferences(source, preferences),
    });
    if (bytes == null || bytes.isEmpty) {
      throw const MihonRuntimeException(
        'EMPTY_IMAGE',
        'Mihon source returned an empty image',
      );
    }
    return bytes;
  }

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) =>
      _invokeVoid('clearSourceData', <String, Object?>{
        'packageName': extension.packageName,
        'sourceId': source.id,
      });

  @override
  Future<void> invalidateExtension(String packageName) => _invokeVoid(
        'invalidateExtension',
        <String, Object?>{'packageName': packageName},
      );

  @override
  Future<void> invalidateExtensions(Iterable<String> packageNames) async {
    // Android 侧失效是一次 method channel 调用，没有桌面端的进程重启代价。
    for (final String packageName in packageNames) {
      await invalidateExtension(packageName);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _proxyConfiguration;
      await _invokeVoid('dispose', const <String, Object?>{});
    } finally {
      await _proxyPolicy?.close();
      _proxyPolicy = null;
      _proxyConfiguration = null;
    }
  }

  Future<Map<String, Object?>> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final Object? value = await _invoke<Object?>(method, arguments);
    if (value is! Map<Object?, Object?>) {
      throw MihonRuntimeException(
        'INVALID_RESPONSE',
        '$method returned ${value.runtimeType}, expected an object',
      );
    }
    return value.cast<String, Object?>();
  }

  Future<void> _invokeVoid(
    String method,
    Map<String, Object?> arguments,
  ) async {
    await _invoke<Object?>(method, arguments);
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      if (const <String>{
        'invoke',
        'fetchImage',
        'fetchSourceImage',
        'solveCloudflare',
      }.contains(method)) {
        await (_proxyConfiguration ??= _configureProxyPolicy());
      }
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      if (error.code == 'CLOUDFLARE_CHALLENGE_REQUIRED' &&
          error.details is Map) {
        final Map<Object?, Object?> details =
            error.details as Map<Object?, Object?>;
        final Uri? url = Uri.tryParse(details['url']?.toString() ?? '');
        if (url != null &&
            const <String>{'http', 'https'}.contains(url.scheme) &&
            url.host.isNotEmpty) {
          throw MihonCloudflareChallengeException(
            url,
            userAgent: details['userAgent']?.toString(),
            cause: error,
          );
        }
      }
      throw MihonRuntimeException(
        error.code,
        error.message ?? 'Android Mihon runtime failed',
        cause: error,
        details: error.details?.toString(),
      );
    } on MissingPluginException catch (error) {
      throw MihonRuntimeException(
        'UNAVAILABLE',
        'Android Mihon runtime is not registered',
        cause: error,
      );
    }
  }
}
