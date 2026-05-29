import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
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

// Google Fonts API 为主，jsDelivr CDN（中国可访问）为备选。
List<_RecommendedFont> get _recommendedFonts => [
      // ── 推荐首选 ──
      _RecommendedFont(
        name: 'Klee One',
        nameJa: 'クレー One',
        urls: [
          'https://fonts.google.com/download?family=Klee+One',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/kleeone/KleeOne-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_klee_one,
      ),
      // ── CJK 覆盖（日中韩通用，不会缺字） ──
      _RecommendedFont(
        name: 'Noto Sans JP',
        nameJa: 'Noto Sans 日本語',
        urls: [
          'https://fonts.google.com/download?family=Noto+Sans+JP',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_noto_sans_jp,
      ),
      _RecommendedFont(
        name: 'Noto Serif JP',
        nameJa: 'Noto Serif 日本語',
        urls: [
          'https://fonts.google.com/download?family=Noto+Serif+JP',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notoserifjp/NotoSerifJP%5Bwght%5D.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_noto_serif_jp,
      ),
      _RecommendedFont(
        name: 'Noto Sans SC',
        nameJa: 'Noto Sans 简体中文',
        urls: [
          'https://fonts.google.com/download?family=Noto+Sans+SC',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_noto_sans_sc,
      ),
      _RecommendedFont(
        name: 'Noto Serif SC',
        nameJa: 'Noto Serif 简体中文',
        urls: [
          'https://fonts.google.com/download?family=Noto+Serif+SC',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_noto_serif_sc,
      ),
      _RecommendedFont(
        name: 'Noto Sans TC',
        nameJa: 'Noto Sans 繁體中文',
        urls: [
          'https://fonts.google.com/download?family=Noto+Sans+TC',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_noto_sans_tc,
      ),
      // ── 日语特色字体（风格独特，建议搭配 Noto Sans JP 做回退） ──
      _RecommendedFont(
        name: 'Shippori Mincho',
        nameJa: 'しっぽり明朝',
        urls: [
          'https://fonts.google.com/download?family=Shippori+Mincho',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/shipporimincho/ShipporiMincho-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_shippori_mincho,
      ),
      _RecommendedFont(
        name: 'Zen Old Mincho',
        nameJa: '禅オールド明朝',
        urls: [
          'https://fonts.google.com/download?family=Zen+Old+Mincho',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenoldmincho/ZenOldMincho-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_zen_old_mincho,
      ),
      _RecommendedFont(
        name: 'Zen Maru Gothic',
        nameJa: '禅丸ゴシック',
        urls: [
          'https://fonts.google.com/download?family=Zen+Maru+Gothic',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenmarugothic/ZenMaruGothic-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_zen_maru_gothic,
      ),
      _RecommendedFont(
        name: 'M PLUS Rounded 1c',
        nameJa: 'M PLUS Rounded 1c',
        urls: [
          'https://fonts.google.com/download?family=M+PLUS+Rounded+1c',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mplusrounded1c/MPLUSRounded1c-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_mplus_rounded_1c,
      ),
      _RecommendedFont(
        name: 'Hina Mincho',
        nameJa: 'ひな明朝',
        urls: [
          'https://fonts.google.com/download?family=Hina+Mincho',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/hinamincho/HinaMincho-Regular.ttf',
        ],
        license: 'OFL 1.1',
        description: t.font_desc_hina_mincho,
      ),
      _RecommendedFont(
        name: 'Zen Kaku Gothic New',
        nameJa: '禅角ゴシック New',
        urls: [
          'https://fonts.google.com/download?family=Zen+Kaku+Gothic+New',
          'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenkakugothicnew/ZenKakuGothicNew-Regular.ttf',
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
    final q = query.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _allFonts
          : _allFonts.where((f) => f.toLowerCase().contains(q)).toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                if (added) {
                  return AdaptiveSettingsRow(
                    title: name,
                    icon: Icons.font_download_outlined,
                    trailing: Icon(Icons.check, color: scheme.outline),
                  );
                }
                return AdaptiveSettingsNavigationRow(
                  title: name,
                  icon: Icons.font_download_outlined,
                  onTap: () => Navigator.pop(context, name),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
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
  const CustomFontsPage({super.key});

  @override
  BasePageState createState() => _CustomFontsPageState();
}

class _CustomFontsPageState extends BasePageState {
  ReaderSettings? _settings;

  // HBK-AUDIT-116: typed in-memory model; converted to/from the persisted
  // `List<Map<String, dynamic>>` only at the ReaderSettings boundary below.
  List<CustomFontEntry> _fonts = [];

  static List<CustomFontEntry> _entriesFromSettings(ReaderSettings settings) =>
      settings.customFonts.map(CustomFontEntry.fromMap).toList();

  @override
  void initState() {
    super.initState();
    _settings = ReaderHibikiSource.readerSettings;
    if (_settings == null) {
      final rs = ReaderSettings(appModel.database);
      rs.refreshFromDb().then((_) {
        ReaderHibikiSource.readerSettings = rs;
        if (!mounted) return;
        setState(() => _fonts = _entriesFromSettings(rs));
      });
      _settings = rs;
    } else {
      _fonts = _entriesFromSettings(_settings!);
    }
  }

  Future<void> _save() async {
    await _settings!.setCustomFonts(_fonts.map((e) => e.toMap()).toList());
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
      HibikiToast.show(msg: t.custom_fonts_imported_count(count: count));
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
    final entry = CustomFontEntry(name: name, path: destPath, enabled: true);
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
          '${overrideName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}_${DateTime.now().millisecondsSinceEpoch}$ext',
        );
        File(destPath).writeAsBytesSync(entry.content as List<int>);
        final fontEntry =
            CustomFontEntry(name: overrideName, path: destPath, enabled: true);
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
        final fontEntry =
            CustomFontEntry(name: baseName, path: destPath, enabled: true);
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
      HibikiToast.show(msg: t.custom_fonts_archive_error);
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
        HibikiToast.show(msg: t.custom_fonts_imported_count(count: count));
      } else {
        HibikiToast.show(msg: t.custom_fonts_no_fonts_in_archive);
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
      _fonts.map((CustomFontEntry e) => e.name).toSet();

  Future<void> _openRecommended() async {
    final font = await Navigator.push<_RecommendedFont>(
      context,
      adaptivePageRoute(
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
        builder: (_) => _SystemFontPickerPage(alreadyAdded: _addedFontNames),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _fonts.add(CustomFontEntry(name: selected, path: null, enabled: true));
    });
    _save();
  }

  Future<void> _removeFont(int index) async {
    final CustomFontEntry entry = _fonts[index];
    final String? filePath = entry.path;
    setState(() => _fonts.removeAt(index));
    await _save();
    if (filePath != null) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (e, stack) {
        ErrorLogService.instance.log('CustomFontsPage.deleteFont', e, stack);
        debugPrint('[Hibiki] failed to delete font file $filePath: $e');
      }
    }
    HibikiToast.show(msg: t.custom_fonts_removed);
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final item = _fonts.removeAt(oldIndex);
      _fonts.insert(newIndex, item);
    });
    _save();
  }

  void _toggleFont(int index) {
    setState(() {
      _fonts[index] = _fonts[index].copyWith(enabled: !_fonts[index].enabled);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsScaffold(
      title: Text(t.custom_fonts),
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
              AdaptiveSettingsRow(
                title: t.custom_fonts_drag_hint,
                icon: Icons.info_outline,
              ),
              AdaptiveSettingsRow(
                title: t.custom_fonts_manage,
                icon: Icons.format_size,
                controlBelow: true,
                trailing: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: _fonts.length,
                  onReorder: _onReorder,
                  itemBuilder: (context, index) {
                    final CustomFontEntry entry = _fonts[index];
                    return _FontTile(
                      key: ValueKey('${entry.name}-$index'),
                      name: entry.name,
                      isFile: entry.isFile,
                      enabled: entry.enabled,
                      index: index,
                      onToggle: () => _toggleFont(index),
                      onDelete: () => _removeFont(index),
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

class _FontTile extends StatelessWidget {
  const _FontTile({
    required this.name,
    required this.isFile,
    required this.enabled,
    required this.index,
    required this.onToggle,
    required this.onDelete,
    super.key,
  });

  final String name;
  final bool isFile;
  final bool enabled;
  final int index;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AdaptiveSettingsSwitchActionRow(
      title: name,
      subtitle: isFile ? t.font_source_file : t.font_source_system,
      icon: isFile ? Icons.file_present_outlined : Icons.phone_android_outlined,
      value: enabled,
      onChanged: (_) => onToggle(),
      actions: [
        ReorderableDragStartListener(
          index: index,
          child: const Icon(Icons.drag_handle),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: t.custom_fonts_removed,
          onPressed: onDelete,
        ),
      ],
    );
  }
}
