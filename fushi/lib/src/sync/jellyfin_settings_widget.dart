// Jellyfin / Emby 媒体服务器登录设置组件（视频设置「媒体服务器」分区消费）。
//
// 多服务器（视频页「媒体服务器」栏目一台一张卡片，对标 Optic Player 的「选择
// 服务器」页）：已登录服务器**列表**（每台一行：服务器名 + 地址 + 账号；点行展开
// 媒体库勾选 + 只登出这一台）+ 列表下方常驻「添加服务器」表单（AuthenticateByName
// 成功即 [SyncRepository.upsertJellyfinServer]，同 `(serverUrl, userId)` 重复登录 =
// 换令牌、不多出一张卡）。配置生效面在视频库页的远端源解析链（home_video_page
// `_resolveJellyfinVideoClient`），此处只管配置读写。
//
// BUG-1891：「自动列出条目」开关与媒体库勾选是给「几十万条目的公共 Emby 服」用的
// 止血阀。默认值刻意保持旧行为（自动列出=开、库=全部视频库），小库用户一点感觉
// 不到；大库用户可以把枚举收窄到几个库，或干脆改成下拉刷新时才列。开关是全局
// 偏好（一处、放列表上方），库勾选是每台服务器自己的。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

/// Jellyfin 服务器配置块。
class JellyfinConfigWidget extends StatefulWidget {
  const JellyfinConfigWidget({
    required this.settingsContext,
    this.httpClientFactory,
    super.key,
  });

  final SettingsContext settingsContext;

  /// 测试注入点：[JellyfinApi] 用的 http client 工厂（登录 + 读媒体库清单各建一个
  /// 短命 api，用完即 close）。null = [JellyfinApi] 缺省的 `createAppHttpIoClient`
  /// （走全应用代理装配）。生产代码不传。
  final http.Client Function()? httpClientFactory;

  @override
  State<JellyfinConfigWidget> createState() => _JellyfinConfigWidgetState();
}

class _JellyfinConfigWidgetState extends State<JellyfinConfigWidget> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  SyncRepository get _syncRepo =>
      SyncRepository(widget.settingsContext.appModel.database);

  /// null = 读取中；空列表 = 未登录任何服务器。
  Future<List<JellyfinServerConfig>>? _serversFuture;
  bool _busy = false;

  /// 展开了媒体库面板的服务器（键 = [JellyfinVideoClient.sourceIdFor]）。
  final Set<String> _expanded = <String>{};

  /// 每台服务器的媒体库视图清单（BUG-1891 勾选面板）。只在该行被展开时才建
  /// （分区本身 collapsedByDefault，不展开就不发这次请求）。
  final Map<String, Future<List<JellyfinLibraryView>>> _viewsFutures =
      <String, Future<List<JellyfinLibraryView>>>{};

  /// 每台服务器当前勾选的库 id；缺项 = 还没从配置里读进来。空集 = 全部视频库。
  final Map<String, Set<String>> _selectedLibraryIds = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    _serversFuture = _syncRepo.getJellyfinServers();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  static String _idOf(JellyfinServerConfig config) =>
      JellyfinVideoClient.sourceIdFor(
        serverUrl: config.serverUrl,
        userId: config.userId,
      );

  JellyfinApi _api({required String serverUrl, String? accessToken}) =>
      JellyfinApi(
        serverUrl: serverUrl,
        accessToken: accessToken,
        client: widget.httpClientFactory?.call(),
      );

  void _reload() {
    setState(() {
      _serversFuture = _syncRepo.getJellyfinServers();
    });
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
    final JellyfinApi api = _api(serverUrl: serverUrl);
    try {
      final JellyfinAuthResult auth =
          await api.authenticateByName(username, password);
      if (auth.accessToken.isEmpty || auth.userId.isEmpty) {
        throw JellyfinApiException(0, '/Users/AuthenticateByName');
      }
      final JellyfinServerConfig fresh = JellyfinServerConfig(
        serverUrl: serverUrl,
        username: username,
        userId: auth.userId,
        accessToken: auth.accessToken,
        serverName: auth.serverName,
      );
      // 同一账号重复登录只是换令牌：保留用户在这台服务器上已点名的媒体库，
      // 否则「令牌过期重登一次」就把库选择静默清回「全部」（BUG-1891 止血阀失效）。
      final String id = _idOf(fresh);
      final List<JellyfinServerConfig> existing =
          await _syncRepo.getJellyfinServers();
      JellyfinServerConfig? previous;
      for (final JellyfinServerConfig s in existing) {
        if (_idOf(s) == id) {
          previous = s;
          break;
        }
      }
      await _syncRepo.upsertJellyfinServer(
        previous == null
            ? fresh
            : fresh.copyWithLibraryIds(previous.libraryIds),
      );
      if (!mounted) return;
      _urlController.clear();
      _userController.clear();
      _passwordController.clear();
      _reload();
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

  /// 「在视频库中混排显示」（B4，全局偏好，默认关）：开了才把服务器条目拍平混进
  /// 首页 / 系列 / 全部视频；关着时条目只在「媒体服务器」分区按服务器自己的树浏览。
  Future<void> _setShowInLibrary(bool value) async {
    await widget.settingsContext.appModel.prefsRepo
        .setJellyfinShowInLibrary(value);
    if (mounted) setState(() {});
  }

  /// 「进入视频页时自动列出条目」（全局偏好，非每服务器——它是用户对枚举行为的
  /// 取舍，换服务器重登也该保持）。只在混排开着时才有意义。
  Future<void> _setAutoList(bool value) async {
    await widget.settingsContext.appModel.prefsRepo
        .setJellyfinAutoListVideos(value);
    if (mounted) setState(() {});
  }

  /// 保存一台服务器的媒体库勾选。库 id 是每服务器的 GUID，所以落在
  /// [JellyfinServerConfig] 的 JSON 里（登出随条目一起删），不进全局偏好表。
  ///
  /// 改完必须清掉这台服务器的远端清单槽：不清的话，TTL 内视频页拿到的还是按旧
  /// 选择枚举出来的那份清单，用户会以为设置没生效。
  Future<void> _commitLibraryIds(
    JellyfinServerConfig config,
    Set<String> ids,
  ) async {
    final List<String> sorted = ids.toList()..sort();
    await _syncRepo.upsertJellyfinServer(config.copyWithLibraryIds(sorted));
    widget.settingsContext.ref
        .read(remoteLibraryCacheProvider)
        .invalidateSource(_idOf(config));
    if (!mounted) return;
    _selectedLibraryIds[_idOf(config)] = ids;
    _reload();
  }

  /// 只登出这一台；其它服务器不受影响。
  Future<void> _signOut(JellyfinServerConfig config) async {
    setState(() => _busy = true);
    try {
      await _syncRepo.removeJellyfinServer(
        serverUrl: config.serverUrl,
        userId: config.userId,
      );
      // 清掉这台服务器 + 这个账号的全部远端清单槽：不清的话，登出后立刻用同一
      // 账号重新登录（或改了服务器上的库）在 TTL 内还会拿到登出前那份清单。
      // 槽身份必须与 [JellyfinVideoClient.remoteLibrarySourceId] 逐字一致。
      final String id = _idOf(config);
      widget.settingsContext.ref
          .read(remoteLibraryCacheProvider)
          .invalidateSource(id);
      if (mounted) {
        _expanded.remove(id);
        _viewsFutures.remove(id);
        _selectedLibraryIds.remove(id);
        _reload();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<JellyfinServerConfig>>(
      future: _serversFuture,
      builder: (BuildContext context,
          AsyncSnapshot<List<JellyfinServerConfig>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final List<JellyfinServerConfig> servers =
            snapshot.data ?? const <JellyfinServerConfig>[];
        final TextTheme textTheme = Theme.of(context).textTheme;
        final bool showInLibrary =
            widget.settingsContext.appModel.prefsRepo.jellyfinShowInLibrary;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t.jellyfin_settings_hint, style: textTheme.bodySmall),
              const SizedBox(height: 8),
              // B4：混排是显式 opt-in（默认关）。关着时下面的「自动列出」没有意义
              // ——库页根本不会去问服务器要拍平清单——所以一并禁用而不是藏起来，
              // 用户能看出两者的从属关系。
              AdaptiveSettingsSwitchRow(
                title: t.jellyfin_show_in_library_title,
                subtitle: t.jellyfin_show_in_library_hint,
                horizontalPadding: 0,
                value: showInLibrary,
                onChanged: _busy ? null : _setShowInLibrary,
              ),
              // BUG-1891 止血阀 ①：进页面自动枚举的总开关（默认开，小库无感）。
              // 全局偏好，一处、放列表上方，不随服务器条目重复。
              AdaptiveSettingsSwitchRow(
                title: t.jellyfin_auto_list_title,
                subtitle: t.jellyfin_auto_list_hint,
                horizontalPadding: 0,
                value: widget
                    .settingsContext.appModel.prefsRepo.jellyfinAutoListVideos,
                onChanged: (_busy || !showInLibrary) ? null : _setAutoList,
              ),
              const SizedBox(height: 8),
              Text(
                t.jellyfin_servers_signed_in_title,
                style: textTheme.titleSmall,
              ),
              if (servers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    t.jellyfin_servers_empty_hint,
                    style: textTheme.bodySmall,
                  ),
                ),
              for (final JellyfinServerConfig config in servers)
                _buildServerRow(config),
              const SizedBox(height: 12),
              Text(t.jellyfin_servers_add_title, style: textTheme.titleSmall),
              const SizedBox(height: 8),
              _buildSignInForm(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSignInForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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

  /// 一台已登录服务器：一行摘要（点击展开 / 收起），展开后是这台的媒体库勾选
  /// 面板 + 只登出这一台的按钮。
  Widget _buildServerRow(JellyfinServerConfig config) {
    final String id = _idOf(config);
    final bool expanded = _expanded.contains(id);
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
          trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() {
            if (!_expanded.remove(id)) _expanded.add(id);
          }),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // BUG-1891 止血阀 ②：把枚举收窄到点名的媒体库（默认不选 = 全部
                // 视频库）。每台服务器各自一份。
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
            ),
          ),
      ],
    );
  }

  /// 媒体库勾选面板。视图清单经 `/Users/{uid}/Views` 取一次（本行不展开就不发
  /// 这次请求）；只列视频域的库（[JellyfinLibraryView.isVideoish] 滤掉音乐/图书/
  /// 照片）。
  Widget _buildLibraryPicker(JellyfinServerConfig config) {
    final String id = _idOf(config);
    _selectedLibraryIds.putIfAbsent(id, () => config.libraryIds.toSet());
    final Future<List<JellyfinLibraryView>> viewsFuture =
        _viewsFutures.putIfAbsent(id, () => _loadViews(config));
    return FutureBuilder<List<JellyfinLibraryView>>(
      future: viewsFuture,
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
            _selectedLibraryIds[id] ?? const <String>{};
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
    final JellyfinApi api = _api(
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
    final Set<String> next = <String>{...?_selectedLibraryIds[_idOf(config)]};
    if (!next.remove(id)) next.add(id);
    unawaited(_commitLibraryIds(config, next));
  }
}
