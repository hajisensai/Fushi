/// 设置 › 音乐 › 插件音源（docs/specs/2026-10-28-music-plugins.md）：从 `.fushiplug` 文件
/// 安装（先校验、展示清单 / 权限 / 网络域名 / 签名，用户确认后按确认时的摘要安装）、启停、卸载。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_login.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 能力 → 用户看得懂的名字。
String musicPluginCapabilityLabel(String capability) => switch (capability) {
  'search' => t.music_plugins_cap_search,
  'album' => t.music_section_albums,
  'playlist' => t.music_section_playlists,
  'artist' => t.music_section_artists,
  'stream' => t.music_plugins_cap_stream,
  'lyrics' => t.music_plugins_cap_lyrics,
  _ => capability,
};

/// 权限 → 用户看得懂的名字。
String musicPluginPermissionLabel(String permission) => switch (permission) {
  'network' => t.music_plugins_perm_network,
  'storage' => t.music_plugins_perm_storage,
  'insecureHttp' => t.music_plugins_perm_insecure_http,
  _ => permission,
};

/// 插件错误给用户看的部分（宿主已截成第一行；这里兜住非插件异常的多行文本）。
String musicPluginErrorText(Object error) => musicPluginErrorSummary(
  error is MusicPluginException ? error.message : '$error',
);

class MusicPluginSettingsBody extends StatefulWidget {
  const MusicPluginSettingsBody({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MusicPluginSettingsBody> createState() =>
      _MusicPluginSettingsBodyState();
}

class _MusicPluginSettingsBodyState extends State<MusicPluginSettingsBody> {
  MusicPluginManager get _manager => widget.appModel.musicPluginManager;
  late Future<List<InstalledMusicPlugin>> _plugins = _manager.list();
  bool _busy = false;

  void _reload() => setState(() {
    _plugins = _manager.list();
  });

  Future<void> _install() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['fushiplug', 'zip'],
      withData: true,
    );
    final PlatformFile? file = picked?.files.firstOrNull;
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final Uint8List bytes =
          file.bytes ?? await File(file.path!).readAsBytes();
      final MusicPluginPackageInfo info = await _manager.inspect(bytes);
      if (!mounted) return;
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.music_plugins_install_title,
        icon: FushiIcons.browserExtension,
        confirmLabel: t.music_plugins_install_action,
        content: MusicPluginPackageDetails(info: info),
      );
      if (!ok) return;
      await _manager.install(bytes, info.digest);
      FushiToast.show(
        msg: t.music_plugins_installed(name: info.manifest.name),
        severity: ToastSeverity.success,
      );
      _reload();
    } on Object catch (e) {
      FushiToast.show(
        msg: t.music_plugins_install_failed(error: musicPluginErrorText(e)),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall(InstalledMusicPlugin p) async {
    final String name = p.info?.manifest.name ?? p.id;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_plugins_uninstall,
      message: t.music_plugins_uninstall_confirm(name: name),
      destructive: true,
    );
    if (!ok) return;
    await _manager.uninstall(p.id);
    _reload();
  }

  Future<void> _toggle(InstalledMusicPlugin p, bool on) async {
    await _manager.setEnabled(p.id, on);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<List<InstalledMusicPlugin>>(
      future: _plugins,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<InstalledMusicPlugin>> snap,
          ) {
            final List<InstalledMusicPlugin> plugins =
                snap.data ?? const <InstalledMusicPlugin>[];
            return FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  Text(
                    t.music_plugins_hint,
                    style: context.fushiType.bodySmall,
                  ),
                  if (snap.connectionState != ConnectionState.done || _busy)
                    const FushiLinearProgressIndicator()
                  else if (plugins.isEmpty)
                    Text(
                      t.music_plugins_empty,
                      style: context.fushiType.bodyMedium,
                    ),
                  for (int i = 0; i < plugins.length; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: _PluginTile(
                        key: ValueKey<String>(
                          'music-plugin-setting-${plugins[i].id}',
                        ),
                        plugin: plugins[i],
                        appModel: widget.appModel,
                        onToggle: (bool v) => unawaited(_toggle(plugins[i], v)),
                        onUninstall: () => unawaited(_uninstall(plugins[i])),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FushiPressScale(
                      child: FushiFilledButton.icon(
                        key: const ValueKey<String>('music_plugin_install'),
                        onPressed: _busy ? null : () => unawaited(_install()),
                        icon: const FushiIcon(FushiIcons.importFile),
                        label: Text(t.music_plugins_install),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
    );
  }
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({
    super.key,
    required this.plugin,
    required this.appModel,
    required this.onToggle,
    required this.onUninstall,
  });

  final InstalledMusicPlugin plugin;
  final AppModel appModel;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginManifest? m = plugin.info?.manifest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          icon: plugin.info == null
              ? FushiIcons.warning
              : FushiIcons.browserExtension,
          showIcon: true,
          title: m?.name ?? plugin.id,
          subtitle: m == null
              ? t.music_plugins_broken
              : <String>[
                  t.music_plugins_version(version: m.version),
                  m.id,
                  if (m.author != null) m.author!,
                ].join(' · '),
          value: plugin.enabled && plugin.info != null,
          onChanged: plugin.info == null ? null : onToggle,
        ),
        if (plugin.usable && m!.can(MusicPluginCapability.login))
          _PluginAccountRow(
            key: ValueKey<String>('music-plugin-account-${plugin.id}'),
            appModel: appModel,
            manifest: m,
          ),
        Padding(
          padding: EdgeInsets.only(left: tokens.spacing.gap),
          child: Wrap(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              if (plugin.info != null)
                FushiPressScale(
                  child: FushiTextButton.icon(
                    onPressed: () => unawaited(
                      showFushiConfirmDialog(
                        context: context,
                        title: m!.name,
                        icon: FushiIcons.browserExtension,
                        cancelLabel: MaterialLocalizations.of(
                          context,
                        ).closeButtonLabel,
                        confirmLabel: MaterialLocalizations.of(
                          context,
                        ).okButtonLabel,
                        content: MusicPluginPackageDetails(info: plugin.info!),
                      ),
                    ),
                    icon: const FushiIcon(FushiIcons.info),
                    label: Text(t.music_plugins_permissions),
                  ),
                ),
              FushiPressScale(
                child: FushiTextButton.icon(
                  key: ValueKey<String>('music-plugin-uninstall-${plugin.id}'),
                  onPressed: onUninstall,
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.music_plugins_uninstall),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 插件包详情（安装确认 / 已装插件详情共用）：名称版本、说明、能力、权限、网络域名、签名。
class MusicPluginPackageDetails extends StatelessWidget {
  const MusicPluginPackageDetails({super.key, required this.info});

  final MusicPluginPackageInfo info;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginManifest m = info.manifest;
    final TextStyle label = context.fushiType.labelLarge;
    final TextStyle body = context.fushiType.bodyMedium;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap * 0.5,
      children: <Widget>[
        Text(
          <String>[
            m.name,
            t.music_plugins_version(version: m.version),
            if (m.author != null) m.author!,
          ].join(' · '),
          style: context.fushiType.titleMedium,
        ),
        Text(m.id, style: context.fushiType.bodySmall),
        if (m.description != null) Text(m.description!, style: body),
        SizedBox(height: tokens.spacing.gap * 0.5),
        Text(t.music_plugins_capabilities, style: label),
        Text(
          m.capabilities.map(musicPluginCapabilityLabel).join('、'),
          style: body,
        ),
        Text(t.music_plugins_permissions, style: label),
        Text(
          m.permissions.isEmpty
              ? '—'
              : m.permissions.map(musicPluginPermissionLabel).join('、'),
          style: body,
        ),
        if (m.networkDomains.isNotEmpty) ...<Widget>[
          Text(t.music_plugins_domains, style: label),
          Text(m.networkDomains.join('\n'), style: body),
        ],
        SizedBox(height: tokens.spacing.gap * 0.5),
        Row(
          spacing: tokens.spacing.gap * 0.5,
          children: <Widget>[
            FushiIcon(
              info.signer == null ? FushiIcons.warning : FushiIcons.verified,
              size: 18,
            ),
            Expanded(
              child: Text(
                info.signer == null
                    ? t.music_plugins_unsigned
                    : t.music_plugins_signed(key: _shortKey(info.signer!)),
                style: context.fushiType.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _shortKey(String key) =>
      key.length <= 16 ? key : '${key.substring(0, 16)}…';
}

/// 插件账号：登录状态 + 登录 / 退出。账号状态每次进页都向插件现查（插件自己判断凭据是否失效）。
class _PluginAccountRow extends StatefulWidget {
  const _PluginAccountRow({
    super.key,
    required this.appModel,
    required this.manifest,
  });

  final AppModel appModel;
  final MusicPluginManifest manifest;

  @override
  State<_PluginAccountRow> createState() => _PluginAccountRowState();
}

class _PluginAccountRowState extends State<_PluginAccountRow> {
  MusicPluginSource get _source =>
      widget.appModel.musicPluginManager.source(widget.manifest.id);
  late Future<MusicPluginAccount> _account = _source.account();

  void _reload() => setState(() {
    _account = _source.account();
  });

  Future<void> _login() async {
    if (await openMusicPluginLogin(
      context,
      appModel: widget.appModel,
      manifest: widget.manifest,
    )) {
      _reload();
    }
  }

  Future<void> _logout() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_plugin_account_logout,
      message: t.music_plugin_logout_confirm(name: widget.manifest.name),
      destructive: true,
    );
    if (!ok) return;
    try {
      await _source.logout();
      widget.appModel.onMusicPluginAccountChanged(widget.manifest.id);
    } on MusicPluginException catch (e) {
      FushiToast.show(
        msg: musicPluginErrorText(e),
        severity: ToastSeverity.error,
      );
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<MusicPluginAccount>(
      future: _account,
      builder: (BuildContext context, AsyncSnapshot<MusicPluginAccount> snap) {
        final MusicPluginAccount? a = snap.data;
        final String status = snap.hasError
            ? musicPluginErrorText(snap.error!)
            : a == null
            ? '…'
            : a.loggedIn
            ? <String>[
                t.music_plugin_account_signed_in(name: a.name ?? '—'),
                ?a.badge,
              ].join(' · ')
            : t.music_plugin_account_anonymous;
        return Padding(
          padding: EdgeInsets.only(left: tokens.spacing.gap),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap * 0.5,
            children: <Widget>[
              FushiIcon(FushiIcons.account, size: 18),
              Text(
                status,
                key: ValueKey<String>(
                  'music-plugin-account-status-${widget.manifest.id}',
                ),
                style: context.fushiType.bodyMedium,
              ),
              if (a != null && !a.loggedIn || snap.hasError)
                FushiPressScale(
                  child: FushiTextButton.icon(
                    key: ValueKey<String>(
                      'music-plugin-login-${widget.manifest.id}',
                    ),
                    onPressed: () => unawaited(_login()),
                    icon: const FushiIcon(FushiIcons.login),
                    label: Text(t.music_plugin_account_login),
                  ),
                ),
              if (a != null && a.loggedIn)
                FushiPressScale(
                  child: FushiTextButton.icon(
                    key: ValueKey<String>(
                      'music-plugin-logout-${widget.manifest.id}',
                    ),
                    onPressed: () => unawaited(_logout()),
                    icon: const FushiIcon(FushiIcons.logout),
                    label: Text(t.music_plugin_account_logout),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
