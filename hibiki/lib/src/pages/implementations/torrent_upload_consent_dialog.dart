import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';

/// 「上传/做种」首用提示对话框。首次下载时弹一次：提醒上传默认关闭、询问是否
/// 开启，并允许当场配置上传限速 / 做种时长 / 分享率上限。
///
/// 纯 UI + 回调（[onApply] 落库、设首用 flag 由调用方在回调里做），不直接依赖
/// AppModel，便于 widget 测试。用户「保持关闭」= 以 uploadEnabled:false 应用。
class TorrentUploadConsentDialog extends StatefulWidget {
  const TorrentUploadConsentDialog({
    super.key,
    required this.initialConfig,
    required this.onApply,
  });

  /// 当前下载配置（对话框在其上 copyWith 出上传相关字段）。
  final QbConnectionConfig initialConfig;

  /// 用户确认后应用最终配置（调用方负责写偏好 + 置首用 flag）。
  final Future<void> Function(QbConnectionConfig config) onApply;

  @override
  State<TorrentUploadConsentDialog> createState() =>
      _TorrentUploadConsentDialogState();
}

class _TorrentUploadConsentDialogState
    extends State<TorrentUploadConsentDialog> {
  late bool _uploadEnabled;
  late final TextEditingController _uploadLimitCtrl;
  late final TextEditingController _seedTimeCtrl;
  late final TextEditingController _seedRatioCtrl;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final QbConnectionConfig c = widget.initialConfig;
    _uploadEnabled = c.uploadEnabled;
    _uploadLimitCtrl = TextEditingController(
        text: c.uploadLimitKbps == 0 ? '' : '${c.uploadLimitKbps}');
    _seedTimeCtrl = TextEditingController(
        text: c.seedTimeLimitMinutes == 0 ? '' : '${c.seedTimeLimitMinutes}');
    _seedRatioCtrl = TextEditingController(
        text: c.seedRatioLimit == 0 ? '' : '${c.seedRatioLimit}');
  }

  @override
  void dispose() {
    _uploadLimitCtrl.dispose();
    _seedTimeCtrl.dispose();
    _seedRatioCtrl.dispose();
    super.dispose();
  }

  static int _nonNegInt(String value) {
    final int n = int.tryParse(value.trim()) ?? 0;
    return n < 0 ? 0 : n;
  }

  static double _nonNegDouble(String value) {
    final double n = double.tryParse(value.trim()) ?? 0;
    return (n.isFinite && n > 0) ? n : 0;
  }

  Future<void> _apply({required bool enable}) async {
    if (_applying) return;
    setState(() => _applying = true);
    final QbConnectionConfig next = widget.initialConfig.copyWith(
      uploadEnabled: enable,
      uploadLimitKbps: enable ? _nonNegInt(_uploadLimitCtrl.text) : null,
      seedTimeLimitMinutes: enable ? _nonNegInt(_seedTimeCtrl.text) : null,
      seedRatioLimit: enable ? _nonNegDouble(_seedRatioCtrl.text) : null,
    );
    await widget.onApply(next);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.upload_outlined),
      title: Text(t.torrent_upload_intro_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(t.torrent_upload_intro_body),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.torrent_upload_intro_enable),
              value: _uploadEnabled,
              onChanged: _applying
                  ? null
                  : (bool v) => setState(() => _uploadEnabled = v),
            ),
            if (_uploadEnabled) ...<Widget>[
              const SizedBox(height: 4),
              TextField(
                controller: _uploadLimitCtrl,
                enabled: !_applying,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.video_setting_torrent_upload_limit,
                  hintText: t.video_setting_torrent_limit_hint,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _seedTimeCtrl,
                enabled: !_applying,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.video_setting_torrent_seed_time_limit,
                  hintText: t.video_setting_torrent_seed_time_hint,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _seedRatioCtrl,
                enabled: !_applying,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: t.video_setting_torrent_seed_ratio_limit,
                  hintText: t.video_setting_torrent_seed_ratio_hint,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _applying ? null : () => _apply(enable: false),
          child: Text(t.torrent_upload_intro_keep_off),
        ),
        FilledButton(
          onPressed: _applying ? null : () => _apply(enable: _uploadEnabled),
          child: Text(t.torrent_upload_intro_confirm),
        ),
      ],
    );
  }
}
