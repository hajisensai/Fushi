/// 设置 › 音乐 › 服务器曲库（音乐方案 §13 P5）：Jellyfin 家族（凭据就是视频的媒体服务器
/// 配置，这里只列出、不另登录）与 OpenSubsonic（这里增删），每台一个「显示在曲库里」开关
/// （显式 opt-in 混排）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';

import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 服务器曲库设置页的正文。
class MusicServerSettingsBody extends StatefulWidget {
  const MusicServerSettingsBody({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MusicServerSettingsBody> createState() =>
      _MusicServerSettingsBodyState();
}

class _MusicServerSettingsBodyState extends State<MusicServerSettingsBody> {
  late Future<List<MusicServerBrowser>> _servers = loadMusicServerBrowsers(
    widget.appModel,
  );

  void _reload() =>
      setState(() => _servers = loadMusicServerBrowsers(widget.appModel));

  Future<void> _toggleMix(MusicServerBrowser server, bool on) async {
    final Set<String> mix = <String>{
      ...widget.appModel.prefsRepo.musicServerLibraryMix,
    };
    if (on) {
      mix.add(server.serverId);
    } else {
      mix.remove(server.serverId);
    }
    await widget.appModel.prefsRepo.setMusicServerLibraryMix(mix);
    if (mounted) setState(() {});
  }

  Future<void> _remove(MusicServerBrowser server) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_server_remove,
      message: t.music_server_remove_confirm(name: server.displayName),
      destructive: true,
    );
    if (!ok) return;
    await widget.appModel.prefsRepo
        .setMusicSubsonicServers(<SubsonicServerConfig>[
          for (final SubsonicServerConfig c
              in widget.appModel.prefsRepo.musicSubsonicServers)
            if (c.serverId != server.serverId) c,
        ]);
    await _toggleMix(server, false);
    _reload();
  }

  Future<void> _add() async {
    final SubsonicServerConfig? added =
        await showAppDialog<SubsonicServerConfig>(
          context: context,
          builder: (_) => const _AddSubsonicDialog(),
        );
    if (added == null) return;
    await widget.appModel.prefsRepo.setMusicSubsonicServers(
      <SubsonicServerConfig>[
        ...widget.appModel.prefsRepo.musicSubsonicServers,
        added,
      ],
    );
    FushiToast.show(
      msg: t.music_server_added(name: added.displayName),
      severity: ToastSeverity.success,
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Set<String> mix = widget.appModel.prefsRepo.musicServerLibraryMix;
    return FutureBuilder<List<MusicServerBrowser>>(
      future: _servers,
      builder:
          (BuildContext context, AsyncSnapshot<List<MusicServerBrowser>> snap) {
            final List<MusicServerBrowser> servers =
                snap.data ?? const <MusicServerBrowser>[];
            return FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  Text(
                    t.music_servers_settings_hint,
                    style: context.fushiType.bodySmall,
                  ),
                  if (snap.connectionState != ConnectionState.done)
                    const FushiLinearProgressIndicator()
                  else if (servers.isEmpty)
                    Text(
                      t.music_servers_empty,
                      style: context.fushiType.bodyMedium,
                    ),
                  for (int i = 0; i < servers.length; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: AdaptiveSettingsSwitchRow(
                        key: ValueKey<String>(
                          'music-server-setting-${servers[i].serverId}',
                        ),
                        icon: FushiIcons.server,
                        showIcon: true,
                        title: servers[i].displayName,
                        subtitle: switch (servers[i].kind) {
                          MusicServerKind.jellyfin =>
                            t.music_server_jellyfin_subtitle,
                          MusicServerKind.subsonic =>
                            t.music_server_subsonic_subtitle,
                        },
                        value: mix.contains(servers[i].serverId),
                        onChanged: (bool v) =>
                            unawaited(_toggleMix(servers[i], v)),
                      ),
                    ),
                  for (final MusicServerBrowser s in servers)
                    if (s.kind == MusicServerKind.subsonic)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FushiPressScale(
                          child: FushiTextButton.icon(
                            onPressed: () => unawaited(_remove(s)),
                            icon: const FushiIcon(FushiIcons.delete),
                            label: Text(
                              '${t.music_server_remove} · ${s.displayName}',
                            ),
                          ),
                        ),
                      ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FushiPressScale(
                      child: FushiFilledButton.icon(
                        key: const ValueKey<String>(
                          'music_server_add_subsonic',
                        ),
                        onPressed: () => unawaited(_add()),
                        icon: const FushiIcon(FushiIcons.add),
                        label: Text(t.music_server_add_subsonic),
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

/// 添加 OpenSubsonic 服务器：填完先测连接（`ping`），通了才保存。
class _AddSubsonicDialog extends StatefulWidget {
  const _AddSubsonicDialog();

  @override
  State<_AddSubsonicDialog> createState() => _AddSubsonicDialogState();
}

class _AddSubsonicDialogState extends State<_AddSubsonicDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  bool _allowHttp = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _url,
      _user,
      _password,
      _apiKey,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final SubsonicServerConfig config;
    try {
      String raw = _url.text.trim();
      if (!raw.contains('://')) raw = 'https://$raw';
      config = SubsonicServerConfig(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _name.text.trim(),
        serverUrl: Uri.parse(raw),
        username: _user.text.trim(),
        password: _password.text.isEmpty ? null : _password.text,
        apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
        allowInsecureHttp: _allowHttp,
      );
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = t.music_server_invalid(error: '$e');
      });
      return;
    }
    final SubsonicMusicClient client = SubsonicMusicClient(config);
    try {
      await client.ping();
      if (mounted) Navigator.of(context).pop(config);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t.music_server_connect_failed(
            error: redactSubsonicCredentials('$e'),
          );
        });
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      title: Text(t.music_server_add_subsonic),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          FushiTextField(
            controller: _url,
            labelText: t.music_server_field_url,
            hintText: 'https://music.example.com',
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
          FushiTextField(
            controller: _name,
            labelText: t.music_server_field_name,
          ),
          FushiTextField(
            controller: _user,
            labelText: t.music_server_field_user,
          ),
          FushiTextField(
            controller: _password,
            labelText: t.music_server_field_password,
            obscureText: true,
          ),
          FushiTextField(
            controller: _apiKey,
            labelText: t.music_server_field_api_key,
            helperText: t.music_server_field_api_key_hint,
            obscureText: true,
          ),
          AdaptiveSettingsSwitchRow(
            title: t.music_server_allow_http,
            subtitle: t.music_server_allow_http_hint,
            value: _allowHttp,
            onChanged: (bool v) => setState(() => _allowHttp = v),
          ),
          if (_busy) const FushiLinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: context.fushiType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          label: t.music_server_test_and_save,
          kind: FushiDialogActionKind.primary,
          onPressed: _busy ? null : () => unawaited(_submit()),
        ),
      ],
    );
  }
}
