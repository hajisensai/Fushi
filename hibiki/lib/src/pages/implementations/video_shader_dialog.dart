import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';

/// mpv 着色器管理对话框：导入 `.glsl`/`.hook` 着色器、勾选启用、即时应用。
///
/// 自身只管文件列表与勾选状态；启用集（按文件名）经 [onApply] 上报给视频页，由其
/// 持久化 + 解析成绝对路径 + 调 [VideoPlayerController.applyShaders] 实时生效（仅桌面
/// libmpv，移动端静默）。勾选顺序按目录列表顺序，保证着色器叠加顺序稳定。
class VideoShaderDialog extends StatefulWidget {
  const VideoShaderDialog({
    required this.initialEnabled,
    required this.onApply,
    super.key,
  });

  /// 初始启用的着色器文件名集合。
  final List<String> initialEnabled;

  /// 勾选变化时回调，参数为按目录顺序排列的启用文件名列表。
  final Future<void> Function(List<String> enabledNames) onApply;

  @override
  State<VideoShaderDialog> createState() => _VideoShaderDialogState();
}

class _VideoShaderDialogState extends State<VideoShaderDialog> {
  late final Set<String> _enabled = widget.initialEnabled.toSet();
  List<String> _files = const <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final List<String> files = await listShaderFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _import() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['glsl', 'hook'],
      allowMultiple: true,
    );
    if (result == null) return;
    for (final PlatformFile f in result.files) {
      final String? path = f.path;
      if (path != null) await importShaderFile(path);
    }
    await _refresh();
  }

  Future<void> _toggle(String name, bool on) async {
    setState(() {
      if (on) {
        _enabled.add(name);
      } else {
        _enabled.remove(name);
      }
    });
    // 按目录列表顺序排出启用集，保证着色器叠加顺序稳定可复现。
    final List<String> ordered =
        _files.where(_enabled.contains).toList(growable: false);
    await widget.onApply(ordered);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_setting_shaders),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t.video_setting_shaders_hint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (_files.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        t.video_shaders_empty,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: <Widget>[
                          for (final String name in _files)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title:
                                  Text(name, overflow: TextOverflow.ellipsis),
                              value: _enabled.contains(name),
                              onChanged: (bool? v) => _toggle(name, v ?? false),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: Text(t.video_shader_import),
          onPressed: _import,
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
