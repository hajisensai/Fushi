import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/torrent/magnet_utils.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;

/// 「管线 + 后端落点」的一次性解析结果。两者要么都有（可以开表单），要么就是
/// 后端没配好——把它们收成一个值，调用方的重试路径才不用把三个变量各自搬一遍。
class _ManualDownloadBackend {
  const _ManualDownloadBackend({this.pipeline, this.target, this.error});

  final VideoDownloadPipelineService? pipeline;
  final VideoDownloadBackendTarget? target;

  /// 身份解析抛出的原因（后端配了但连不上时透传给用户）。
  final Object? error;

  bool get usable => pipeline != null && target != null;
}

Future<_ManualDownloadBackend> _resolveBackend(AppModel appModel) async {
  final VideoDownloadPipelineService? pipeline =
      appModel.videoDownloadPipelineService;
  if (pipeline == null) return const _ManualDownloadBackend();
  try {
    return _ManualDownloadBackend(
      pipeline: pipeline,
      target: await appModel.currentVideoDownloadBackendTarget(),
    );
  } on Object catch (error) {
    return _ManualDownloadBackend(pipeline: pipeline, error: error);
  }
}

/// 手动添加下载任务的唯一入口（下载页页头「添加任务」+ 各库页拖入 `.torrent`）。
///
/// 前置条件（后端可达 + 身份可解析）在开框前解析好：解析失败给一条可读提示，
/// 不让用户填完表单才发现后端没配。
///
/// [torrentPaths] 非空 = 拖入种子文件：每个种子各开一次对话框预填（对话框结构上
/// 是单任务的，标题/内容类型/目标来源要逐个确认），用户取消其中一个即停止后续
/// ——取消是「别再问了」，不是「跳过这个」。[initialDiscoveryKind] 按落点表面预填
/// 内容类型（null = 视频，与对话框自身约定一致），用户仍可在框里改。
Future<void> showManualDownloadTaskDialog({
  required BuildContext context,
  required AppModel appModel,
  InterconnectDownloadClient? remoteClient,
  List<String> torrentPaths = const <String>[],
  DiscoveryMediaKind? initialDiscoveryKind,
}) async {
  // 互联 host 代下载（设计 §3.3）：有已配对 host 宣告 downloads 能力时，本机没配
  // 下载后端也能打开对话框，把磁链交给 host。探测失败按「没有远端」处理。
  final InterconnectDownloadClient remote = remoteClient ??
      InterconnectDownloadClient(repo: SyncRepository(appModel.database));
  // 「下载执行设备」偏好指向的 host 优先（并作为对话框的默认落点）；没设 / 连不上
  // 时退回「第一台宣告能力的 host」——对话框里有下拉，用户看得见投给了谁。
  final DownloadExecutionResolution execution =
      await resolveDownloadExecution(appModel, client: remote);
  HostDownloadTarget? remoteTarget =
      execution is DownloadExecutionRemote ? execution.target : null;
  if (remoteTarget == null) {
    try {
      remoteTarget = await remote.probe();
    } catch (_) {
      remoteTarget = null;
    }
  }
  final bool preferRemote = execution is DownloadExecutionRemote;
  if (!context.mounted) return;
  _ManualDownloadBackend resolved = await _resolveBackend(appModel);
  // 远端只收磁链（`_canSubmit` 的远端分支拒绝 `.torrent`）：带种子进来时不走
  // 「仅远端」捷径，否则开出来的框一个都提交不了；照常引导配本机后端。
  if (!resolved.usable && remoteTarget != null && torrentPaths.isEmpty) {
    final List<MediaSourceRow> sources =
        await appModel.getManagedVideoDownloadSources();
    if (!context.mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext _) => ManualDownloadTaskDialog(
        pipeline: null,
        target: null,
        sources: sources,
        defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
        remoteClient: remote,
        remoteTarget: remoteTarget,
        initialUseRemote: preferRemote,
        initialDiscoveryKind: initialDiscoveryKind,
      ),
    );
    return;
  }
  if (!resolved.usable) {
    if (!context.mounted) return;
    // 后端没配好：**直接弹引导**，配完当场重试一次，而不是甩一句提示把用户
    // 想做的事丢掉。用户取消引导 = 明确放弃，不再补提示。
    final bool configured = await promptDownloadBackendSetup(
      context: context,
      appModel: appModel,
    );
    if (!configured || !context.mounted) return;
    resolved = await _resolveBackend(appModel);
    if (!context.mounted) return;
    if (!resolved.usable) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            resolved.error?.toString() ?? t.download_backend_not_configured,
          ),
        ),
      );
      return;
    }
  }
  final VideoDownloadPipelineService pipeline = resolved.pipeline!;
  final VideoDownloadBackendTarget target = resolved.target!;
  final List<MediaSourceRow> sources =
      await appModel.getManagedVideoDownloadSources();
  if (!context.mounted) return;
  Future<bool?> open(String? torrentPath) => showAppDialog<bool>(
        context: context,
        builder: (BuildContext _) => ManualDownloadTaskDialog(
          pipeline: pipeline,
          target: target,
          sources: sources,
          defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
          remoteClient: remote,
          remoteTarget: remoteTarget,
          initialUseRemote: preferRemote,
          initialTorrentPath: torrentPath,
          initialDiscoveryKind: initialDiscoveryKind,
        ),
      );
  if (torrentPaths.isEmpty) {
    await open(null);
    return;
  }
  for (final String torrentPath in torrentPaths) {
    final bool? submitted = await open(torrentPath);
    if (submitted != true || !context.mounted) return;
  }
}

/// 粘贴磁力 / 选或拖入 .torrent 文件 → [VideoDownloadPipelineService.enqueueManual]。
///
/// 内容类型决定入库路径：视频走完整视频流程（需要目标受管来源），小说/漫画/
/// 有声书/游戏在下载完成后整包交发现导入执行器按域入库。
///
/// 关闭结果：提交成功 pop `true`；取消 / 关闭 pop `null`。调用方按它决定要不要
/// 继续排队开下一个种子（见 [showManualDownloadTaskDialog]）。
class ManualDownloadTaskDialog extends StatefulWidget {
  const ManualDownloadTaskDialog({
    required this.pipeline,
    required this.target,
    required this.sources,
    required this.defaultSourceId,
    this.remoteClient,
    this.remoteTarget,
    this.initialUseRemote = false,
    this.initialTorrentPath,
    this.initialDiscoveryKind,
    super.key,
  });

  /// 拖入 / 外部指定的种子文件：开框后立刻读取并预填，与点「选 .torrent 文件」
  /// 选中同一个文件的结果完全一致。读不到或不是合法 metainfo 给同一条
  /// `download_task_add_invalid` 提示，框保持打开让用户改选。
  final String? initialTorrentPath;

  /// 初始内容类型（null = 视频）。拖入种子时按落点表面预填。
  final DiscoveryMediaKind? initialDiscoveryKind;

  /// 本机下载管线；null = 本机没配后端（只能投给远端 host）。
  final VideoDownloadPipelineService? pipeline;
  final VideoDownloadBackendTarget? target;

  /// 互联代下载：有 host 时对话框多一个「下载到」选择。
  final InterconnectDownloadClient? remoteClient;
  final HostDownloadTarget? remoteTarget;

  /// 「下载到」默认选 [remoteTarget]（用户在下载设置里把执行设备指到了它）。
  /// 本机没有管线时无论此值如何都只能选远端。
  final bool initialUseRemote;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;

  @override
  State<ManualDownloadTaskDialog> createState() =>
      _ManualDownloadTaskDialogState();
}

class _ManualDownloadTaskDialogState extends State<ManualDownloadTaskDialog> {
  final TextEditingController _magnetController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();

  InspectedTorrentMetainfo? _metainfo;
  String? _metainfoFileName;

  /// null = 视频（默认）；其余按域入库。
  DiscoveryMediaKind? _discoveryKind;
  VideoMetadataMediaKind _mediaKind = VideoMetadataMediaKind.movie;
  int? _sourceId;
  VideoDownloadSubtitlePolicy _subtitlePolicy =
      VideoDownloadSubtitlePolicy.none;
  bool _submitting = false;

  /// 标题框最近一次被自动预填的值：用户改过就不再覆盖。
  String _autoFilledTitle = '';

  /// true = 投给 [ManualDownloadTaskDialog.remoteTarget]。
  bool _useRemote = false;

  @override
  void initState() {
    super.initState();
    _sourceId = widget.defaultSourceId ??
        (widget.sources.isEmpty ? null : widget.sources.first.id);
    _useRemote = widget.remoteTarget != null &&
        (widget.initialUseRemote || widget.pipeline == null);
    _discoveryKind = widget.initialDiscoveryKind;
    final String? torrentPath = widget.initialTorrentPath;
    if (torrentPath != null) unawaited(_loadTorrentFile(torrentPath));
  }

  @override
  void dispose() {
    _magnetController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  String? get _magnetHash => parseMagnetInfoHash(_magnetController.text);

  bool get _hasPayload => _metainfo != null || _magnetHash != null;

  bool get _isVideo => _discoveryKind == null;

  bool get _canSubmit =>
      !_submitting &&
      _hasPayload &&
      _titleController.text.trim().isNotEmpty &&
      (_useRemote
          // 远端只收磁链（.torrent 文件不过线）；非视频域要 host 宣告能按域入库
          // （app 当 host 收全部四个域，无头 fushi_server 只收视频）。
          ? _metainfo == null &&
              _magnetHash != null &&
              widget.remoteTarget?.supportsKind(_discoveryKind?.name) == true
          : widget.pipeline != null && (!_isVideo || _sourceId != null));

  void _prefillTitle(String? candidate) {
    final String value = candidate?.trim() ?? '';
    if (value.isEmpty) return;
    final String current = _titleController.text.trim();
    if (current.isNotEmpty && current != _autoFilledTitle) return;
    _titleController.text = value;
    _autoFilledTitle = value;
  }

  void _onMagnetChanged(String value) {
    setState(() {
      if (value.trim().isNotEmpty) {
        // 磁力与 .torrent 文件互斥：以最后编辑的一方为准。
        _metainfo = null;
        _metainfoFileName = null;
      }
      _prefillTitle(parseMagnetDisplayName(value));
    });
  }

  Future<void> _pickTorrentFile() async {
    final FilePickerResult? picked = await pickFilesByExtensions(
      context: context,
      allowedExtensions: <String>['torrent'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final PlatformFile file = picked.files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await _readTorrentBytes(file.path!);
    }
    if (!mounted) return;
    _applyTorrentBytes(bytes, file.name);
  }

  /// 拖入 / 预填路径的种子：读文件 → 与选择器同一套解析与落字段。
  Future<void> _loadTorrentFile(String path) async {
    final Uint8List? bytes = await _readTorrentBytes(path);
    if (!mounted) return;
    _applyTorrentBytes(bytes, p.basename(path));
  }

  Future<Uint8List?> _readTorrentBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } on Object {
      return null;
    }
  }

  /// 种子字节 → metainfo → 填字段（清磁力框、预填标题）。选择器、拖入、初始
  /// 路径三条入口的唯一汇合点：无效种子的提示、标题预填规则只写一遍。
  void _applyTorrentBytes(Uint8List? bytes, String fileName) {
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.download_task_add_invalid)),
      );
      return;
    }
    final InspectedTorrentMetainfo metainfo;
    try {
      metainfo = inspectTorrentMetainfo(bytes);
    } on TorrentMetainfoException {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.download_task_add_invalid)),
      );
      return;
    }
    setState(() {
      _metainfo = metainfo;
      _metainfoFileName = fileName;
      _magnetController.clear();
      // 远端只收磁链：手里有本机后端时自动切回本机，否则用户得自己发现
      // 「提交按钮为什么灰着」。没有本机后端时保持远端，让 _canSubmit 挡住。
      if (_useRemote && widget.pipeline != null) _useRemote = false;
      _prefillTitle(metainfo.suggestedName ?? fileName);
    });
  }

  /// 拖文件进本对话框：只认 `.torrent`（第一个），其余忽略——磁力是文本、不会经
  /// 文件拖放通道进来；视频/字幕等在这里没有语义。
  void _handleDialogDrop(List<String> paths, Offset _) {
    if (_submitting) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    if (files.torrents.isEmpty) return;
    unawaited(_loadTorrentFile(files.torrents.first));
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    if (_useRemote) return _submitRemote();
    final VideoDownloadPipelineService? pipeline = widget.pipeline;
    final VideoDownloadBackendTarget? target = widget.target;
    if (pipeline == null || target == null) return;
    setState(() => _submitting = true);
    try {
      await pipeline.enqueueManual(
        VideoDownloadManualEnqueueRequest(
          title: _titleController.text.trim(),
          backendTarget: target,
          magnetUri: _metainfo == null ? _magnetController.text.trim() : null,
          metainfo: _metainfo,
          discoveryKind: _discoveryKind,
          mediaKind: _mediaKind,
          targetSourceId: _isVideo ? _sourceId : null,
          subtitlePolicy: _subtitlePolicy,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.download_task_add_submitted)),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(t.download_task_action_failed(error: '$error')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitRemote() async {
    final InterconnectDownloadClient? client = widget.remoteClient;
    final HostDownloadTarget? target = widget.remoteTarget;
    if (client == null || target == null) return;
    setState(() => _submitting = true);
    try {
      await client.addMagnet(
        target,
        magnetUri: _magnetController.text.trim(),
        title: _titleController.text.trim(),
        mediaKind: _mediaKind.name,
        discoveryKind: _discoveryKind?.name,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.download_task_add_submitted)),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(t.download_task_action_failed(error: '$error')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 模态框开着时页级 drop target 被 `isCurrent` 守卫挡住，拖种子进框必须由框
    // 自己接（与四个导入对话框同一范式）。
    return FushiFileDropTarget(
      enabled: !_submitting,
      debugLabel: 'manual-download-dialog',
      onDrop: _handleDialogDrop,
      child: _buildDialog(context, tokens),
    );
  }

  Widget _buildDialog(BuildContext context, FushiDesignTokens tokens) {
    return AlertDialog(
      title: Text(t.download_task_add),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.remoteTarget != null) ...<Widget>[
                DropdownButtonFormField<bool>(
                  key: const ValueKey<String>('manual-task-download-target'),
                  initialValue: _useRemote,
                  decoration: InputDecoration(
                    labelText: t.download_target_label,
                  ),
                  items: <DropdownMenuItem<bool>>[
                    if (widget.pipeline != null)
                      DropdownMenuItem<bool>(
                        value: false,
                        child: Text(t.download_target_local),
                      ),
                    DropdownMenuItem<bool>(
                      value: true,
                      child: Text(
                        t.download_target_remote(
                          device: widget.remoteTarget!.label,
                        ),
                      ),
                    ),
                  ],
                  onChanged: _submitting
                      ? null
                      : (bool? v) => setState(() => _useRemote = v ?? false),
                ),
                SizedBox(height: tokens.spacing.gap),
              ],
              TextField(
                key: const ValueKey<String>('manual-task-magnet'),
                controller: _magnetController,
                decoration: InputDecoration(
                  labelText: t.anime_download_generic_hint,
                  prefixIcon: const Icon(Icons.link),
                ),
                maxLines: 1,
                keyboardType: TextInputType.url,
                onChanged: _onMagnetChanged,
              ),
              SizedBox(height: tokens.spacing.gap),
              Row(
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const ValueKey<String>('manual-task-pick-torrent'),
                    onPressed: _submitting ? null : _pickTorrentFile,
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: Text(t.download_task_add_pick_torrent),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      _metainfoFileName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              TextField(
                key: const ValueKey<String>('manual-task-title'),
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: t.download_task_add_title_label,
                ),
                maxLines: 1,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: tokens.spacing.gap),
              DropdownButtonFormField<DiscoveryMediaKind?>(
                key: const ValueKey<String>('manual-task-content-kind'),
                initialValue: _discoveryKind,
                decoration: InputDecoration(
                  labelText: t.download_task_add_content_kind,
                ),
                items: <DropdownMenuItem<DiscoveryMediaKind?>>[
                  DropdownMenuItem<DiscoveryMediaKind?>(
                    value: null,
                    child: Text(t.anime_download_kind_video),
                  ),
                  DropdownMenuItem<DiscoveryMediaKind?>(
                    value: DiscoveryMediaKind.novel,
                    child: Text(t.discovery_kind_novel),
                  ),
                  DropdownMenuItem<DiscoveryMediaKind?>(
                    value: DiscoveryMediaKind.manga,
                    child: Text(t.discovery_kind_manga),
                  ),
                  DropdownMenuItem<DiscoveryMediaKind?>(
                    value: DiscoveryMediaKind.audiobook,
                    child: Text(t.discovery_kind_audiobook),
                  ),
                  DropdownMenuItem<DiscoveryMediaKind?>(
                    value: DiscoveryMediaKind.game,
                    child: Text(t.games),
                  ),
                ],
                onChanged: _submitting
                    ? null
                    : (DiscoveryMediaKind? value) =>
                        setState(() => _discoveryKind = value),
              ),
              if (_isVideo) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<VideoMetadataMediaKind>(
                        key: const ValueKey<String>('manual-task-media-kind'),
                        initialValue: _mediaKind,
                        decoration: InputDecoration(
                          labelText: t.media_tracking_kind,
                        ),
                        items: <DropdownMenuItem<VideoMetadataMediaKind>>[
                          DropdownMenuItem<VideoMetadataMediaKind>(
                            value: VideoMetadataMediaKind.movie,
                            child: Text(t.collection_relation_movie),
                          ),
                          DropdownMenuItem<VideoMetadataMediaKind>(
                            value: VideoMetadataMediaKind.tv,
                            child: Text(t.series),
                          ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (VideoMetadataMediaKind? value) {
                                if (value != null) {
                                  setState(() => _mediaKind = value);
                                }
                              },
                      ),
                    ),
                    SizedBox(width: tokens.spacing.gap),
                    Expanded(
                      child:
                          DropdownButtonFormField<VideoDownloadSubtitlePolicy>(
                        key: const ValueKey<String>(
                          'manual-task-subtitle-policy',
                        ),
                        initialValue: _subtitlePolicy,
                        decoration: InputDecoration(
                          labelText: t.anime_download_include_subs,
                        ),
                        items: <DropdownMenuItem<VideoDownloadSubtitlePolicy>>[
                          DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                            value: VideoDownloadSubtitlePolicy.none,
                            child: Text(t.anime_download_no_subs),
                          ),
                          DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                            value: VideoDownloadSubtitlePolicy.bestEffort,
                            child: Text(t.anime_download_include_subs),
                          ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (VideoDownloadSubtitlePolicy? value) {
                                if (value != null) {
                                  setState(() => _subtitlePolicy = value);
                                }
                              },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap),
                if (widget.sources.isEmpty)
                  Text(
                    t.download_no_managed_video_source,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  )
                else
                  DropdownButtonFormField<int>(
                    key: const ValueKey<String>('manual-task-source'),
                    initialValue: _sourceId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t.video_download_target_source_title,
                    ),
                    items: widget.sources
                        .map(
                          (MediaSourceRow source) => DropdownMenuItem<int>(
                            value: source.id,
                            child: Text(
                              source.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _submitting
                        ? null
                        : (int? value) => setState(() => _sourceId = value),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FilledButton.icon(
          key: const ValueKey<String>('manual-task-submit'),
          onPressed: _canSubmit ? () => unawaited(_submit()) : null,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(t.download_task_add),
        ),
      ],
    );
  }
}
