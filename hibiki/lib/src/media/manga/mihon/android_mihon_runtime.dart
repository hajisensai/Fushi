import 'package:flutter/services.dart';

import 'package:hibiki/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

class AndroidMihonRuntime extends MihonBridgeRuntime
    implements CancellableMihonRuntime {
  AndroidMihonRuntime({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('app.hibiki.reader/mihon');

  final MethodChannel _channel;
  int _imageRequestSequence = 0;

  @override
  Future<MihonCapabilities> getCapabilities() async =>
      MihonCapabilities.fromJson(
        await _invokeMap('capabilities', const <String, Object?>{}),
      );

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async =>
      MihonExtensionInspection.fromJson(
        await _invokeMap(
          'inspectExtension',
          <String, Object?>{'apkPath': apkPath},
        ),
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

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments,
  ) =>
      _invoke<Object?>(
        'invoke',
        <String, Object?>{
          'packageName': extension.packageName,
          'apkPath': extension.apkPath,
          'method': method,
          ...arguments,
        },
      );

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
    final Uint8List? bytes = await _invoke<Uint8List>(
      'fetchSourceImage',
      <String, Object?>{
        'packageName': extension.packageName,
        'apkPath': extension.apkPath,
        'sourceId': source.id,
        'url': url,
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
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) =>
      _invokeVoid(
        'clearSourceData',
        <String, Object?>{
          'packageName': extension.packageName,
          'sourceId': source.id,
        },
      );

  @override
  Future<void> invalidateExtension(String packageName) => _invokeVoid(
        'invalidateExtension',
        <String, Object?>{'packageName': packageName},
      );

  @override
  Future<void> dispose() => _invokeVoid('dispose', const <String, Object?>{});

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

  Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw MihonRuntimeException(
        error.code,
        error.message ?? 'Android Mihon runtime failed',
        cause: error,
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
