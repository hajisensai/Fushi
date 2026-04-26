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
  final String url;
  final String license;
  final String description;
  const _RecommendedFont({
    required this.name,
    required this.nameJa,
    required this.url,
    required this.license,
    required this.description,
  });
}

const _recommendedFonts = [
  // ── 全 CJK 覆盖（日中韩通用，不会缺字） ──
  _RecommendedFont(
    name: 'Noto Sans CJK JP',
    nameJa: 'Noto Sans CJK 日本語',
    url: 'https://github.com/googlefonts/noto-cjk/releases/download/Sans2.004/08_NotoSansJP.zip',
    license: 'OFL 1.1',
    description: 'Google/Adobe 黑体 · 日语字形优先 · 覆盖全 CJK 统一汉字',
  ),
  _RecommendedFont(
    name: 'Noto Serif CJK JP',
    nameJa: 'Noto Serif CJK 日本語',
    url: 'https://github.com/googlefonts/noto-cjk/releases/download/Serif2.003/09_NotoSerifJP.zip',
    license: 'OFL 1.1',
    description: 'Google/Adobe 宋体 · 日语字形优先 · 适合竖排阅读',
  ),
  _RecommendedFont(
    name: 'Noto Sans CJK SC',
    nameJa: 'Noto Sans CJK 简体中文',
    url: 'https://github.com/googlefonts/noto-cjk/releases/download/Sans2.004/11_NotoSansSC.zip',
    license: 'OFL 1.1',
    description: 'Google/Adobe 黑体 · 简中字形优先 · 搭配日文字体做回退',
  ),
  _RecommendedFont(
    name: 'Noto Serif CJK SC',
    nameJa: 'Noto Serif CJK 简体中文',
    url: 'https://github.com/googlefonts/noto-cjk/releases/download/Serif2.003/12_NotoSerifSC.zip',
    license: 'OFL 1.1',
    description: 'Google/Adobe 宋体 · 简中字形优先 · 搭配日文字体做回退',
  ),
  _RecommendedFont(
    name: 'Noto Sans CJK TC',
    nameJa: 'Noto Sans CJK 繁體中文',
    url: 'https://github.com/googlefonts/noto-cjk/releases/download/Sans2.004/14_NotoSansTC.zip',
    license: 'OFL 1.1',
    description: 'Google/Adobe 黑体 · 繁中字形优先',
  ),
  // ── 日语特色字体（风格独特，建议搭配 Noto CJK 做回退） ──
  _RecommendedFont(
    name: 'Klee One',
    nameJa: 'クレー One',
    url: 'https://github.com/googlefonts/klee-one/raw/main/fonts/ttf/KleeOne-Regular.ttf',
    license: 'OFL 1.1',
    description: '手写教科书体 · 清晰易读 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'Shippori Mincho',
    nameJa: 'しっぽり明朝',
    url: 'https://github.com/googlefonts/shippori-mincho/raw/main/fonts/ttf/ShipporiMincho-Regular.ttf',
    license: 'OFL 1.1',
    description: '优雅明朝体 · 文学作品推荐 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'Zen Old Mincho',
    nameJa: '禅オールド明朝',
    url: 'https://github.com/googlefonts/zen-oldmincho/raw/main/fonts/ttf/ZenOldMincho-Regular.ttf',
    license: 'OFL 1.1',
    description: '复古明朝体 · 古典文学风格 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'Zen Maru Gothic',
    nameJa: '禅丸ゴシック',
    url: 'https://github.com/googlefonts/zen-marugothic/raw/main/fonts/ttf/ZenMaruGothic-Regular.ttf',
    license: 'OFL 1.1',
    description: '柔和圆润黑体 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'M PLUS Rounded 1c',
    nameJa: 'M PLUS Rounded 1c',
    url: 'https://github.com/googlefonts/mplus-fonts/raw/main/fonts/ttf/MPLUSRounded1c-Regular.ttf',
    license: 'OFL 1.1',
    description: '圆角可爱风格 · 适合轻小说 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'Hina Mincho',
    nameJa: 'ひな明朝',
    url: 'https://github.com/googlefonts/hina-mincho/raw/main/fonts/ttf/HinaMincho-Regular.ttf',
    license: 'OFL 1.1',
    description: '柔和装饰性明朝体 · 建议搭配 Noto CJK 回退',
  ),
  _RecommendedFont(
    name: 'Zen Kaku Gothic New',
    nameJa: '禅角ゴシック New',
    url: 'https://github.com/googlefonts/zen-kakugothic/raw/main/fonts/ttf/ZenKakuGothicNew-Regular.ttf',
    license: 'OFL 1.1',
    description: '现代角黑体 · 通用阅读 · 建议搭配 Noto CJK 回退',
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
    final ext = p.extension(fileName);
    final destPath = p.join(
        _fontsDir.path, '${name}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await srcFile.copy(destPath);
    setState(() {
      _fonts.add({'name': name, 'path': destPath, 'enabled': true});
    });
    return 1;
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

  Future<void> _downloadUrl(String url, {String? displayName}) async {
    final uri = Uri.parse(url);
    final fileName = uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last)
        : 'font_${DateTime.now().millisecondsSinceEpoch}';
    final tempPath = p.join(_fontsDir.path, '_tmp_$fileName');
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
      final dio = Dio();
      await dio.download(
        url,
        tempPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            progressNotifier.value = received / total;
          }
        },
      );

      if (mounted) Navigator.pop(context);

      final tempFile = File(tempPath);
      final ext = p.extension(fileName).toLowerCase();
      int count = 0;
      if (_fontExtensions.contains(ext)) {
        count = await _addSingleFont(tempFile, fileName);
        await tempFile.delete();
      } else {
        count = await _extractFontsFromArchive(tempFile);
        if (await tempFile.exists()) await tempFile.delete();
      }

      if (count > 0) {
        await _save();
        Fluttertoast.showToast(msg: t.custom_fonts_imported_count(count: count));
      } else {
        Fluttertoast.showToast(msg: t.custom_fonts_no_fonts_in_archive);
      }
    } on DioError catch (e) {
      if (mounted) Navigator.pop(context);
      if (e.type != DioErrorType.cancel) {
        debugPrint('[hibiki-fonts] download failed: $e');
        Fluttertoast.showToast(msg: t.custom_fonts_download_failed);
      }
      final f = File(tempPath);
      if (await f.exists()) await f.delete();
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint('[hibiki-fonts] download failed: $e');
      Fluttertoast.showToast(msg: t.custom_fonts_download_failed);
      final f = File(tempPath);
      if (await f.exists()) await f.delete();
    } finally {
      progressNotifier.dispose();
    }
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
    await _downloadUrl(font.url, displayName: font.name);
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
            (n) => n.toLowerCase().contains(font.name.toLowerCase().split(' ').first),
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
