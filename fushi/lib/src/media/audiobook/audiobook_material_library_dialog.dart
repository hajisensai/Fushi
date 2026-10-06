/// 有声书素材库目录管理框：加/删目录，并如实显示扫描结果。
///
/// 「认得 N 部作品」按身份键去重统计——用户据此判断自己的库有没有被认出来，
/// 而不是加完目录一片沉默、只能等下一次下载才知道配没配上。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    // 扫描状态色块上的字跟卡片配对前景（fushiType 自带页面前景，HBK-AUDIT-022）。
    final Color? onStatusCard = fushiCardToneColors(
      context,
      FushiCardTone.secondary,
    )?.onContainer;
    final FushiMotionScheme motion = context.fushiMotion;
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.audiobook,
        tone: FushiHeroTone.primary,
      ),
      title: Text(t.audiobook_material_library),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.audiobook_material_library_hint,
              style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (_dirs.isEmpty)
              FushiCard(
                variant: FushiCardVariant.outlined,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                child: Row(
                  children: <Widget>[
                    const FushiListLeadingIcon(
                      FushiIcons.folderOpen,
                      shape: FushiLeadingShape.cookie,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        t.audiobook_material_none,
                        style: type.bodyLarge,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: FushiEntranceScope(
                  child: SingleChildScrollView(
                    child: FushiGroupedList(
                      children: <Widget>[
                        for (int i = 0; i < _dirs.length; i++)
                          FushiStaggeredEntrance(
                            key: ValueKey<String>(
                              'audiobook-material-dir-${_dirs[i]}',
                            ),
                            index: i,
                            child: FushiListItem(
                              title: Text(_dirs[i]),
                              subtitle: missing.contains(_dirs[i])
                                  ? Text(
                                      t.audiobook_material_missing_dir,
                                      style: TextStyle(color: cs.error),
                                    )
                                  : null,
                              leading: FushiListLeadingIcon(
                                missing.contains(_dirs[i])
                                    ? FushiIcons.warning
                                    : FushiIcons.folder,
                                shape: FushiLeadingShape.square,
                                tone: missing.contains(_dirs[i])
                                    ? FushiCardTone.error
                                    : FushiCardTone.secondary,
                              ),
                              trailing: FushiIconButtonControl(
                                icon: const FushiIcon(FushiIcons.close),
                                onPressed: () => _removeDir(_dirs[i]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: motion.effectsDefault.duration,
              switchInCurve: motion.effectsDefault.curve,
              switchOutCurve: motion.effectsDefault.curve,
              child: _scanning
                  ? const Padding(
                      key: ValueKey<String>('scanning'),
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: FushiLinearProgressIndicator(),
                    )
                  : (scan != null && _dirs.isNotEmpty)
                  ? FushiCard(
                      key: const ValueKey<String>('status'),
                      tone: FushiCardTone.secondary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: <Widget>[
                          Text(
                            '${scan.index.identifiedWorkCount}',
                            style: type.headlineSmallEmphasized.tabular
                                .copyWith(color: onStatusCard),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              t.audiobook_material_status(
                                dirs: '${_dirs.length}',
                                works: '${scan.index.identifiedWorkCount}',
                              ),
                              style: type.bodyMedium.copyWith(
                                color: onStatusCard,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey<String>('idle')),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton.icon(
          key: const ValueKey<String>('audiobook-material-add-dir'),
          onPressed: _scanning ? null : _addDir,
          icon: const FushiIcon(FushiIcons.add),
          label: Text(t.audiobook_material_add_dir),
        ),
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
