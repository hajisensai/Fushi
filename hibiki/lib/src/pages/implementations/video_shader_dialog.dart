import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';

/// mpv 着色器管理对话框：导入 `.glsl`/`.hook` 着色器、一键下载 Anime4K 推荐预设、
/// 勾选启用、即时应用。
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

  /// 打开 Anime4K 预设下载子对话框：选预设 → 多镜像逐文件下载（进度）→ 刷新列表。
  Future<void> _openAnime4kDownload() async {
    final Anime4kPreset? preset = await showDialog<Anime4kPreset>(
      context: context,
      builder: (_) => Anime4kPresetPickerDialog(
        downloadedFiles: _files.toSet(),
      ),
    );
    if (preset == null || !mounted) return;
    await _downloadPreset(preset);
  }

  /// 下载某预设的全部着色器到 mpv_shaders（进度对话框 + 取消），完成刷新列表 + 提示。
  Future<void> _downloadPreset(Anime4kPreset preset) async {
    final ValueNotifier<({int index, int total, double? progress})>
        progressNotifier =
        ValueNotifier<({int index, int total, double? progress})>(
            (index: 0, total: preset.shaders.length, progress: null));
    final CancelToken cancelToken = CancelToken();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    // 进度对话框：取消只置 cancelToken（不自己 pop），关闭统一由本方法在下载收尾时
    // 做一次 pop——保证「关进度框」只有一条路径，不会与取消路径重复 pop 误伤视频页路由。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: _Anime4kProgressDialog(
          presetName: preset.name,
          progressNotifier: progressNotifier,
          onCancel: cancelToken.cancel,
        ),
      ),
    );

    Anime4kDownloadResult? result;
    Object? error;
    bool cancelled = false;
    try {
      result = await downloadAnime4kFiles(
        preset,
        cancelToken: cancelToken,
        onFileProgress: (int i, int total, double? p) {
          progressNotifier.value = (index: i, total: total, progress: p);
        },
      );
    } on DioError catch (e) {
      if (e.type == DioErrorType.cancel) {
        cancelled = true;
      } else {
        error = e;
      }
    } catch (e) {
      error = e;
    } finally {
      progressNotifier.dispose();
    }

    if (!mounted) return;
    // 关闭进度对话框（唯一一次 pop）。
    Navigator.of(context).pop();
    await _refresh();
    if (!mounted || cancelled) return;

    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.video_shader_download_failed)),
      );
      return;
    }
    if (result == null) return; // 被取消。
    final String message;
    if (result.allOk) {
      message = t.video_shader_download_done(count: result.downloaded.length);
    } else if (result.downloaded.isNotEmpty) {
      message = t.video_shader_download_partial(
        ok: result.downloaded.length,
        failed: result.failed.length,
      );
    } else {
      message = t.video_shader_download_failed;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
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
                  // Anime4K 一键下载入口：选预设 → 多镜像下载 → 自动加入下方列表。
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(t.video_shader_download_anime4k),
                      onPressed: _openAnime4kDownload,
                    ),
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

/// Anime4K 推荐预设选择对话框：列出 [kAnime4kPresets]，点某项 pop 回该预设；已下载
/// 全部文件的预设标「已下载」。预设标题用技术名（Mode A/B/C），说明走 i18n。
@visibleForTesting
class Anime4kPresetPickerDialog extends StatelessWidget {
  const Anime4kPresetPickerDialog({
    required this.downloadedFiles,
    super.key,
  });

  /// 当前 mpv_shaders 目录已有的文件名集合（判预设是否「已下载」）。
  final Set<String> downloadedFiles;

  /// 预设 id → 本地化说明文案。
  static String presetDescription(String id) {
    switch (id) {
      case 'mode_a_fast':
        return t.video_shader_preset_mode_a_fast;
      case 'mode_b_fast':
        return t.video_shader_preset_mode_b_fast;
      case 'mode_c_fast':
        return t.video_shader_preset_mode_c_fast;
      case 'mode_a_hq':
        return t.video_shader_preset_mode_a_hq;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(t.video_shader_anime4k_title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.video_shader_anime4k_hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final Anime4kPreset preset in kAnime4kPresets)
                    () {
                      final bool added =
                          preset.fileNames.every(downloadedFiles.contains);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(preset.name),
                        subtitle: Text(presetDescription(preset.id)),
                        trailing: added
                            ? Icon(Icons.check, color: cs.primary)
                            : const Icon(Icons.download_outlined),
                        onTap: () => Navigator.pop(context, preset),
                      );
                    }(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}

/// Anime4K 下载进度对话框：显示「文件 i/N」+ 当前文件百分比 + 取消。
class _Anime4kProgressDialog extends StatelessWidget {
  const _Anime4kProgressDialog({
    required this.presetName,
    required this.progressNotifier,
    required this.onCancel,
  });

  final String presetName;
  final ValueNotifier<({int index, int total, double? progress})>
      progressNotifier;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_shader_downloading),
      content: SizedBox(
        width: 320,
        child:
            ValueListenableBuilder<({int index, int total, double? progress})>(
          valueListenable: progressNotifier,
          builder: (_, ({int index, int total, double? progress}) v, __) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(presetName, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: v.progress),
                const SizedBox(height: 8),
                Text(
                  '${v.index + 1} / ${v.total}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: onCancel,
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}
