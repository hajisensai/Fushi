import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:path/path.dart' as p;

/// 把字体目录状态写穿并刷新消费端（生产 = [persistCustomFontState]）。
typedef CustomFontStatePersister =
    Future<void> Function(
      ReaderSettings settings,
      FontCatalogState state,
      Map<String, List<Map<String, dynamic>>> legacy,
    );

/// 字体下载 / 导入失败（网络、压缩包里没有字体…）：不是参数错，也不是状态冲突。
class CustomFontLibraryException implements Exception {
  const CustomFontLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载被调用方经 `CancelToken` 取消（不算失败）。
class CustomFontDownloadCancelled implements Exception {
  const CustomFontDownloadCancelled();

  @override
  String toString() => '下载已取消';
}

/// 删除一条字体的结果：文件字体在没有别的行引用时连文件一起删。
class CustomFontRemoval {
  const CustomFontRemoval({
    required this.row,
    required this.fileDeleted,
    this.fileError,
  });

  final CustomFontCatalogRow row;
  final bool fileDeleted;

  /// 目录已更新、但删文件失败时的原因（不吞：交给调用方展示）。
  final String? fileError;
}

/// 字体库的无界面操作面：与「字体库」页（[CustomFontsPage]）同一份目录状态
/// （`font_catalog` / `font_targets` 偏好 + `<appDirectory>/custom_fonts`）、
/// 同一个 [FontDownloadService]、同一组读写函数。控制通道（`fushi_cli config
/// items appearance.font_catalog.cli.fonts …`）经它导入 / 下载 / 添加系统字体 /
/// 改用途 / 排序 / 删除。
///
/// 每次变更都是「读目录 → 改 → 写穿」整段串行（静态链），两个并发请求不会
/// 互相覆盖对方的 commit。
class CustomFontLibrary {
  CustomFontLibrary({
    required FushiDatabase database,
    required Directory fontsDir,
    required CustomFontStatePersister persist,
    FontDownloadService? service,
  }) : _database = database,
       _persist = persist,
       _service = service ?? FontDownloadService(fontsDir: fontsDir);

  /// 生产装配：AppModel 的数据库与字体目录，写穿后刷新全部消费端。
  factory CustomFontLibrary.forApp(AppModel appModel) => CustomFontLibrary(
    database: appModel.database,
    fontsDir: customFontsDirectory(appModel.appDirectory),
    persist:
        (
          ReaderSettings settings,
          FontCatalogState state,
          Map<String, List<Map<String, dynamic>>> legacy,
        ) => persistCustomFontState(
          appModel: appModel,
          settings: settings,
          state: state,
          legacy: legacy,
        ),
  );

  final FushiDatabase _database;
  final CustomFontStatePersister _persist;
  final FontDownloadService _service;

  static Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final Future<T> result = _tail.then((_) => body());
    // 链本身只负责排队；失败照样经 result 抛给调用方。
    _tail = result.then<void>((T _) {}, onError: (Object _) {});
    return result;
  }

  Future<ReaderSettings> _settings() async {
    ReaderSettings? settings = ReaderFushiSource.readerSettings;
    if (settings == null) {
      settings = ReaderSettings(_database);
      await settings.refreshFromDb();
      ReaderFushiSource.readerSettings = settings;
    }
    return settings;
  }

  Future<List<CustomFontCatalogRow>> _rows(ReaderSettings settings) async =>
      customFontCatalogRowsFromState(
        await readCustomFontCatalogState(
          database: _database,
          settings: settings,
        ),
      );

  /// 读 → [change] 原地改行 → 写穿；返回写穿后的行（新行已分配 id）。
  Future<List<CustomFontCatalogRow>> _mutate(
    FutureOr<void> Function(List<CustomFontCatalogRow> rows) change,
  ) => _serial(() async {
    final ReaderSettings settings = await _settings();
    final List<CustomFontCatalogRow> rows = await _rows(settings);
    await change(rows);
    final FontCatalogState state = customFontCatalogStateFromRows(rows);
    await _persist(settings, state, customFontLegacyListsFromRows(rows));
    return customFontCatalogRowsFromState(state);
  });

  /// 字体库全部行（目录顺序 = 各用途的字体链顺序）。
  Future<List<CustomFontCatalogRow>> list() async => _rows(await _settings());

  /// 导入本机字体文件或压缩包（与页面「导入文件」同一条落地路径）。
  Future<List<CustomFontCatalogRow>> importFile(
    String path, {
    required Set<FontTarget> targets,
    String? overrideName,
  }) async {
    _requirePlatformTargets(targets);
    if (!p.isAbsolute(path)) {
      throw ArgumentError('字体文件要给绝对路径：$path');
    }
    final File file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('文件不存在：$path');
    }
    final List<ImportedFontFile> files = await _service.importFile(
      file,
      fileName: p.basename(path),
      overrideName: overrideName,
    );
    return _append(files, targets);
  }

  /// 从 URL 下载字体（首条失败依次回退 [urls] 后面的镜像）。
  ///
  /// [cancelToken] / [onProgress] 直通 [FontDownloadService.download]（后台任务
  /// 用它报进度、取消）；[onCommit] 在下载完成、写字体目录之前调一次（任务据此
  /// 进入不可取消的提交阶段）。取消抛 [CustomFontDownloadCancelled]。
  Future<List<CustomFontCatalogRow>> download(
    List<String> urls, {
    required Set<FontTarget> targets,
    String? overrideName,
    CancelToken? cancelToken,
    void Function(double? progress)? onProgress,
    void Function()? onCommit,
  }) async {
    checkDownloadRequest(urls: urls, targets: targets);
    final FontDownloadResult result = await _service.download(
      urls,
      overrideName: overrideName,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    if (result.cancelled) {
      throw const CustomFontDownloadCancelled();
    }
    if (result.error != null) {
      throw CustomFontLibraryException('下载失败：${result.error}');
    }
    if (result.files.isEmpty) {
      throw const CustomFontLibraryException('下载的文件里没有字体');
    }
    onCommit?.call();
    return _append(result.files, targets);
  }

  /// 下载推荐字体表（[recommendedFontsCatalog]）里的一款（参数同 [download]）。
  Future<List<CustomFontCatalogRow>> downloadRecommended(
    String name, {
    required Set<FontTarget> targets,
    CancelToken? cancelToken,
    void Function(double? progress)? onProgress,
    void Function()? onCommit,
  }) async {
    final RecommendedFont? font = findRecommendedFont(name);
    if (font == null) {
      throw ArgumentError(
        '推荐字体表里没有「$name」；可选：'
        '${recommendedFontsCatalog.map((RecommendedFont f) => f.name).join(', ')}',
      );
    }
    final List<CustomFontCatalogRow> rows = await list();
    if (rows.any((CustomFontCatalogRow r) => _sameName(r.name, font.name))) {
      throw ArgumentError('「${font.name}」已在字体库里');
    }
    return download(
      font.urls,
      targets: targets,
      overrideName: font.name,
      cancelToken: cancelToken,
      onProgress: onProgress,
      onCommit: onCommit,
    );
  }

  /// 添加系统字体族（只登记族名，不复制文件），与页面「添加系统字体」同口径：
  /// 同名（显示名）已在库里的不重复加；平台给得出可信名单时族名必须在名单里。
  Future<List<CustomFontCatalogRow>> addSystemFamily(
    String family, {
    required Set<FontTarget> targets,
  }) async {
    _requirePlatformTargets(targets);
    final String name = family.trim();
    if (name.isEmpty) throw ArgumentError('系统字体族名为空');
    final SystemFontList system = await SystemFontCatalog.load();
    SystemFontFamily? match;
    for (final SystemFontFamily f in system.families) {
      if (_sameName(f.family, name)) {
        match = f;
        break;
      }
    }
    if (match == null && system.namesReliable) {
      throw ArgumentError('本机没有系统字体「$name」（用 system_fonts 动作列出）');
    }
    final String canonical = match?.family ?? name;
    final List<CustomFontCatalogRow> after = await _mutate((
      List<CustomFontCatalogRow> rows,
    ) {
      if (rows.any((CustomFontCatalogRow r) => _sameName(r.name, canonical))) {
        throw ArgumentError('「$canonical」已在字体库里');
      }
      rows.add(
        CustomFontCatalogRow(
          id: null,
          name: canonical,
          path: null,
          targetEnabled: <FontTarget, bool>{
            for (final FontTarget t in targets) t: true,
          },
        ),
      );
    });
    return <CustomFontCatalogRow>[
      for (final CustomFontCatalogRow row in after)
        if (row.path == null && row.name == canonical) row,
    ];
  }

  /// 把一行的用途集合整体换成 [targets]（空集 = 不用于任何用途，仍留在库里）。
  Future<CustomFontCatalogRow> setTargets(
    String id,
    Set<FontTarget> targets,
  ) async {
    _requirePlatformTargets(targets);
    final List<CustomFontCatalogRow> after = await _mutate((
      List<CustomFontCatalogRow> rows,
    ) {
      final CustomFontCatalogRow row = _requireRow(rows, id);
      final Map<FontTarget, String> unsupported = customFontUnsupportedTargets(
        row,
      );
      for (final FontTarget target in targets) {
        final String? reason = unsupported[target];
        if (reason != null) {
          throw ArgumentError('「${row.name}」不能用于 ${target.name}：$reason');
        }
      }
      row.targetEnabled.removeWhere(
        (FontTarget target, bool _) => !targets.contains(target),
      );
      for (final FontTarget target in targets) {
        row.targetEnabled[target] = true;
      }
    });
    return _requireRow(after, id);
  }

  /// 某用途的字体链整体设成 [ids]（按 id 或显示名）：在列表里的行加上该用途，
  /// 不在的去掉。链顺序跟随目录顺序（用 [move] 调整）。
  Future<List<CustomFontCatalogRow>> setTargetFonts(
    FontTarget target,
    List<String> ids,
  ) async {
    _requirePlatformTargets(<FontTarget>{target});
    return _mutate((List<CustomFontCatalogRow> rows) {
      final Set<CustomFontCatalogRow> wanted = <CustomFontCatalogRow>{
        for (final String key in ids) _requireRowByKey(rows, key),
      };
      for (final CustomFontCatalogRow row in wanted) {
        final String? reason = customFontUnsupportedTargets(row)[target];
        if (reason != null) {
          throw ArgumentError('「${row.name}」不能用于 ${target.name}：$reason');
        }
      }
      for (final CustomFontCatalogRow row in rows) {
        if (wanted.contains(row)) {
          row.targetEnabled[target] = true;
        } else {
          row.targetEnabled.remove(target);
        }
      }
    });
  }

  /// 把一行挪到目录第 [index] 位（0 起，最终下标）。目录顺序就是各用途的
  /// 字体链 / 缺字回退顺序。
  Future<CustomFontCatalogRow> move(String id, int index) async {
    final List<CustomFontCatalogRow> after = await _mutate((
      List<CustomFontCatalogRow> rows,
    ) {
      final CustomFontCatalogRow row = _requireRow(rows, id);
      if (index < 0 || index >= rows.length) {
        throw ArgumentError('position 超出范围 0..${rows.length - 1}：$index');
      }
      rows
        ..remove(row)
        ..insert(index, row);
    });
    return _requireRow(after, id);
  }

  /// 从字体库删除一行；文件字体在没有别的行引用同一文件时连文件一起删。
  Future<CustomFontRemoval> remove(String id) async {
    late CustomFontCatalogRow removed;
    final List<CustomFontCatalogRow> after = await _mutate((
      List<CustomFontCatalogRow> rows,
    ) {
      removed = _requireRow(rows, id);
      rows.remove(removed);
    });
    final String? path = removed.path;
    if (path == null) {
      return CustomFontRemoval(row: removed, fileDeleted: false);
    }
    try {
      final bool deleted = await deleteCustomFontFileIfUnreferenced(
        after,
        path,
      );
      return CustomFontRemoval(row: removed, fileDeleted: deleted);
    } on FileSystemException catch (e) {
      return CustomFontRemoval(
        row: removed,
        fileDeleted: false,
        fileError: '${e.message}: ${e.path ?? path}',
      );
    }
  }

  Future<List<CustomFontCatalogRow>> _append(
    List<ImportedFontFile> files,
    Set<FontTarget> targets,
  ) async {
    if (files.isEmpty) {
      throw const CustomFontLibraryException('没有可导入的字体');
    }
    final Set<String> paths = <String>{
      for (final ImportedFontFile f in files) f.path,
    };
    final List<CustomFontCatalogRow> after = await _mutate((
      List<CustomFontCatalogRow> rows,
    ) {
      for (final ImportedFontFile file in files) {
        final CustomFontCatalogRow row = CustomFontCatalogRow(
          id: null,
          name: file.name,
          path: file.path,
          targetEnabled: <FontTarget, bool>{},
        );
        // 格式上用不了的用途（WOFF 进 native 浮窗）不挂：与页面禁用对应芯片同一判据。
        final Map<FontTarget, String> unsupported =
            customFontUnsupportedTargets(row);
        for (final FontTarget target in targets) {
          if (!unsupported.containsKey(target)) {
            row.targetEnabled[target] = true;
          }
        }
        rows.add(row);
      }
    });
    return <CustomFontCatalogRow>[
      for (final CustomFontCatalogRow row in after)
        if (row.path != null && paths.contains(row.path)) row,
    ];
  }

  /// 下载请求的同步校验（[download] / [downloadRecommended] 进网络前做的同一组）：
  /// 用途在本平台有消费端、地址是 http(s) / 推荐字体表里有这款。不合法抛
  /// [ArgumentError]。后台任务起之前先调它，让参数错直接报给调用方。
  static void checkDownloadRequest({
    List<String>? urls,
    String? recommended,
    required Set<FontTarget> targets,
  }) {
    _requirePlatformTargets(targets);
    if (recommended != null) {
      if (findRecommendedFont(recommended) == null) {
        throw ArgumentError(
          '推荐字体表里没有「$recommended」；可选：'
          '${recommendedFontsCatalog.map((RecommendedFont f) => f.name).join(', ')}',
        );
      }
      return;
    }
    if (urls == null || urls.isEmpty) throw ArgumentError('没有下载地址');
    for (final String url in urls) {
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        throw ArgumentError('下载地址要是 http(s) URL：$url');
      }
    }
  }

  static void _requirePlatformTargets(Set<FontTarget> targets) {
    for (final FontTarget target in targets) {
      if (!isFontTargetAvailableOnPlatform(target)) {
        throw ArgumentError('用途 ${target.name} 在本平台没有消费端');
      }
    }
  }

  static CustomFontCatalogRow _requireRow(
    List<CustomFontCatalogRow> rows,
    String id,
  ) {
    for (final CustomFontCatalogRow row in rows) {
      if (row.id == id) return row;
    }
    throw ArgumentError('字体库里没有 id「$id」');
  }

  static CustomFontCatalogRow _requireRowByKey(
    List<CustomFontCatalogRow> rows,
    String key,
  ) {
    for (final CustomFontCatalogRow row in rows) {
      if (row.id == key) return row;
    }
    final List<CustomFontCatalogRow> byName = <CustomFontCatalogRow>[
      for (final CustomFontCatalogRow row in rows)
        if (_sameName(row.name, key)) row,
    ];
    if (byName.length == 1) return byName.single;
    if (byName.length > 1) {
      throw ArgumentError('名字「$key」对应多行，请改用 id');
    }
    throw ArgumentError('字体库里没有「$key」（id 或显示名）');
  }

  static bool _sameName(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();
}

/// 推荐字体表里按名字（不分大小写）找一款；没有返回 null。
RecommendedFont? findRecommendedFont(String name) {
  final String key = name.trim().toLowerCase();
  for (final RecommendedFont font in recommendedFontsCatalog) {
    if (font.name.toLowerCase() == key) return font;
  }
  return null;
}

/// 用途名（[FontTarget.name]）→ 枚举；逗号分隔，空串 = 空集。不认识的抛
/// [ArgumentError]。
Set<FontTarget> parseFontTargets(String raw) {
  final Set<FontTarget> out = <FontTarget>{};
  for (final String part in raw.split(',')) {
    final String name = part.trim();
    if (name.isEmpty) continue;
    final FontTarget? target = FontTarget.values
        .where((FontTarget t) => t.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (target == null) {
      throw ArgumentError(
        '不认识的用途「$name」；可选：'
        '${FontTarget.values.map((FontTarget t) => t.name).join(', ')}',
      );
    }
    out.add(target);
  }
  return out;
}
