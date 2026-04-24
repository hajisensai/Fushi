import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

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

  void _addSystemFont() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.custom_fonts_add_system),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: t.custom_fonts_system_hint),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) {
                Fluttertoast.showToast(msg: t.custom_fonts_name_empty);
                return;
              }
              Navigator.pop(ctx);
              setState(() {
                _fonts.add({'name': name, 'path': null, 'enabled': true});
              });
              _save();
            },
            child: Text(t.dialog_add),
          ),
        ],
      ),
    );
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
                      FilledButton.tonalIcon(
                        onPressed: _importFontFile,
                        icon: const Icon(Icons.file_open),
                        label: Text(t.custom_fonts_import_file),
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
