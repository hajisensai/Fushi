import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/sync/extension_font_api.dart';
import 'package:path/path.dart' as p;

/// 浏览器扩展字体端点的 app 侧实现：字体真源就是 app 的字体目录
/// （`ReaderSettings` 的 `font_catalog` 偏好 + `<appDirectory>/custom_fonts`），
/// 下载走与「自定义字体」页同一份 [FontDownloadService] + 同一套读/写函数。
///
/// 扩展下载的字体也会挂到 [FontTarget.videoSubtitle]：扩展要它就是为了网页字幕，
/// 与 app 内视频字幕同一用途；不挂到正文，免得改了小说字体。
class BrowserExtensionFontCatalog implements ExtensionFontApi {
  BrowserExtensionFontCatalog(this._appModel);

  final AppModel _appModel;

  /// 同名并发下载去重：第二个请求直接等第一个的结果，不下两份。
  final Map<String, Future<ExtensionFontDownloadOutcome>> _inFlight =
      <String, Future<ExtensionFontDownloadOutcome>>{};

  /// 「读目录 → 追加行 → 持久化」串行链：两个不同名字并发下载时，谁的 commit 都不能
  /// 建立在对方 commit 之前的快照上，否则后写的把先写的行抹掉。
  Future<void> _commitTail = Future<void>.value();

  FontDownloadService? _service;

  FontDownloadService get _fontService => _service ??= FontDownloadService(
        fontsDir: customFontsDirectory(_appModel.appDirectory),
      );

  Future<ReaderSettings> _settings() async {
    ReaderSettings? settings = ReaderFushiSource.readerSettings;
    if (settings == null) {
      settings = ReaderSettings(_appModel.database);
      await settings.refreshFromDb();
      ReaderFushiSource.readerSettings = settings;
    }
    return settings;
  }

  Future<List<CustomFontCatalogRow>> _rows(ReaderSettings settings) async {
    final FontCatalogState state = await readCustomFontCatalogState(
      database: _appModel.database,
      settings: settings,
    );
    return customFontCatalogRowsFromState(state);
  }

  static ExtensionFontEntry? _entryOf(CustomFontCatalogRow row) {
    final String? id = row.id;
    final String? path = row.path;
    if (id == null || id.isEmpty || path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    final String ext = p.extension(path).toLowerCase();
    return ExtensionFontEntry(
      id: id,
      name: row.name,
      family: ReaderCustomFontCss.normalizedFontFamilyName(row.name),
      ext: ext.startsWith('.') ? ext.substring(1) : ext,
      path: path,
    );
  }

  static List<ExtensionFontEntry> _entriesOf(List<CustomFontCatalogRow> rows) =>
      <ExtensionFontEntry>[
        for (final CustomFontCatalogRow row in rows)
          if (_entryOf(row) case final ExtensionFontEntry entry) entry,
      ];

  static bool _sameName(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();

  @override
  Future<List<ExtensionFontEntry>> listFonts() async =>
      _entriesOf(await _rows(await _settings()));

  @override
  Future<List<ExtensionRecommendedFont>> listRecommended() async {
    final List<CustomFontCatalogRow> rows = await _rows(await _settings());
    return <ExtensionRecommendedFont>[
      for (final RecommendedFont font in recommendedFontsCatalog)
        ExtensionRecommendedFont(
          name: font.name,
          nameJa: font.nameJa,
          description: font.description,
          license: font.license,
          installed: rows.any(
            (CustomFontCatalogRow row) => _sameName(row.name, font.name),
          ),
        ),
    ];
  }

  @override
  Future<ExtensionFontEntry?> findFont(String id) async {
    if (id.isEmpty) return null;
    final List<CustomFontCatalogRow> rows = await _rows(await _settings());
    for (final CustomFontCatalogRow row in rows) {
      if (row.id == id) return _entryOf(row);
    }
    return null;
  }

  @override
  Future<ExtensionFontDownloadOutcome> downloadRecommended(String name) {
    final Future<ExtensionFontDownloadOutcome>? running = _inFlight[name];
    if (running != null) return running;
    final Future<ExtensionFontDownloadOutcome> job =
        _downloadRecommended(name).whenComplete(() => _inFlight.remove(name));
    _inFlight[name] = job;
    return job;
  }

  Future<ExtensionFontDownloadOutcome> _downloadRecommended(String name) async {
    RecommendedFont? font;
    for (final RecommendedFont candidate in recommendedFontsCatalog) {
      if (_sameName(candidate.name, name)) {
        font = candidate;
        break;
      }
    }
    if (font == null) return const ExtensionFontDownloadOutcome.unknownFont();
    final RecommendedFont wanted = font;

    final ReaderSettings settings = await _settings();
    final List<ExtensionFontEntry> installed = _entriesOf(
      await _rows(settings),
    ).where((ExtensionFontEntry e) => _sameName(e.name, wanted.name)).toList();
    if (installed.isNotEmpty) return ExtensionFontDownloadOutcome.ok(installed);

    final FontDownloadResult result = await _fontService.download(
      wanted.urls,
      overrideName: wanted.name,
    );
    if (result.cancelled) {
      return const ExtensionFontDownloadOutcome.failed('cancelled');
    }
    if (result.error != null) {
      return ExtensionFontDownloadOutcome.failed(result.error);
    }
    if (result.files.isEmpty) {
      return const ExtensionFontDownloadOutcome.failed('no fonts in archive');
    }

    final Future<List<ExtensionFontEntry>> commit = _commitTail.then(
      (_) => _commit(settings, result.files),
    );
    _commitTail = commit.then((_) {}, onError: (Object _) {});
    return ExtensionFontDownloadOutcome.ok(await commit);
  }

  /// 读目录 → 追加行 → 持久化，返回新增行对应的条目（带分配好的 id）。
  Future<List<ExtensionFontEntry>> _commit(
    ReaderSettings settings,
    List<ImportedFontFile> files,
  ) async {
    final List<CustomFontCatalogRow> rows = await _rows(settings);
    final List<CustomFontCatalogRow> added = <CustomFontCatalogRow>[
      for (final ImportedFontFile file in files)
        CustomFontCatalogRow(
          id: null,
          name: file.name,
          path: file.path,
          targetEnabled: customFontInitialTargets(FontTarget.videoSubtitle),
        ),
    ];
    rows.addAll(added);
    final FontCatalogState state = customFontCatalogStateFromRows(rows);
    await persistCustomFontState(
      appModel: _appModel,
      settings: settings,
      state: state,
      legacy: customFontLegacyListsFromRows(rows),
    );
    // id 由 customFontCatalogStateFromRows 分配：按 path 回查拿到带 id 的条目。
    final Set<String> addedPaths = <String>{
      for (final ImportedFontFile file in files) file.path,
    };
    return _entriesOf(customFontCatalogRowsFromState(state))
        .where((ExtensionFontEntry e) => addedPaths.contains(e.path))
        .toList();
  }
}
