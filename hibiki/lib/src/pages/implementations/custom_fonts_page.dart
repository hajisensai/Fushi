import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

const _fontExtensions = {'.ttf', '.otf', '.ttc', '.woff', '.woff2'};

class _RecommendedFont {
  final String name;
  final String nameJa;
  final List<String> urls;
  final String license;
  final String description;
  const _RecommendedFont({
    required this.name,
    required this.nameJa,
    required this.urls,
    required this.license,
    required this.description,
  });
}

// Google Fonts API 为主，jsDelivr CDN（中国可访问）为备选。
const _recommendedFonts = [
  // ── 推荐首选 ──
  _RecommendedFont(
    name: 'Klee One',
    nameJa: 'クレー One',
    urls: [
      'https://fonts.google.com/download?family=Klee+One',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/kleeone/KleeOne-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '手写教科书体 · 清晰易读 · 建议搭配 Noto Sans JP 回退',
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
    description: 'Google/Adobe 黑体 · 日语字形优先 · 可变字重',
  ),
  _RecommendedFont(
    name: 'Noto Serif JP',
    nameJa: 'Noto Serif 日本語',
    urls: [
      'https://fonts.google.com/download?family=Noto+Serif+JP',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notoserifjp/NotoSerifJP%5Bwght%5D.ttf',
    ],
    license: 'OFL 1.1',
    description: 'Google/Adobe 宋体 · 日语字形优先 · 适合竖排阅读',
  ),
  _RecommendedFont(
    name: 'Noto Sans SC',
    nameJa: 'Noto Sans 简体中文',
    urls: [
      'https://fonts.google.com/download?family=Noto+Sans+SC',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf',
    ],
    license: 'OFL 1.1',
    description: 'Google/Adobe 黑体 · 简中字形优先 · 搭配日文字体做回退',
  ),
  _RecommendedFont(
    name: 'Noto Serif SC',
    nameJa: 'Noto Serif 简体中文',
    urls: [
      'https://fonts.google.com/download?family=Noto+Serif+SC',
    ],
    license: 'OFL 1.1',
    description: 'Google/Adobe 宋体 · 简中字形优先 · 搭配日文字体做回退',
  ),
  _RecommendedFont(
    name: 'Noto Sans TC',
    nameJa: 'Noto Sans 繁體中文',
    urls: [
      'https://fonts.google.com/download?family=Noto+Sans+TC',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf',
    ],
    license: 'OFL 1.1',
    description: 'Google/Adobe 黑体 · 繁中字形优先',
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
    description: '优雅明朝体 · 文学作品推荐 · 建议搭配 Noto Sans JP 回退',
  ),
  _RecommendedFont(
    name: 'Zen Old Mincho',
    nameJa: '禅オールド明朝',
    urls: [
      'https://fonts.google.com/download?family=Zen+Old+Mincho',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenoldmincho/ZenOldMincho-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '复古明朝体 · 古典文学风格 · 建议搭配 Noto Sans JP 回退',
  ),
  _RecommendedFont(
    name: 'Zen Maru Gothic',
    nameJa: '禅丸ゴシック',
    urls: [
      'https://fonts.google.com/download?family=Zen+Maru+Gothic',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenmarugothic/ZenMaruGothic-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '柔和圆润黑体 · 建议搭配 Noto Sans JP 回退',
  ),
  _RecommendedFont(
    name: 'M PLUS Rounded 1c',
    nameJa: 'M PLUS Rounded 1c',
    urls: [
      'https://fonts.google.com/download?family=M+PLUS+Rounded+1c',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/mplusrounded1c/MPLUSRounded1c-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '圆角可爱风格 · 适合轻小说 · 建议搭配 Noto Sans JP 回退',
  ),
  _RecommendedFont(
    name: 'Hina Mincho',
    nameJa: 'ひな明朝',
    urls: [
      'https://fonts.google.com/download?family=Hina+Mincho',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/hinamincho/HinaMincho-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '柔和装饰性明朝体 · 建议搭配 Noto Sans JP 回退',
  ),
  _RecommendedFont(
    name: 'Zen Kaku Gothic New',
    nameJa: '禅角ゴシック New',
    urls: [
      'https://fonts.google.com/download?family=Zen+Kaku+Gothic+New',
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/zenkakugothicnew/ZenKakuGothicNew-Regular.ttf',
    ],
    license: 'OFL 1.1',
    description: '现代角黑体 · 通用阅读 · 建议搭配 Noto Sans JP 回退',
  ),
];

bool _isFontFile(String path) {
  return _fontExtensions.contains(p.extension(path).toLowerCase());
}

// ── 系统字体扫描（通过 platform channel） ─────────────────────────────────────

const _fontsChannel = MethodChannel('app.hibiki.reader/fonts');
List<String>? _cachedSystemFonts;

Future<List<String>> _getSystemFonts() async {
  if (_cachedSystemFonts != null && _cachedSystemFonts!.isNotEmpty) {
    return _cachedSystemFonts!;
  }
  try {
    final result = await _fontsChannel.invokeMethod<List<dynamic>>('listSystemFonts');
    debugPrint('[hibiki-fonts] channel returned ${result?.length} fonts');
    _cachedSystemFonts = result?.cast<String>() ?? [];
  } catch (e) {
    debugPrint('[hibiki-fonts] channel error: $e');
    _cachedSystemFonts = [];
  }
  return _cachedSystemFonts!;
}

// ── 系统字体选择页 ────────────────────────────────────────────────────────────

class _SystemFontPickerPage extends StatefulWidget {
  final Set<String> alreadyAdded;
  const _SystemFontPickerPage({required this.alreadyAdded});

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
    return Scaffold(
      appBar: AppBar(
        title: Text(t.custom_fonts_add_system),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: t.custom_fonts_search_hint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: _onSearch,
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filtered.isEmpty
              ? Center(child: Text(t.custom_fonts_empty))
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) {
                    final name = _filtered[index];
                    final added = widget.alreadyAdded.contains(name);
                    return ListTile(
                      leading: Icon(
                        Icons.font_download,
                        color: added
                            ? Theme.of(context).colorScheme.outline
                            : Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(name),
                      trailing: added
                          ? Icon(Icons.check, color: Theme.of(context).colorScheme.outline)
                          : null,
                      enabled: !added,
                      onTap: () => Navigator.pop(context, name),
                    );
                  },
                ),
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
  ReaderTtuSource get _source => ReaderTtuSource.instance;

  List<Map<String, dynamic>> _fonts = [];

  @override
  void initState() {
    super.initState();
    _fonts = _source.customFonts;
  }

  Future<void> _save() async {
    await _source.setCustomFonts(_fonts);
  }

  Directory get _fontsDir {
    final dir = Directory(p.join(appModel.appDirectory.path, 'custom_fonts'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _importFontFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf', 'ttc', 'woff', 'woff2', 'zip', '7z', 'rar', 'tar', 'gz'],
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
      Fluttertoast.showToast(msg: t.custom_fonts_imported_count(count: count));
    }
  }

  Future<int> _addSingleFont(File srcFile, String fileName) async {
    final name = p.basenameWithoutExtension(fileName);
    var ext = p.extension(fileName).toLowerCase();
    if (!_fontExtensions.contains(ext)) {
      ext = await _detectFontExtension(srcFile) ?? '.ttf';
    }
    final destPath = p.join(
        _fontsDir.path, '${name}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await srcFile.copy(destPath);
    setState(() {
      _fonts.add({'name': name, 'path': destPath, 'enabled': true});
    });
    return 1;
  }

  Future<String?> _detectFontExtension(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(8);
        if (header.length < 4) return null;
        // wOFF
        if (header[0] == 0x77 && header[1] == 0x4F &&
            header[2] == 0x46 && header[3] == 0x46) {
          return header.length >= 8 && header[4] == 0x00 &&
              header[5] == 0x01 && header[6] == 0x00 && header[7] == 0x00
              ? '.woff' : '.woff2';
        }
        // TrueType / OpenType
        if (header[0] == 0x00 && header[1] == 0x01 &&
            header[2] == 0x00 && header[3] == 0x00) return '.ttf';
        if (header[0] == 0x4F && header[1] == 0x54 &&
            header[2] == 0x54 && header[3] == 0x4F) return '.otf';
        // TTC
        if (header[0] == 0x74 && header[1] == 0x74 &&
            header[2] == 0x63 && header[3] == 0x66) return '.ttc';
        return null;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isZipFile(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(4);
        return header.length >= 4 &&
            header[0] == 0x50 && header[1] == 0x4B &&
            header[2] == 0x03 && header[3] == 0x04;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<int> _extractFontsFromArchive(File archiveFile) async {
    try {
      final bytes = await archiveFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      int count = 0;
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (final entry in archive.files) {
        if (entry.isFile && _isFontFile(entry.name)) {
          final baseName = p.basenameWithoutExtension(entry.name);
          final ext = p.extension(entry.name);
          final destPath = p.join(_fontsDir.path, '${baseName}_$ts$ext');
          File(destPath).writeAsBytesSync(entry.content as List<int>);
          setState(() {
            _fonts.add({'name': baseName, 'path': destPath, 'enabled': true});
          });
          count++;
        }
      }
      return count;
    } catch (e) {
      debugPrint('[hibiki-fonts] archive extract failed: $e');
      Fluttertoast.showToast(msg: t.custom_fonts_archive_error);
      return 0;
    }
  }

  Future<void> _downloadUrl(String url,
      {String? displayName, List<String> mirrorUrls = const []}) async {
    final allUrls = [url, ...mirrorUrls];
    final ts = DateTime.now().millisecondsSinceEpoch;
    final tempPath = p.join(_fontsDir.path, '_tmp_$ts');
    final progressNotifier = ValueNotifier<double?>(null);
    final cancelToken = CancelToken();

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(displayName ?? t.custom_fonts_downloading),
            content: ValueListenableBuilder<double?>(
              valueListenable: progressNotifier,
              builder: (_, progress, __) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 8),
                  Text(progress != null
                      ? '${(progress * 100).toStringAsFixed(0)}%'
                      : t.custom_fonts_downloading),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelToken.cancel();
                  Navigator.pop(ctx);
                },
                child: Text(t.dialog_cancel),
              ),
            ],
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
        debugPrint('[hibiki-fonts] trying source ${i + 1}/${allUrls.length}: $currentUrl');
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
        throw lastError ?? Exception('All sources failed');
      }

      if (mounted) Navigator.pop(context);

      final tempFile = File(tempPath);
      final fileName = _fileNameFromUrl(downloadedUrl);
      int count = 0;
      final isZip = await _isZipFile(tempFile);
      if (isZip) {
        count = await _extractFontsFromArchive(tempFile);
        if (count == 0) {
          count = await _addSingleFont(tempFile, fileName);
        }
      } else {
        count = await _addSingleFont(tempFile, fileName);
      }
      if (await tempFile.exists()) await tempFile.delete();

      if (count > 0) {
        await _save();
        Fluttertoast.showToast(msg: t.custom_fonts_imported_count(count: count));
      } else {
        Fluttertoast.showToast(msg: t.custom_fonts_no_fonts_in_archive);
      }
    } on DioError catch (e, stack) {
      if (mounted) Navigator.pop(context);
      if (e.type != DioErrorType.cancel) {
        debugPrint('[hibiki-fonts] DioError: type=${e.type} '
            'status=${e.response?.statusCode} msg=${e.message}');
        debugPrint('[hibiki-fonts] stack: $stack');
        Fluttertoast.showToast(
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
      Fluttertoast.showToast(
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
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.custom_fonts_import_url),
        content: TextField(
          controller: urlController,
          decoration: InputDecoration(
            hintText: 'https://example.com/fonts.zip',
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, urlController.text.trim()),
            child: Text(t.dialog_import),
          ),
        ],
      ),
    );
    urlController.dispose();
    if (url == null || url.isEmpty) return;
    await _downloadUrl(url);
  }

  Future<void> _downloadRecommendedFont(_RecommendedFont font) async {
    await _downloadUrl(font.urls.first,
        displayName: font.name, mirrorUrls: font.urls.skip(1).toList());
  }

  Future<void> _openRecommended() async {
    final font = await Navigator.push<_RecommendedFont>(
      context,
      MaterialPageRoute(
        builder: (_) => _RecommendedFontsPage(
          alreadyAdded: _fonts.map((e) => e['name'] as String).toSet(),
        ),
      ),
    );
    if (font == null || !mounted) return;
    await _downloadRecommendedFont(font);
  }

  Future<void> _addSystemFont() async {
    final alreadyAdded = _fonts
        .where((e) => e['path'] == null)
        .map((e) => e['name'] as String)
        .toSet();
    final selected = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _SystemFontPickerPage(alreadyAdded: alreadyAdded),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _fonts.add({'name': selected, 'path': null, 'enabled': true});
    });
    _save();
  }

  Future<void> _removeFont(int index) async {
    final entry = _fonts[index];
    final filePath = entry['path'] as String?;
    setState(() => _fonts.removeAt(index));
    await _save();
    if (filePath != null) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    Fluttertoast.showToast(msg: t.custom_fonts_removed);
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
      _fonts[index]['enabled'] =
          !(_fonts[index]['enabled'] as bool? ?? true);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.custom_fonts),
        actions: [
          IconButton(
            icon: const Icon(Icons.star_outline),
            tooltip: t.custom_fonts_recommended,
            onPressed: _openRecommended,
          ),
          PopupMenuButton<VoidCallback>(
            icon: const Icon(Icons.add),
            onSelected: (fn) => fn(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _addSystemFont,
                child: ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text(t.custom_fonts_add_system),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _importFontFile,
                child: ListTile(
                  leading: const Icon(Icons.file_open),
                  title: Text(t.custom_fonts_import_file),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _importFromUrl,
                child: ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(t.custom_fonts_import_url),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _fonts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.font_download_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(t.custom_fonts_empty,
                      style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _openRecommended,
                    icon: const Icon(Icons.star_outline),
                    label: Text(t.custom_fonts_recommended),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.custom_fonts_drag_hint,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _fonts.length,
                    onReorder: _onReorder,
                    itemBuilder: (context, index) {
                      final entry = _fonts[index];
                      final name = entry['name'] as String;
                      final isFile = entry['path'] != null;
                      final enabled = entry['enabled'] as bool? ?? true;
                      return _FontTile(
                        key: ValueKey('$name-$index'),
                        name: name,
                        isFile: isFile,
                        enabled: enabled,
                        index: index,
                        onToggle: () => _toggleFont(index),
                        onDelete: () => _removeFont(index),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _RecommendedFontsPage extends StatelessWidget {
  final Set<String> alreadyAdded;
  const _RecommendedFontsPage({required this.alreadyAdded});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.custom_fonts_recommended)),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _recommendedFonts.length,
        itemBuilder: (context, index) {
          final font = _recommendedFonts[index];
          final added = alreadyAdded.any(
            (n) => n.toLowerCase() == font.name.toLowerCase(),
          );
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: Icon(
                Icons.font_download,
                color: added ? cs.outline : cs.primary,
              ),
              title: Text(font.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(font.nameJa,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(font.description,
                      style: Theme.of(context).textTheme.bodySmall),
                  Text(font.license,
                      style: TextStyle(fontSize: 10, color: cs.outline)),
                ],
              ),
              trailing: added
                  ? Icon(Icons.check, color: cs.outline)
                  : FilledButton.tonal(
                      onPressed: () => Navigator.pop(context, font),
                      child: const Icon(Icons.download, size: 20),
                    ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}

class _FontTile extends StatelessWidget {
  const _FontTile({
    super.key,
    required this.name,
    required this.isFile,
    required this.enabled,
    required this.index,
    required this.onToggle,
    required this.onDelete,
  });

  final String name;
  final bool isFile;
  final bool enabled;
  final int index;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
            const SizedBox(width: 8),
            Icon(
              isFile ? Icons.file_present : Icons.phone_android,
              color: cs.primary,
            ),
          ],
        ),
        title: Text(
          name,
          style: TextStyle(
            color: enabled ? null : cs.outline,
            decoration: enabled ? null : TextDecoration.lineThrough,
          ),
        ),
        subtitle: Text(
          isFile ? 'Font File' : 'System Font',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: enabled,
              onChanged: (_) => onToggle(),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: cs.error),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
