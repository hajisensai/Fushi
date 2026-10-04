// Plex 媒体服务器登录设置组件（设置 › 在线服务 › 媒体服务器 › Plex）。
//
// 两种添加方式，与 Jellyfin 设置页同一套视觉语言（已登录列表 + 下方添加区）：
// 1. **Plex 账号登录（PIN）**：建 plex.tv PIN → 浏览器打开授权页 → 轮询拿账号
//    token → 列账号下全部服务器（resources），每台按 局域网 → 公网 → relay 逐条
//    探测 `/identity`，第一条可达且 machineIdentifier 对得上的设为当前连接、全部
//    连接存成线路（视频页服务器卡片可切）。一台都连不上就报错，不写配置。
// 2. **手动连接**：地址 + X-Plex-Token，先 `/identity` 探连通与身份，再
//    `/library/sections` 验 token；账号信息 best-effort 从 plex.tv 补。
//
// 配置落 `SyncRepository.upsertMediaServer`（与 Jellyfin 同一个列表键，JSON 带
// `kind: plex`）；出站一律经 app HTTP client 装配（`PlexApi` / `PlexTvApi` 缺省的
// `createAppHttpIoClient`，走全应用代理）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_tv_auth.dart';

/// Plex 服务器配置块。
class PlexConfigWidget extends StatefulWidget {
  const PlexConfigWidget({
    required this.settingsContext,
    this.httpClientFactory,
    this.openUrl,
    this.pinPollInterval = const Duration(seconds: 2),
    this.probeTimeout = const Duration(seconds: 5),
    super.key,
  });

  final SettingsContext settingsContext;

  /// 测试注入点：[PlexApi] / [PlexTvApi] 用的 http client 工厂。null = 缺省的
  /// `createAppHttpIoClient`（走全应用代理装配）。生产代码不传。
  final http.Client Function()? httpClientFactory;

  /// 测试注入点：打开 PIN 授权页。null = `url_launcher` 外部浏览器。
  final Future<bool> Function(Uri url)? openUrl;
  final Duration pinPollInterval;

  /// 单条连接地址的探测超时（relay / 公网地址不通时别让用户干等 15 秒一条）。
  final Duration probeTimeout;

  @override
  State<PlexConfigWidget> createState() => _PlexConfigWidgetState();
}

class _PlexConfigWidgetState extends State<PlexConfigWidget> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  SyncRepository get _syncRepo =>
      SyncRepository(widget.settingsContext.appModel.database);

  Future<List<PlexServerConfig>>? _serversFuture;
  bool _busy = false;

  /// PIN 登录进行中时的授权页 URL（非 null = 显示等待面板）。
  String? _pendingAuthUrl;
  bool _pinCancelled = false;

  @override
  void initState() {
    super.initState();
    _serversFuture = _loadServers();
  }

  @override
  void dispose() {
    _pinCancelled = true;
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<List<PlexServerConfig>> _loadServers() async => <PlexServerConfig>[
    for (final MediaServerConfig s in await _syncRepo.getMediaServers())
      if (s is PlexServerConfig) s,
  ];

  void _reload() {
    setState(() {
      _serversFuture = _loadServers();
    });
  }

  Future<PlexClientInfo> _clientInfo() async =>
      PlexClientInfo(clientIdentifier: await _syncRepo.getOrCreateDeviceId());

  PlexApi _api(String serverUrl, String token, PlexClientInfo info) => PlexApi(
    serverUrl: serverUrl,
    token: token,
    clientInfo: info,
    client: widget.httpClientFactory?.call(),
  );

  PlexTvApi _tvApi(PlexClientInfo info) =>
      PlexTvApi(clientInfo: info, client: widget.httpClientFactory?.call());

  Future<void> _showError(String message) async {
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => FushiAlertDialog(
        title: Text(t.plex_sign_in_failed),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  /// [uri] 可达且确实是 [machineIdentifier] 那台服务器。
  Future<bool> _probe(
    String uri,
    String token,
    String machineIdentifier,
    PlexClientInfo info,
  ) async {
    final PlexApi api = _api(uri, token, info);
    try {
      final String id = await api.identity().timeout(widget.probeTimeout);
      return id == machineIdentifier;
    } finally {
      api.close();
    }
  }

  Future<void> _signInWithAccount() async {
    setState(() {
      _busy = true;
      _pinCancelled = false;
    });
    final PlexClientInfo info = await _clientInfo();
    final PlexTvApi tv = _tvApi(info);
    try {
      final PlexPin pin = await tv.createPin();
      final String authUrl = tv.authUrl(pin);
      if (!mounted) return;
      setState(() => _pendingAuthUrl = authUrl);
      final Future<bool> Function(Uri url) open =
          widget.openUrl ??
          (Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);
      unawaited(open(Uri.parse(authUrl)).catchError((Object _) => false));
      final ({PlexPinPollOutcome outcome, String? token}) result =
          await pollPlexPin(
            check: () => tv.checkPin(pin),
            isCancelled: () => _pinCancelled || !mounted,
            interval: widget.pinPollInterval,
          );
      if (!mounted) return;
      setState(() => _pendingAuthUrl = null);
      switch (result.outcome) {
        case PlexPinPollOutcome.cancelled:
          return;
        case PlexPinPollOutcome.expired:
          await _showError(t.plex_pin_expired);
          return;
        case PlexPinPollOutcome.authorized:
          break;
      }
      final String accountToken = result.token!;
      PlexTvUser? user;
      try {
        user = await tv.user(accountToken);
      } catch (_) {
        // 账号名只用于卡片副标题，查不到不妨碍登录。
      }
      final List<PlexResource> resources = await tv.resources(accountToken);
      int added = 0;
      for (final PlexResource r in resources) {
        final String token = r.accessToken ?? accountToken;
        final List<String> ordered = <String>[
          for (final PlexConnection c in orderPlexConnections(r.connections))
            if (c.uri.isNotEmpty) c.uri,
        ];
        final String? reachable = await firstReachablePlexConnection(
          orderPlexConnections(r.connections),
          (String uri) => _probe(uri, token, r.clientIdentifier, info),
        );
        if (reachable == null || ordered.isEmpty) continue;
        await _syncRepo.upsertMediaServer(
          PlexServerConfig(
            machineIdentifier: r.clientIdentifier,
            token: token,
            clientIdentifier: info.clientIdentifier,
            connections: ordered,
            serverName: r.name,
            accountId: user?.id ?? '',
            accountName: user?.username ?? '',
          ).withActiveRoute(reachable),
        );
        added++;
      }
      if (!mounted) return;
      if (added == 0) {
        await _showError(t.plex_servers_none_reachable);
        return;
      }
      _reload();
      FushiToast.show(
        msg: t.plex_servers_added(n: added),
        severity: ToastSeverity.success,
      );
    } catch (e) {
      if (mounted) setState(() => _pendingAuthUrl = null);
      await _showError('$e');
    } finally {
      tv.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancelPin() {
    setState(() {
      _pinCancelled = true;
      _pendingAuthUrl = null;
    });
  }

  Future<void> _connectManually() async {
    final String serverUrl = PlexApi.normalizeServerUrl(_urlController.text);
    final String token = _tokenController.text.trim();
    if (serverUrl.isEmpty || token.isEmpty) {
      FushiToast.show(
        msg: t.plex_sign_in_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    setState(() => _busy = true);
    final PlexClientInfo info = await _clientInfo();
    final PlexApi api = _api(serverUrl, token, info);
    final PlexTvApi tv = _tvApi(info);
    try {
      final String machineIdentifier;
      try {
        machineIdentifier = await api.identity();
      } catch (e) {
        await _showError(
          t.jellyfin_server_unreachable(url: serverUrl, reason: '$e'),
        );
        return;
      }
      if (machineIdentifier.isEmpty) {
        throw const FormatException('Plex /identity has no machineIdentifier');
      }
      // `/identity` 不验 token；列库才是真正的鉴权请求。
      await api.sections();
      String? serverName;
      try {
        serverName = await api.friendlyName();
      } catch (_) {
        // 服务器名只用于展示。
      }
      PlexTvUser? user;
      try {
        user = await tv.user(token);
      } catch (_) {
        // 服务器本地 token 在 plex.tv 查不到账号：身份只按服务器区分。
      }
      await _syncRepo.upsertMediaServer(
        PlexServerConfig(
          machineIdentifier: machineIdentifier,
          token: token,
          clientIdentifier: info.clientIdentifier,
          connections: <String>[serverUrl],
          serverName: serverName,
          accountId: user?.id ?? '',
          accountName: user?.username ?? '',
        ),
      );
      if (!mounted) return;
      _urlController.clear();
      _tokenController.clear();
      _reload();
      FushiToast.show(
        msg: t.sync_connection_success,
        severity: ToastSeverity.success,
      );
    } catch (e) {
      await _showError('$e');
    } finally {
      api.close();
      tv.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut(PlexServerConfig config) async {
    setState(() => _busy = true);
    try {
      await _syncRepo.removeMediaServer(config.sourceId);
      widget.settingsContext.ref
          .read(remoteLibraryCacheProvider)
          .invalidateSource(config.sourceId);
      if (mounted) _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PlexServerConfig>>(
      future: _serversFuture,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<PlexServerConfig>> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: FushiLoadingView(compact: true)),
              );
            }
            final List<PlexServerConfig> servers =
                snapshot.data ?? const <PlexServerConfig>[];
            final TextTheme textTheme = Theme.of(context).textTheme;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(t.plex_settings_hint, style: textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                    t.jellyfin_servers_signed_in_title,
                    style: FushiSectionTitle.styleOf(
                      context,
                      FushiSectionTitleLevel.group,
                    ),
                  ),
                  if (servers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        t.jellyfin_servers_empty_hint,
                        style: textTheme.bodySmall,
                      ),
                    ),
                  for (final PlexServerConfig config in servers)
                    _buildServerRow(config),
                  const SizedBox(height: 12),
                  Text(
                    t.jellyfin_servers_add_title,
                    style: FushiSectionTitle.styleOf(
                      context,
                      FushiSectionTitleLevel.group,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildAccountSignIn(textTheme),
                  const SizedBox(height: 16),
                  Text(
                    t.plex_manual_title,
                    style: FushiSectionTitle.styleOf(
                      context,
                      FushiSectionTitleLevel.group,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildManualForm(),
                ],
              ),
            );
          },
    );
  }

  Widget _buildServerRow(PlexServerConfig config) {
    final String activeUrl = config.effectiveServerUrl;
    final String label = (config.serverName?.isNotEmpty ?? false)
        ? '${config.serverName} · $activeUrl'
        : activeUrl;
    return FushiListItem(
      key: ValueKey<String>('plex-server-${config.sourceId}'),
      // Plex 用「播放圆钮」、Jellyfin 系用「服务器机柜」，与浏览页服务器列表同一套类型图标。
      leading: const FushiIcon(Icons.play_circle_outline_rounded),
      title: Text(label),
      subtitle: config.accountName.isEmpty ? null : Text(config.accountName),
      trailing: FushiIconButton(
        icon: Icons.logout,
        tooltip: t.jellyfin_sign_out,
        onTap: _busy ? null : () => _signOut(config),
      ),
    );
  }

  Widget _buildAccountSignIn(TextTheme textTheme) {
    final String? pending = _pendingAuthUrl;
    if (pending == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FushiFilledButton.tonalIcon(
          onPressed: _busy ? null : _signInWithAccount,
          icon: const FushiIcon(Icons.login),
          label: Text(t.plex_account_sign_in),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(
              width: 20,
              height: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(t.plex_pin_waiting)),
            FushiTextButton(onPressed: _cancelPin, child: Text(t.dialog_cancel)),
          ],
        ),
        const SizedBox(height: 4),
        Text(t.plex_pin_link_hint, style: textTheme.bodySmall),
        SelectableText(pending, style: textTheme.bodySmall),
      ],
    );
  }

  Widget _buildManualForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiTextField(
          controller: _urlController,
          labelText: t.jellyfin_server_url,
          hintText: 'http://192.168.1.10:32400',
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        FushiTextField(
          controller: _tokenController,
          labelText: t.plex_token_label,
          obscureText: true,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: _busy && _pendingAuthUrl == null
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                )
              : FushiFilledButton.tonal(
                  onPressed: _busy ? null : _connectManually,
                  child: Text(t.plex_manual_connect),
                ),
        ),
      ],
    );
  }
}
