// Jellyfin / Emby 媒体服务器登录设置组件（视频设置「媒体服务器」分区消费）。
//
// 状态两态：未登录 = 地址/用户名/密码表单 + 「登录」（AuthenticateByName 成功即
// 落 SyncRepository `sync_jellyfin_server`）；已登录 = 服务器/账号展示 + 「退出
// 登录」（删键）。配置生效面在视频库页的远端源解析链
// （home_video_page `_resolveJellyfinVideoClient`），此处只管配置读写。

import 'package:flutter/material.dart';

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

/// Jellyfin 服务器配置块。
class JellyfinConfigWidget extends StatefulWidget {
  const JellyfinConfigWidget({required this.settingsContext, super.key});

  final SettingsContext settingsContext;

  @override
  State<JellyfinConfigWidget> createState() => _JellyfinConfigWidgetState();
}

class _JellyfinConfigWidgetState extends State<JellyfinConfigWidget> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  SyncRepository get _syncRepo =>
      SyncRepository(widget.settingsContext.appModel.database);

  /// null = 读取中；含 null 值 = 未登录。
  Future<JellyfinServerConfig?>? _configFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _configFuture = _syncRepo.getJellyfinServer();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final String rawUrl = _urlController.text;
    final String username = _userController.text.trim();
    final String password = _passwordController.text;
    final String serverUrl = JellyfinApi.normalizeServerUrl(rawUrl);
    if (serverUrl.isEmpty || username.isEmpty) {
      FushiToast.show(
        msg: t.jellyfin_sign_in_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    setState(() => _busy = true);
    final JellyfinApi api = JellyfinApi(serverUrl: serverUrl);
    try {
      final JellyfinAuthResult auth =
          await api.authenticateByName(username, password);
      if (auth.accessToken.isEmpty || auth.userId.isEmpty) {
        throw JellyfinApiException(0, '/Users/AuthenticateByName');
      }
      await _syncRepo.setJellyfinServer(JellyfinServerConfig(
        serverUrl: serverUrl,
        username: username,
        userId: auth.userId,
        accessToken: auth.accessToken,
        serverName: auth.serverName,
      ));
      if (!mounted) return;
      _passwordController.clear();
      setState(() {
        _configFuture = _syncRepo.getJellyfinServer();
      });
      FushiToast.show(
        msg: t.sync_connection_success,
        severity: ToastSeverity.success,
      );
    } catch (e) {
      if (mounted) {
        FushiToast.show(
          msg: '${t.jellyfin_sign_in_failed}: $e',
          severity: ToastSeverity.error,
        );
      }
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await _syncRepo.setJellyfinServer(null);
      if (mounted) {
        setState(() {
          _configFuture = _syncRepo.getJellyfinServer();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<JellyfinServerConfig?>(
      future: _configFuture,
      builder: (BuildContext context,
          AsyncSnapshot<JellyfinServerConfig?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final JellyfinServerConfig? config = snapshot.data;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: config == null ? _buildSignInForm() : _buildSignedIn(config),
        );
      },
    );
  }

  Widget _buildSignInForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.jellyfin_settings_hint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FushiTextField(
          controller: _urlController,
          labelText: t.jellyfin_server_url,
          hintText: 'http://192.168.1.10:8096',
        ),
        const SizedBox(height: 12),
        FushiTextField(
          controller: _userController,
          labelText: t.sync_username,
        ),
        const SizedBox(height: 12),
        FushiTextField(
          controller: _passwordController,
          labelText: t.sync_password,
          obscureText: true,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton.tonal(
                  onPressed: _signIn,
                  child: Text(t.jellyfin_sign_in),
                ),
        ),
      ],
    );
  }

  Widget _buildSignedIn(JellyfinServerConfig config) {
    final String serverLabel = (config.serverName?.isNotEmpty ?? false)
        ? '${config.serverName} · ${config.serverUrl}'
        : config.serverUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiListItem(
          leading: const Icon(Icons.dns_outlined),
          title: Text(serverLabel),
          subtitle: Text(config.username),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: _signOut,
                  child: Text(t.jellyfin_sign_out),
                ),
        ),
      ],
    );
  }
}
