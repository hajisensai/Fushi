import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/media_search_text.dart';
import 'package:hibiki/src/reader/font_catalog.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

const _fontExtensions = {'.ttf', '.otf', '.ttc', '.woff', '.woff2'};

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

  CustomFontEntry copyWith({bool? enabled}) => CustomFontEntry(
        name: name,
        path: path,
        enabled: enabled ?? this.enabled,
      );
}

@visibleForTesting
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

@visibleForTesting
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

@visibleForTesting
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

@visibleForTesting
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
    final int? value =
        match == null ? null : int.tryParse(match.group(1) ?? '');
    if (value != null && value >= next) {
      next = value + 1;
    }
  }
  return next;
}

class _RecommendedFont {
  _RecommendedFont({
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
List<_RecommendedFont> get _recommendedFonts => [
      // ── 推荐首选 ──
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
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
      _RecommendedFont(
        name: 'Shippori Mincho',
        nameJa: 'しっぽり明朝',
        urls: [
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/shipporimincho/ShipporiMincho-Regular.ttf',
          'https://fonts.google.com/download?family=Shippori+Mincho',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_shippori_mincho,
      ),
      _RecommendedFont(
        name: 'Zen Old Mincho',
        nameJa: '禅オールド明朝',
        urls: [
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenoldmincho/ZenOldMincho-Regular.ttf',
          'https://fonts.google.com/download?family=Zen+Old+Mincho',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_zen_old_mincho,
      ),
      _RecommendedFont(
        name: 'Zen Maru Gothic',
        nameJa: '禅丸ゴシック',
        urls: [
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenmarugothic/ZenMaruGothic-Regular.ttf',
          'https://fonts.google.com/download?family=Zen+Maru+Gothic',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_zen_maru_gothic,
      ),
      _RecommendedFont(
        name: 'M PLUS Rounded 1c',
        nameJa: 'M PLUS Rounded 1c',
        urls: [
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mplusrounded1c/MPLUSRounded1c-Regular.ttf',
          'https://fonts.google.com/download?family=M+PLUS+Rounded+1c',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_mplus_rounded_1c,
      ),
      _RecommendedFont(
        name: 'Hina Mincho',
        nameJa: 'ひな明朝',
        urls: [
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/hinamincho/HinaMincho-Regular.ttf',
          'https://fonts.google.com/download?family=Hina+Mincho',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_hina_mincho,
      ),
      _RecommendedFont(
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

bool _isFontFile(String path) {
  return _fontExtensions.contains(p.extension(path).toLowerCase());
}

// ── 系统字体扫描 ─────────────────────────────────────────────────────────────

const _fontsChannel = HibikiChannels.fonts;
List<String>? _cachedSystemFonts;

Future<List<String>> _getSystemFonts() async {
  if (_cachedSystemFonts != null && _cachedSystemFonts!.isNotEmpty) {
    return _cachedSystemFonts!;
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    _cachedSystemFonts = await _getDesktopSystemFonts();
  } else {
    try {
      final result =
          await _fontsChannel.invokeMethod<List<dynamic>>('listSystemFonts');
      debugPrint('[hibiki-fonts] channel returned ${result?.length} fonts');
      _cachedSystemFonts = result?.cast<String>() ?? [];
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.listSystemFonts', e, stack);
      debugPrint('[hibiki-fonts] channel error: $e');
      _cachedSystemFonts = [];
    }
  }
  return _cachedSystemFonts!;
}

Future<List<String>> _getDesktopSystemFonts() async {
  final fontDirs = <String>[];
  if (Platform.isWindows) {
    fontDirs.add(r'C:\Windows\Fonts');
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      fontDirs.add(p.join(localAppData, r'Microsoft\Windows\Fonts'));
    }
  } else if (Platform.isMacOS) {
    fontDirs.addAll(['/System/Library/Fonts', '/Library/Fonts']);
    final home = Platform.environment['HOME'];
    if (home != null) fontDirs.add('$home/Library/Fonts');
  } else if (Platform.isLinux) {
    fontDirs.addAll(['/usr/share/fonts', '/usr/local/share/fonts']);
    final home = Platform.environment['HOME'];
    if (home != null) fontDirs.add('$home/.local/share/fonts');
  }

  final names = <String>{};
  for (final dirPath in fontDirs) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) continue;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (!_fontExtensions.contains(ext)) continue;
        final name = p
            .basenameWithoutExtension(entity.path)
            .replaceAll(RegExp(r'[-_]'), ' ')
            .replaceAll(
                RegExp(
                    r'\s+(Regular|Bold|Italic|Light|Medium|Thin|'
                    r'Black|ExtraBold|SemiBold|ExtraLight|Condensed|Expanded)$',
                    caseSensitive: false),
                '');
        if (name.isNotEmpty) names.add(name);
      }
    } catch (e) {
      debugPrint('[hibiki-fonts] error scanning $dirPath: $e');
    }
  }
  final sorted = names.toList()..sort();
  debugPrint('[hibiki-fonts] desktop scan found ${sorted.length} fonts');
  return sorted;
}

// ── 系统字体选择页 ────────────────────────────────────────────────────────────

class _SystemFontPickerPage extends StatefulWidget {
  const _SystemFontPickerPage({required this.alreadyAdded});
  final Set<String> alreadyAdded;

  @override
  State<_SystemFontPickerPage> createState() => _SystemFontPickerPageState();
}

class _SystemFontPickerPageState extends State<_SystemFontPickerPage> {
  List<String> _allFonts = [];
  List<String> _filtered = [];
  bool _loading = true;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    final fonts = await _getSystemFonts();
    if (!mounted) return;
    setState(() {
      _allFonts = fonts;
      _filtered = fonts;
      _loading = false;
    });
  }

  void _onSearch(String query) {
    // G6：与库页搜索同一归一化口径（日文字体族名常含全角/片假名差异）。
    setState(() {
      _filtered =
          filterByMediaSearch(_allFonts, query, (String f) => <String>[f]);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> fontRows = _loading
        ? <Widget>[
            AdaptiveSettingsRow(
              title: t.custom_fonts_downloading,
              icon: Icons.hourglass_empty,
              trailing: adaptiveIndicator(context: context),
            ),
          ]
        : _filtered.isEmpty
            ? <Widget>[
                AdaptiveSettingsRow(
                  title: t.custom_fonts_empty,
                  icon: Icons.font_download_outlined,
                ),
              ]
            : _filtered.map((String name) {
                final bool added = widget.alreadyAdded.contains(name);
                // Single-choice list: added fonts show a trailing check,
                // pickable fonts are plain tappable rows. No navigation chevron
                // — tapping pops this page with the font name, it does not drill
                // into a subpage, so a `chevron_right` would falsely imply one.
                return AdaptiveSettingsRow(
                  title: name,
                  icon: Icons.font_download_outlined,
                  trailing:
                      added ? Icon(Icons.check, color: scheme.outline) : null,
                  onTap: added ? null : () => Navigator.pop(context, name),
                );
              }).toList();

    return AdaptiveSettingsScaffold(
      title: Text(t.custom_fonts_add_system),
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsRow(
              title: t.custom_fonts_search_hint,
              icon: Icons.search,
              controlBelow: true,
              trailing: SizedBox(
                width: double.infinity,
                child: HibikiTextField(
                  controller: _searchController,
                  hintText: t.custom_fonts_search_hint,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.rowHorizontal,
                    vertical: tokens.spacing.rowVertical,
                  ),
                  onChanged: _onSearch,
                ),
              ),
            ),
          ],
        ),
        AdaptiveSettingsSection(children: fontRows),
      ],
    );
  }
}

// ── 主页面 ────────────────────────────────────────────────────────────────────

class CustomFontsPage extends BasePage {
  /// TODO-049: which of the three independent font targets this page manages.
  /// Defaults to [FontTarget.body] so the legacy reader call site is unchanged.
  const CustomFontsPage({super.key, this.target = FontTarget.body});

  final FontTarget target;

  @override
  BasePageState createState() => _CustomFontsPageState();
}

/// 阅读器设置的 DB 偏好 key：经单一真相编码器 [dbSourcePrefKey]（`reader_ttu`
/// 是冻结的历史 sourceId，旧数据兼容，勿改）。
String _readerPrefKey(String shortKey) =>
    dbSourcePrefKey(kReaderSourcePersistedKey, shortKey);

class _CustomFontsPageState extends BasePageState {
  ReaderSettings? _settings;

  List<CustomFontCatalogRow> _fonts = [];

  @override
  void initState() {
    super.initState();
    _settings = ReaderHibikiSource.readerSettings;
    if (_settings == null) {
      final rs = ReaderSettings(appModel.database);
      rs.refreshFromDb().then((_) {
        ReaderHibikiSource.readerSettings = rs;
        if (!mounted) return;
        _loadFonts(rs);
      });
      _settings = rs;
    } else {
      _loadFonts(_settings!);
    }
  }

  Future<void> _loadFonts(ReaderSettings settings) async {
    final FontCatalogState state = await _readCatalogState(settings);
    if (!mounted) return;
    setState(() => _fonts = customFontCatalogRowsFromState(state));
  }

  Future<FontCatalogState> _readCatalogState(ReaderSettings settings) async {
    final String? catalogJson = await appModel.database.getPref(
      _readerPrefKey(ReaderSettings.fontCatalogKey),
    );
    final String? targetsJson = await appModel.database.getPref(
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
        ReaderSettings.fontKeyForTarget(target):
            settings.fontsForTarget(target),
    });
  }

  Future<void> _save() async {
    final FontCatalogState state = customFontCatalogStateFromRows(_fonts);
    final Map<String, List<Map<String, dynamic>>> legacy =
        customFontLegacyListsFromRows(_fonts);

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
    await _settings!.refreshFromDb();
    await appModel.refreshAppFont();
    ReaderHibikiSource.onSettingsChangedLive?.call();
  }

  Directory get _fontsDir {
    final dir = Directory(p.join(appModel.appDirectory.path, 'custom_fonts'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _importFontFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'ttf',
        'otf',
        'ttc',
        'woff',
        'woff2',
        'zip',
        '7z',
        'rar',
        'tar',
        'gz'
      ],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    int count = 0;
    for (final picked in result.files) {
      if (picked.path == null) continue;
      final ext = p.extension(picked.name).toLowerCase();

      if (_fontExtensions.contains(ext)) {
        count += await _addSingleFont(File(picked.path!), picked.name);
      } else {
        count += await _extractFontsFromArchive(File(picked.path!));
      }
    }

    if (count > 0) {
      await _save();
      HibikiToast.show(
        msg: t.custom_fonts_imported_count(count: count),
        severity: ToastSeverity.success,
      );
    }
  }

  Future<int> _addSingleFont(
    File srcFile,
    String fileName, {
    String? overrideName,
  }) async {
    final name = overrideName ?? p.basenameWithoutExtension(fileName);
    var ext = p.extension(fileName).toLowerCase();
    if (!_fontExtensions.contains(ext)) {
      ext = await _detectFontExtension(srcFile) ?? '.ttf';
    }
    final destPath = p.join(
        _fontsDir.path, '${name}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await srcFile.copy(destPath);
    final entry = CustomFontCatalogRow(
      id: null,
      name: name,
      path: destPath,
      targetEnabled: <FontTarget, bool>{FontTarget.body: true},
    );
    if (mounted) {
      setState(() => _fonts.add(entry));
    } else {
      _fonts.add(entry);
    }
    return 1;
  }

  Future<String?> _detectFontExtension(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(8);
        if (header.length < 4) return null;
        // wOFF
        if (header[0] == 0x77 &&
            header[1] == 0x4F &&
            header[2] == 0x46 &&
            header[3] == 0x46) {
          return header.length >= 8 &&
                  header[4] == 0x00 &&
                  header[5] == 0x01 &&
                  header[6] == 0x00 &&
                  header[7] == 0x00
              ? '.woff'
              : '.woff2';
        }
        // TrueType / OpenType
        if (header[0] == 0x00 &&
            header[1] == 0x01 &&
            header[2] == 0x00 &&
            header[3] == 0x00) {
          return '.ttf';
        }
        if (header[0] == 0x4F &&
            header[1] == 0x54 &&
            header[2] == 0x54 &&
            header[3] == 0x4F) {
          return '.otf';
        }
        // TTC
        if (header[0] == 0x74 &&
            header[1] == 0x74 &&
            header[2] == 0x63 &&
            header[3] == 0x66) {
          return '.ttc';
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.detectFontExt', e, stack);
      return null;
    }
  }

  Future<bool> _isValidFontFile(File file) async {
    return await _detectFontExtension(file) != null;
  }

  Future<bool> _isZipFile(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(4);
        return header.length >= 4 &&
            header[0] == 0x50 &&
            header[1] == 0x4B &&
            header[2] == 0x03 &&
            header[3] == 0x04;
      } finally {
        await raf.close();
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.isZipArchive', e, stack);
      return false;
    }
  }

  Future<int> _extractFontsFromArchive(
    File archiveFile, {
    String? overrideName,
  }) async {
    try {
      final bytes = await archiveFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final fontEntries = archive.files
          .where((entry) => entry.isFile && _isFontFile(entry.name))
          .toList();
      if (overrideName != null && fontEntries.isNotEmpty) {
        final entry = fontEntries.firstWhere(
          (entry) {
            final base = p.basenameWithoutExtension(entry.name).toLowerCase();
            return base.contains('regular') || base.contains('[wght]');
          },
          orElse: () => fontEntries.first,
        );
        final ext = p.extension(entry.name);
        final destPath = p.join(
          _fontsDir.path,
          '${safeWindowsFileName(overrideName)}_${DateTime.now().millisecondsSinceEpoch}$ext',
        );
        File(destPath).writeAsBytesSync(entry.content as List<int>);
        final fontEntry = CustomFontCatalogRow(
          id: null,
          name: overrideName,
          path: destPath,
          targetEnabled: <FontTarget, bool>{FontTarget.body: true},
        );
        if (mounted) {
          setState(() => _fonts.add(fontEntry));
        } else {
          _fonts.add(fontEntry);
        }
        return 1;
      }

      int count = 0;
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (final entry in fontEntries) {
        final baseName = p.basenameWithoutExtension(entry.name);
        final ext = p.extension(entry.name);
        final destPath = p.join(_fontsDir.path, '${baseName}_$ts$ext');
        File(destPath).writeAsBytesSync(entry.content as List<int>);
        final fontEntry = CustomFontCatalogRow(
          id: null,
          name: baseName,
          path: destPath,
          targetEnabled: <FontTarget, bool>{FontTarget.body: true},
        );
        if (mounted) {
          setState(() => _fonts.add(fontEntry));
        } else {
          _fonts.add(fontEntry);
        }
        count++;
      }
      return count;
    } catch (e, stack) {
      ErrorLogService.instance.log('CustomFontsPage.extractArchive', e, stack);
      debugPrint('[hibiki-fonts] archive extract failed: $e');
      HibikiToast.show(
        msg: t.custom_fonts_archive_error,
        severity: ToastSeverity.error,
      );
      return 0;
    }
  }

  Future<void> _downloadUrl(String url,
      {String? displayName,
      List<String> mirrorUrls = const [],
      String? overrideName}) async {
    final allUrls = [url, ...mirrorUrls];
    final ts = DateTime.now().millisecondsSinceEpoch;
    final tempPath = p.join(_fontsDir.path, '_tmp_$ts');
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
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 10),
        followRedirects: true,
        maxRedirects: 10,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android) Hibiki/1.0',
          'Accept': '*/*',
        },
      ));

      String? downloadedUrl;
      Object? lastError;
      for (int i = 0; i < allUrls.length; i++) {
        final currentUrl = allUrls[i];
        debugPrint(
            '[hibiki-fonts] trying source ${i + 1}/${allUrls.length}: $currentUrl');
        progressNotifier.value = null;
        try {
          await dio.download(
            currentUrl,
            tempPath,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (total > 0) {
                progressNotifier.value = received / total;
              }
            },
          );
          final tempFile = File(tempPath);
          if (await tempFile.exists() &&
              !await _isZipFile(tempFile) &&
              !await _isValidFontFile(tempFile)) {
            debugPrint(
                '[hibiki-fonts] source ${i + 1} returned non-font data, skipping');
            lastError =
                Exception('Downloaded file is not a valid font or archive');
            await tempFile.delete();
            continue;
          }
          downloadedUrl = currentUrl;
          break;
        } on DioError catch (e) {
          if (e.type == DioErrorType.cancel) rethrow;
          lastError = e;
          debugPrint('[hibiki-fonts] source ${i + 1} failed: ${e.type.name}');
          final f = File(tempPath);
          if (await f.exists()) await f.delete();
        }
      }

      if (downloadedUrl == null) {
        final Object err = lastError ?? Exception('All sources failed');
        if (err is Exception) throw err;
        if (err is Error) throw err;
        throw Exception(err.toString());
      }

      if (mounted) Navigator.pop(context);

      final tempFile = File(tempPath);
      final fileName = _fileNameFromUrl(downloadedUrl);
      int count = 0;
      final isZip = await _isZipFile(tempFile);
      if (isZip) {
        count = await _extractFontsFromArchive(
          tempFile,
          overrideName: overrideName,
        );
        if (count == 0) {
          count = await _addSingleFont(
            tempFile,
            fileName,
            overrideName: overrideName,
          );
        }
      } else {
        count = await _addSingleFont(
          tempFile,
          fileName,
          overrideName: overrideName,
        );
      }
      if (await tempFile.exists()) await tempFile.delete();

      if (count > 0) {
        await _save();
        HibikiToast.show(
          msg: t.custom_fonts_imported_count(count: count),
          severity: ToastSeverity.success,
        );
      } else {
        HibikiToast.show(
          msg: t.custom_fonts_no_fonts_in_archive,
          severity: ToastSeverity.error,
        );
      }
    } on DioError catch (e, stack) {
      if (mounted) Navigator.pop(context);
      if (e.type != DioErrorType.cancel) {
        debugPrint('[hibiki-fonts] DioError: type=${e.type} '
            'status=${e.response?.statusCode} msg=${e.message}');
        debugPrint('[hibiki-fonts] stack: $stack');
        HibikiToast.show(
          msg: '${t.custom_fonts_download_failed}: ${e.type.name}',
          toastLength: Toast.LENGTH_LONG,
          severity: ToastSeverity.error,
        );
      }
      final f = File(tempPath);
      if (await f.exists()) await f.delete();
    } catch (e, stack) {
      if (mounted) Navigator.pop(context);
      debugPrint('[hibiki-fonts] download failed: $e');
      debugPrint('[hibiki-fonts] stack: $stack');
      HibikiToast.show(
        msg: '${t.custom_fonts_download_failed}: $e',
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.error,
      );
      final f = File(tempPath);
      if (await f.exists()) await f.delete();
    } finally {
      progressNotifier.dispose();
    }
  }

  String _fileNameFromUrl(String url) {
    final uri = Uri.parse(url);
    // Google Fonts download API: ?family=Font+Name → derive filename from query
    if (uri.queryParameters.containsKey('family')) {
      final family = uri.queryParameters['family']!.replaceAll(' ', '_');
      return '$family.zip';
    }
    if (uri.pathSegments.isNotEmpty) {
      return Uri.decodeComponent(uri.pathSegments.last);
    }
    return 'font_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _importFromUrl() async {
    final url = await showAppDialog<String>(
      context: context,
      builder: (ctx) => const CustomFontUrlImportDialog(),
    );
    if (url == null || url.isEmpty) return;
    await _downloadUrl(url);
  }

  Future<void> _downloadRecommendedFont(_RecommendedFont font) async {
    await _downloadUrl(
      font.urls.first,
      displayName: font.name,
      mirrorUrls: font.urls.skip(1).toList(),
      overrideName: font.name,
    );
  }

  // HBK-AUDIT-109: one canonical dedupe key (the display name) shared by both
  // pickers. Previously the recommended picker keyed on ALL names while the
  // system picker keyed only on system fonts (`path == null`), so a file font
  // and a system font sharing a name disagreed about what was "already added".
  Set<String> get _addedFontNames =>
      _fonts.map((CustomFontCatalogRow e) => e.name).toSet();

  Future<void> _openRecommended() async {
    final font = await Navigator.push<_RecommendedFont>(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => _RecommendedFontsPage(
          alreadyAdded: _addedFontNames,
        ),
      ),
    );
    if (font == null || !mounted) return;
    await _downloadRecommendedFont(font);
  }

  Future<void> _addSystemFont() async {
    final selected = await Navigator.push<String>(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => _SystemFontPickerPage(alreadyAdded: _addedFontNames),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _fonts.add(CustomFontCatalogRow(
        id: null,
        name: selected,
        path: null,
        targetEnabled: <FontTarget, bool>{FontTarget.body: true},
      ));
    });
    _save();
  }

  Future<void> _removeFont(int index) async {
    final CustomFontCatalogRow entry = _fonts[index];
    final String? filePath = entry.path;
    setState(() => _fonts.removeAt(index));
    await _save();
    if (filePath != null && !customFontFileStillReferenced(_fonts, filePath)) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (e, stack) {
        ErrorLogService.instance.log('CustomFontsPage.deleteFont', e, stack);
        debugPrint('[Hibiki] failed to delete font file $filePath: $e');
      }
    }
    HibikiToast.show(
      msg: t.custom_fonts_removed,
      severity: ToastSeverity.success,
    );
  }

  /// [newIndex] 是**最终下标**（HibikiReorderableColumn 语义），不是 SDK
  /// `ReorderableListView` 的「移除前下标」——故这里没有 `newIndex--` 修正。
  /// 上/下移按钮同样按最终下标传（下移传 index+1）。
  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
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

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsScaffold(
      title: Text(t.custom_fonts_catalog_title),
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsNavigationRow(
              title: t.custom_fonts_recommended,
              icon: Icons.star_outline,
              onTap: _openRecommended,
            ),
            AdaptiveSettingsNavigationRow(
              title: t.custom_fonts_add_system,
              icon: Icons.text_fields,
              onTap: _addSystemFont,
            ),
            AdaptiveSettingsNavigationRow(
              title: t.custom_fonts_import_file,
              icon: Icons.file_open_outlined,
              onTap: _importFontFile,
            ),
            AdaptiveSettingsNavigationRow(
              title: t.custom_fonts_import_url,
              icon: Icons.link,
              onTap: _importFromUrl,
            ),
          ],
        ),
        if (_fonts.isEmpty)
          AdaptiveSettingsSection(
            title: t.custom_fonts_manage,
            children: [
              AdaptiveSettingsRow(
                title: t.custom_fonts_empty,
                icon: Icons.font_download_outlined,
              ),
            ],
          )
        else
          AdaptiveSettingsSection(
            title: t.custom_fonts_manage,
            children: [
              // 拖拽提示不再单列一行：每行左侧的 ☰ 手柄（见 CustomFontCatalogTile）
              // 直接把「可拖拽重排」这件事画出来，比一句纯文字更直观。
              AdaptiveSettingsRow(
                title: t.custom_fonts_manage,
                icon: Icons.format_size,
                controlBelow: true,
                // 自实现的 HibikiReorderableColumn 而非 SDK ReorderableListView：
                // 整棵树活在 HibikiAppUiScale 的 Transform.scale 之下，而 SDK 的
                // _DragItemProxy 用「全局坐标 − overlay 原点」纯平移、不认祖先
                // 缩放，「界面大小」非 100% 时拖拽浮层按 (1−s)×距离 漂移、缩小时
                // 一拖即飞出屏幕（BUG-778 同根因，当时只修了合集与词典两条链路，
                // 这里漏了）。原本就是 shrinkWrap + NeverScrollableScrollPhysics
                //（外层滚动），与本组件语义一致。
                trailing: HibikiReorderableColumn(
                  itemCount: _fonts.length,
                  keyForIndex: (int index) =>
                      ValueKey<String>('${_fonts[index].name}-$index'),
                  onReorder: _onReorder,
                  itemBuilder: (context, index) {
                    final CustomFontCatalogRow entry = _fonts[index];
                    return CustomFontCatalogTile(
                      name: entry.name,
                      isFile: entry.isFile,
                      targets: entry.targets,
                      index: index,
                      isLast: index == _fonts.length - 1,
                      onTargetToggled: (FontTarget target) =>
                          _toggleTarget(index, target),
                      onDelete: () => _removeFont(index),
                      onMoveUp: () => _onReorder(index, index - 1),
                      onMoveDown: () => _onReorder(index, index + 1),
                    );
                  },
                ),
              ),
            ],
          ),
      ],
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: HibikiModalSheetFrame(
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
              LinearProgressIndicator(value: progress),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
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
        body: HibikiTextField(
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

class _RecommendedFontsPage extends StatelessWidget {
  const _RecommendedFontsPage({required this.alreadyAdded});
  final Set<String> alreadyAdded;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AdaptiveSettingsScaffold(
      title: Text(t.custom_fonts_recommended),
      children: [
        AdaptiveSettingsSection(
          children: _recommendedFonts.map((font) {
            final bool added = alreadyAdded.any(
              (String name) => name.toLowerCase() == font.name.toLowerCase(),
            );
            return AdaptiveSettingsRow(
              title: font.name,
              subtitle: '${font.nameJa}\n${font.description}',
              icon: Icons.font_download_outlined,
              trailing: added
                  ? Icon(Icons.check, color: scheme.outline)
                  : IconButton.filledTonal(
                      icon: const Icon(Icons.download_outlined, size: 20),
                      tooltip: t.dialog_import,
                      onPressed: () => Navigator.pop(context, font),
                    ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

@visibleForTesting
class CustomFontCatalogTile extends StatefulWidget {
  const CustomFontCatalogTile({
    required this.name,
    required this.isFile,
    required this.targets,
    required this.index,
    required this.isLast,
    required this.onTargetToggled,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final String name;
  final bool isFile;
  final Set<FontTarget> targets;
  final int index;
  final bool isLast;
  final ValueChanged<FontTarget> onTargetToggled;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  State<CustomFontCatalogTile> createState() => _CustomFontCatalogTileState();
}

class _CustomFontCatalogTileState extends State<CustomFontCatalogTile> {
  // 4 个字体用途开关（System UI / Novel Text / Dictionary / Video Subtitle）
  // 默认折叠：每行不再被四枚 FilterChip 撑高，一屏能看到更多字体。展开后才显示。
  bool _rolesExpanded = false;

  String _targetLabel(FontTarget target) => switch (target) {
        FontTarget.appUi => t.font_target_app_ui,
        FontTarget.body => t.font_target_body,
        FontTarget.dictionary => t.font_target_dictionary,
        FontTarget.videoSubtitle => t.font_target_video_subtitle,
      };

  /// 折叠态摘要：把已启用的用途拼成一行，用户不展开也能一眼看到该字体用在哪。
  String get _rolesSummary => <String>[
        for (final FontTarget target in FontTarget.values)
          if (widget.targets.contains(target)) _targetLabel(target),
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool cupertino = isCupertinoPlatform(context);
    final TextStyle? titleStyle = cupertino
        ? tokens.type.listTitle
        : Theme.of(context).textTheme.bodyMedium;
    final TextStyle? subtitleStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            );
    // ☰ 拖拽手柄：整行本就可拖（外层 HibikiReorderDragListener——桌面按下即拖、
    // 移动端长按再拖），这枚手柄是把「可拖拽重排」画出来的视觉锚点，替代原先
    // 单列一行的「拖拽以调整优先级」文字提示。
    final Widget dragHandle = Tooltip(
      message: t.custom_fonts_drag_hint,
      child: Padding(
        padding: EdgeInsets.only(right: tokens.spacing.gap),
        child: Icon(
          Icons.drag_indicator,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final Widget actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HibikiIconButton(
          icon: Icons.keyboard_arrow_up,
          size: 18,
          tooltip: t.move_up,
          enabled: widget.index > 0,
          onTap: widget.onMoveUp,
        ),
        SizedBox(width: tokens.spacing.gap),
        HibikiIconButton(
          icon: Icons.keyboard_arrow_down,
          size: 18,
          tooltip: t.move_down,
          enabled: !widget.isLast,
          onTap: widget.onMoveDown,
        ),
        SizedBox(width: tokens.spacing.gap),
        HibikiIconButton(
          icon: Icons.delete_outline,
          size: 18,
          enabledColor: scheme.error,
          tooltip: t.custom_fonts_removed,
          onTap: widget.onDelete,
        ),
      ],
    );
    // 折叠头：点一下展开/收起 4 个用途开关。用普通 Icon（非 HibikiIconButton）
    // 与 InkWell，避免破坏「每行恰好 3 个动作按钮」的布局守卫。
    final Widget rolesHeader = InkWell(
      onTap: () => setState(() => _rolesExpanded = !_rolesExpanded),
      borderRadius: tokens.radii.controlRadius,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          children: [
            Icon(
              _rolesExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(width: tokens.spacing.gap),
            Text(t.custom_fonts_font_roles, style: subtitleStyle),
            if (!_rolesExpanded && _rolesSummary.isNotEmpty) ...[
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  _rolesSummary,
                  style: subtitleStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    // 不再自带拖拽监听：整行拖拽由外层 HibikiReorderableColumn 统一接管
    //（它按输入设备分流起拖：鼠标按下即拖、触摸长按），行内容保持纯净。
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: cupertino ? 16 : 12,
        vertical: 10,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: cupertino ? 58 : 60),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                dragHandle,
                Expanded(
                  child: Text(
                    widget.name,
                    style: titleStyle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                actions,
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                widget.isFile ? t.font_source_file : t.font_source_system,
                style: subtitleStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            rolesHeader,
            if (_rolesExpanded) ...[
              SizedBox(height: tokens.spacing.gap),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: [
                  for (final FontTarget target in FontTarget.values)
                    FilterChip(
                      label: Text(_targetLabel(target)),
                      selected: widget.targets.contains(target),
                      onSelected: (_) => widget.onTargetToggled(target),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
