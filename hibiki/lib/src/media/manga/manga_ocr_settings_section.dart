import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/ocr/cloud_ocr_client.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/utils.dart';

/// 设置区「漫画 OCR」组的正文（内联进阅读设置分类）。
///
/// 内容：内置 OCR 模型状态行（已下载/未下载 + 体积）、下载按钮（进度条 + 可取消）、
/// 删除按钮（二次确认）——**全平台显示**（P4：单框补扫只需识别三件套，移动端也
/// 用得上；整卷 OCR 向导仍桌面/远程，`isSupportedPlatform` 不支持时加一行小字说明
/// 移动端用于框选识别）。下方是外部 mokuro CLI 路径设置（仅桌面：CLI 是桌面工具）
/// 与「云端手写识别（Gemini）」子组（开关默认关 + API key 密文 + 模型名 + 明示
/// 图片上云的隐私说明）。
///
/// 服务经构造参数注入（不 `ref.read` provider），偏好与外部探测提供可注入默认实现，
/// 故最小 widget 测试注 fake 即可独立编译/通过；真实接线由 `settings_schema_manga_ocr.dart`
/// 从 provider 取服务后构造本 widget。
class MangaOcrSettingsSection extends ConsumerStatefulWidget {
  const MangaOcrSettingsSection({
    required this.service,
    this.probeExternal,
    this.mokuroPathGetter,
    this.mokuroPathSetter,
    this.cloudEnabledGetter,
    this.cloudEnabledSetter,
    this.cloudApiKeyGetter,
    this.cloudApiKeySetter,
    this.cloudModelGetter,
    this.cloudModelSetter,
    super.key,
  });

  /// 内置 OCR 服务（接口；测试注 fake）。
  final MangaOcrService service;

  /// 外部 mokuro 探测注入口（测试用）：null = 用当前路径真实构造 [ExternalMokuroRunner]。
  final Future<String?> Function(String path)? probeExternal;

  /// 外部 mokuro 路径读取（测试用）：null = 读 [appProvider] 偏好。
  final String Function()? mokuroPathGetter;

  /// 外部 mokuro 路径写入（测试用）：null = 写 [appProvider] 偏好。
  final Future<void> Function(String value)? mokuroPathSetter;

  /// 云端识别偏好注入口（测试用）：null = 走 [appProvider] 偏好委托。
  final bool Function()? cloudEnabledGetter;
  final Future<void> Function(bool value)? cloudEnabledSetter;
  final String Function()? cloudApiKeyGetter;
  final Future<void> Function(String value)? cloudApiKeySetter;
  final String Function()? cloudModelGetter;
  final Future<void> Function(String value)? cloudModelSetter;

  @override
  ConsumerState<MangaOcrSettingsSection> createState() =>
      _MangaOcrSettingsSectionState();
}

class _MangaOcrSettingsSectionState
    extends ConsumerState<MangaOcrSettingsSection> {
  late final TextEditingController _pathCtrl;
  late final TextEditingController _cloudKeyCtrl;
  late final TextEditingController _cloudModelCtrl;

  bool _cloudEnabled = false;

  MangaOcrModelStatus? _status;
  bool _loadingStatus = true;

  // 下载态。
  bool _downloading = false;
  String? _downloadingFile;
  double? _downloadProgress;
  StreamSubscription<MangaOcrDownloadEvent>? _downloadSub;

  bool _deleting = false;

  // 外部探测态。
  bool _probing = false;
  String? _probeResult;

  @override
  void initState() {
    super.initState();
    _pathCtrl = TextEditingController(text: _readPath());
    _cloudEnabled = _readCloudEnabled();
    _cloudKeyCtrl = TextEditingController(text: _readCloudApiKey());
    _cloudModelCtrl = TextEditingController(text: _readCloudModel());
    // 模型状态全平台加载（单框补扫移动端也用识别模型；只有整卷向导受
    // isSupportedPlatform 限制）。
    unawaited(_loadStatus());
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _pathCtrl.dispose();
    _cloudKeyCtrl.dispose();
    _cloudModelCtrl.dispose();
    super.dispose();
  }

  String _readPath() {
    final String Function()? getter = widget.mokuroPathGetter;
    if (getter != null) return getter();
    return ref.read(appProvider).mangaExternalMokuroPath;
  }

  Future<void> _writePath(String value) async {
    final Future<void> Function(String)? setter = widget.mokuroPathSetter;
    if (setter != null) {
      await setter(value);
      return;
    }
    await ref.read(appProvider).setMangaExternalMokuroPath(value);
  }

  bool _readCloudEnabled() {
    final bool Function()? getter = widget.cloudEnabledGetter;
    if (getter != null) return getter();
    return ref.read(appProvider).mangaCloudOcrEnabled;
  }

  Future<void> _writeCloudEnabled(bool value) async {
    final Future<void> Function(bool)? setter = widget.cloudEnabledSetter;
    if (setter != null) {
      await setter(value);
      return;
    }
    await ref.read(appProvider).setMangaCloudOcrEnabled(value);
  }

  String _readCloudApiKey() {
    final String Function()? getter = widget.cloudApiKeyGetter;
    if (getter != null) return getter();
    return ref.read(appProvider).mangaCloudOcrApiKey;
  }

  Future<void> _writeCloudApiKey(String value) async {
    final Future<void> Function(String)? setter = widget.cloudApiKeySetter;
    if (setter != null) {
      await setter(value);
      return;
    }
    await ref.read(appProvider).setMangaCloudOcrApiKey(value);
  }

  String _readCloudModel() {
    final String Function()? getter = widget.cloudModelGetter;
    if (getter != null) return getter();
    return ref.read(appProvider).mangaCloudOcrModel;
  }

  Future<void> _writeCloudModel(String value) async {
    final Future<void> Function(String)? setter = widget.cloudModelSetter;
    if (setter != null) {
      await setter(value);
      return;
    }
    await ref.read(appProvider).setMangaCloudOcrModel(value);
  }

  Future<void> _loadStatus() async {
    setState(() => _loadingStatus = true);
    MangaOcrModelStatus? status;
    try {
      status = await widget.service.modelStatus();
    } catch (_) {
      status = null;
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _loadingStatus = false;
    });
  }

  void _startDownload() {
    setState(() {
      _downloading = true;
      _downloadingFile = null;
      _downloadProgress = null;
    });
    _downloadSub = widget.service.downloadModels().listen(
      (MangaOcrDownloadEvent event) {
        if (!mounted) return;
        setState(() {
          _downloadingFile = event.fileName;
          _downloadProgress = event.totalBytes > 0
              ? (event.receivedBytes / event.totalBytes).clamp(0.0, 1.0)
              : null;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _downloadSub = null;
        });
        HibikiToast.show(msg: t.manga_ocr_download_failed);
      },
      onDone: () async {
        _downloadSub = null;
        if (!mounted) return;
        setState(() => _downloading = false);
        HibikiToast.show(msg: t.manga_ocr_download_done);
        await _loadStatus();
      },
    );
  }

  Future<void> _cancelDownload() async {
    await _downloadSub?.cancel();
    _downloadSub = null;
    if (!mounted) return;
    setState(() => _downloading = false);
  }

  Future<void> _confirmDelete() async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.manga_ocr_delete_confirm_title),
        content: Text(t.manga_ocr_delete_confirm_message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.manga_ocr_delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.service.deleteModels();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    HibikiToast.show(msg: t.manga_ocr_delete_done);
    await _loadStatus();
  }

  Future<void> _detectExternal() async {
    if (_probing) return;
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final String path = _pathCtrl.text.trim();
    await _writePath(path);
    String? version;
    try {
      final Future<String?> Function(String)? probe = widget.probeExternal;
      version = probe != null
          ? await probe(path)
          : await ExternalMokuroRunner(
              configuredPath: path.isEmpty ? null : path,
            ).probe();
    } catch (_) {
      version = null;
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = version != null
          ? t.manga_ocr_external_detected(version: version)
          : t.manga_ocr_external_not_found;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Material 透明层：cupertino 桌面嵌入渲染（BUG-009 R2 路径）下设置正文没有
    // Material 祖先，而本组含 TextField/InkWell 系控件——透明 Material 只补墨水
    // 与文本编辑依赖，不改视觉。
    return Material(
      type: MaterialType.transparency,
      child: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _sectionLabel(theme, t.manga_ocr_section),
        // 模型状态/下载全平台显示（单框补扫只需识别三件套，移动端也用）；
        // 整卷内置引擎不支持的平台补一行小字说明模型的用途。
        _buildModelBlock(theme),
        if (!widget.service.isSupportedPlatform)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t.manga_ocr_mobile_note,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        // 外部 mokuro CLI 是桌面工具，仅桌面显示。
        if (isDesktopPlatform) ...<Widget>[
          const SizedBox(height: 16),
          _buildExternalBlock(theme),
        ],
        const SizedBox(height: 16),
        _buildCloudBlock(theme),
      ],
    );
  }

  /// 云端手写识别（Gemini）子组：开关（默认关）+ API key（密文）+ 模型名 +
  /// 隐私说明（明示所选图片将发送至 Google API）。
  Widget _buildCloudBlock(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _sectionLabel(theme, t.manga_cloud_ocr_section),
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('manga_cloud_ocr_switch'),
          title: t.manga_cloud_ocr_enabled,
          value: _cloudEnabled,
          onChanged: (bool value) {
            setState(() => _cloudEnabled = value);
            unawaited(_writeCloudEnabled(value));
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('manga_cloud_ocr_api_key'),
          controller: _cloudKeyCtrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: t.manga_cloud_ocr_api_key,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (String v) => unawaited(_writeCloudApiKey(v.trim())),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('manga_cloud_ocr_model'),
          controller: _cloudModelCtrl,
          decoration: InputDecoration(
            labelText: t.manga_cloud_ocr_model,
            hintText: kCloudOcrDefaultModel,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (String v) => unawaited(_writeCloudModel(v.trim())),
        ),
        const SizedBox(height: 8),
        Text(
          t.manga_cloud_ocr_privacy,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildModelBlock(ThemeData theme) {
    if (_loadingStatus) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    final MangaOcrModelStatus? status = _status;
    final bool ready = status?.allReady ?? false;
    final String? sizeText = status == null || status.totalBytes <= 0
        ? null
        : '${_formatBytes(status.downloadedBytes)} / '
            '${_formatBytes(status.totalBytes)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: ready
              ? t.manga_ocr_model_status_ready
              : t.manga_ocr_model_status_missing,
          subtitle: sizeText,
          icon: ready ? Icons.check_circle_outline : Icons.download_outlined,
          showIcon: true,
        ),
        if (_downloading) ...<Widget>[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _downloadProgress),
          const SizedBox(height: 4),
          if (_downloadingFile != null)
            Text(
              t.manga_ocr_downloading_file(file: _downloadingFile!),
              style: theme.textTheme.bodySmall,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _cancelDownload,
              child: Text(t.dialog_cancel),
            ),
          ),
        ] else ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ready
                ? OutlinedButton.icon(
                    onPressed: _deleting ? null : _confirmDelete,
                    icon: _deleting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline, size: 18),
                    label: Text(t.manga_ocr_delete),
                  )
                : FilledButton.icon(
                    onPressed: _startDownload,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(t.manga_ocr_download),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildExternalBlock(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _pathCtrl,
          decoration: InputDecoration(
            labelText: t.manga_ocr_external_cli_label,
            hintText: t.manga_ocr_external_cli_hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (String v) => unawaited(_writePath(v.trim())),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _probing ? null : _detectExternal,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_outlined, size: 18),
              label: Text(t.manga_ocr_external_detect),
            ),
            if (_probeResult != null) ...<Widget>[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _probeResult!,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }

  static String _formatBytes(int bytes) => HibikiByteFormat.bytes(bytes);
}
