import 'dart:typed_data';

import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';

abstract interface class MihonRuntime {
  Future<MihonCapabilities> getCapabilities();

  Future<MihonExtensionInspection> inspectExtension(String apkPath);

  /// Android 把 APK 原子复制到 app 私有 `.ext` 目录；桌面实现返回原路径，
  /// 由上层的跨平台安装仓库负责原子替换。
  Future<String> installPrivateExtension(String apkPath);

  Future<void> uninstallPrivateExtension(String packageName);

  Future<List<MihonSource>> listSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> getLatest(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  /// Fetches a cover or other source-owned image with the extension's
  /// OkHttp client. Callers must not use a plain HTTP client because that
  /// would drop extension interceptors, cookies, and per-request headers.
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> getPreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  });

  Future<List<MihonPreference>> setPreference(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPreference preference, {
    required List<MihonPreference> persisted,
  });

  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  );

  Future<void> invalidateExtension(String packageName);

  Future<void> dispose();
}

/// Optional runtime capability used by the online reader to abort image
/// requests when a chapter is closed. Implementations must cancel the
/// underlying HTTP/OkHttp operation, not only discard its eventual result.
abstract interface class CancellableMihonRuntime {
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  Future<void> cancelImageRequests(Iterable<String> requestIds);
}

Map<String, Object?> mihonBridgeContext(
  MihonSource source, {
  String? changedPreferenceKey,
}) =>
    <String, Object?>{
      'key': '__mangatan_bridge_context__',
      'sourceId': source.id,
      if (changedPreferenceKey != null)
        'changedPreferenceKey': changedPreferenceKey,
    };

List<Map<String, Object?>> mihonBridgePreferences(
  MihonSource source,
  List<MihonPreference> preferences, {
  String? changedPreferenceKey,
}) =>
    <Map<String, Object?>>[
      mihonBridgeContext(
        source,
        changedPreferenceKey: changedPreferenceKey,
      ),
      ...preferences.map(
        (MihonPreference preference) => preference.toBridgeJson(),
      ),
    ];
