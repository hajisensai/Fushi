import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_specimen.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_library_widgets.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_target_preview.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_browser_page.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:path/path.dart' as p;

/// A font added from a target-specific entry point must immediately belong to
/// that target. Previously every add path silently assigned [FontTarget.body],
/// so fonts downloaded from the dictionary/game lookup settings appeared in
/// the catalog but had no effect on the surface that opened it.
Map<FontTarget, bool> customFontInitialTargets(FontTarget target) =>
    <FontTarget, bool>{target: true};

// HBK-AUDIT-116: typed model for a managed font entry. Replaces the untyped
// `Map<String, dynamic>` that was poked with scattered `as` casts. Parsing a
// persisted map is now confined to [CustomFontEntry.fromMap], so a malformed
// stored value (e.g. `enabled` written as int) degrades gracefully here instead
// of throwing a CastError at a random access site.
class CustomFontEntry {
  const CustomFontEntry({
    required this.name,
    required this.path,
    required this.enabled,
  });

  /// Display name of the font. Doubles as the CSS family for system fonts.
  final String name;

  /// Absolute path to the imported font file; `null` for system fonts.
  final String? path;

  /// Whether this font is active in the reader.
  final bool enabled;

  /// True when this entry references an imported file (vs a system font).
  bool get isFile => path != null;

  factory CustomFontEntry.fromMap(Map<String, dynamic> map) {
    final Object? rawName = map['name'];
    final Object? rawPath = map['path'];
    final Object? rawEnabled = map['enabled'];
    return CustomFontEntry(
      name: rawName is String ? rawName : rawName?.toString() ?? '',
      path: rawPath is String ? rawPath : null,
      enabled: rawEnabled is bool ? rawEnabled : true,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'name': name,
    'path': path,
    'enabled': enabled,
  };

  CustomFontEntry copyWith({bool? enabled}) =>
      CustomFontEntry(name: name, path: path, enabled: enabled ?? this.enabled);
}

/// 字体目录的一行（页面内存态；浏览器扩展字体端点追加行时也用它）。
class CustomFontCatalogRow {
  CustomFontCatalogRow({
    required this.id,
    required this.name,
    required this.path,
    required Map<FontTarget, bool> targetEnabled,
  }) : targetEnabled = Map<FontTarget, bool>.of(targetEnabled);

  final String? id;
  final String name;
  final String? path;
  final Map<FontTarget, bool> targetEnabled;

  bool get isFile => path != null;

  Set<FontTarget> get targets => targetEnabled.keys.toSet();

  String get identity => '$name\u0000${path ?? ''}';

  CustomFontEntry toCustomFontEntry(FontTarget target) => CustomFontEntry(
    name: name,
    path: path,
    enabled: targetEnabled[target] ?? true,
  );
}

List<CustomFontCatalogRow> customFontCatalogRowsFromState(
  FontCatalogState state,
) {
  final Map<String, CustomFontCatalogRow> rowsById =
      <String, CustomFontCatalogRow>{
        for (final FontCatalogEntry font in state.fonts)
          font.id: CustomFontCatalogRow(
            id: font.id,
            name: font.name,
            path: font.path,
            targetEnabled: <FontTarget, bool>{},
          ),
      };

  for (final FontTarget target in FontTarget.values) {
    final String targetKey = ReaderSettings.fontKeyForTarget(target);
    for (final FontTargetFont row
        in state.targets[targetKey] ?? const <FontTargetFont>[]) {
      rowsById[row.fontId]?.targetEnabled[target] = row.enabled;
    }
  }

  return <CustomFontCatalogRow>[
    for (final FontCatalogEntry font in state.fonts)
      if (rowsById[font.id] != null) rowsById[font.id]!,
  ];
}

FontCatalogState customFontCatalogStateFromRows(
  List<CustomFontCatalogRow> rows,
) {
  final Set<String> usedIds = <String>{};
  int nextGeneratedId = _nextCatalogFontId(rows);

  String idForRow(CustomFontCatalogRow row) {
    final String? existing = row.id;
    if (existing != null &&
        existing.isNotEmpty &&
        !usedIds.contains(existing)) {
      usedIds.add(existing);
      return existing;
    }
    while (usedIds.contains('font_$nextGeneratedId')) {
      nextGeneratedId += 1;
    }
    final String generated = 'font_$nextGeneratedId';
    usedIds.add(generated);
    nextGeneratedId += 1;
    return generated;
  }

  final List<FontCatalogEntry> fonts = <FontCatalogEntry>[];
  final Map<FontTarget, List<FontTargetFont>> targetRows =
      <FontTarget, List<FontTargetFont>>{
        for (final FontTarget target in FontTarget.values)
          target: <FontTargetFont>[],
      };

  for (final CustomFontCatalogRow row in rows) {
    if (row.name.isEmpty) continue;
    final String id = idForRow(row);
    fonts.add(FontCatalogEntry(id: id, name: row.name, path: row.path));
    for (final FontTarget target in FontTarget.values) {
      final bool? enabled = row.targetEnabled[target];
      if (enabled == null) continue;
      targetRows[target]!.add(FontTargetFont(fontId: id, enabled: enabled));
    }
  }

  return FontCatalogState(
    fonts: fonts,
    targets: <String, List<FontTargetFont>>{
      for (final FontTarget target in FontTarget.values)
        ReaderSettings.fontKeyForTarget(target): targetRows[target]!,
    },
  );
}

Map<String, List<Map<String, dynamic>>> customFontLegacyListsFromRows(
  List<CustomFontCatalogRow> rows,
) {
  return <String, List<Map<String, dynamic>>>{
    for (final FontTarget target in FontTarget.values)
      ReaderSettings.fontKeyForTarget(target): <Map<String, dynamic>>[
        for (final CustomFontCatalogRow row in rows)
          if (row.targets.contains(target))
            row.toCustomFontEntry(target).toMap(),
      ],
  };
}

@visibleForTesting
bool customFontFileStillReferenced(
  List<CustomFontCatalogRow> rows,
  String filePath,
) {
  return rows.any((CustomFontCatalogRow row) => row.path == filePath);
}

int _nextCatalogFontId(List<CustomFontCatalogRow> rows) {
  final RegExp generatedId = RegExp(r'^font_(\d+)$');
  int next = 1;
  for (final CustomFontCatalogRow row in rows) {
    final String? id = row.id;
    if (id == null) continue;
    final RegExpMatch? match = generatedId.firstMatch(id);
    final int? value = match == null
        ? null
        : int.tryParse(match.group(1) ?? '');
    if (value != null && value >= next) {
      next = value + 1;
    }
  }
  return next;
}

/// 推荐字体表的一项。浏览器扩展的字体端点也按这张表下载，所以不再是仅测试可见。
class RecommendedFont {
  RecommendedFont({
    required this.name,
    required this.nameJa,
    required this.urls,
    required this.license,
    required this.description,
  });
  final String name;
  final String nameJa;
  final List<String> urls;
  final String license;
  final String description;
}

// 下载源顺序：直链单文件 CDN 优先，Google Fonts 打包接口垫底。
//
// `https://fonts.google.com/download?family=X` 现在返回的是网站 SPA 的
// text/html（不再是 zip），对「下载单个字体文件」这条路径已失效——它只会
// 命中 `_isValidFontFile` 校验失败后回退到镜像。所以把能直接吐字体文件的
// jsDelivr / GitHub raw 直链排在前面，Google 接口仅作最后兜底。
//
// jsDelivr 对整个包 >50MB 的目录会整目录 403（例如 notoserifsc），这类只能
// 走 GitHub raw；GitHub raw 无此限制，对 CJK 大字体统一补一条兜底直链。
List<RecommendedFont> get recommendedFontsCatalog => [
  // ── 推荐首选 ──
  RecommendedFont(
    name: 'Klee One',
    nameJa: 'クレー One',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/kleeone/KleeOne-Regular.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/kleeone/KleeOne-Regular.ttf',
      'https://fonts.google.com/download?family=Klee+One',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_klee_one,
  ),
  // ── CJK 覆盖（日中韩通用，不会缺字） ──
  RecommendedFont(
    name: 'Noto Sans JP',
    nameJa: 'Noto Sans 日本語',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Sans+JP',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_sans_jp,
  ),
  RecommendedFont(
    name: 'Noto Serif JP',
    nameJa: 'Noto Serif 日本語',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notoserifjp/NotoSerifJP%5Bwght%5D.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifjp/NotoSerifJP%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Serif+JP',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_serif_jp,
  ),
  RecommendedFont(
    name: 'Noto Sans SC',
    nameJa: 'Noto Sans 简体中文',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Sans+SC',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_sans_sc,
  ),
  RecommendedFont(
    name: 'Noto Serif SC',
    nameJa: 'Noto Serif 简体中文',
    // jsDelivr 整目录 >50MB → notoserifsc 直接 403，只能走 GitHub raw。
    urls: [
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Serif+SC',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_serif_sc,
  ),
  RecommendedFont(
    name: 'Noto Sans TC',
    nameJa: 'Noto Sans 繁體中文',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Sans+TC',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_sans_tc,
  ),
  RecommendedFont(
    name: 'Noto Serif TC',
    nameJa: 'Noto Serif 繁體中文',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notoseriftc/NotoSerifTC%5Bwght%5D.ttf',
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notoseriftc/NotoSerifTC%5Bwght%5D.ttf',
      'https://fonts.google.com/download?family=Noto+Serif+TC',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_noto_serif_tc,
  ),
  // ── 日语特色字体（风格独特，建议搭配 Noto Sans JP 做回退） ──
  RecommendedFont(
    name: 'Shippori Mincho',
    nameJa: 'しっぽり明朝',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/shipporimincho/ShipporiMincho-Regular.ttf',
      'https://fonts.google.com/download?family=Shippori+Mincho',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_shippori_mincho,
  ),
  RecommendedFont(
    name: 'Zen Old Mincho',
    nameJa: '禅オールド明朝',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenoldmincho/ZenOldMincho-Regular.ttf',
      'https://fonts.google.com/download?family=Zen+Old+Mincho',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_zen_old_mincho,
  ),
  RecommendedFont(
    name: 'Zen Maru Gothic',
    nameJa: '禅丸ゴシック',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenmarugothic/ZenMaruGothic-Regular.ttf',
      'https://fonts.google.com/download?family=Zen+Maru+Gothic',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_zen_maru_gothic,
  ),
  RecommendedFont(
    name: 'M PLUS Rounded 1c',
    nameJa: 'M PLUS Rounded 1c',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mplusrounded1c/MPLUSRounded1c-Regular.ttf',
      'https://fonts.google.com/download?family=M+PLUS+Rounded+1c',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_mplus_rounded_1c,
  ),
  RecommendedFont(
    name: 'Hina Mincho',
    nameJa: 'ひな明朝',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/hinamincho/HinaMincho-Regular.ttf',
      'https://fonts.google.com/download?family=Hina+Mincho',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_hina_mincho,
  ),
  RecommendedFont(
    name: 'Zen Kaku Gothic New',
    nameJa: '禅角ゴシック New',
    urls: [
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenkakugothicnew/ZenKakuGothicNew-Regular.ttf',
      'https://fonts.google.com/download?family=Zen+Kaku+Gothic+New',
    ],
    license: 'OFL 1.1',
    description: t.font_desc_zen_kaku_gothic_new,
  ),
];

// ── 主页面 ────────────────────────────────────────────────────────────────────

class CustomFontsPage extends BasePage {
  /// 本次进入字体库的**作用域用途**：决定新导入/新添加的字体默认挂到哪个
  /// [FontTarget]。默认 [FontTarget.body]，所以从外观设置进来的历史路径行为不变。
  ///
  /// 这个参数曾经是死参数（声明了但 State 从不读），导致从「设置·游戏·Hook 文本
  /// 字体」进来导入的字体被挂到小说正文，游戏浮窗永远不变——用户看到的就是
  /// 「字体库里没有游戏」。
  const CustomFontsPage({super.key, this.target = FontTarget.body});

  final FontTarget target;

  @override
  BasePageState createState() => _CustomFontsPageState();
}

/// 阅读器设置的 DB 偏好 key：经单一真相编码器 [dbSourcePrefKey]（`reader_fushi`
/// 是冻结的历史 sourceId，旧数据兼容，勿改）。
String _readerPrefKey(String shortKey) =>
    dbSourcePrefKey(kReaderSourcePersistedKey, shortKey);

/// 读字体目录状态：优先 v2 的 `font_catalog` + `font_targets` 两键，解析不出来
/// 就从各用途的旧列表（`fontsForTarget`）合成。页面与浏览器扩展字体端点共用。
Future<FontCatalogState> readCustomFontCatalogState({
  required FushiDatabase database,
  required ReaderSettings settings,
}) async {
  final String? catalogJson = await database.getPref(
    _readerPrefKey(ReaderSettings.fontCatalogKey),
  );
  final String? targetsJson = await database.getPref(
    _readerPrefKey(ReaderSettings.fontTargetsKey),
  );
  if (catalogJson != null && targetsJson != null) {
    final FontCatalogState? state = FontCatalogState.tryParse(
      catalogJson: catalogJson,
      targetsJson: targetsJson,
      targetKeys: <String>[
        for (final FontTarget target in FontTarget.values)
          ReaderSettings.fontKeyForTarget(target),
      ],
    );
    if (state != null) return state;
  }
  return FontCatalogState.fromLegacy(<String, List<Map<String, dynamic>>>{
    for (final FontTarget target in FontTarget.values)
      ReaderSettings.fontKeyForTarget(target): settings.fontsForTarget(target),
  });
}

/// 把字体目录状态写穿 DB（v2 两键 + 各用途旧列表），再刷新所有消费端：
/// [ReaderSettings] 缓存、app 全局字体、Windows 的 galgame 分层窗、活着的阅读器。
/// 页面与浏览器扩展字体端点共用——扩展下载的字体也要立刻在 app 里生效。
Future<void> persistCustomFontState({
  required AppModel appModel,
  required ReaderSettings settings,
  required FontCatalogState state,
  required Map<String, List<Map<String, dynamic>>> legacy,
}) async {
  await appModel.database.setPref(
    _readerPrefKey(ReaderSettings.fontCatalogKey),
    jsonEncode(state.toCatalogJson()),
  );
  await appModel.database.setPref(
    _readerPrefKey(ReaderSettings.fontTargetsKey),
    jsonEncode(state.toTargetsJson()),
  );
  for (final MapEntry<String, List<Map<String, dynamic>>> entry
      in legacy.entries) {
    await appModel.database.setPref(
      _readerPrefKey(entry.key),
      jsonEncode(entry.value),
    );
  }
  await settings.refreshFromDb();
  await appModel.refreshAppFont();
  // 平台门在**取单例之前**：GalHookTextOverlayController.instance 会把整套 galgame
  // 单例图（含 GalIngameLookupController 与它挂上去、永不释放的监听器）建起来。
  // 非 Windows 用户只是存了一次字体，不该因此拉起一整个 Windows 专属子系统。
  if (GalHookTextOverlayController.isSupported) {
    await GalHookTextOverlayController.instance.applyFontFromSettings();
  }
  ReaderFushiSource.onSettingsChangedLive?.call();
}

/// 字体落地目录：`<appDirectory>/custom_fonts`。不存在时创建。
Directory customFontsDirectory(Directory appDirectory) {
  final Directory dir = Directory(p.join(appDirectory.path, 'custom_fonts'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

class _CustomFontsPageState extends BasePageState<CustomFontsPage> {
  ReaderSettings? _settings;

  List<CustomFontCatalogRow> _fonts = [];
  late final Future<void> _fontsReady;
  Future<void> _saveTail = Future<void>.value();
  bool _fontsLoading = true;

  @override
  void initState() {
    super.initState();
    _fontsReady = _initializeFonts();
    _loadSystemFamilyKeys();
  }

  Future<void> _initializeFonts() async {
    try {
      ReaderSettings? settings = ReaderFushiSource.readerSettings;
      if (settings == null) {
        // initState must not call BasePageState.appModel: that getter uses
        // ref.watch and therefore depends on ProviderScope before initState has
        // completed. The base state populated this read-only cache in
        // super.initState(), specifically for lifecycle-safe initialization.
        settings = ReaderSettings(appModelNoUpdate.database);
        await settings.refreshFromDb();
        ReaderFushiSource.readerSettings = settings;
      }
      _settings = settings;
      final FontCatalogState state = await readCustomFontCatalogState(
        database: appModelNoUpdate.database,
        settings: settings,
      );
      if (!mounted) return;
      setState(() {
        _fonts = customFontCatalogRowsFromState(state);
        _fontsLoading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.initializeFonts', e, stack);
      if (!mounted) return;
      setState(() => _fontsLoading = false);
    }
  }

  /// 新导入/新添加字体的默认用途集合：跟随本次进入字体库的作用域
  /// [CustomFontsPage.target]，而不是恒定 [FontTarget.body]。
  ///
  /// 四个新增入口（文件导入 / 压缩包解包 / 推荐字体下载 / 系统字体）共用它，
  /// 保证「从哪个设置入口进来，导入的字体就为哪个用途生效」。派生规则本身放在
  /// 顶层 [customFontInitialTargets]（可单测、可被别处复用），这里只是调用点的
  /// 单一名字——四个入口共用同一个名字才守得住「有新入口没接作用域」。
  Map<FontTarget, bool> _newFontTargets() =>
      customFontInitialTargets(widget.target);

  /// 这个字体行**格式上**用不了的用途 → 给用户看的原因。
  ///
  /// 只有一条来源：native 分层窗（[FontTarget.gameLookup]）的 DirectWrite 只吃裸
  /// sfnt，WOFF/WOFF2 会被 `resolveForNativeOverlay` 静默跳过。判据与 loader 共用
  /// 同一个 [AppFontLoader.nativeOverlayCanUse]，两处不会漂开。
  Map<FontTarget, String> _unsupportedTargetsFor(CustomFontCatalogRow row) {
    final String? path = row.path;
    if (AppFontLoader.nativeOverlayCanUse(path)) {
      return const <FontTarget, String>{};
    }
    return <FontTarget, String>{
      FontTarget.gameLookup: t.import_unsupported_file_format(
        ext: p.extension(path!).toLowerCase(),
      ),
    };
  }

  Future<void> _save() {
    final FontCatalogState state = customFontCatalogStateFromRows(_fonts);
    final Map<String, List<Map<String, dynamic>>> legacy =
        customFontLegacyListsFromRows(_fonts);

    // Target chips, reorder buttons, and add actions may fire before the
    // previous multi-key write finishes. Preserve invocation order so an older
    // refresh cannot overwrite the newest in-memory target selection.
    final Future<void> operation = _saveTail.then(
      (_) => persistCustomFontState(
        appModel: appModel,
        settings: _settings!,
        state: state,
        legacy: legacy,
      ),
    );
    _saveTail = operation.catchError((Object error, StackTrace stack) {
      ErrorLogService.instance.log('CustomFontsPage.save', error, stack);
    });
    return operation;
  }

  /// 文件层执行体（复制 / 解包 / 多源下载），与浏览器扩展字体端点共用同一份。
  late final FontDownloadService _fontService = FontDownloadService(
    fontsDir: customFontsDirectory(appModel.appDirectory),
  );

  /// 把服务落好的文件登记成目录行，挂到本次进入页面的作用域用途。
  /// 文件导入 / 压缩包解包 / 推荐字体下载 / URL 下载四个入口都汇到这里。
  int _appendImported(List<ImportedFontFile> files) {
    final List<CustomFontCatalogRow> rows = <CustomFontCatalogRow>[
      for (final ImportedFontFile file in files)
        CustomFontCatalogRow(
          id: null,
          name: file.name,
          path: file.path,
          targetEnabled: _newFontTargets(),
        ),
    ];
    if (rows.isEmpty) return 0;
    if (mounted) {
      setState(() => _fonts.addAll(rows));
    } else {
      _fonts.addAll(rows);
    }
    return rows.length;
  }

  /// 文件选择器与桌面拖放共用的导入扩展名（字体 + 压缩包）。
  static const List<String> _importExtensions = <String>[
    'ttf',
    'otf',
    'ttc',
    'woff',
    'woff2',
    'zip',
    '7z',
    'rar',
    'tar',
    'gz',
  ];

  Future<void> _importFontFile() async {
    final result = await pickFilesByExtensions(
      context: context,
      allowedExtensions: _importExtensions,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    await _importFiles(<(File, String)>[
      for (final picked in result.files)
        if (picked.path != null) (File(picked.path!), picked.name),
    ]);
  }

  /// 桌面拖放：把拖进窗口的文件按扩展名过滤后走同一条导入路径。
  Future<void> _importDroppedPaths(List<String> paths) async {
    await _importFiles(<(File, String)>[
      for (final String path in paths)
        if (_importExtensions.contains(
          p.extension(path).replaceFirst('.', '').toLowerCase(),
        ))
          (File(path), p.basename(path)),
    ]);
  }

  /// 批量导入：M3E snackbar 显示逐个进度，结束后换成结果 snackbar（成功数 +
  /// 失败数）。逐个串行——都要落到同一个字体目录、跑同一套解包与落库。
  Future<void> _importFiles(List<(File, String)> files) async {
    if (files.isEmpty) return;
    await _fontsReady;
    if (!mounted) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final ValueNotifier<int> done = ValueNotifier<int>(0);
    final int total = files.length;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      FushiSnackBar(
        duration: const Duration(minutes: 10),
        content: ValueListenableBuilder<int>(
          valueListenable: done,
          builder: (BuildContext context, int n, Widget? _) => Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 20,
                child: FushiCircularProgressIndicator(
                  strokeWidth: 2.5,
                  value: n / total,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t.font_library_importing(
                    current: (n + 1).clamp(1, total),
                    total: total,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    int imported = 0;
    int failed = 0;
    for (final (File file, String name) in files) {
      final int added = await _importPickedFile(file, name, quiet: true);
      if (added == 0) failed++;
      imported += added;
      done.value = done.value + 1;
    }
    if (imported > 0) await _save();
    messenger?.hideCurrentSnackBar();
    final String message = imported > 0
        ? <String>[
            t.custom_fonts_imported_count(count: imported),
            if (failed > 0) t.font_library_import_failed_count(n: failed),
          ].join(' · ')
        : t.font_library_import_failed_count(n: failed);
    messenger?.showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 用户选的单个文件（字体或压缩包）→ 服务落地 → 登记目录行。
  /// 解不开 / 不是字体时返回 0，不中断同批其它文件；[quiet] 为 false 时
  /// 额外 toast 一句（批量导入由调用方汇总成一条结果 snackbar）。
  Future<int> _importPickedFile(
    File src,
    String fileName, {
    bool quiet = false,
  }) async {
    try {
      return _appendImported(
        await _fontService.importFile(src, fileName: fileName),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.importFile', e, stack);
      debugPrint('[fushi-fonts] import failed: $e');
      if (!quiet) {
        FushiToast.show(
          msg: t.custom_fonts_archive_error,
          severity: ToastSeverity.error,
        );
      }
      return 0;
    }
  }

  /// 下载执行体：**不碰 Navigator、不弹 toast**，只跑「多源回退下载 → 校验 →
  /// 解包/落库 → 登记目录行」。UI 由调用方负责。
  ///
  /// 批量下载真正要避开的是旧实现里「每条各弹一个 barrierDismissible:false +
  /// PopScope(canPop:false) 的独占模态框」——那种框在下载期间把整个 UI 锁死，
  /// 连着下 5 个字体就是连着锁 5 次，中途还没法看进度到哪了。
  ///
  /// 执行体的取消由调用方持有 [cancelToken]：批量时一次取消应当停掉整批。
  Future<FontDownloadResult> _runFontDownload(
    List<String> urls, {
    required ValueNotifier<double?> progressNotifier,
    required CancelToken cancelToken,
    String? overrideName,
  }) async {
    final FontDownloadResult result = await _fontService.download(
      urls,
      overrideName: overrideName,
      cancelToken: cancelToken,
      onProgress: (double? progress) => progressNotifier.value = progress,
    );
    _appendImported(result.files);
    return result;
  }

  /// 单条下载：独占进度框 + 逐条 toast，行为与重构前一致。
  Future<void> _downloadUrl(
    String url, {
    String? displayName,
    List<String> mirrorUrls = const [],
    String? overrideName,
  }) async {
    final progressNotifier = ValueNotifier<double?>(null);
    final cancelToken = CancelToken();
    if (mounted) {
      showAppDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: CustomFontDownloadProgressDialog(
            title: displayName ?? t.custom_fonts_downloading,
            progressNotifier: progressNotifier,
            onCancel: () {
              cancelToken.cancel();
              Navigator.pop(ctx);
            },
          ),
        ),
      );
    }
    try {
      final FontDownloadResult result = await _runFontDownload(
        <String>[url, ...mirrorUrls],
        progressNotifier: progressNotifier,
        cancelToken: cancelToken,
        overrideName: overrideName,
      );
      // 取消时进度框已被 onCancel 关掉，别再 pop 一次——那会连着把字体页也弹掉。
      if (mounted && !result.cancelled) Navigator.pop(context);
      if (result.cancelled) return;
      if (result.error != null) {
        FushiToast.show(
          msg: '${t.custom_fonts_download_failed}: ${result.error}',
          toastLength: Toast.LENGTH_LONG,
          severity: ToastSeverity.error,
        );
        return;
      }
      if (result.importedCount > 0) {
        await _save();
        FushiToast.show(
          msg: t.custom_fonts_imported_count(count: result.importedCount),
          severity: ToastSeverity.success,
        );
      } else {
        FushiToast.show(
          msg: t.custom_fonts_no_fonts_in_archive,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      progressNotifier.dispose();
    }
  }

  Future<void> _importFromUrl() async {
    final url = await showAppDialog<String>(
      context: context,
      builder: (ctx) => const CustomFontUrlImportDialog(),
    );
    if (url == null || url.isEmpty) return;
    await _downloadUrl(url);
  }

  /// 批量下载推荐字体：**一个**进度框跑完整批，逐条串行。
  ///
  /// 串行而非并发：每条都要落到同一个字体目录、跑同一套解包与 _save() 落库，
  /// 并发只会让临时文件与 catalog 写入互相踩。
  ///
  /// 一条失败不中断整批（网络抽风是常态，一条挂掉不该把其余六条也废掉），
  /// 结果聚合成一句 toast；中途取消则停掉整批——用户点的是「取消」不是「跳过」。
  Future<void> _downloadRecommendedFonts(List<RecommendedFont> fonts) async {
    final progressNotifier = ValueNotifier<double?>(null);
    final cancelToken = CancelToken();
    final ValueNotifier<String> titleNotifier = ValueNotifier<String>(
      fonts.first.name,
    );
    if (mounted) {
      showAppDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: ValueListenableBuilder<String>(
            valueListenable: titleNotifier,
            builder: (BuildContext context, String title, _) =>
                CustomFontDownloadProgressDialog(
              title: title,
              progressNotifier: progressNotifier,
              onCancel: () {
                cancelToken.cancel();
                Navigator.pop(ctx);
              },
            ),
          ),
        ),
      );
    }
    int imported = 0;
    int failed = 0;
    bool cancelled = false;
    try {
      for (int i = 0; i < fonts.length; i++) {
        final RecommendedFont font = fonts[i];
        titleNotifier.value = fonts.length > 1
            ? '${font.name}  (${i + 1}/${fonts.length})'
            : font.name;
        progressNotifier.value = null;
        final FontDownloadResult result = await _runFontDownload(
          font.urls,
          progressNotifier: progressNotifier,
          cancelToken: cancelToken,
          overrideName: font.name,
        );
        if (result.cancelled) {
          cancelled = true;
          break;
        }
        if (result.error != null || result.importedCount == 0) {
          failed++;
          continue;
        }
        imported += result.importedCount;
      }
      // 取消时进度框已被 onCancel 关掉，别再 pop 一次。
      if (mounted && !cancelled) Navigator.pop(context);
      if (imported > 0) await _save();
      if (!mounted) return;
      if (imported > 0) {
        FushiToast.show(
          msg: t.custom_fonts_imported_count(count: imported),
          severity: ToastSeverity.success,
        );
      }
      if (failed > 0) {
        FushiToast.show(
          msg: '${t.custom_fonts_download_failed}: $failed',
          toastLength: Toast.LENGTH_LONG,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      progressNotifier.dispose();
      titleNotifier.dispose();
    }
  }

  // HBK-AUDIT-109: one canonical dedupe key (the display name) shared by both
  // pickers. Previously the recommended picker keyed on ALL names while the
  // system picker keyed only on system fonts (`path == null`), so a file font
  // and a system font sharing a name disagreed about what was "already added".
  Set<String> get _addedFontNames =>
      _fonts.map((CustomFontCatalogRow e) => e.name).toSet();

  Future<void> _openRecommended() async {
    await _fontsReady;
    if (!mounted) return;
    final fonts = await Navigator.push<List<RecommendedFont>>(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => RecommendedFontsPage(alreadyAdded: _addedFontNames),
      ),
    );
    if (fonts == null || fonts.isEmpty || !mounted) return;
    await _downloadRecommendedFonts(fonts);
  }

  /// 系统字体浏览页：每款字体用自己渲染日文样张，可多选一次加入。浏览页底部样张
  /// 按当前预览中的用途渲染；加入后挂到进页作用域（[_newFontTargets]），与其余
  /// 三个新增入口同一口径。
  Future<void> _addSystemFont() async {
    await _fontsReady;
    if (!mounted) return;
    final List<String>? selected = await Navigator.push<List<String>>(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => SystemFontBrowserPage(
          alreadyAdded: _addedFontNames,
          target: _previewTarget,
        ),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    setState(() {
      for (final String family in selected) {
        _fonts.add(
          CustomFontCatalogRow(
            id: null,
            name: family,
            path: null,
            targetEnabled: _newFontTargets(),
          ),
        );
      }
    });
    _save();
  }

  // ── 状态变更广播 ───────────────────────────────────────────────────────────

  /// 每次页面状态变化 +1：窄屏详情是独立路由（bottom sheet），靠它跟着刷新。
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value = _revision.value + 1;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _sampleController.dispose();
    _revision.dispose();
    super.dispose();
  }

  // ── 预览 ────────────────────────────────────────────────────────────────────

  /// 预览区当前展示的用途；进页时 = 作用域 [CustomFontsPage.target]，用户可在
  /// 预览区切换。只影响预览，不改变新增字体挂到哪个用途。
  late FontTarget _previewTarget = widget.target;

  /// 行 identity → 解析出的引擎族名（null = 解析失败）。只增不删：同名同路径的
  /// 条目族名不会变，删掉再加回来也直接复用。
  final Map<String, String?> _resolvedFamilies = <String, String?>{};
  final Set<String> _resolving = <String>{};

  /// 行 identity → 文件元数据（格式 / 大小 / 字重 / 语言 / 风格）。只给文件行读。
  final Map<String, FontFileMetadata?> _metadata =
      <String, FontFileMetadata?>{};
  final Set<String> _metadataLoading = <String>{};

  /// 本机系统字体族名（小写），用于标出「系统里没有」的系统字体条目；
  /// null = 还没枚举完或平台给不出可信名单，此时不下结论。
  Set<String>? _systemFamilyKeys;

  /// 本机系统字体族名（小写）→ 是否带日文字形（null = 平台判不出）。
  Map<String, bool?> _systemJapanese = <String, bool?>{};

  Future<void> _loadSystemFamilyKeys() async {
    final SystemFontList list = await SystemFontCatalog.load();
    if (!mounted || list.families.isEmpty) return;
    setState(() {
      _systemJapanese = <String, bool?>{
        for (final SystemFontFamily f in list.families)
          f.family.toLowerCase(): f.supportsJapanese,
      };
      if (list.namesReliable) {
        _systemFamilyKeys = <String>{
          for (final SystemFontFamily f in list.families) f.family.toLowerCase(),
        };
      }
    });
  }

  /// 为还没解析过的行排队解析族名（文件字体要经 FontLoader 注册）与读文件元数据，
  /// 完成后刷新。
  void _ensureResolved() {
    for (final CustomFontCatalogRow row in _fonts) {
      final String key = row.identity;
      if (!_resolvedFamilies.containsKey(key) && _resolving.add(key)) {
        resolveCatalogFontFamily(name: row.name, path: row.path).then(
          (String? family) {
            if (!mounted) return;
            setState(() {
              _resolving.remove(key);
              _resolvedFamilies[key] = family;
            });
          },
        );
      }
      final String? path = row.path;
      if (path != null &&
          !_metadata.containsKey(key) &&
          _metadataLoading.add(key)) {
        readFontFileMetadata(path).then((FontFileMetadata? meta) {
          if (!mounted) return;
          setState(() {
            _metadataLoading.remove(key);
            _metadata[key] = meta;
          });
        });
      }
    }
  }

  FontSpecimenState _specimenStateFor(CustomFontCatalogRow row) {
    if (!_resolvedFamilies.containsKey(row.identity)) {
      return FontSpecimenState.loading;
    }
    return _resolvedFamilies[row.identity] == null
        ? FontSpecimenState.unavailable
        : FontSpecimenState.ready;
  }

  /// 预览用途下已启用的条目，按用户顺序。
  List<CustomFontCatalogRow> get _previewEnabledRows => <CustomFontCatalogRow>[
    for (final CustomFontCatalogRow row in _fonts)
      if (row.targetEnabled[_previewTarget] == true) row,
  ];

  bool _missingOnSystem(CustomFontCatalogRow row) {
    final Set<String>? keys = _systemFamilyKeys;
    return keys != null && !row.isFile && !keys.contains(row.name.toLowerCase());
  }

  FontLibraryEntryView _viewOf(CustomFontCatalogRow row) => FontLibraryEntryView(
    identity: row.identity,
    name: row.name,
    isFile: row.isFile,
    path: row.path,
    family: _resolvedFamilies[row.identity],
    state: _specimenStateFor(row),
    // 与用途开关同一判据：键在即挂上（值是历史的 enabled 标记）。
    targets: row.targets,
    metadata: _metadata[row.identity],
    missingOnSystem: _missingOnSystem(row),
    // native 分层窗只吃裸 sfnt；WOFF/WOFF2 勾了游戏用途下游会静默跳过，
    // 详情页直接把那枚用途按钮置灰，别让用户白设。
    unsupportedTargets: _unsupportedTargetsFor(row),
  );

  FontLibraryTraits _traitsOf(CustomFontCatalogRow row) =>
      fontLibraryTraitsFor(
        name: row.name,
        metadata: _metadata[row.identity],
        systemSupportsJapanese: row.isFile
            ? null
            : _systemJapanese[row.name.toLowerCase()],
      );

  Widget _buildPreviewSection() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> families = effectiveFontTargetFamilies(
      _previewTarget,
      <FontPreviewCandidate>[
        for (final CustomFontCatalogRow row in _previewEnabledRows)
          FontPreviewCandidate(
            family: _resolvedFamilies[row.identity],
            path: row.path,
          ),
      ],
    );
    return FushiCard(
      pressScale: false,
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: [
              for (final FontTarget target in FontTarget.values)
                if (isFontTargetAvailableOnPlatform(target))
                  FushiSelectableChip(
                    key: ValueKey<String>('font-preview-target-${target.name}'),
                    label: fontTargetLabel(target),
                    selected: _previewTarget == target,
                    onSelected: (_) => setState(() => _previewTarget = target),
                  ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          FontTargetPreview(
            target: _previewTarget,
            families: families,
            subtitleStyle: VideoSubtitleStyle.decode(
              appModel.videoSubtitleStyle,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeFont(int index) async {
    final CustomFontCatalogRow entry = _fonts[index];
    final String? filePath = entry.path;
    setState(() {
      _fonts.removeAt(index);
      if (_detailIdentity == entry.identity) _detailIdentity = null;
    });
    await _save();
    if (filePath != null && !customFontFileStillReferenced(_fonts, filePath)) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (e, stack) {
        ErrorLogService.instance.log('CustomFontsPage.deleteFont', e, stack);
        debugPrint('[Fushi] failed to delete font file $filePath: $e');
      }
    }
    FushiToast.show(
      msg: t.custom_fonts_removed,
      severity: ToastSeverity.success,
    );
  }

  /// 删除前的破坏性确认（共享 M3E 确认框）：文件字体连文件一起删，系统字体
  /// 只是移出字体库，文案分开说清楚。
  Future<void> _confirmRemoveFont(int index) async {
    final CustomFontCatalogRow row = _fonts[index];
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.font_library_delete_title(name: row.name),
      message: row.isFile
          ? t.font_library_delete_message_file
          : t.font_library_delete_message_system,
      icon: FushiIcons.delete,
      confirmLabel: t.font_library_delete_action,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final int current = _indexOfIdentity(row.identity);
    if (current >= 0) await _removeFont(current);
  }

  /// [newIndex] 是**最终下标**（FushiReorderableColumn 语义），不是 SDK
  /// `ReorderableListView` 的「移除前下标」——故这里没有 `newIndex--` 修正。
  /// 上/下移按钮同样按最终下标传（下移传 index+1）。
  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    if (newIndex < 0 || newIndex >= _fonts.length) return;
    setState(() {
      final item = _fonts.removeAt(oldIndex);
      _fonts.insert(newIndex, item);
    });
    _save();
  }

  void _toggleTarget(int index, FontTarget target) {
    setState(() {
      final CustomFontCatalogRow entry = _fonts[index];
      if (entry.targetEnabled.containsKey(target)) {
        entry.targetEnabled.remove(target);
      } else {
        entry.targetEnabled[target] = true;
      }
    });
    _save();
  }

  // ── 浏览：搜索 / 筛选 / 样例 / 布局 ──────────────────────────────────────────

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _sampleController = TextEditingController();
  String _query = '';
  FontLibraryFilter _filter = FontLibraryFilter.all;
  FontSampleScript _script = FontSampleScript.japanese;

  /// 用户手动选的布局；null = 跟随宽度（宽屏网格、窄屏列表）。
  FontLibraryLayout? _layoutOverride;

  /// 宽屏侧板里正在看的字体（行 identity）。
  String? _detailIdentity;

  /// 最近一次布局是否宽到放得下侧板（决定点卡片开侧板还是 bottom sheet）。
  bool _wide = false;

  /// 网格单元的固定高度（重排网格要求等高）。
  static const double _gridCellExtent = 232;

  /// 宽屏侧板宽度。
  static const double _detailPanelWidth = 400;

  int _indexOfIdentity(String identity) =>
      _fonts.indexWhere((CustomFontCatalogRow row) => row.identity == identity);

  bool get _isFiltered =>
      _query.trim().isNotEmpty || _filter != FontLibraryFilter.all;

  /// 当前搜索 + 筛选下可见的行（保留目录顺序）。
  List<CustomFontCatalogRow> get _visibleRows {
    final List<CustomFontCatalogRow> filtered = <CustomFontCatalogRow>[
      for (final CustomFontCatalogRow row in _fonts)
        if (fontLibraryFilterMatches(
          _filter,
          isFile: row.isFile,
          traits: _traitsOf(row),
        ))
          row,
    ];
    return filterByMediaSearch(
      filtered,
      _query,
      (CustomFontCatalogRow row) => <String>[row.name],
    );
  }

  /// 有命中的筛选项才显示（全部 / 已导入 / 系统恒显示）。
  List<FontLibraryFilter> get _availableFilters {
    final List<FontLibraryTraits> traits = <FontLibraryTraits>[
      for (final CustomFontCatalogRow row in _fonts) _traitsOf(row),
    ];
    bool any(bool Function(FontLibraryTraits traits) test) => traits.any(test);
    return <FontLibraryFilter>[
      FontLibraryFilter.all,
      FontLibraryFilter.imported,
      FontLibraryFilter.system,
      if (any((FontLibraryTraits x) => x.japanese)) FontLibraryFilter.japanese,
      if (any((FontLibraryTraits x) => x.chinese)) FontLibraryFilter.chinese,
      if (any((FontLibraryTraits x) => x.styleClass == FontStyleClass.serif))
        FontLibraryFilter.serif,
      if (any(
        (FontLibraryTraits x) => x.styleClass == FontStyleClass.sansSerif,
      ))
        FontLibraryFilter.sansSerif,
      if (any(
        (FontLibraryTraits x) => x.styleClass == FontStyleClass.monospace,
      ))
        FontLibraryFilter.monospace,
      // 当前选中的筛选即使已无命中也留着，免得 chip 凭空消失。
      if (!<FontLibraryFilter>{
        FontLibraryFilter.all,
        FontLibraryFilter.imported,
        FontLibraryFilter.system,
      }.contains(_filter))
        _filter,
    ].toSet().toList();
  }

  String _filterLabel(FontLibraryFilter filter) => switch (filter) {
    FontLibraryFilter.all => t.font_library_filter_all,
    FontLibraryFilter.imported => t.font_library_filter_imported,
    FontLibraryFilter.system => t.font_library_filter_system,
    FontLibraryFilter.japanese => t.font_library_filter_japanese,
    FontLibraryFilter.chinese => t.font_library_filter_chinese,
    FontLibraryFilter.serif => t.font_library_filter_serif,
    FontLibraryFilter.sansSerif => t.font_library_filter_sans,
    FontLibraryFilter.monospace => t.font_library_filter_mono,
  };

  String get _sampleText =>
      fontLibrarySampleText(_script, _sampleController.text);

  // ── 详情 / 上下文菜单 ─────────────────────────────────────────────────────

  Widget _detailPanelFor(
    int index, {
    VoidCallback? onClose,
    VoidCallback? beforeDelete,
    ScrollController? scrollController,
  }) {
    final CustomFontCatalogRow row = _fonts[index];
    return FontLibraryDetailPanel(
      key: ValueKey<String>('font-detail-${row.identity}'),
      entry: _viewOf(row),
      script: _script,
      customSample: _sampleController.text,
      chainPosition: index + 1,
      onToggleTarget: (FontTarget target) {
        final int at = _indexOfIdentity(row.identity);
        if (at >= 0) _toggleTarget(at, target);
      },
      onMoveUp: index > 0
          ? () {
              final int at = _indexOfIdentity(row.identity);
              if (at > 0) _onReorder(at, at - 1);
            }
          : null,
      onMoveDown: index < _fonts.length - 1
          ? () {
              final int at = _indexOfIdentity(row.identity);
              if (at >= 0) _onReorder(at, at + 1);
            }
          : null,
      onDelete: () {
        // 窄屏 sheet 先收起再确认：删完这款已不存在，sheet 留着只是空壳。
        beforeDelete?.call();
        final int at = _indexOfIdentity(row.identity);
        if (at >= 0) _confirmRemoveFont(at);
      },
      onClose: onClose,
      scrollController: scrollController,
    );
  }

  /// 点卡片：宽屏开侧板，窄屏开 bottom sheet（sheet 内容随 [_revision] 刷新）。
  Future<void> _openDetail(CustomFontCatalogRow row) async {
    if (_wide) {
      setState(() => _detailIdentity = row.identity);
      return;
    }
    final String identity = row.identity;
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final bool apple = isGlassDesign(sheetContext);
        return Material(
          color: apple
              ? appleColorsOf(sheetContext).secondaryGroupedBackground
              : Theme.of(sheetContext).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(apple ? 12 : 28),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.86,
            child: ValueListenableBuilder<int>(
              valueListenable: _revision,
              builder: (BuildContext context, int _, Widget? __) {
                final int index = _indexOfIdentity(identity);
                if (index < 0) return const SizedBox.shrink();
                return _detailPanelFor(
                  index,
                  beforeDelete: () => Navigator.of(sheetContext).pop(),
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 右键 / 长按 / 「更多」钮的上下文菜单。坐标经 Overlay globalToLocal 消掉
  /// FushiAppUiScale 缩放（BUG-781 同族纪律）。
  Future<void> _showFontMenu(int index, Offset globalPosition) async {
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final CustomFontCatalogRow row = _fonts[index];
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem<String>(
          value: value,
          child: Row(
            children: <Widget>[
              FushiIcon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        );
    final Map<FontTarget, String> unsupported = _unsupportedTargetsFor(row);
    final String? action = await showFushiMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        item('details', FushiIcons.info, t.font_library_details),
        const PopupMenuDivider(),
        for (final FontTarget target in visibleFontTargets)
          if (!unsupported.containsKey(target))
            item(
              'target:${target.name}',
              row.targetEnabled.containsKey(target)
                  ? FushiIcons.check
                  : fontTargetIcon(target),
              fontTargetLabel(target),
            ),
        const PopupMenuDivider(),
        if (index > 0) item('up', FushiIcons.expandLess, t.move_up),
        if (index < _fonts.length - 1)
          item('down', FushiIcons.expandMore, t.move_down),
        item('delete', FushiIcons.delete, t.font_library_delete_action),
      ],
    );
    if (action == null || !mounted) return;
    final int at = _indexOfIdentity(row.identity);
    if (at < 0) return;
    if (action == 'details') {
      await _openDetail(_fonts[at]);
    } else if (action == 'up') {
      _onReorder(at, at - 1);
    } else if (action == 'down') {
      _onReorder(at, at + 1);
    } else if (action == 'delete') {
      await _confirmRemoveFont(at);
    } else if (action.startsWith('target:')) {
      final String name = action.substring('target:'.length);
      for (final FontTarget target in FontTarget.values) {
        if (target.name == name) _toggleTarget(at, target);
      }
    }
  }

  Future<void> _showAddMenu(BuildContext anchorContext) async {
    final RenderObject? box = anchorContext.findRenderObject();
    final Offset at = box is RenderBox && box.hasSize
        ? box.localToGlobal(box.size.bottomRight(Offset.zero))
        : Offset.zero;
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(at);
    PopupMenuItem<VoidCallback> item(
      IconData icon,
      String label,
      VoidCallback run,
    ) =>
        PopupMenuItem<VoidCallback>(
          value: run,
          child: Row(
            children: <Widget>[
              FushiIcon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        );
    final VoidCallback? run = await showFushiMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<VoidCallback>>[
        item(FushiIcons.importFile, t.custom_fonts_import_file, _importFontFile),
        item(FushiIcons.star, t.custom_fonts_recommended, _openRecommended),
        item(FushiIcons.textFields, t.custom_fonts_add_system, _addSystemFont),
        item(FushiIcons.link, t.custom_fonts_import_url, _importFromUrl),
      ],
    );
    if (run != null && mounted) run();
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  Widget _sectionHeader(String text, {Widget? trailing}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.gap,
      ),
      child: FushiSectionTitle(
        text,
        trailing: trailing,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _cardFor(
    CustomFontCatalogRow row,
    FontLibraryLayout layout, {
    required bool reorderable,
  }) {
    final int index = _indexOfIdentity(row.identity);
    return FontSpecimenCard(
      key: ValueKey<String>('font-card-${row.identity}'),
      entry: _viewOf(row),
      sampleText: _sampleText,
      layout: layout,
      selected: _wide && _detailIdentity == row.identity,
      // 重排模式下触摸长按留给拖拽；菜单走右键或卡片的「更多」钮。
      allowLongPressMenu: !reorderable,
      showDragHandle: reorderable && layout == FontLibraryLayout.list,
      onOpen: () => _openDetail(row),
      onContextMenu: (Offset position) => _showFontMenu(index, position),
    );
  }

  List<Widget> _buildFontSlivers(
    BuildContext context,
    double width,
    FontLibraryLayout layout,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double pad = tokens.spacing.page;
    const double gap = 12;
    final double inner = width - pad * 2 < 0 ? 0.0 : width - pad * 2;
    final int columns = layout == FontLibraryLayout.list
        ? 1
        : ((inner + gap) / (inner < 600 ? 170 + gap : 280 + gap))
              .floor()
              .clamp(2, 6);

    if (_fontsLoading) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          sliver: layout == FontLibraryLayout.list
              ? SliverList.separated(
                  itemCount: 3,
                  separatorBuilder: (_, __) => const SizedBox(height: gap),
                  itemBuilder: (BuildContext context, int index) =>
                      const FontSpecimenCardSkeleton(
                    layout: FontLibraryLayout.list,
                  ),
                )
              : SliverGrid.builder(
                  itemCount: columns * 2,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: _gridCellExtent,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                  ),
                  itemBuilder: (BuildContext context, int index) =>
                      const FontSpecimenCardSkeleton(
                    layout: FontLibraryLayout.grid,
                  ),
                ),
        ),
      ];
    }

    if (_fonts.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: SettingsEmptyState(
            icon: FushiIcons.font,
            title: t.font_library_empty_title,
            message: t.font_library_empty_message,
            action: FushiFilledButton.tonalIcon(
              onPressed: _importFontFile,
              icon: const FushiIcon(FushiIcons.importFile),
              label: Text(t.font_library_import_fab),
            ),
          ),
        ),
      ];
    }

    final List<CustomFontCatalogRow> visible = _visibleRows;
    if (visible.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: SettingsEmptyState(
            icon: FushiIcons.searchOff,
            title: t.font_library_no_match,
          ),
        ),
      ];
    }

    // 无搜索、无筛选时卡片可拖拽排序（顺序 = 各用途的回退优先级）。
    if (!_isFiltered) {
      final Widget reorder = layout == FontLibraryLayout.list
          // 自实现的 FushiReorderableColumn 而非 SDK ReorderableListView：
          // 整棵树活在 FushiAppUiScale 的 Transform.scale 之下，而 SDK 的
          // _DragItemProxy 用「全局坐标 − overlay 原点」纯平移、不认祖先
          // 缩放，「界面大小」非 100% 时拖拽浮层按 (1−s)×距离 漂移、缩小时
          // 一拖即飞出屏幕（BUG-778 同根因）。
          ? FushiReorderableColumn(
              itemCount: _fonts.length,
              spacing: gap,
              feedbackBorderRadius: FushiM3eShape.cardRadius,
              keyForIndex: (int index) =>
                  ValueKey<String>('${_fonts[index].identity}-$index'),
              onReorder: _onReorder,
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                index: index,
                child: _cardFor(
                  _fonts[index],
                  layout,
                  reorderable: true,
                ),
              ),
            )
          : FushiReorderableGrid(
              itemCount: _fonts.length,
              crossAxisCount: columns,
              childAspectRatio:
                  ((inner - gap * (columns - 1)) / columns) / _gridCellExtent,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
              feedbackBorderRadius: FushiM3eShape.cardRadius,
              keyForIndex: (int index) =>
                  ValueKey<String>('${_fonts[index].identity}-$index'),
              onReorder: _onReorder,
              itemBuilder: (BuildContext context, int index) =>
                  FushiStaggeredEntrance(
                index: index,
                child: _cardFor(
                  _fonts[index],
                  layout,
                  reorderable: true,
                ),
              ),
            );
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          sliver: SliverToBoxAdapter(child: reorder),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, tokens.spacing.gap),
        sliver: SliverToBoxAdapter(
          child: Text(
            t.font_library_reorder_filtered_hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        sliver: layout == FontLibraryLayout.list
            ? SliverList.separated(
                itemCount: visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: gap),
                itemBuilder: (BuildContext context, int index) =>
                    FushiStaggeredEntrance(
                  index: index,
                  child: _cardFor(visible[index], layout, reorderable: false),
                ),
              )
            : SliverGrid.builder(
                itemCount: visible.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: _gridCellExtent,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: gap,
                ),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) =>
                      _cardFor(visible[index], layout, reorderable: false),
                ),
              ),
      ),
    ];
  }

  Widget _buildBrowser(
    BuildContext context,
    SettingsSectionSpy spy,
    double width,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double pad = tokens.spacing.page;
    final FontLibraryLayout layout =
        _layoutOverride ??
        (width >= 600 ? FontLibraryLayout.grid : FontLibraryLayout.list);
    final List<FontLibraryFilter> filters = _availableFilters;

    final Widget toolbar = SettingsSectionAnchor(
      title: t.font_library_section_fonts,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(
              t.font_library_section_fonts,
              trailing: _fonts.isEmpty
                  ? null
                  : SettingsCountBadge(count: _fonts.length),
            ),
            FushiSearchBar(
              fieldKey: const ValueKey<String>('font-library-search'),
              controller: _searchController,
              hintText: t.custom_fonts_search_hint,
              onQueryChanged: (String q) => setState(() => _query = q),
            ),
            SizedBox(height: tokens.spacing.gap),
            SizedBox(
              height: 48,
              child: ListView.separated(
                primary: false,
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap),
                itemBuilder: (BuildContext context, int index) {
                  final FontLibraryFilter filter = filters[index];
                  return Center(
                    child: FushiSelectableChip(
                      key: ValueKey<String>('font-library-filter-${filter.name}'),
                      label: _filterLabel(filter),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                  );
                },
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            FontSampleToolbar(
              script: _script,
              onScriptChanged: (FontSampleScript script) =>
                  setState(() => _script = script),
              controller: _sampleController,
              onCustomChanged: () => setState(() {}),
            ),
            SizedBox(height: tokens.spacing.card),
          ],
        ),
      ),
    );

    final Widget preview = SettingsSectionAnchor(
      title: t.font_preview_title,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(t.font_preview_title),
            if (_fontsLoading)
              const SettingsLoadingState()
            else
              _buildPreviewSection(),
          ],
        ),
      ),
    );

    final Widget sources = SettingsSectionAnchor(
      title: t.font_library_section_sources,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(t.font_library_section_sources),
            FushiCard(
              pressScale: false,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  FontLibrarySourceRow(
                    key: const ValueKey<String>('font-source-file'),
                    icon: FushiIcons.importFile,
                    title: t.custom_fonts_import_file,
                    tone: FushiCardTone.primary,
                    onTap: _fontsLoading ? null : _importFontFile,
                  ),
                  FontLibrarySourceRow(
                    key: const ValueKey<String>('font-source-recommended'),
                    icon: FushiIcons.star,
                    title: t.custom_fonts_recommended,
                    tone: FushiCardTone.tertiary,
                    onTap: _fontsLoading ? null : _openRecommended,
                  ),
                  FontLibrarySourceRow(
                    key: const ValueKey<String>('font-source-system'),
                    icon: FushiIcons.textFields,
                    title: t.custom_fonts_add_system,
                    onTap: _fontsLoading ? null : _addSystemFont,
                  ),
                  FontLibrarySourceRow(
                    key: const ValueKey<String>('font-source-url'),
                    icon: FushiIcons.link,
                    title: t.custom_fonts_import_url,
                    onTap: _fontsLoading ? null : _importFromUrl,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return FushiEntranceScope(
      replayKey: '${_filter.name}|${layout.name}|${_query.trim()}',
      child: CustomScrollView(
        primary: true,
        slivers: <Widget>[
          SliverToBoxAdapter(child: toolbar),
          ..._buildFontSlivers(context, width, layout),
          SliverToBoxAdapter(child: preview),
          SliverToBoxAdapter(child: sources),
          // FAB 下方留白，最后一行不被扩展 FAB 挡住。
          const SliverToBoxAdapter(child: SizedBox(height: 112)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureResolved();
    final bool apple = isGlassDesign(context);
    return SettingsKitScaffold(
      // 带作用域进来时把用途写进标题：用户从「设置·游戏·Hook 文本字体」点进来，
      // 看到的是同一个全量字体库，不说明的话没法知道自己新导入的字体会挂到哪。
      title: widget.target == FontTarget.body
          ? t.custom_fonts_catalog_title
          : '${t.custom_fonts_catalog_title} · '
                '${fontTargetLabel(widget.target)}',
      leadingIcon: FushiIcons.font,
      leadingTone: SettingsIconTone.purple,
      actions: <Widget>[
        Builder(
          builder: (BuildContext context) {
            final bool grid =
                (_layoutOverride ??
                    (_wide || MediaQuery.sizeOf(context).width >= 600
                        ? FontLibraryLayout.grid
                        : FontLibraryLayout.list)) ==
                FontLibraryLayout.grid;
            return FushiIconButton(
              key: const ValueKey<String>('font-library-layout'),
              icon: grid ? FushiIcons.listView : FushiIcons.gridView,
              tooltip: grid
                  ? t.font_library_view_list
                  : t.font_library_view_grid,
              onTap: () => setState(
                () => _layoutOverride = grid
                    ? FontLibraryLayout.list
                    : FontLibraryLayout.grid,
              ),
            );
          },
        ),
        Builder(
          builder: (BuildContext anchorContext) => FushiIconButton(
            key: const ValueKey<String>('font-library-add-menu'),
            icon: FushiIcons.add,
            tooltip: t.font_library_more_sources,
            onTap: _fontsLoading ? null : () => _showAddMenu(anchorContext),
          ),
        ),
      ],
      floatingActionButton: FushiFab(
        key: const ValueKey<String>('font-library-import-fab'),
        icon: const FushiIcon(FushiIcons.importFile),
        label: Text(t.font_library_import_fab),
        tooltip: t.custom_fonts_import_file,
        onPressed: _fontsLoading ? null : _importFontFile,
      ),
      bodyBuilder: (
        BuildContext context,
        ScrollController controller,
        SettingsSectionSpy spy,
      ) {
        return FushiFileDropTarget(
          debugLabel: 'font-library',
          enabled: !_fontsLoading,
          onDrop: (List<String> paths, Offset _) => _importDroppedPaths(paths),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 1000;
              _wide = wide;
              final int detailIndex = wide && _detailIdentity != null
                  ? _indexOfIdentity(_detailIdentity!)
                  : -1;
              final bool showPanel = detailIndex >= 0;
              final double browserWidth = showPanel
                  ? constraints.maxWidth - _detailPanelWidth - 16
                  : constraints.maxWidth;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _buildBrowser(context, spy, browserWidth)),
                  AnimatedSwitcher(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    switchInCurve: FushiMotion.enter,
                    switchOutCurve: FushiMotion.exit,
                    transitionBuilder:
                        (Widget child, Animation<double> animation) =>
                            FadeTransition(
                      opacity: animation,
                      child: SizeTransition(
                        sizeFactor: animation,
                        axis: Axis.horizontal,
                        axisAlignment: -1,
                        child: child,
                      ),
                    ),
                    child: !showPanel
                        ? const SizedBox.shrink(key: ValueKey<String>('none'))
                        : Padding(
                            key: const ValueKey<String>('font-detail-side'),
                            padding: const EdgeInsetsDirectional.fromSTEB(
                              0,
                              4,
                              16,
                              16,
                            ),
                            child: SizedBox(
                              width: _detailPanelWidth,
                              child: Material(
                                color: apple
                                    ? appleColorsOf(context)
                                        .secondaryGroupedBackground
                                    : Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerLow,
                                shape: RoundedRectangleBorder(
                                  borderRadius: apple
                                      ? const BorderRadius.all(
                                          Radius.circular(12),
                                        )
                                      : FushiM3eShape.containerLargeRadius,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: _detailPanelFor(
                                  detailIndex,
                                  onClose: () =>
                                      setState(() => _detailIdentity = null),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

@visibleForTesting
class CustomFontDownloadProgressDialog extends StatelessWidget {
  const CustomFontDownloadProgressDialog({
    required this.title,
    required this.progressNotifier,
    required this.onCancel,
    super.key,
  });

  final String title;
  final ValueNotifier<double?> progressNotifier;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: title,
        leadingIcon: Icons.download_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<double?>(
          valueListenable: progressNotifier,
          builder: (_, progress, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FushiLinearProgressIndicator(value: progress),
              SizedBox(height: tokens.spacing.gap),
              Text(
                progress != null
                    ? '${(progress * 100).toStringAsFixed(0)}%'
                    : t.custom_fonts_downloading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.listSubtitle,
              ),
            ],
          ),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: onCancel,
              child: Text(t.dialog_cancel),
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
class CustomFontUrlImportDialog extends StatefulWidget {
  const CustomFontUrlImportDialog({super.key});

  @override
  State<CustomFontUrlImportDialog> createState() =>
      _CustomFontUrlImportDialogState();
}

class _CustomFontUrlImportDialogState extends State<CustomFontUrlImportDialog> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.72,
      child: FushiModalSheetFrame(
        title: t.custom_fonts_import_url,
        leadingIcon: Icons.link_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: FushiTextField(
          controller: _urlController,
          hintText: 'https://example.com/fonts.zip',
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () =>
                  Navigator.pop(context, _urlController.text.trim()),
              child: Text(t.dialog_import),
            ),
          ],
        ),
      ),
    );
  }
}

/// 推荐字体页：**默认就是多选**，不设「进入选择态」开关。
///
/// 这个页面唯一的用途就是挑字体下载，再要求先点一下「选择」纯属多余一步；词典
/// 下载弹窗也是同样形态（进去就是勾选列表），两处保持一致。
///
/// 返回 `List<RecommendedFont>`（取消为 null）。旧实现是 `Navigator.pop(context, font)`
/// 单值返回，选一个字体就把整页弹掉，想再下一个得重新进来——这正是要改掉的。
@visibleForTesting
class RecommendedFontsPage extends StatefulWidget {
  const RecommendedFontsPage({required this.alreadyAdded, super.key});
  final Set<String> alreadyAdded;

  @override
  State<RecommendedFontsPage> createState() => _RecommendedFontsPageState();
}

class _RecommendedFontsPageState extends State<RecommendedFontsPage> {
  final Set<String> _selected = <String>{};

  bool _isAdded(RecommendedFont font) => widget.alreadyAdded.any(
        (String name) => name.toLowerCase() == font.name.toLowerCase(),
      );

  /// 可勾选域：已装的不参与全选，与词典下载弹窗同判据——已经有的再下一遍只是
  /// 白跑一趟下载 + 导入。
  List<RecommendedFont> get _selectable =>
      recommendedFontsCatalog.where((f) => !_isAdded(f)).toList();

  void _toggle(RecommendedFont font) {
    setState(() {
      if (!_selected.remove(font.name)) _selected.add(font.name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<RecommendedFont> selectable = _selectable;
    return AdaptiveSettingsScaffold(
      title: Text(t.custom_fonts_recommended),
      bottom: _selected.isEmpty
          ? null
          : BatchActionBar(
              selectedCount: _selected.length,
              onSelectAll: () => setState(
                () => _selected.addAll(selectable.map((f) => f.name)),
              ),
              onInvertSelection: () => setState(() {
                final Set<String> next = <String>{
                  for (final RecommendedFont font in selectable)
                    if (!_selected.contains(font.name)) font.name,
                };
                _selected
                  ..clear()
                  ..addAll(next);
              }),
              actions: <Widget>[
                FushiIconButton(
                  key: const ValueKey<String>('recommended-fonts-download'),
                  tooltip: t.dialog_import,
                  icon: Icons.download_outlined,
                  onTap: () => Navigator.pop(
                    context,
                    <RecommendedFont>[
                      for (final RecommendedFont font in recommendedFontsCatalog)
                        if (_selected.contains(font.name)) font,
                    ],
                  ),
                ),
              ],
            ),
      children: [
        AdaptiveSettingsSection(
          children: recommendedFontsCatalog.map((font) {
            final bool added = _isAdded(font);
            final bool selected = _selected.contains(font.name);
            return AdaptiveSettingsRow(
              key: ValueKey<String>('recommended-font-${font.name}'),
              title: font.name,
              subtitle: '${font.nameJa}\n${font.description}',
              icon: Icons.font_download_outlined,
              onTap: added ? null : () => _toggle(font),
              trailing: added
                  ? FushiIcon(Icons.check, color: scheme.outline)
                  : FushiCheckbox(
                      value: selected,
                      onChanged: (_) => _toggle(font),
                    ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
