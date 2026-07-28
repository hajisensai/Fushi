import 'dart:typed_data';

import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';

abstract class MihonBridgeRuntime implements MihonRuntime {
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments,
  );

  @override
  Future<List<MihonSource>> listSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'sourcesManga',
      <String, Object?>{},
    );
    return _asMapList(response)
        .map((Map<String, Object?> json) =>
            MihonSource.fromJson(extension.packageName, json))
        .toList(growable: false);
  }

  @override
  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'filtersManga',
      _sourceArguments(source, preferences),
    );
    final List<Object?> filters = response is List<Object?>
        ? response
        : ((response as Map<Object?, Object?>?)?['filterList']
                as List<Object?>? ??
            const <Object?>[]);
    return filters
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> value) =>
            _filterFromJson(value.cast<String, Object?>()))
        .toList(growable: false);
  }

  @override
  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonMangaPage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getPopularManga',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
            },
          ),
        ),
      );

  @override
  Future<MihonMangaPage> getLatest(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonMangaPage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getLatestManga',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
            },
          ),
        ),
      );

  @override
  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonMangaPage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getSearchManga',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
              'search': query,
              'filterList': filters
                  .map((MihonFilter filter) => filter.toBridgeJson())
                  .toList(growable: false),
            },
          ),
        ),
      );

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonManga.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getDetailsManga',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'mangaData': manga.toJson(),
            },
          ),
        ),
      );

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getChapterList',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'mangaData': manga.toJson(),
      },
    );
    return _asMapList(response)
        .map(MihonChapter.fromJson)
        .toList(growable: false);
  }

  @override
  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getPageList',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'chapterData': chapter.toJson(),
      },
    );
    return _asMapList(response).map(MihonPage.fromJson).toList(growable: false);
  }

  @override
  Future<List<MihonPreference>> getPreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  }) async =>
      _preferencesFromResponse(
        await invokeBridge(
          extension,
          'preferencesManga',
          _sourceArguments(source, persisted),
        ),
      );

  @override
  Future<List<MihonPreference>> setPreference(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPreference preference, {
    required List<MihonPreference> persisted,
  }) async {
    final List<MihonPreference> merged = <MihonPreference>[
      for (final MihonPreference item in persisted)
        if (item.key != preference.key) item,
      preference,
    ];
    return _preferencesFromResponse(
      await invokeBridge(
        extension,
        'setPreferenceManga',
        <String, Object?>{
          'preferences': mihonBridgePreferences(
            source,
            merged,
            changedPreferenceKey: preference.key,
          ),
        },
      ),
    );
  }

  Map<String, Object?> _sourceArguments(
    MihonSource source,
    List<MihonPreference> preferences,
  ) =>
      <String, Object?>{
        'preferences': mihonBridgePreferences(source, preferences),
      };

  List<MihonPreference> _preferencesFromResponse(Object? response) =>
      _asMapList(response)
          .map(MihonPreference.fromBridgeJson)
          .where((MihonPreference preference) => preference.key.isNotEmpty)
          .toList(growable: false);

  static Map<String, Object?> _asMap(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw MihonRuntimeException(
        'INVALID_RESPONSE',
        'Mihon bridge returned ${value.runtimeType}, expected an object',
      );
    }
    return value.cast<String, Object?>();
  }

  static List<Map<String, Object?>> _asMapList(Object? value) {
    if (value is! List<Object?>) {
      throw MihonRuntimeException(
        'INVALID_RESPONSE',
        'Mihon bridge returned ${value.runtimeType}, expected a list',
      );
    }
    return value
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> item) => item.cast<String, Object?>())
        .toList(growable: false);
  }

  static MihonFilter _filterFromJson(Map<String, Object?> json) {
    final Object? rawState = json['state'];
    final Object? state = rawState is Map<Object?, Object?>
        ? <String, Object?>{
            'index': (rawState['index'] as num?)?.toInt() ?? 0,
            'ascending': rawState['ascending'] != false,
          }
        : rawState;
    final List<String> values =
        (json['values'] as List<Object?>? ?? const <Object?>[])
            .map((Object? value) => value.toString())
            .toList(growable: false);
    final List<MihonFilter> children = (state is List<Object?>
            ? state
            : json['children'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> child) =>
            _filterFromJson(child.cast<String, Object?>()))
        .toList(growable: false);
    final String type =
        (json['type'] ?? json['runtimeType'] ?? '').toString().toLowerCase();
    final MihonFilterKind kind = switch (type) {
      final String value when value.contains('header') =>
        MihonFilterKind.header,
      final String value when value.contains('separator') =>
        MihonFilterKind.separator,
      final String value when value.contains('select') =>
        MihonFilterKind.select,
      final String value when value.contains('text') => MihonFilterKind.text,
      final String value when value.contains('checkbox') =>
        MihonFilterKind.checkBox,
      final String value when value.contains('tristate') =>
        MihonFilterKind.triState,
      final String value when value.contains('group') => MihonFilterKind.group,
      final String value when value.contains('sort') => MihonFilterKind.sort,
      _
          when state is Map<Object?, Object?> &&
              state.containsKey('index') &&
              state.containsKey('ascending') =>
        MihonFilterKind.sort,
      _ when children.isNotEmpty => MihonFilterKind.group,
      _ when values.isNotEmpty => MihonFilterKind.select,
      _ when state is bool => MihonFilterKind.checkBox,
      _ when state is String => MihonFilterKind.text,
      _ => MihonFilterKind.unsupported,
    };
    return MihonFilter(
      name: json['name']?.toString() ?? '',
      kind: kind,
      state: state,
      values: values,
      children: children,
    );
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  });
}
