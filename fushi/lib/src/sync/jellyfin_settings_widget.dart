// Jellyfin / Emby 媒体服务器登录设置组件（视频设置「媒体服务器」分区消费）。
//
// 状态两态：未登录 = 地址/用户名/密码表单 + 「登录」（AuthenticateByName 成功即
// 落 SyncRepository `sync_jellyfin_server`）；已登录 = 服务器/账号展示 +
// 「自动列出条目」开关 + 媒体库勾选 + 「退出登录」（删键）。配置生效面在视频库页的
// 远端源解析链（home_video_page `_resolveJellyfinVideoClient`），此处只管配置读写。
//
// BUG-1891：后两项是给「几十万条目的公共 Emby 服」用的止血阀。默认值刻意保持旧
// 行为（自动列出=开、库=全部视频库），小库用户一点感觉不到；大库用户可以把枚举
// 收窄到几个库，或干脆改成下拉刷新时才列。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
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

  /// 已登录服务器的媒体库视图清单（BUG-1891 勾选面板）。只在已登录态、且本设置
  /// 分区被展开时才建（分区 collapsedByDefault，不展开就不发这次请求）。
  Future<List<JellyfinLibraryView>>? _viewsFuture;

  /// 当前勾选的库 id；null = 还没从配置里读进来。空集 = 全部视频库。
  Set<String>? _selectedLibraryIds;

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

  /// 「进入视频页时自动列出条目」（全局偏好，非每服务器——它是用户对枚举行为的
  /// 取舍，换服务器重登也该保持）。
  Future<void> _setAutoList(bool value) async {
    await widget.settingsContext.appModel.prefsRepo
        .setJellyfinAutoListVideos(value);
    if (mounted) setState(() {});
  }

  /// 保存媒体库勾选。库 id 是每服务器的 GUID，所以落在 [JellyfinServerConfig] 的
  /// JSON 里（登出随键一起删），不进全局偏好表。
  ///
  /// 改完必须清掉这台服务器的远端清单槽：不清的话，TTL 内视频页拿到的还是按旧
  /// 选择枚举出来的那份清单，用户会以为设置没生效。
  Future<void> _commitLibraryIds(
    JellyfinServerConfig config,
    Set<String> ids,
  ) async {
    final List<String> sorted = ids.toList()..sort();
    await _syncRepo.setJellyfinServer(config.copyWithLibraryIds(sorted));
    widget.settingsContext.ref
        .read(remoteLibraryCacheProvider)
        .invalidateSource(JellyfinVideoClient.sourceIdFor(
          serverUrl: config.serverUrl,
          userId: config.userId,
        ));
    if (!mounted) return;
    setState(() {
      _selectedLibraryIds = ids;
      _configFuture = _syncRepo.getJellyfinServer();
    });
  }

  Future<void> _signOut(JellyfinServerConfig config) async {
    setState(() => _busy = true);
    try {
      await _syncRepo.setJellyfinServer(null);
      // 清掉这台服务器 + 这个账号的全部远端清单槽：不清的话，登出后立刻用同一
      // 账号重新登录（或改了服务器上的库）在 TTL 内还会拿到登出前那份清单。
      // 槽身份必须与 [JellyfinVideoClient.remoteLibrarySourceId] 逐字一致。
      widget.settingsContext.ref
          .read(remoteLibraryCacheProvider)
          .invalidateSource(JellyfinVideoClient.sourceIdFor(
            serverUrl: config.serverUrl,
            userId: config.userId,
          ));
      if (mounted) {
        setState(() {
          _configFuture = _syncRepo.getJellyfinServer();
          _viewsFuture = null;
          _selectedLibraryIds = null;
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
          // 局域网 IP：scheme 冒号 + 三个点 + 端口冒号，中文输入法下全中
          // （BUG-1807）。归一化在 JellyfinApi.normalizeServerUrl 里兜底。
          keyboardType: TextInputType.url,
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
        // BUG-1891 止血阀 ①：进页面自动枚举的总开关（默认开，小库无感）。
        AdaptiveSettingsSwitchRow(
          title: t.jellyfin_auto_list_title,
          subtitle: t.jellyfin_auto_list_hint,
          horizontalPadding: 0,
          value: widget
              .settingsContext.appModel.prefsRepo.jellyfinAutoListVideos,
          onChanged: _busy ? null : _setAutoList,
        ),
        const SizedBox(height: 8),
        // BUG-1891 止血阀 ②：把枚举收窄到点名的媒体库（默认不选 = 全部视频库）。
        Text(
          t.jellyfin_libraries_title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          t.jellyfin_libraries_hint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _buildLibraryPicker(config),
        Align(
          alignment: Alignment.centerRight,
          child: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: () => _signOut(config),
                  child: Text(t.jellyfin_sign_out),
                ),
        ),
      ],
    );
  }

  /// 媒体库勾选面板。视图清单经 `/Users/{uid}/Views` 取一次（本设置分区
  /// collapsedByDefault，不展开就不发这次请求）；只列视频域的库
  /// （[JellyfinLibraryView.isVideoish] 滤掉音乐/图书/照片）。
  Widget _buildLibraryPicker(JellyfinServerConfig config) {
    _selectedLibraryIds ??= config.libraryIds.toSet();
    _viewsFuture ??= _loadViews(config);
    return FutureBuilder<List<JellyfinLibraryView>>(
      future: _viewsFuture,
      builder: (BuildContext context,
          AsyncSnapshot<List<JellyfinLibraryView>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              t.jellyfin_libraries_load_failed,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final List<JellyfinLibraryView> views =
            snapshot.data ?? const <JellyfinLibraryView>[];
        final Set<String> selected =
            _selectedLibraryIds ?? const <String>{};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final JellyfinLibraryView view in views)
              FushiListItem(
                title: Text(view.name),
                trailing: Checkbox(
                  value: selected.contains(view.id),
                  onChanged: _busy
                      ? null
                      : (bool? _) => _toggleLibrary(config, view.id),
                ),
                onTap: _busy ? null : () => _toggleLibrary(config, view.id),
              ),
          ],
        );
      },
    );
  }

  Future<List<JellyfinLibraryView>> _loadViews(
    JellyfinServerConfig config,
  ) async {
    final JellyfinApi api = JellyfinApi(
      serverUrl: config.serverUrl,
      accessToken: config.accessToken,
    );
    try {
      final List<JellyfinLibraryView> views = await api.views(config.userId);
      return <JellyfinLibraryView>[
        for (final JellyfinLibraryView v in views)
          if (v.isVideoish && v.id.isNotEmpty) v,
      ];
    } finally {
      api.close();
    }
  }

  void _toggleLibrary(JellyfinServerConfig config, String id) {
    final Set<String> next = <String>{...?_selectedLibraryIds};
    if (!next.remove(id)) next.add(id);
    unawaited(_commitLibraryIds(config, next));
  }
}
