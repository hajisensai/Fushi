import 'dart:typed_data';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

abstract class MihonBridgeRuntime
    implements MihonRuntime, AnimeMihonRuntime, MihonWebUrlRuntime {
  /// [source] 是本次调用**打给哪个源**。桌面端据它挑出该源站的登录 cookie 注入
  /// 请求头（BUG-2425）——sidecar 侧的 domain 也是从 `source.getBaseUrl()` 推的，
  /// 两边必须看同一个 baseUrl，否则注进去的 cookie 域对不上、等于没注。
  ///
  /// 可空是因为 [listSources] 发生在「还不知道有哪些源」之前；那一步不出网到源站，
  /// 没有 cookie 可言。Android 忽略这个参数（系统 `CookieManager` 是唯一所有者）。
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  });

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
      source: source,
    );
    return _filtersFromResponse(response);
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
            source: source,
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
            source: source,
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
            source: source,
          ),
        ),
      );

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final MihonManga parsed = MihonManga.fromJson(
      _asMap(
        await invokeBridge(
          extension,
          'getDetailsManga',
          <String, Object?>{
            ..._sourceArguments(source, preferences),
            'mangaData': manga.toJson(),
          },
          source: source,
        ),
      ),
    );
    return manga.mergedWithDetails(parsed);
  }

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
      source: source,
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
      source: source,
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
          source: source,
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
        source: source,
      ),
    );
  }

  // ── Aniyomi（视频）调用面 ───────────────────────────────────────────
  // 与上面的漫画方法一一对应，只换 wire 方法名与模型；sidecar 与 Android 宿主
  // 两边的分发表都按这些名字实现（`MihonInvoker.invokeMethod` /
  // `MihonChannelHandler.invoke`）。

  @override
  Future<List<MihonSource>> listAnimeSources(
    MihonExtensionRef extension, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'sourcesAnime',
      <String, Object?>{},
    );
    return _asMapList(response)
        .map((Map<String, Object?> json) =>
            MihonSource.fromJson(extension.packageName, json))
        .toList(growable: false);
  }

  @override
  Future<List<MihonFilter>> getAnimeFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'filtersAnime',
      _sourceArguments(source, preferences),
      source: source,
    );
    return _filtersFromResponse(response);
  }

  @override
  Future<MihonAnimePage> getPopularAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonAnimePage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getPopularAnime',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
            },
            source: source,
          ),
        ),
      );

  @override
  Future<MihonAnimePage> getLatestAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonAnimePage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getLatestAnime',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
            },
            source: source,
          ),
        ),
      );

  @override
  Future<MihonAnimePage> searchAnime(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      MihonAnimePage.fromJson(
        _asMap(
          await invokeBridge(
            extension,
            'getSearchAnime',
            <String, Object?>{
              ..._sourceArguments(source, preferences),
              'page': page,
              'search': query,
              'filterList': filters
                  .map((MihonFilter filter) => filter.toBridgeJson())
                  .toList(growable: false),
            },
            source: source,
          ),
        ),
      );

  @override
  Future<MihonAnime> getAnimeDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final MihonAnime parsed = MihonAnime.fromJson(
      _asMap(
        await invokeBridge(
          extension,
          'getDetailsAnime',
          <String, Object?>{
            ..._sourceArguments(source, preferences),
            'animeData': anime.toJson(),
          },
          source: source,
        ),
      ),
    );
    return anime.mergedWithDetails(parsed);
  }

  @override
  Future<List<MihonEpisode>> getEpisodes(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getEpisodeList',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'animeData': anime.toJson(),
      },
      source: source,
    );
    return _asMapList(response)
        .map(MihonEpisode.fromJson)
        .toList(growable: false);
  }

  @override
  Future<List<MihonVideo>> getVideos(
    MihonExtensionRef extension,
    MihonSource source,
    MihonEpisode episode, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getVideoList',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'episodeData': episode.toJson(),
      },
      source: source,
    );
    return _asMapList(response)
        .map(MihonVideo.fromJson)
        .where((MihonVideo video) => video.resolvedUrl.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<String> getMangaWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getMangaUrl',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'mangaData': manga.toJson(),
      },
      source: source,
    );
    return response?.toString() ?? '';
  }

  @override
  Future<String> getAnimeWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Object? response = await invokeBridge(
      extension,
      'getAnimeUrl',
      <String, Object?>{
        ..._sourceArguments(source, preferences),
        'animeData': anime.toJson(),
      },
      source: source,
    );
    return response?.toString() ?? '';
  }

  @override
  Future<List<MihonPreference>> getAnimePreferences(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> persisted = const <MihonPreference>[],
  }) async =>
      _preferencesFromResponse(
        await invokeBridge(
          extension,
          'preferencesAnime',
          _sourceArguments(source, persisted),
          source: source,
        ),
      );

  @override
  Future<List<MihonPreference>> setAnimePreference(
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
        'setPreferenceAnime',
        <String, Object?>{
          'preferences': mihonBridgePreferences(
            source,
            merged,
            changedPreferenceKey: preference.key,
          ),
        },
        source: source,
      ),
    );
  }

  /// 两种响应信封（裸数组 / `{filterList: [...]}`）都收，漫画与视频共用。
  static List<MihonFilter> _filtersFromResponse(Object? response) {
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
