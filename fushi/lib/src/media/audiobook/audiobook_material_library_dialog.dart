/// 有声书素材库目录管理框：加/删目录，并如实显示扫描结果。
///
/// 「认得 N 部作品」按身份键去重统计——用户据此判断自己的库有没有被认出来，
/// 而不是加完目录一片沉默、只能等下一次下载才知道配没配上。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

class AudiobookMaterialLibraryDialog extends StatefulWidget {
  const AudiobookMaterialLibraryDialog({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<AudiobookMaterialLibraryDialog> createState() =>
      _AudiobookMaterialLibraryDialogState();
}

class _AudiobookMaterialLibraryDialogState
    extends State<AudiobookMaterialLibraryDialog> {
  late List<String> _dirs = decodeAudiobookMaterialDirs(
    widget.appModel.prefsRepo.audiobookMaterialDirs,
  );
  AudiobookMaterialScan? _scan;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    final AudiobookMaterialScan scan = await widget
        .appModel
        .audiobookMaterialService
        .refresh();
    if (!mounted) return;
    setState(() {
      _scan = scan;
      _scanning = false;
    });
  }

  Future<void> _persist(List<String> dirs) async {
    await widget.appModel.prefsRepo.setAudiobookMaterialDirs(
      encodeAudiobookMaterialDirs(dirs),
    );
    if (!mounted) return;
    setState(() => _dirs = dirs);
    await _rescan();
  }

  Future<void> _addDir() async {
    final String? picked = await pickRealDirectoryPath(
      context: context,
      appModel: widget.appModel,
      dialogTitle: t.audiobook_material_add_dir,
    );
    if (picked == null || picked.trim().isEmpty) return;
    if (_dirs.contains(picked)) return;
    await _persist(<String>[..._dirs, picked]);
  }

  Future<void> _removeDir(String dir) => _persist(<String>[
    for (final String d in _dirs)
      if (d != dir) d,
  ]);

  @override
  Widget build(BuildContext context) {
    final AudiobookMaterialScan? scan = _scan;
    final Set<String> missing = <String>{...?scan?.missingDirs};
    return AlertDialog(
      title: Text(t.audiobook_material_library),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.audiobook_material_library_hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_dirs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t.audiobook_material_none),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final String dir in _dirs)
                      FushiListItem(
                        key: ValueKey<String>('audiobook-material-dir-$dir'),
                        title: Text(dir),
                        subtitle: missing.contains(dir)
                            ? Text(t.audiobook_material_missing_dir)
                            : null,
                        leading: Icon(
                          missing.contains(dir)
                              ? Icons.folder_off_outlined
                              : Icons.folder_outlined,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => _removeDir(dir),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_scanning)
              const LinearProgressIndicator()
            else if (scan != null && _dirs.isNotEmpty)
              Text(
                t.audiobook_material_status(
                  dirs: '${_dirs.length}',
                  works: '${scan.index.identifiedWorkCount}',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          key: const ValueKey<String>('audiobook-material-add-dir'),
          onPressed: _scanning ? null : _addDir,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(t.audiobook_material_add_dir),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
