import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const _fontExtensions = {'.ttf', '.otf', '.ttc', '.woff', '.woff2'};

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

  Future<void> _importFromUrl() async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.custom_fonts_import_url),
        content: TextField(
          controller: urlController,
          decoration: InputDecoration(
            hintText: 'https://example.com/font.ttf',
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

    Fluttertoast.showToast(msg: t.custom_fonts_downloading);
    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        Fluttertoast.showToast(msg: t.custom_fonts_download_failed);
        return;
      }

      final fileName = uri.pathSegments.isNotEmpty
          ? Uri.decodeComponent(uri.pathSegments.last)
          : 'font_${DateTime.now().millisecondsSinceEpoch}';
      final ext = p.extension(fileName).toLowerCase();
      final tempFile = File(p.join(_fontsDir.path, '_tmp_$fileName'));
      await tempFile.writeAsBytes(response.bodyBytes);

      int count = 0;
      if (_fontExtensions.contains(ext)) {
        count = await _addSingleFont(tempFile, fileName);
        await tempFile.delete();
      } else {
        count = await _extractFontsFromArchive(tempFile);
        await tempFile.delete();
      }

      if (count > 0) {
        await _save();
        Fluttertoast.showToast(msg: t.custom_fonts_imported_count(count: count));
      } else if (count == 0 && _fontExtensions.contains(ext) == false) {
        Fluttertoast.showToast(msg: t.custom_fonts_no_fonts_in_archive);
      }
    } catch (e) {
      debugPrint('[hibiki-fonts] URL import failed: $e');
      Fluttertoast.showToast(msg: t.custom_fonts_download_failed);
    }
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
            icon: const Icon(Icons.text_fields),
            tooltip: t.custom_fonts_add_system,
            onPressed: _addSystemFont,
          ),
          IconButton(
            icon: const Icon(Icons.file_open),
            tooltip: t.custom_fonts_import_file,
            onPressed: _importFontFile,
          ),
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: t.custom_fonts_import_url,
            onPressed: _importFromUrl,
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
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _addSystemFont,
                        icon: const Icon(Icons.text_fields),
                        label: Text(t.custom_fonts_add_system),
                      ),
                      FilledButton.tonal(
                        onPressed: _importFontFile,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.file_open),
                            const SizedBox(width: 8),
                            Text(t.custom_fonts_import_file),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _importFromUrl,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.link),
                            const SizedBox(width: 8),
                            Text(t.custom_fonts_import_url),
                          ],
                        ),
                      ),
                    ],
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
