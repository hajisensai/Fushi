/// 互联 host 侧：把本机已启用的 Mihon / Aidoku 扩展源借给已配对对端
/// （[HostMangaSourceHost] 的 app 实现，引擎只认接口）。
///
/// 详情 / 页表 / 页图 / 封面全部**复用书架侧既有适配器**（[MihonLibraryAdapter] /
/// [AidokuLibraryAdapter]）——那两条已经把「必须经扩展自己的 OkHttp」「Aidoku 带
/// Referer + cookie jar」「Cloudflare 分型」做对了，这里不再写第二份取图逻辑。只有
/// 热门 / 最新 / 搜索是浏览页的能力，适配器契约里没有，直接打运行时。
///
/// 源 id 的口径与发现页一致：`mihon:<包名>:<源 id>` / `aidoku:<包 id>`。
library;

import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_image_page.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart'
    show MangaGlobalSearchRunner;
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

/// 图片字节的类型嗅探（对端拿到字节后交给解码器，类型只是 HTTP 卫生）。
String _sniffImageType(Uint8List bytes) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
    if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'image/png';
    if (bytes[0] == 0x47 && bytes[1] == 0x49) return 'image/gif';
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes.length >= 12) {
      if (bytes[8] == 0x57 && bytes[9] == 0x45) return 'image/webp';
    }
  }
  return 'application/octet-stream';
}

class InterconnectMangaSourceHostImpl implements HostMangaSourceHost {
  InterconnectMangaSourceHostImpl({
    MihonManager? Function()? mihonManager,
    AidokuRuntime? Function()? aidokuRuntime,
    Future<List<AidokuInstalledPackage>> Function()? aidokuPackages,
  }) : _mihonManager = mihonManager ?? _defaultMihonManager,
       _aidokuRuntime = aidokuRuntime ?? _defaultAidokuRuntime,
       _aidokuPackages = aidokuPackages ?? _defaultAidokuPackages;

  /// 取 Mihon 管理器；本平台没有 Mihon 宿主时返回 null（不碰会抛的懒建）。
  final MihonManager? Function() _mihonManager;
  final AidokuRuntime? Function() _aidokuRuntime;
  final Future<List<AidokuInstalledPackage>> Function() _aidokuPackages;

  static MihonManager? _defaultMihonManager() => null;

  static AidokuRuntime? _defaultAidokuRuntime() =>
      AidokuRuntimeFactory.isSupported ? AidokuRuntimeFactory.create() : null;

  static Future<List<AidokuInstalledPackage>> _defaultAidokuPackages() async =>
      AidokuRuntimeFactory.isSupported
      ? (await AidokuPackageStore.open()).listInstalled()
      : const <AidokuInstalledPackage>[];

  static const String _mihonPrefix = 'mihon:';
  static const String _aidokuPrefix = 'aidoku:';

  static String mihonSourceId(MangaOnlineSourceRow row) =>
      '$_mihonPrefix${row.extensionPackage}:${row.sourceId}';

  static String aidokuSourceId(AidokuInstalledPackage package) =>
      '$_aidokuPrefix${package.id}';

  AidokuRuntime? _resolvedAidoku;
  AidokuRuntime? get _aidoku => _resolvedAidoku ??= _aidokuRuntime();

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'version': 1,
    'runtimes': <String>[
      if (MihonRuntimeFactory.isSupported) 'mihon',
      if (AidokuRuntimeFactory.isSupported) 'aidoku',
    ],
  };

  @override
  Future<List<RemoteMangaSourceInfo>> listSources() async {
    final List<RemoteMangaSourceInfo> out = <RemoteMangaSourceInfo>[];
    final MihonManager? manager = _mihonManager();
    if (manager != null) {
      await manager.initialise();
      for (final MangaOnlineSourceRow row in enabledMangaOnlineSources(
        manager,
      )) {
        out.add(
          RemoteMangaSourceInfo(
            id: mihonSourceId(row),
            runtime: 'mihon',
            name: row.name,
            language: row.language,
            baseUrl: row.baseUrl,
            supportsFilters: true,
          ),
        );
      }
    }
    for (final AidokuInstalledPackage package in await _aidokuPackages()) {
      if (!package.enabled) continue;
      out.add(
        RemoteMangaSourceInfo(
          id: aidokuSourceId(package),
          runtime: 'aidoku',
          name: package.name,
          language: package.languages.isEmpty ? '' : package.languages.first,
        ),
      );
    }
    return out;
  }

  @override
  Future<List<Map<String, Object?>>> filters(String sourceId) async {
    final _Resolved resolved = await _resolve(sourceId);
    final MihonSourceContext? context = resolved.mihon;
    if (context == null) return const <Map<String, Object?>>[];
    final List<MihonFilter> filters = await _guard(
      () => resolved.manager!.runtime.getFilters(
        context.extension,
        context.source,
        preferences: context.preferences,
      ),
    );
    return <Map<String, Object?>>[
      for (final MihonFilter f in filters) mihonFilterToWire(f),
    ];
  }

  @override
  Future<RemoteMangaBrowsePage> browse(
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  }) async {
    final _Resolved resolved = await _resolve(sourceId);
    return _guard(() async {
      final MihonSourceContext? context = resolved.mihon;
      if (context != null) {
        final MihonRuntime runtime = resolved.manager!.runtime;
        final MihonMangaPage result = switch (mode) {
          RemoteMangaBrowseMode.popular => await runtime.getPopular(
            context.extension,
            context.source,
            page: page,
            preferences: context.preferences,
          ),
          RemoteMangaBrowseMode.latest => await runtime.getLatest(
            context.extension,
            context.source,
            page: page,
            preferences: context.preferences,
          ),
          RemoteMangaBrowseMode.search => await runtime.search(
            context.extension,
            context.source,
            page: page,
            query: query,
            filters: <MihonFilter>[
              for (final Map<String, Object?> f in filters)
                mihonFilterFromWire(f),
            ],
            preferences: context.preferences,
          ),
        };
        return RemoteMangaBrowsePage(
          items: <Map<String, Object?>>[
            for (final MihonManga manga in result.items)
              MihonLibraryAdapter.seriesOf(manga).toJson(),
          ],
          hasNextPage: result.hasNextPage,
        );
      }
      final AidokuInstalledPackage package = resolved.aidoku!;
      final AidokuRuntime runtime = _aidoku!;
      final Map<String, Object?> result;
      if (mode == RemoteMangaBrowseMode.search) {
        result = await runtime.search(
          package.packagePath,
          query: query,
          page: page,
        );
      } else {
        final List<AidokuListing> listings = (await runtime.inspect(
          package.packagePath,
        )).listings;
        if (listings.isEmpty) {
          result = await runtime.search(package.packagePath, page: page);
        } else {
          // Aidoku 没有「热门 / 最新」的固定概念，只有源自报的 listing 序列：
          // 第一条当热门、第二条（有的话）当最新，与 Aidoku 浏览页的默认一致。
          final AidokuListing listing =
              mode == RemoteMangaBrowseMode.latest && listings.length > 1
              ? listings[1]
              : listings.first;
          result = await runtime.browse(
            package.packagePath,
            listing,
            page: page,
          );
        }
      }
      return RemoteMangaBrowsePage(
        items: <Map<String, Object?>>[
          for (final Map<String, Object?> entry in jsonMapList(
            result['entries'],
          ))
            AidokuLibraryAdapter.seriesOf(
              entry,
              fallbackKey: entry['key']?.toString() ?? '',
            ).toJson(),
        ],
        hasNextPage: result['has_next_page'] == true,
      );
    });
  }

  @override
  Future<RemoteMangaSeriesDetail> details(
    String sourceId,
    Map<String, Object?> series,
  ) async {
    final _Resolved resolved = await _resolve(sourceId);
    final OnlineMangaLibraryEntry entry = _entryFor(resolved, series);
    final OnlineMangaRefreshResult result = await _guard(
      () => resolved.adapter.refresh(entry),
    );
    return RemoteMangaSeriesDetail(
      series: result.series.toJson(),
      chapters: <Map<String, Object?>>[
        for (final OnlineMangaChapter c in result.chapters) c.toJson(),
      ],
    );
  }

  @override
  Future<List<Map<String, Object?>>> pages(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  ) async {
    final _Resolved resolved = await _resolve(sourceId);
    final OnlineMangaChapter? parsed = OnlineMangaChapter.fromJson(chapter);
    if (parsed == null) throw ArgumentError('chapter.key required');
    final AidokuInstalledPackage? package = resolved.aidoku;
    if (package != null) {
      // Aidoku 的页 JSON 原样下发（`AidokuImagePage` 只保留解析结果，没有 raw），
      // 对端回灌时本机再 `AidokuImagePage.fromJson` 一次。
      final List<Object?> raw = await _guard(
        () => resolved.aidokuRuntime!.getPages(
          package.packagePath,
          _seriesRaw(series),
          parsed.raw,
        ),
      );
      final List<Map<String, Object?>> pages = jsonMapList(raw);
      if (pages.isEmpty) {
        throw const HostMangaSourceException(
          HostMangaSourceException.codeRuntime,
          'EMPTY_CHAPTER',
        );
      }
      return <Map<String, Object?>>[
        for (int i = 0; i < pages.length; i++)
          <String, Object?>{...pages[i], 'index': i},
      ];
    }
    final List<OnlineMangaPageRef> refs = await _guard(
      () => resolved.adapter.resolveChapterPages(
        entry: _entryFor(resolved, series),
        chapter: parsed,
      ),
    );
    return <Map<String, Object?>>[
      for (final OnlineMangaPageRef ref in refs) _pageToWire(ref),
    ];
  }

  static Map<String, Object?> _seriesRaw(Map<String, Object?> series) =>
      OnlineMangaSeries.fromJson(series)?.raw ?? series;

  @override
  Future<RemoteMangaImage> pageImage(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  ) async {
    final _Resolved resolved = await _resolve(sourceId);
    final OnlineMangaPageRef ref = _pageFromWire(resolved, series, page);
    final Uint8List bytes = await _guard(
      () => resolved.adapter.fetchChapterPage(ref),
    );
    return RemoteMangaImage(bytes: bytes, contentType: _sniffImageType(bytes));
  }

  @override
  Future<RemoteMangaImage> coverImage(String sourceId, String url) async {
    final _Resolved resolved = await _resolve(sourceId);
    final List<int> bytes = await _guard(
      () => resolved.adapter.fetchCover(
        _entryFor(resolved, <String, Object?>{'key': url, 'title': ''}),
        url,
      ),
    );
    final Uint8List typed = Uint8List.fromList(bytes);
    return RemoteMangaImage(bytes: typed, contentType: _sniffImageType(typed));
  }

  // ── 源解析 ─────────────────────────────────────────────────────

  Future<_Resolved> _resolve(String sourceId) async {
    if (sourceId.startsWith(_mihonPrefix)) {
      final MihonManager? manager = _mihonManager();
      if (manager != null) {
        await manager.initialise();
        for (final MangaOnlineSourceRow row in enabledMangaOnlineSources(
          manager,
        )) {
          if (mihonSourceId(row) != sourceId) continue;
          return _Resolved.mihon(
            manager,
            await manager.contextForSource(row),
            row,
          );
        }
      }
    } else if (sourceId.startsWith(_aidokuPrefix) && _aidoku != null) {
      for (final AidokuInstalledPackage package in await _aidokuPackages()) {
        if (!package.enabled || aidokuSourceId(package) != sourceId) continue;
        return _Resolved.aidoku(_aidoku!, package);
      }
    }
    throw HostMangaSourceException(
      HostMangaSourceException.codeSourceNotFound,
      'Source $sourceId is not enabled on this host',
    );
  }

  OnlineMangaLibraryEntry _entryFor(
    _Resolved resolved,
    Map<String, Object?> series,
  ) => OnlineMangaLibraryEntry(
    runtime: resolved.mihon != null
        ? OnlineMangaRuntimeKind.mihon
        : OnlineMangaRuntimeKind.aidoku,
    extensionPackage: resolved.extensionPackage,
    sourceId: resolved.sourceId,
    series:
        OnlineMangaSeries.fromJson(series) ??
        OnlineMangaSeries(key: '', title: '', raw: series),
    chapters: const <OnlineMangaChapter>[],
  );

  /// 适配器抛的分类错误 → host 结构化错误（对端按 code 分型）。
  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on HostMangaSourceException {
      rethrow;
    } on OnlineMangaUnavailable catch (error) {
      throw HostMangaSourceException(
        _codeFor(error.cause ?? error),
        error.message,
      );
    } on Object catch (error) {
      throw HostMangaSourceException(_codeFor(error), '$error');
    }
  }

  static String _codeFor(Object error) =>
      MangaGlobalSearchRunner.isCloudflareError(error)
      ? HostMangaSourceException.codeCloudflare
      : HostMangaSourceException.codeRuntime;

  // ── wire 形状 ──────────────────────────────────────────────────

  Map<String, Object?> _pageToWire(OnlineMangaPageRef ref) => switch (ref) {
    MihonMangaPageRef(:final page) => <String, Object?>{
      'index': page.index,
      'url': page.url,
      if (page.imageUrl != null) 'imageUrl': page.imageUrl,
    },
    AidokuMangaPageRef() ||
    InterconnectMangaPageRef() ||
    InterconnectSourceMangaPageRef() => throw StateError(
      'unexpected page ref ${ref.runtimeType}',
    ),
  };

  OnlineMangaPageRef _pageFromWire(
    _Resolved resolved,
    Map<String, Object?> series,
    Map<String, Object?> page,
  ) {
    final MihonSourceContext? context = resolved.mihon;
    if (context != null) {
      return MihonMangaPageRef(
        index: (page['index'] as num?)?.toInt() ?? 0,
        context: context,
        page: MihonPage.fromJson(page),
      );
    }
    final OnlineMangaSeries? parsed = OnlineMangaSeries.fromJson(series);
    final String? url = parsed?.raw['url']?.toString();
    return AidokuMangaPageRef(
      index: (page['index'] as num?)?.toInt() ?? 0,
      page: AidokuImagePage.fromJson(page),
      referer: url != null && Uri.tryParse(url)?.isScheme('https') == true
          ? url
          : null,
    );
  }
}

/// [MihonFilter] → wire：bridge JSON（`toBridgeJson` 的形状）再补 `values` /
/// `stateBoolean` / `children`——bridge JSON 只够运行时吃，对端的过滤器弹窗还要
/// 把选项与子项画出来。host 下发过滤器定义与 client 回传选中状态两边共用。
Map<String, Object?> mihonFilterToWire(MihonFilter filter) => <String, Object?>{
  ...filter.toBridgeJson(),
  'values': filter.values,
  if (filter.state is bool) 'stateBoolean': filter.state,
  if (filter.children.isNotEmpty)
    'children': <Map<String, Object?>>[
      for (final MihonFilter c in filter.children) mihonFilterToWire(c),
    ],
};

/// wire → [MihonFilter]（[mihonFilterToWire] 的逆）。对端浏览页的过滤器弹窗与
/// host 还原搜索请求两边共用。
MihonFilter mihonFilterFromWire(Map<String, Object?> json) {
  final String type = json['type']?.toString() ?? '';
  MihonFilterKind kind = MihonFilterKind.unsupported;
  for (final MihonFilterKind k in MihonFilterKind.values) {
    if (k.name == type) kind = k;
  }
  final Object? state = json.containsKey('stateBoolean')
      ? json['stateBoolean']
      : json.containsKey('stateInt')
      ? json['stateInt']
      : json.containsKey('stateString')
      ? json['stateString']
      : json['stateSort'] is Map
      ? jsonMap(json['stateSort'])
      : null;
  return MihonFilter(
    name: json['name']?.toString() ?? '',
    kind: kind,
    state: state,
    values: <String>[
      for (final Object? v in (json['values'] as List<Object?>? ?? const []))
        v.toString(),
    ],
    children: <MihonFilter>[
      for (final Map<String, Object?> c in jsonMapList(json['children']))
        mihonFilterFromWire(c),
    ],
  );
}

class _Resolved {
  const _Resolved.mihon(this.manager, MihonSourceContext this.mihon, this.row)
    : aidoku = null,
      aidokuRuntime = null;

  const _Resolved.aidoku(AidokuRuntime this.aidokuRuntime, this.aidoku)
    : manager = null,
      mihon = null,
      row = null;

  final MihonManager? manager;
  final MihonSourceContext? mihon;
  final MangaOnlineSourceRow? row;
  final AidokuRuntime? aidokuRuntime;
  final AidokuInstalledPackage? aidoku;

  String get extensionPackage => mihon?.extension.packageName ?? aidoku!.id;

  String get sourceId => mihon?.source.id ?? aidoku!.id;

  OnlineMangaRuntimeAdapter get adapter => mihon != null
      ? MihonLibraryAdapter(manager!, presetContext: mihon)
      : AidokuLibraryAdapter(runtime: aidokuRuntime, presetPackage: aidoku);
}
