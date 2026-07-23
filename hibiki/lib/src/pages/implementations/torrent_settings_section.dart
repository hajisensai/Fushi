import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';

/// 下载后端配置（后端二选一 + qb 连接 / 内置引擎限速·上传·做种·内存·连接数）。
/// 从「设置→视频」搬到「下载」页——下载既已独立成页，配置就该在页内，不再埋进
/// 视频设置。所有字段写 `QbConnectionConfig`（即时生效到内置引擎）。
class TorrentSettingsSection extends ConsumerStatefulWidget {
  const TorrentSettingsSection({super.key});

  @override
  ConsumerState<TorrentSettingsSection> createState() =>
      _TorrentSettingsSectionState();
}

class _TorrentSettingsSectionState
    extends ConsumerState<TorrentSettingsSection> {
  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  QbConnectionConfig get _config =>
      effectiveTorrentConfig(ref.read(appProvider).qbConnectionConfig);

  /// 「测试连接」进行中（按钮禁用防重入）。
  bool _probing = false;

  /// 分类输入框：持 controller 是为了失焦回填——清空时存储侧兜底 'hibiki'，
  /// 失焦把实际生效值写回输入框，所见即所得（不再「显示空、实际 hibiki」）。
  late final TextEditingController _categoryCtrl =
      TextEditingController(text: _config.category);
  late final FocusNode _categoryFocus = FocusNode()
    ..addListener(_onCategoryFocusChanged);

  void _onCategoryFocusChanged() {
    if (_categoryFocus.hasFocus) return;
    final String effective = _config.category;
    if (_categoryCtrl.text.trim() != effective) {
      _categoryCtrl.text = effective;
    }
  }

  @override
  void dispose() {
    _categoryFocus.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _commit(
      QbConnectionConfig Function(QbConnectionConfig c) mutate) async {
    await ref.read(appProvider).setQbConnectionConfig(mutate(_config));
    if (mounted) setState(() {});
  }

  /// 测试与下载后端的连通性（按当前配置解析后端；qb = WebUI 版本号）。
  /// 成功 snack 显示版本，失败提示检查地址/账号。
  Future<void> _probeConnection() async {
    if (_probing) return;
    setState(() => _probing = true);
    final TorrentBackend backend =
        ref.read(appProvider).createTorrentBackend(_config);
    String? version;
    try {
      version = await backend.probeConnection();
    } finally {
      backend.close();
    }
    if (!mounted) return;
    setState(() => _probing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(version == null
          ? t.download_test_connection_failed
          : t.download_test_connection_ok(version: version)),
    ));
  }

  static int _nonNegInt(String v) {
    final int n = int.tryParse(v.trim()) ?? 0;
    return n < 0 ? 0 : n;
  }

  static double _nonNegDouble(String v) {
    final double n = double.tryParse(v.trim()) ?? 0;
    return (n.isFinite && n > 0) ? n : 0;
  }

  Widget _text({
    required String label,
    String? initial,
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
    TextEditingController? controller,
    FocusNode? focusNode,
    required ValueChanged<String> onChanged,
  }) {
    assert(
        (initial == null) != (controller == null), 'initial 与 controller 二选一');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: initial,
        controller: controller,
        focusNode: focusNode,
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _numField({
    required String label,
    required int value,
    String? hint,
    bool decimal = false,
    required ValueChanged<String> onChanged,
  }) {
    return _text(
      label: label,
      initial: value == 0 ? '' : '$value',
      hint: hint,
      keyboard: decimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.number,
      onChanged: onChanged,
    );
  }

  Widget _switch({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return AdaptiveSettingsSwitchRow(
      title: label,
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(text,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: theme.colorScheme.primary)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final QbConnectionConfig c = _config;
    final String backend = c.resolveBackend(isDesktop: _isDesktop);
    final bool isQb = backend == QbConnectionConfig.backendQbittorrent;
    final bool isEmbedded = backend == QbConnectionConfig.backendEmbedded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 后端二选一。
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                value: QbConnectionConfig.backendQbittorrent,
                label: Text(t.video_setting_torrent_backend_qb),
              ),
              ButtonSegment<String>(
                value: QbConnectionConfig.backendEmbedded,
                label: Text(t.video_setting_torrent_backend_embedded),
              ),
            ],
            selected: <String>{backend},
            onSelectionChanged: (Set<String> s) =>
                _commit((QbConnectionConfig c) => c.copyWith(backend: s.first)),
          ),
        ),
        const SizedBox(height: 12),

        // 外接 qb 连接字段。
        if (isQb) ...<Widget>[
          _text(
            label: t.video_setting_qb_url,
            initial: c.baseUrl,
            hint: t.video_setting_qb_url_hint,
            keyboard: TextInputType.url,
            onChanged: (String v) => _commit(
                (QbConnectionConfig c) => c.copyWith(baseUrl: v.trim())),
          ),
          _text(
            label: t.video_setting_qb_username,
            initial: c.username,
            onChanged: (String v) => _commit(
                (QbConnectionConfig c) => c.copyWith(username: v.trim())),
          ),
          _text(
            label: t.video_setting_qb_password,
            initial: c.password,
            obscure: true,
            onChanged: (String v) =>
                _commit((QbConnectionConfig c) => c.copyWith(password: v)),
          ),
          // 测试连接：probeConnection 早已存在，给用户一个即时验证入口
          // （成功显示 WebUI 版本，失败提示查地址/账号），不必推一次种子试错。
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _probing ? null : _probeConnection,
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
          ),
        ],

        // 分类（两后端通用）。清空时存储侧兜底 'hibiki'，失焦回填生效值
        // （见 [_onCategoryFocusChanged]），所见即所得。
        _text(
          label: t.video_setting_qb_category,
          controller: _categoryCtrl,
          focusNode: _categoryFocus,
          hint: t.video_setting_qb_category_hint,
          onChanged: (String v) => _commit((QbConnectionConfig c) =>
              c.copyWith(category: v.trim().isEmpty ? 'hibiki' : v.trim())),
        ),

        // 内置引擎资源限制。
        if (isEmbedded) ...<Widget>[
          _numField(
            label: t.video_setting_torrent_download_limit,
            value: c.downloadLimitKbps,
            hint: t.video_setting_torrent_limit_hint,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(downloadLimitKbps: _nonNegInt(v))),
          ),
          AdaptiveSettingsSwitchRow(
            title: t.video_setting_torrent_upload_enabled,
            subtitle: t.video_setting_torrent_upload_enabled_hint,
            value: c.uploadEnabled,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(uploadEnabled: v)),
          ),
          if (c.uploadEnabled) ...<Widget>[
            _numField(
              label: t.video_setting_torrent_upload_limit,
              value: c.uploadLimitKbps,
              hint: t.video_setting_torrent_limit_hint,
              onChanged: (String v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(uploadLimitKbps: _nonNegInt(v))),
            ),
            _numField(
              label: t.video_setting_torrent_seed_time_limit,
              value: c.seedTimeLimitMinutes,
              hint: t.video_setting_torrent_seed_time_hint,
              onChanged: (String v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(seedTimeLimitMinutes: _nonNegInt(v))),
            ),
            _text(
              label: t.video_setting_torrent_seed_ratio_limit,
              initial: c.seedRatioLimit == 0 ? '' : '${c.seedRatioLimit}',
              hint: t.video_setting_torrent_seed_ratio_hint,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (String v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(seedRatioLimit: _nonNegDouble(v))),
            ),
          ],
          _numField(
            label: t.video_setting_torrent_max_connections,
            value: c.maxConnections,
            hint: t.video_setting_torrent_connections_hint,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(maxConnections: _nonNegInt(v))),
          ),
          _numField(
            label: t.video_setting_torrent_memory_limit,
            value: c.memoryLimitMb,
            hint: t.video_setting_torrent_memory_hint,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(memoryLimitMb: _nonNegInt(v))),
          ),

          // ---- 会话设置（抄 qB 关键项）----
          _sectionLabel(theme, t.video_setting_torrent_section_session),
          _numField(
            label: t.video_setting_torrent_listen_port,
            value: c.listenPort,
            hint: t.video_setting_torrent_listen_port_hint,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(listenPort: _nonNegInt(v))),
          ),
          _switch(
            label: t.video_setting_torrent_dht,
            value: c.enableDht,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(enableDht: v)),
          ),
          _switch(
            label: t.video_setting_torrent_lsd,
            value: c.enableLsd,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(enableLsd: v)),
          ),
          _switch(
            label: t.video_setting_torrent_upnp,
            value: c.enableUpnp,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(enableUpnp: v)),
          ),
          _switch(
            label: t.video_setting_torrent_natpmp,
            value: c.enableNatpmp,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(enableNatpmp: v)),
          ),
          _switch(
            label: t.video_setting_torrent_anonymous,
            value: c.anonymousMode,
            onChanged: (bool v) =>
                _commit((QbConnectionConfig c) => c.copyWith(anonymousMode: v)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: <ButtonSegment<int>>[
                  ButtonSegment<int>(
                    value: QbConnectionConfig.encryptionPrefer,
                    label: Text(t.video_setting_torrent_encryption_prefer),
                  ),
                  ButtonSegment<int>(
                    value: QbConnectionConfig.encryptionForced,
                    label: Text(t.video_setting_torrent_encryption_forced),
                  ),
                  ButtonSegment<int>(
                    value: QbConnectionConfig.encryptionDisabled,
                    label: Text(t.video_setting_torrent_encryption_disabled),
                  ),
                ],
                selected: <int>{c.encryptionMode},
                onSelectionChanged: (Set<int> s) => _commit(
                    (QbConnectionConfig c) =>
                        c.copyWith(encryptionMode: s.first)),
              ),
            ),
          ),
          _numField(
            label: t.video_setting_torrent_active_downloads,
            value: c.maxActiveDownloads,
            hint: t.video_setting_torrent_zero_default,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(maxActiveDownloads: _nonNegInt(v))),
          ),
          _numField(
            label: t.video_setting_torrent_active_seeds,
            value: c.maxActiveSeeds,
            hint: t.video_setting_torrent_zero_default,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(maxActiveSeeds: _nonNegInt(v))),
          ),
          _numField(
            label: t.video_setting_torrent_upload_slots,
            value: c.maxUploadSlots,
            hint: t.video_setting_torrent_zero_default,
            onChanged: (String v) => _commit((QbConnectionConfig c) =>
                c.copyWith(maxUploadSlots: _nonNegInt(v))),
          ),

          // ---- 反吸血（抄 qBittorrent-ClientBlocker）----
          _sectionLabel(theme, t.video_setting_torrent_section_antileech),
          _switch(
            label: t.video_setting_torrent_antileech,
            value: c.antiLeechEnabled,
            onChanged: (bool v) => _commit(
                (QbConnectionConfig c) => c.copyWith(antiLeechEnabled: v)),
          ),
          if (c.antiLeechEnabled) ...<Widget>[
            _switch(
              label: t.video_setting_torrent_ban_progress_cheat,
              value: c.banProgressCheat,
              onChanged: (bool v) => _commit(
                  (QbConnectionConfig c) => c.copyWith(banProgressCheat: v)),
            ),
            _switch(
              label: t.video_setting_torrent_ban_relative_cheat,
              value: c.banRelativeProgressCheat,
              onChanged: (bool v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(banRelativeProgressCheat: v)),
            ),
            _numField(
              label: t.video_setting_torrent_max_ip_ports,
              value: c.maxIpPortCount,
              hint: t.video_setting_torrent_zero_off,
              onChanged: (String v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(maxIpPortCount: _nonNegInt(v))),
            ),
            _numField(
              label: t.video_setting_torrent_ban_time,
              value: c.banTimeMinutes,
              hint: t.video_setting_torrent_ban_time_hint,
              onChanged: (String v) => _commit((QbConnectionConfig c) =>
                  c.copyWith(banTimeMinutes: _nonNegInt(v))),
            ),
          ],
        ],
      ],
    );
  }
}
