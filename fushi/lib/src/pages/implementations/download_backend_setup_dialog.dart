import 'package:flutter/material.dart';

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/qb_torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 下载后端配置引导。
///
/// 「请先配置下载后端」以前只是一句话 + 一个「去设置」按钮：用户被丢进整页
/// 下载设置（后端、限速、上传、做种、内存、连接数、代理……几十个字段），要自己
/// 认出哪几个是**现在**必须填的。本对话框把这段路收成一步——只问「谁来下载」，
/// 只显示所选后端**必填**的那几个字段，配完当场就能用。
///
/// 内置引擎排在第一位：它是 [QbConnectionConfig.backendAuto] 在有引擎的平台上的
/// 解析结果，也是唯一不需要用户另外装软件的选项。外接 qBittorrent 排第二。
///
/// 纯 UI + AppModel 写入；不做导航，调用方拿返回值决定要不要重算前置条件。
class DownloadBackendSetupDialog extends StatefulWidget {
  const DownloadBackendSetupDialog({
    required this.appModel,
    super.key,
    this.embeddedSupportedOverride,
  });

  final AppModel appModel;

  /// 仅测试注入：覆盖「本平台是否有内置引擎」的判据（同
  /// `TorrentSettingsSection.embeddedSupportedOverride`）。null = 问 AppModel。
  final bool? embeddedSupportedOverride;

  @override
  State<DownloadBackendSetupDialog> createState() =>
      _DownloadBackendSetupDialogState();
}

class _DownloadBackendSetupDialogState
    extends State<DownloadBackendSetupDialog> {
  late final QbConnectionConfig _initial =
      effectiveTorrentConfig(widget.appModel.qbConnectionConfig);

  late final bool _embeddedSupported = widget.embeddedSupportedOverride ??
      widget.appModel.supportsEmbeddedTorrent;

  /// 当前选中的后端。初值走 [QbConnectionConfig.resolveBackend]，所以
  /// 「从没配过」（backend = auto）在有内置引擎的平台上开屏即停在内置引擎，
  /// 用户直接点「完成」就配好了。
  late String _backend =
      _initial.resolveBackend(embeddedSupported: _embeddedSupported);

  late final TextEditingController _urlCtrl =
      TextEditingController(text: _initial.baseUrl);
  late final TextEditingController _userCtrl =
      TextEditingController(text: _initial.username);
  late final TextEditingController _passCtrl =
      TextEditingController(text: _initial.password);

  bool _probing = false;
  bool _saving = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  bool get _isEmbedded => _backend == QbConnectionConfig.backendEmbedded;

  /// 当前选择是否已经可用：内置引擎要宿主真就绪（缺 DLL 的包配了也下不了），
  /// 外接 qb 至少要有地址。判据与 `torrentBackendReady` 同源。
  bool get _canFinish {
    if (_saving) return false;
    if (_isEmbedded) return widget.appModel.isEmbeddedTorrentReady;
    return _urlCtrl.text.trim().isNotEmpty;
  }

  QbConnectionConfig _composed() => _initial.copyWith(
        backend: _backend,
        baseUrl: _urlCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );

  /// 测试连接：用**对话框里当前填的值**建后端，而不是已保存的配置——否则用户
  /// 填完还没保存就点测试，测的是上一份配置，结果与所见不符。
  Future<void> _probeConnection() async {
    if (_probing) return;
    setState(() => _probing = true);
    final TorrentBackend backend =
        widget.appModel.createTorrentBackend(_composed());
    String? version;
    String? failure;
    try {
      version = await backend.probeConnection();
    } finally {
      if (version == null && backend is QbTorrentBackend) {
        failure = backend.lastProbeFailure;
      }
      backend.close();
    }
    if (!mounted) return;
    setState(() => _probing = false);
    final String message;
    if (version != null) {
      message = t.download_test_connection_ok(version: version);
    } else if (failure != null && failure.isNotEmpty) {
      message = t.download_test_connection_failed_reason(message: failure);
    } else {
      message = t.download_test_connection_failed;
    }
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.appModel.setQbConnectionConfig(_composed());
    // 后端刚变，管线 runtime 要跟着重建：上一次启动因为没有可用后端而失败时
    // service 会留 null，不重建的话配完仍然是「后端未配置」。
    await widget.appModel.reloadVideoDownloadPipelineRuntime();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: (String _) => setState(() {}),
      ),
    );
  }

  Widget _note(ThemeData theme, String text, {bool warning = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: warning
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String saveRoot = widget.appModel.downloadSaveRoot;
    // 走设计系统的对话框壳，**不能**用 AlertDialog：后者把内容裹进
    // IntrinsicWidth，而后端选择器 [FushiSegmentedStrip] 内部是 LayoutBuilder
    // （不支持被问固有尺寸），两者相遇当场 assert。
    return FushiDialogFrame(
      maxWidth: 460,
      maxHeightFactor: 0.82,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.download_backend_setup_title,
        leadingIcon: Icons.download_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _note(theme, t.download_backend_setup_intro),
            if (_embeddedSupported)
              FushiSegmentedStrip<String>(
                segments: <ButtonSegment<String>>[
                  ButtonSegment<String>(
                    value: QbConnectionConfig.backendEmbedded,
                    label: Text(t.video_setting_torrent_backend_embedded),
                  ),
                  ButtonSegment<String>(
                    value: QbConnectionConfig.backendQbittorrent,
                    label: Text(t.video_setting_torrent_backend_qb),
                  ),
                ],
                selected: _backend,
                onChanged: (String value) => setState(() => _backend = value),
              )
            else
              _note(theme, t.download_backend_unsupported_note),
            const SizedBox(height: 12),
            if (_isEmbedded) ...<Widget>[
              _note(theme, t.download_backend_embedded_hint),
              if (!widget.appModel.isEmbeddedTorrentReady)
                _note(theme, t.download_backend_embedded_unavailable,
                    warning: true)
              else if (saveRoot.isNotEmpty) ...<Widget>[
                Text(
                  t.download_save_root_title,
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 2),
                _note(theme, saveRoot),
              ],
            ] else ...<Widget>[
              _note(theme, t.download_backend_qb_hint),
              _field(
                controller: _urlCtrl,
                label: t.video_setting_qb_url,
                hint: t.video_setting_qb_url_hint,
                keyboard: TextInputType.url,
              ),
              _field(controller: _userCtrl, label: t.video_setting_qb_username),
              _field(
                controller: _passCtrl,
                label: t.video_setting_qb_password,
                obscure: true,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _probing || _urlCtrl.text.trim().isEmpty
                      ? null
                      : _probeConnection,
                  icon: _probing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(t.download_test_connection),
                ),
              ),
            ],
          ],
        ),
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(false),
              child: Text(t.dialog_cancel),
            ),
            SizedBox(width: tokens.spacing.gap),
            FilledButton(
              onPressed: _canFinish ? _finish : null,
              child: Text(t.dialog_done),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「下载后端未配置」的统一出口：**直接弹配置引导**，而不是把用户支去设置页
/// 自己找字段。返回 true = 用户配完了（调用方据此重算前置条件 / 重试原动作）。
Future<bool> promptDownloadBackendSetup({
  required BuildContext context,
  required AppModel appModel,
}) async {
  final bool? done = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext _) => DownloadBackendSetupDialog(appModel: appModel),
  );
  return done ?? false;
}
