import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/utils.dart';

/// mpv 着色器内嵌管理视图：导入 `.glsl`/`.hook`、从本机 mpv 发现导入、一键下载
/// Anime4K 推荐预设、勾选启用、即时应用。直接嵌进视频设置面板的「着色器」详情 pane
/// （不再弹独立设置对话框，与书籍设置同款内嵌范式）。
///
/// 自身只管文件列表与勾选状态；启用集（按文件名）经 [onApply] 上报给视频页，由其
/// 持久化 + 解析成绝对路径 + 调 `VideoPlayerController.applyShaders` 实时生效（五平台
/// libmpv 后端均生效——移动端走 vo=gpu 渲染路径，非 no-op；效果因机型 GPU 而异、高档可能
/// 掉帧，UI 用 [t.video_shader_mobile_perf_hint] 提示，见 video_shader_manager.dart doc
/// 的 media_kit 源码出处）。勾选顺序按目录列表顺序，保证着色器叠加顺序稳定。
///
/// 「下载 Anime4K」「从本机 mpv 导入」「导入文件」是**瞬时动作**（弹临时选择/进度对话框
/// 或系统文件选择器），不是设置子页面——它们完成后回到本内嵌视图。
class VideoShaderManagerView extends StatefulWidget {
  const VideoShaderManagerView({
    required this.initialEnabled,
    required this.qualityEnhancementEnabled,
    required this.onQualityEnhancementChanged,
    required this.onApply,
    required this.onSelectTier,
    this.initialMpvDir = '',
    this.onMpvDirChanged,
    this.titlePlacement = SettingsSectionTitlePlacement.outside,
    super.key,
  });

  /// 初始启用的着色器文件名集合。
  final List<String> initialEnabled;

  /// 整个画质增强组是否启用。关闭时保留勾选集，但运行时由调用方旁路 shader。
  final bool qualityEnhancementEnabled;

  /// 切换画质增强组：调用方负责持久化 mpv 基础增强并即时应用/旁路 shader。
  final void Function(bool enabled) onQualityEnhancementChanged;

  /// 勾选变化时回调，参数为按目录顺序排列的启用文件名列表。
  final Future<void> Function(List<String> enabledNames) onApply;

  /// 选某画质档位后回调：本视图已把目标状态算好——[highQuality]（mpv 内置缩放开关）
  /// 与 [enabledNames]（按叠加顺序、已落盘存在的该档着色器集）。调用方一次性持久化这
  /// 两套状态 + 实时应用（着色器文件已由本视图在回调前下载到目录）。[tier] 仅供日志/统计。
  final Future<void> Function(
    VideoShaderTier tier,
    bool highQuality,
    List<String> enabledNames,
  ) onSelectTier;

  /// 用户上次手动指定的本机 mpv 配置/着色器目录（空=未指定，走自动候选）。
  final String initialMpvDir;

  /// 用户手动指定 mpv 目录后回调（持久化，下次优先扫它）。
  final Future<void> Function(String dir)? onMpvDirChanged;

  final SettingsSectionTitlePlacement titlePlacement;

  @override
  State<VideoShaderManagerView> createState() => _VideoShaderManagerViewState();
}

class _VideoShaderManagerViewState extends State<VideoShaderManagerView> {
  late final Set<String> _enabled = widget.initialEnabled.toSet();
  late String _mpvDir = widget.initialMpvDir;
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

  /// 从本机 mpv 安装发现着色器（手动指定目录优先，再叠加自动候选目录的 `shaders/`）
  /// → 多选导入到 mpv_shaders。自动扫不到时**引导手动指定 mpv 目录**（见
  /// [_pickMpvDirAndSearch]）。
  Future<void> _importFromMpv() async {
    final List<String> found =
        await discoverLocalMpvShaders(overrideDir: _mpvDir);
    if (!mounted) return;
    if (found.isEmpty) {
      // 自动找不到：直接转入「手动指定目录并搜索」，而不是只弹个失败提示（用户诉求）。
      await _pickMpvDirAndSearch(autoFallback: true);
      return;
    }
    await _pickAndImportFrom(found);
  }

  /// 手动指定本机 mpv 配置/着色器目录 → 扫描 → 多选导入；记住该目录下次优先。
  /// [autoFallback]=true 表示这是「自动找不到」转过来的（首句提示语略不同）。
  Future<void> _pickMpvDirAndSearch({bool autoFallback = false}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.video_shader_pick_mpv_dir,
      initialDirectory: _mpvDir.isNotEmpty ? _mpvDir : null,
    );
    if (dir == null || !mounted) {
      if (autoFallback) {
        messenger.showSnackBar(
            SnackBar(content: Text(t.video_shader_mpv_not_found)));
      }
      return;
    }
    setState(() => _mpvDir = dir);
    await widget.onMpvDirChanged?.call(dir);
    final List<String> found = await discoverLocalMpvShaders(overrideDir: dir);
    if (!mounted) return;
    if (found.isEmpty) {
      messenger
          .showSnackBar(SnackBar(content: Text(t.video_shader_mpv_dir_empty)));
      return;
    }
    await _pickAndImportFrom(found);
  }

  /// 把发现到的着色器列出多选 → 导入选中的到 mpv_shaders → 刷新 + 提示。
  Future<void> _pickAndImportFrom(List<String> found) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<String>? picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _MpvShaderPickerDialog(
        discovered: found,
        alreadyImported: _files.toSet(),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    for (final String path in picked) {
      await importShaderFile(path);
    }
    await _refresh();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(t.video_shader_import_done(count: picked.length))),
    );
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

  /// 粘贴任意着色器链接（GitHub/直链）下载到 mpv_shaders——不必本机装 mpv（用户诉求）。
  /// **直链优先**：先试用户粘的链接本身，跑不通才回退 jsDelivr/ghfast 镜像（中国可达），
  /// 内容校验防 404/HTML 占位。
  Future<void> _downloadFromUrl() async {
    final TextEditingController urlController = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_shader_download_url),
        content: TextField(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: t.video_shader_url_hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, urlController.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    urlController.dispose();
    final String? trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(t.video_shader_downloading)),
    );
    String? name;
    try {
      name = await downloadShaderFromUrl(trimmed);
    } catch (_) {
      name = null;
    }
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(name != null
          ? t.video_shader_download_done(count: 1)
          : t.video_shader_download_failed),
    ));
  }

  /// 下载某预设的全部着色器到 mpv_shaders（进度对话框 + 取消），完成刷新列表 + 提示。
  /// 返回 true 表示该预设的全部文件现已就绪（全部下载成功或已存在），可据此启用该档。
  Future<bool> _downloadPreset(Anime4kPreset preset) async {
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

    if (!mounted) return false;
    // 关闭进度对话框（唯一一次 pop）。
    Navigator.of(context).pop();
    await _refresh();
    if (!mounted || cancelled) return false;

    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.video_shader_download_failed)),
      );
      return false;
    }
    if (result == null) return false; // 被取消。
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
    return result.allOk;
  }

  /// **一键画质档位切换**（用户诉求 1/3/4 的统一入口）：选 [tier] 后——
  /// 1) 若该档需要 GLSL 且文件未全就绪 → 走 [_downloadPreset] 下载（带进度，可取消）；
  /// 2) 下载成功 / 无需下载 → 刷新目录，调 [VideoShaderManagerView.onSelectTier]
  ///    让视频页一次性写「内置缩放开关 + 启用集」并实时应用。
  /// 下载失败（用户取消 / 网络全挂）则不改档，停在原状态（不留半启用）。
  Future<void> _selectTier(VideoShaderTier tier) async {
    final VideoShaderTierSpec spec = shaderTierSpec(tier);
    final Anime4kPreset? preset = spec.preset;
    if (preset != null) {
      final bool alreadyHave = preset.fileNames.every(_files.toSet().contains);
      if (!alreadyHave) {
        final bool ok =
            await _downloadPreset(preset); // 内部已 _refresh 刷新 _files。
        if (!mounted || !ok) return; // 取消/失败：不切档（不留半启用）。
      }
    }
    // 从目录现有文件按该档叠加顺序过滤出有序启用集（个别下载失败也只启用存在的）。
    final List<String> enabled = orderedEnabledForTier(tier, _files.toSet());
    setState(() {
      _enabled
        ..clear()
        ..addAll(enabled);
    });
    await widget.onSelectTier(tier, spec.highQuality, enabled);
    if (mounted) setState(() {}); // 重算当前选中档高亮。
  }

  /// 当前命中的画质档（据内置缩放开关 + 已启用集反查）；都不命中=用户自定义勾选→null。
  VideoShaderTier? get _currentTier => tierFromState(
        highQuality: widget.qualityEnhancementEnabled,
        enabledShaders: _files.where(_enabled.contains).toList(),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final List<Widget> installedRows = _files.isEmpty
        ? <Widget>[
            AdaptiveSettingsRow(
              title: t.video_shaders_empty,
              icon: Icons.hourglass_empty_outlined,
              showIcon: true,
            ),
          ]
        : <Widget>[
            for (final String name in _files)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(name, overflow: TextOverflow.ellipsis),
                value: _enabled.contains(name),
                onChanged: (bool? v) => _toggle(name, v ?? false),
              ),
          ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ── 画质档位（无/低/中/高/极高）：一键选档即下载+启用，普通用户唯一需要的入口 ──
        AdaptiveSettingsSection(
          title: t.video_shader_quality_tier,
          titlePlacement: widget.titlePlacement,
          children: <Widget>[
            VideoShaderTierSelector(
              current: _currentTier,
              onSelect: _selectTier,
            ),
            // 选档前就把五档「档名 — 一句话 + 显卡要求」常驻列出，便于横向比较，
            // 不用点开某档才看到要求（用户诉求 2）。当前命中档加粗高亮。
            VideoShaderTierComparison(current: _currentTier),
            if (_currentTier == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                  t.video_shader_tier_custom_hint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (isMobilePlatform)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                  t.video_shader_mobile_perf_hint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                ),
              ),
          ],
        ),
        // ── 进阶：手动导入文件 / 粘贴链接下载 / 从本机 mpv 导入（给懂的人用的逃生口）──
        AdaptiveSettingsSection(
          title: t.video_shader_section_advanced,
          titlePlacement: widget.titlePlacement,
          children: <Widget>[
            _actionRow(
              title: t.video_shader_import,
              icon: Icons.add_outlined,
              onTap: _import,
            ),
            _actionRow(
              title: t.video_shader_download_url,
              subtitle: t.video_shader_url_hint,
              icon: Icons.link_outlined,
              onTap: _downloadFromUrl,
            ),
            _actionRow(
              title: t.video_shader_import_from_mpv,
              subtitle: _mpvDir.isEmpty
                  ? t.video_shader_import_from_mpv_hint
                  : t.video_shader_mpv_dir_current(path: _mpvDir),
              icon: Icons.travel_explore_outlined,
              onTap: _importFromMpv,
            ),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.video_shader_section_installed,
          titlePlacement: widget.titlePlacement,
          children: installedRows,
        ),
      ],
    );
  }

  AdaptiveSettingsRow _actionRow({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 从本机 mpv 发现的着色器多选导入对话框：列出绝对路径的 basename，已在 mpv_shaders
/// 里的标「已导入」并禁选；点「导入」pop 回选中的绝对路径列表，取消 pop null。
class _MpvShaderPickerDialog extends StatefulWidget {
  const _MpvShaderPickerDialog({
    required this.discovered,
    required this.alreadyImported,
  });

  /// 发现到的着色器绝对路径。
  final List<String> discovered;

  /// 已在 mpv_shaders 目录里的文件名（basename），用于标「已导入」并禁选。
  final Set<String> alreadyImported;

  @override
  State<_MpvShaderPickerDialog> createState() => _MpvShaderPickerDialogState();
}

class _MpvShaderPickerDialogState extends State<_MpvShaderPickerDialog> {
  // 默认勾选所有尚未导入的；已导入的不勾（也禁选）。
  late final Set<String> _selected = <String>{
    for (final String path in widget.discovered)
      if (!widget.alreadyImported.contains(p.basename(path))) path,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_shader_mpv_pick_title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final String path in widget.discovered)
                    () {
                      final String name = p.basename(path);
                      final bool imported =
                          widget.alreadyImported.contains(name);
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(name, overflow: TextOverflow.ellipsis),
                        subtitle: imported
                            ? Text(t.video_shader_downloaded_label)
                            : null,
                        value: imported || _selected.contains(path),
                        onChanged: imported
                            ? null
                            : (bool? v) => setState(() {
                                  if (v ?? false) {
                                    _selected.add(path);
                                  } else {
                                    _selected.remove(path);
                                  }
                                }),
                      );
                    }(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(t.video_shader_import),
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
      case 'mode_b_hq':
        return t.video_shader_preset_mode_b_hq;
      case 'mode_c_hq':
        return t.video_shader_preset_mode_c_hq;
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

/// 画质档位 i18n 标签（无/低/中/高/极高）。纯映射。
String shaderTierLabel(VideoShaderTier tier) {
  switch (tier) {
    case VideoShaderTier.off:
      return t.video_shader_tier_off;
    case VideoShaderTier.low:
      return t.video_shader_tier_low;
    case VideoShaderTier.medium:
      return t.video_shader_tier_medium;
    case VideoShaderTier.high:
      return t.video_shader_tier_high;
    case VideoShaderTier.ultra:
      return t.video_shader_tier_ultra;
  }
}

/// 画质档位一句话说明（选谁用谁，告诉用户该档画质/GPU 取舍）。纯映射。
String shaderTierLabelDescription(VideoShaderTier tier) {
  switch (tier) {
    case VideoShaderTier.off:
      return t.video_shader_tier_off_hint;
    case VideoShaderTier.low:
      return t.video_shader_tier_low_hint;
    case VideoShaderTier.medium:
      return t.video_shader_tier_medium_hint;
    case VideoShaderTier.high:
      return t.video_shader_tier_high_hint;
    case VideoShaderTier.ultra:
      return t.video_shader_tier_ultra_hint;
  }
}

/// 画质档位单选器：横排五个分段按钮（无/低/中/高/极高），选中即回调 [onSelect]。
/// [current]=null（用户手工自定义勾选）时不高亮任何分段，用户仍可点任一档覆盖回标准档。
///
/// 用 [SegmentedButton]（MD3 单选）——五档互斥，选一个即整体切换底层两套状态，
/// 不让用户对着一堆陌生着色器名逐个勾（用户诉求）。窄屏不下时分段按钮自动横向滚动。
class VideoShaderTierSelector extends StatelessWidget {
  const VideoShaderTierSelector({
    required this.current,
    required this.onSelect,
    super.key,
  });

  /// 当前命中的档（null=自定义，不选中任何分段）。
  final VideoShaderTier? current;

  /// 选某档回调。
  final Future<void> Function(VideoShaderTier tier) onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SegmentedButton<VideoShaderTier>(
        segments: <ButtonSegment<VideoShaderTier>>[
          for (final VideoShaderTierSpec spec in kVideoShaderTiers)
            ButtonSegment<VideoShaderTier>(
              value: spec.tier,
              label: Text(shaderTierLabel(spec.tier)),
            ),
        ],
        selected:
            current == null ? <VideoShaderTier>{} : <VideoShaderTier>{current!},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        multiSelectionEnabled: false,
        onSelectionChanged: (Set<VideoShaderTier> selection) {
          if (selection.isEmpty) return;
          onSelect(selection.first);
        },
      ),
    );
  }
}

/// 五档画质对照表：把「无/低/中/高/极高」每一档的「档名 — 一句话说明 + 显卡要求」
/// 紧凑列出，常驻在档位选择器下方——让用户**选档前**就能横向比较各档的画质取舍与
/// GPU 门槛（型号示例已写在各档 [shaderTierLabelDescription] 里），而不是点选某档后
/// 才看到要求（用户诉求 2）。当前命中的 [current] 档加粗高亮；自定义勾选（current=null）
/// 时不高亮任何档。纯展示，不可点（切档仍走上方的 [VideoShaderTierSelector]）。
class VideoShaderTierComparison extends StatelessWidget {
  const VideoShaderTierComparison({required this.current, super.key});

  /// 当前命中的档（null=自定义勾选，不高亮任何行）。
  final VideoShaderTier? current;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final VideoShaderTierSpec spec in kVideoShaderTiers)
            () {
              final bool active = current == spec.tier;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 档名列：定宽，加粗高亮当前档，便于上下对齐成「表格」观感。
                    SizedBox(
                      width: 52,
                      child: Text(
                        shaderTierLabel(spec.tier),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? cs.primary : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 说明列：一句话 + 显卡要求（含 N卡/A卡型号示例）。
                    Expanded(
                      child: Text(
                        shaderTierLabelDescription(spec.tier),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: active
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }(),
        ],
      ),
    );
  }
}
