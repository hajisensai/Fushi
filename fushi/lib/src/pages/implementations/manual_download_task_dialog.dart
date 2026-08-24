import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi/src/media/torrent/magnet_utils.dart';
import 'package:fushi/src/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;

/// 「管线 + 后端身份」的一次性解析结果。两者要么都有（可以开表单），要么就是
/// 后端没配好——把它们收成一个值，调用方的重试路径才不用把三个变量各自搬一遍。
class _ManualDownloadBackend {
  const _ManualDownloadBackend({this.pipeline, this.identity, this.error});

  final VideoDownloadPipelineService? pipeline;
  final VideoDownloadBackendIdentity? identity;

  /// 身份解析抛出的原因（后端配了但连不上时透传给用户）。
  final Object? error;

  bool get usable => pipeline != null && identity != null;
}

Future<_ManualDownloadBackend> _resolveBackend(AppModel appModel) async {
  final VideoDownloadPipelineService? pipeline =
      appModel.videoDownloadPipelineService;
  if (pipeline == null) return const _ManualDownloadBackend();
  try {
    return _ManualDownloadBackend(
      pipeline: pipeline,
      identity: await appModel.currentVideoDownloadBackendIdentity(),
    );
  } on Object catch (error) {
    return _ManualDownloadBackend(pipeline: pipeline, error: error);
  }
}

/// 手动添加下载任务的唯一入口（下载页页头「添加任务」）。
///
/// 前置条件（后端可达 + 身份可解析）在开框前解析好：解析失败给一条可读提示，
/// 不让用户填完表单才发现后端没配。
Future<void> showManualDownloadTaskDialog({
  required BuildContext context,
  required AppModel appModel,
}) async {
  _ManualDownloadBackend resolved = await _resolveBackend(appModel);
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
  final VideoDownloadBackendIdentity identity = resolved.identity!;
  final List<MediaSourceRow> sources =
      await appModel.getManagedVideoDownloadSources();
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext _) => ManualDownloadTaskDialog(
      pipeline: pipeline,
      identity: identity,
      sources: sources,
      defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
    ),
  );
}

/// 粘贴磁力 / 选 .torrent 文件 → [VideoDownloadPipelineService.enqueueManual]。
///
/// 内容类型决定入库路径：视频走完整视频流程（需要目标受管来源），小说/漫画/
/// 有声书/游戏在下载完成后整包交发现导入执行器按域入库。
class ManualDownloadTaskDialog extends StatefulWidget {
  const ManualDownloadTaskDialog({
    required this.pipeline,
    required this.identity,
    required this.sources,
    required this.defaultSourceId,
    super.key,
  });

  final VideoDownloadPipelineService pipeline;
  final VideoDownloadBackendIdentity identity;
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

  @override
  void initState() {
    super.initState();
    _sourceId = widget.defaultSourceId ??
        (widget.sources.isEmpty ? null : widget.sources.first.id);
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
      (!_isVideo || _sourceId != null);

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
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['torrent'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final PlatformFile file = picked.files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } on Object {
        bytes = null;
      }
    }
    if (!mounted) return;
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
      _metainfoFileName = file.name;
      _magnetController.clear();
      _prefillTitle(metainfo.suggestedName ?? file.name);
    });
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    try {
      await widget.pipeline.enqueueManual(
        VideoDownloadManualEnqueueRequest(
          title: _titleController.text.trim(),
          backendIdentity: widget.identity,
          magnetUri: _metainfo == null ? _magnetController.text.trim() : null,
          metainfo: _metainfo,
          discoveryKind: _discoveryKind,
          mediaKind: _mediaKind,
          targetSourceId: _isVideo ? _sourceId : null,
          subtitlePolicy: _subtitlePolicy,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
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
    return AlertDialog(
      title: Text(t.download_task_add),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('manual-task-magnet'),
                controller: _magnetController,
                decoration: InputDecoration(
                  labelText: t.anime_download_generic_hint,
                  prefixIcon: const Icon(Icons.link),
                ),
                maxLines: 1,
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
