import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

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
      allowedExtensions: ['ttf', 'otf', 'ttc', 'woff', 'woff2'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    if (picked.path == null) return;

    final srcFile = File(picked.path!);
    final name = p.basenameWithoutExtension(picked.name);
    final ext = p.extension(picked.name);
    final destPath = p.join(_fontsDir.path, '${name}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await srcFile.copy(destPath);

    setState(() {
      _fonts.add({'name': name, 'path': destPath, 'enabled': true});
    });
    await _save();
    Fluttertoast.showToast(msg: t.custom_fonts_imported(name: name));
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        onPressed: _addSystemFont,
                        icon: const Icon(Icons.text_fields),
                        label: Text(t.custom_fonts_add_system),
                      ),
                      const SizedBox(width: 12),
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
