import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
    await adaptiveModalSheet<bool>(
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
        FushiSnackBar(
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
  // 宽屏居中 M3E 面板（圆角 28、图标 hero 头部），窄屏底部 sheet。
  Future<bool?> open(String? torrentPath) => adaptiveModalSheet<bool>(
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

/// 添加任务的来源形态（分段控件）。磁力 · 链接粘贴文本；种子文件走拖放区 /
/// 文件选择。只是输入方式的切换，提交参数仍由「手里是磁力还是 metainfo」决定。
enum _ManualTaskSource { magnet, torrent }

/// 选择行的一个选项（底部选择 sheet 用）。
class _ChoiceOption<T> {
  const _ChoiceOption(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
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

  /// 正在读 / 解析种子文件（拖放区下画波浪进度、提交禁用）。
  bool _readingTorrent = false;

  /// 内联错误（无效种子 / 提交失败）；有新输入时清掉。
  String? _error;

  /// 打开时剪贴板里识别到的磁力链接（输入框为空时给一枚「使用」chip）。
  String? _clipboardMagnet;

  _ManualTaskSource _source = _ManualTaskSource.magnet;

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
    if (torrentPath != null) {
      _source = _ManualTaskSource.torrent;
      unawaited(_loadTorrentFile(torrentPath));
    } else {
      unawaited(_detectClipboardMagnet());
    }
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
      !_readingTorrent &&
      _hasPayload &&
      _titleController.text.trim().isNotEmpty &&
      (_useRemote
          // 远端只收磁链（.torrent 文件不过线）；非视频域要 host 宣告能按域入库
          // （app 当 host 收全部四个域，无头 fushi_server 只收视频）。
          ? _metainfo == null &&
              _magnetHash != null &&
              widget.remoteTarget?.supportsKind(_discoveryKind?.name) == true
          : widget.pipeline != null && (!_isVideo || _sourceId != null));

  /// 剪贴板里有磁力链接就记下来，给一枚「使用剪贴板中的磁力链接」chip——不自动
  /// 填进去：剪贴板内容是用户别处复制的，静默改写输入框会让人以为是自己粘的。
  Future<void> _detectClipboardMagnet() async {
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } on PlatformException {
      // 平台拒绝读剪贴板（权限 / 无文本）：没有可提示的内容，按「没识别到」处理。
      return;
    } on MissingPluginException {
      return;
    }
    final String text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty || parseMagnetInfoHash(text) == null) return;
    if (_magnetController.text.trim().isNotEmpty) return;
    setState(() => _clipboardMagnet = text);
  }

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    final String text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    _useMagnetText(text);
  }

  void _useMagnetText(String text) {
    _magnetController.text = text;
    _magnetController.selection = TextSelection.collapsed(offset: text.length);
    _onMagnetChanged(text);
  }

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
      _error = null;
      _clipboardMagnet = null;
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
      setState(() => _readingTorrent = true);
      bytes = await _readTorrentBytes(file.path!);
    }
    if (!mounted) return;
    _applyTorrentBytes(bytes, file.name);
  }

  /// 拖入 / 预填路径的种子：读文件 → 与选择器同一套解析与落字段。
  Future<void> _loadTorrentFile(String path) async {
    setState(() => _readingTorrent = true);
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
    InspectedTorrentMetainfo? metainfo;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        metainfo = inspectTorrentMetainfo(bytes);
      } on TorrentMetainfoException {
        metainfo = null;
      }
    }
    final InspectedTorrentMetainfo? parsed = metainfo;
    setState(() {
      _readingTorrent = false;
      if (parsed == null) {
        // 内联 error 提示（与选择器同一句），保留已有的种子 / 输入不动。
        _error = t.download_task_add_invalid;
        return;
      }
      _error = null;
      _source = _ManualTaskSource.torrent;
      _metainfo = parsed;
      _metainfoFileName = fileName;
      _magnetController.clear();
      // 远端只收磁链：手里有本机后端时自动切回本机，否则用户得自己发现
      // 「提交按钮为什么灰着」。没有本机后端时保持远端，让 _canSubmit 挡住。
      if (_useRemote && widget.pipeline != null) _useRemote = false;
      _prefillTitle(parsed.suggestedName ?? fileName);
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
    setState(() {
      _submitting = true;
      _error = null;
    });
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
        FushiSnackBar(content: Text(t.download_task_add_submitted)),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = t.download_task_action_failed(error: '$error'),
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
    setState(() {
      _submitting = true;
      _error = null;
    });
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
        FushiSnackBar(content: Text(t.download_task_add_submitted)),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = t.download_task_action_failed(error: '$error'),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 模态框开着时页级 drop target 被 `isCurrent` 守卫挡住，拖种子进框必须由框
    // 自己接（与四个导入对话框同一范式）。
    return FushiFileDropTarget(
      enabled: !_submitting,
      debugLabel: 'manual-download-dialog',
      onDrop: _handleDialogDrop,
      child: _buildSheet(context),
    );
  }

  /// 选择行 + 底部选择 sheet：行上显示当前值，点开是一列带勾选的选项。
  Widget _choiceRow<T>({
    required Key key,
    required String title,
    required IconData icon,
    required List<_ChoiceOption<T>> options,
    required T selected,
    required ValueChanged<T> onChanged,
  }) {
    _ChoiceOption<T>? current;
    for (final _ChoiceOption<T> option in options) {
      if (option.value == selected) current = option;
    }
    return AdaptiveSettingsRow(
      key: key,
      title: title,
      subtitle: current?.label,
      icon: icon,
      showIcon: true,
      trailing: const FushiIcon(FushiIcons.chevronRight),
      onTap: _submitting
          ? null
          : () async {
              final _ChoiceOption<T>? picked = await _showChoiceSheet<T>(
                title: title,
                icon: icon,
                options: options,
                selected: selected,
              );
              if (picked != null && mounted) onChanged(picked.value);
            },
    );
  }

  Future<_ChoiceOption<T>?> _showChoiceSheet<T>({
    required String title,
    required IconData icon,
    required List<_ChoiceOption<T>> options,
    required T selected,
  }) {
    return adaptiveModalSheet<_ChoiceOption<T>>(
      context: context,
      builder: (BuildContext sheetContext) => FushiModalSheetFrame(
        title: title,
        leadingIcon: icon,
        scrollable: true,
        bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        body: FushiGroupedList(
          children: <Widget>[
            for (final _ChoiceOption<T> option in options)
              FushiListItem(
                key: ValueKey<String>('manual-task-option-${option.label}'),
                selected: option.value == selected,
                leading: option.icon == null ? null : FushiIcon(option.icon),
                title: Text(option.label),
                trailing: option.value == selected
                    ? const FushiIcon(FushiIcons.check)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceSwitch() => FushiSegmentedStrip<_ManualTaskSource>(
        key: const ValueKey<String>('manual-task-source-kind'),
        segments: <ButtonSegment<_ManualTaskSource>>[
          ButtonSegment<_ManualTaskSource>(
            value: _ManualTaskSource.magnet,
            label: Text(t.download_task_add_source_magnet),
            icon: const FushiIcon(FushiIcons.link),
          ),
          ButtonSegment<_ManualTaskSource>(
            value: _ManualTaskSource.torrent,
            label: Text(t.download_task_add_source_torrent),
            icon: const FushiIcon(FushiIcons.file),
          ),
        ],
        selected: _source,
        onChanged: (_ManualTaskSource value) {
          if (_submitting) return;
          setState(() => _source = value);
        },
      );

  Widget _buildMagnetInput(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? clipboard = _clipboardMagnet;
    return Column(
      key: const ValueKey<String>('manual-task-magnet-pane'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiTextFieldControl(
          key: const ValueKey<String>('manual-task-magnet'),
          controller: _magnetController,
          decoration: InputDecoration(
            labelText: t.anime_download_generic_hint,
            alignLabelWithHint: true,
            prefixIcon: const FushiIcon(FushiIcons.link),
            suffixIcon: FushiIconButton(
              key: const ValueKey<String>('manual-task-paste'),
              tooltip: t.paste,
              icon: FushiIcons.copy,
              onTap: _submitting ? null : () => unawaited(_pasteFromClipboard()),
            ),
          ),
          minLines: 3,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          onChanged: _onMagnetChanged,
        ),
        if (clipboard != null && _magnetController.text.trim().isEmpty) ...<
            Widget>[
          SizedBox(height: tokens.spacing.gap),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiActionChip(
              key: const ValueKey<String>('manual-task-clipboard-magnet'),
              icon: FushiIcons.link,
              label: t.download_task_add_clipboard_use,
              onPressed: () => _useMagnetText(clipboard),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTorrentDropZone(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    return FushiCard(
      key: const ValueKey<String>('manual-task-drop-zone'),
      variant: FushiCardVariant.outlined,
      onTap: _submitting ? null : () => unawaited(_pickTorrentFile()),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: <Widget>[
          const FushiListLeadingIcon(
            FushiIcons.importFile,
            shape: FushiLeadingShape.cookie,
            tone: FushiCardTone.primary,
            size: 56,
          ),
          const SizedBox(height: 12),
          Text(
            t.download_task_add_drop_hint,
            textAlign: TextAlign.center,
            style: type.bodyMedium.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('manual-task-pick-torrent'),
            onPressed: _submitting ? null : () => unawaited(_pickTorrentFile()),
            icon: const FushiIcon(FushiIcons.folderOpen, size: 18),
            label: Text(t.download_task_add_pick_torrent),
          ),
          if (_readingTorrent) ...<Widget>[
            const SizedBox(height: 16),
            const FushiLinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  /// 种子解析后的元信息预览：名称、总大小、文件数 + 文件列表（只读：选文件
  /// 在任务详情里做，这里不改提交参数）。
  Widget _buildPreview(BuildContext context, InspectedTorrentMetainfo info) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final int total = info.files.fold<int>(
      0,
      (int sum, InspectedTorrentFile file) => sum + file.length,
    );
    const int shown = 6;
    final String? name = info.suggestedName;
    return FushiCard(
      key: const ValueKey<String>('manual-task-preview'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const FushiListLeadingIcon(
                FushiIcons.file,
                shape: FushiLeadingShape.square,
                tone: FushiCardTone.tertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (name != null && name.isNotEmpty)
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: type.titleSmallEmphasized,
                      ),
                    Text(
                      _metainfoFileName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              FushiTagChip(
                label: FushiByteFormat.bytes(total),
                tone: FushiTagChipTone.surface,
              ),
              FushiTagChip(
                label: t.download_task_add_file_count(n: info.files.length),
                tone: FushiTagChipTone.surface,
              ),
            ],
          ),
          if (info.files.length > 1) ...<Widget>[
            const SizedBox(height: 10),
            FushiGroupedList(
              children: <Widget>[
                for (final InspectedTorrentFile file in info.files.take(shown))
                  FushiListItem(
                    key: ValueKey<String>('manual-task-file-${file.index}'),
                    density: FushiListDensity.compact,
                    title: Text(
                      p.basename(file.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      FushiByteFormat.bytes(file.length),
                      style: type.labelMedium.tabular.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (info.files.length > shown)
                  FushiListItem(
                    density: FushiListDensity.compact,
                    title: Text(
                      '+${info.files.length - shown}',
                      style: type.labelLarge.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, String message) {
    return FushiInlineNotice(
      key: const ValueKey<String>('manual-task-error'),
      severity: FushiNoticeSeverity.error,
      icon: FushiIcons.error,
      message: message,
    );
  }

  List<Widget> _buildOptionRows() {
    return <Widget>[
      _choiceRow<DiscoveryMediaKind?>(
        key: const ValueKey<String>('manual-task-content-kind'),
        title: t.download_task_add_content_kind,
        icon: FushiIcons.widgets,
        options: <_ChoiceOption<DiscoveryMediaKind?>>[
          _ChoiceOption<DiscoveryMediaKind?>(
            null,
            t.anime_download_kind_video,
            icon: FushiIcons.video,
          ),
          _ChoiceOption<DiscoveryMediaKind?>(
            DiscoveryMediaKind.novel,
            t.discovery_kind_novel,
            icon: FushiIcons.books,
          ),
          _ChoiceOption<DiscoveryMediaKind?>(
            DiscoveryMediaKind.manga,
            t.discovery_kind_manga,
            icon: FushiIcons.manga,
          ),
          _ChoiceOption<DiscoveryMediaKind?>(
            DiscoveryMediaKind.audiobook,
            t.discovery_kind_audiobook,
            icon: FushiIcons.audiobook,
          ),
          _ChoiceOption<DiscoveryMediaKind?>(
            DiscoveryMediaKind.game,
            t.games,
            icon: FushiIcons.games,
          ),
        ],
        selected: _discoveryKind,
        onChanged: (DiscoveryMediaKind? value) =>
            setState(() => _discoveryKind = value),
      ),
      if (_isVideo) ...<Widget>[
        _choiceRow<VideoMetadataMediaKind>(
          key: const ValueKey<String>('manual-task-media-kind'),
          title: t.media_tracking_kind,
          icon: FushiIcons.tv,
          options: <_ChoiceOption<VideoMetadataMediaKind>>[
            _ChoiceOption<VideoMetadataMediaKind>(
              VideoMetadataMediaKind.movie,
              t.collection_relation_movie,
            ),
            _ChoiceOption<VideoMetadataMediaKind>(
              VideoMetadataMediaKind.tv,
              t.series,
            ),
          ],
          selected: _mediaKind,
          onChanged: (VideoMetadataMediaKind value) =>
              setState(() => _mediaKind = value),
        ),
        _choiceRow<VideoDownloadSubtitlePolicy>(
          key: const ValueKey<String>('manual-task-subtitle-policy'),
          title: t.anime_download_include_subs,
          icon: FushiIcons.subtitles,
          options: <_ChoiceOption<VideoDownloadSubtitlePolicy>>[
            _ChoiceOption<VideoDownloadSubtitlePolicy>(
              VideoDownloadSubtitlePolicy.none,
              t.anime_download_no_subs,
            ),
            _ChoiceOption<VideoDownloadSubtitlePolicy>(
              VideoDownloadSubtitlePolicy.bestEffort,
              t.anime_download_include_subs,
            ),
          ],
          selected: _subtitlePolicy,
          onChanged: (VideoDownloadSubtitlePolicy value) =>
              setState(() => _subtitlePolicy = value),
        ),
        if (widget.sources.isNotEmpty)
          _choiceRow<int?>(
            key: const ValueKey<String>('manual-task-source'),
            title: t.video_download_target_source_title,
            icon: FushiIcons.folder,
            options: <_ChoiceOption<int?>>[
              for (final MediaSourceRow source in widget.sources)
                _ChoiceOption<int?>(source.id, source.label),
            ],
            selected: _sourceId,
            onChanged: (int? value) => setState(() => _sourceId = value),
          ),
      ],
      if (widget.remoteTarget != null)
        _choiceRow<bool>(
          key: const ValueKey<String>('manual-task-download-target'),
          title: t.download_target_label,
          icon: _useRemote ? FushiIcons.hub : FushiIcons.devices,
          options: <_ChoiceOption<bool>>[
            if (widget.pipeline != null)
              _ChoiceOption<bool>(
                false,
                t.download_target_local,
                icon: FushiIcons.devices,
              ),
            _ChoiceOption<bool>(
              true,
              t.download_target_remote(device: widget.remoteTarget!.label),
              icon: FushiIcons.hub,
            ),
          ],
          selected: _useRemote,
          onChanged: (bool value) => setState(() => _useRemote = value),
        ),
    ];
  }

  Widget _buildSheet(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final Widget sourceInput = _source == _ManualTaskSource.magnet
        ? _buildMagnetInput(context)
        : _buildTorrentDropZone(context);
    final InspectedTorrentMetainfo? metainfo = _metainfo;
    final String? error = _error;
    return FushiModalSheetFrame(
      title: t.download_task_add,
      leadingIcon: FushiIcons.download,
      scrollable: true,
      bodyPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSourceSwitch(),
          SizedBox(height: tokens.spacing.gap + 4),
          // 两种输入形态之间：尺寸弹簧 + 交叉淡入（透明度走 effects 弹簧）。
          // 零时长的 AnimatedSize 会在 performLayout 中同步通知布局变化；
          // 减弱动态效果 / 墨水屏直接替换输入，正常模式保留尺寸与淡入动画。
          if (!motion.enabled)
            sourceInput
          else
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: motion.effectsDefault.duration,
                switchInCurve: motion.effectsDefault.curve,
                switchOutCurve: motion.effectsDefault.curve,
                child: sourceInput,
              ),
            ),
          if (error != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildError(context, error),
          ],
          if (metainfo != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap + 4),
            _buildPreview(context, metainfo),
          ],
          SizedBox(height: tokens.spacing.gap + 4),
          FushiTextFieldControl(
            key: const ValueKey<String>('manual-task-title'),
            controller: _titleController,
            decoration: InputDecoration(
              labelText: t.download_task_add_title_label,
              prefixIcon: const FushiIcon(FushiIcons.edit),
            ),
            maxLines: 1,
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: tokens.spacing.gap + 8),
          Text(
            t.download_task_add_options,
            style: context.fushiType.labelLargeEmphasized.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          AdaptiveSettingsSection(children: _buildOptionRows()),
          if (_isVideo && widget.sources.isEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            _buildError(context, t.download_no_managed_video_source),
          ],
        ],
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_submitting) ...<Widget>[
            const FushiLinearProgressIndicator(),
            SizedBox(height: tokens.spacing.gap),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiTextButton(
                onPressed:
                    _submitting ? null : () => Navigator.of(context).pop(),
                child: Text(t.dialog_cancel),
              ),
              FushiFilledButton.icon(
                key: const ValueKey<String>('manual-task-submit'),
                onPressed: _canSubmit ? () => unawaited(_submit()) : null,
                icon: const FushiIcon(FushiIcons.download),
                label: Text(t.download_task_add_start),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
