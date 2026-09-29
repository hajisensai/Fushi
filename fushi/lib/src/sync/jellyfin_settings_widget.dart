// Jellyfin / Emby 媒体服务器登录设置组件（视频设置「媒体服务器」分区消费）。
//
// 多服务器（视频页「媒体服务器」栏目一台一张卡片，对标 Optic Player 的「选择
// 服务器」页）：已登录服务器**列表**（每台一行：服务器名 + 地址 + 账号；点行展开
// 媒体库勾选 + 只登出这一台）+ 列表下方常驻「添加服务器」表单（AuthenticateByName
// 成功即 [SyncRepository.upsertJellyfinServer]，同 `(serverUrl, userId)` 重复登录 =
// 换令牌、不多出一张卡）。配置生效面在视频库页的远端源解析链（home_video_page
// `_resolveJellyfinVideoClient`），此处只管配置读写。
//
// 多线路（同一台服务器的多条访问地址：局域网 / 公网 / 反代 / 内网穿透）：每台
// 展开后有「线路」面板——登录地址恒在首位、单选切换当前线路、备用线路可删、
// 底部一行输入框添加。添加线路**不重新登录**：令牌按 DeviceId 归属、与地址无关，
// 所以只需拿现有令牌经新地址打一个认证请求（`/Users/{uid}/Views`）——通了就同时
// 证明「地址可达」和「这就是同一台服务器」（别家服务器不认这个令牌，401）。
// 身份锚（缓存槽 / 封面命名空间）始终是登录地址，切线路不换身份，见
// [JellyfinServerConfig.serverUrl]。
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

  /// 每台服务器「添加线路」输入框的控制器（键 = [JellyfinVideoClient.sourceIdFor]），
  /// 首次展开该行时才建，随 State 一起 dispose。
  final Map<String, TextEditingController> _routeControllers =
      <String, TextEditingController>{};

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
    for (final TextEditingController c in _routeControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _idOf(JellyfinServerConfig config) =>
      JellyfinVideoClient.sourceIdFor(
        serverUrl: config.serverUrl,
        userId: config.userId,
      );

  JellyfinApi _api({
    required String serverUrl,
    String? accessToken,
    String deviceId = JellyfinApi.kLegacyDeviceId,
  }) =>
      JellyfinApi(
        serverUrl: serverUrl,
        accessToken: accessToken,
        deviceId: deviceId,
        client: widget.httpClientFactory?.call(),
      );

  /// 登录 / 连接失败的呈现：对话框 + 可选中文本。此前走 [FushiToast]，手机上是
  /// 2 秒、两行截断的原生 toast——`SocketException: Connection refused (OS Error …),
  /// address = …, port = …` 这种真正有用的原因根本看不全，用户只能报「直接连不上」。
  Future<void> _showSignInError(String message) =>
      _showErrorDialog(t.jellyfin_sign_in_failed, message);

  Future<void> _showErrorDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  /// 把连接阶段的异常翻成用户能行动的话：主机名解析失败追加「改用 IP」提示。
  String _describeConnectFailure(String serverUrl, Object error) {
    final String reason = JellyfinApi.isHostLookupFailure(error)
        ? '$error\n\n${t.jellyfin_host_lookup_hint}'
        : '$error';
    return t.jellyfin_server_unreachable(url: serverUrl, reason: reason);
  }

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
    // 设备身份：本机 per-install id（见 JellyfinApi.deviceId），令牌与它绑定、随
    // 配置一起持久化。
    final String deviceId = await _syncRepo.getOrCreateDeviceId();
    final JellyfinApi api = _api(serverUrl: serverUrl, deviceId: deviceId);
    try {
      // 先探连通性再登录：连不上与账号错是两种完全不同的处置。
      try {
        await api.publicSystemInfo();
      } catch (e) {
        await _showSignInError(_describeConnectFailure(serverUrl, e));
        return;
      }
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
        deviceId: deviceId,
      );
      // 同一账号重复登录只是换令牌：保留用户在这台服务器上已点名的媒体库，
      // 否则「令牌过期重登一次」就把库选择静默清回「全部」（BUG-1891 止血阀失效）。
      // 「同一台」按线路认（登录地址或任一备用线路命中），不然从公网线路重登会多出
      // 一条 serverUrl=公网 的记录：两个 sourceId、两套封面 namespace、两张卡。
      final List<JellyfinServerConfig> existing =
          await _syncRepo.getJellyfinServers();
      JellyfinServerConfig? previous;
      for (final JellyfinServerConfig s in existing) {
        if (s.userId == auth.userId && s.ownsRoute(serverUrl)) {
          previous = s;
          break;
        }
      }
      await _syncRepo.upsertJellyfinServer(
        previous == null
            ? fresh
            : previous.withRefreshedSession(
                username: username,
                accessToken: auth.accessToken,
                deviceId: deviceId,
                signedInUrl: serverUrl,
                serverName: auth.serverName,
              ),
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
      await _showSignInError('$e');
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

  TextEditingController _routeControllerFor(String id) =>
      _routeControllers.putIfAbsent(id, TextEditingController.new);

  /// 给一台服务器添加一条备用线路。
  ///
  /// 不登录、不要密码：先探 `/System/Info/Public`（可达性，与登录同款分诊），再拿
  /// **现有令牌**经新地址读 `/Users/{uid}/Views`——令牌是这台服务器签的，别台服务器
  /// 回 401，所以这一步同时证明「同一台服务器」；令牌过期同样是 401，错误文案把
  /// 两种可能都说出来。只追加不切换：用户在列表里点单选才换当前线路。
  Future<void> _addRoute(JellyfinServerConfig config) async {
    final String id = _idOf(config);
    final String url =
        JellyfinApi.normalizeServerUrl(_routeControllerFor(id).text);
    if (url.isEmpty) {
      FushiToast.show(
        msg: t.jellyfin_route_add_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (config.routeUrls.contains(url)) {
      FushiToast.show(
        msg: t.jellyfin_route_exists,
        severity: ToastSeverity.error,
      );
      return;
    }
    setState(() => _busy = true);
    final JellyfinApi api = _api(
      serverUrl: url,
      accessToken: config.accessToken,
      deviceId: config.deviceId,
    );
    try {
      try {
        await api.publicSystemInfo();
      } catch (e) {
        await _showErrorDialog(
          t.jellyfin_route_add_failed,
          _describeConnectFailure(url, e),
        );
        return;
      }
      try {
        await api.views(config.userId);
      } catch (e) {
        await _showErrorDialog(
          t.jellyfin_route_add_failed,
          t.jellyfin_route_verify_failed(url: url, reason: '$e'),
        );
        return;
      }
      await _syncRepo.upsertJellyfinServer(
        config.copyWithRoutes(
          alternateUrls: <String>[...config.alternateUrls, url],
        ),
      );
      if (!mounted) return;
      _routeControllerFor(id).clear();
      _reload();
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 切换当前线路。远端清单缓存槽里的封面 / 流 URL 已把旧线路的 host 烤进去
  /// （RemoteVideoInfo.coverUrl 是绝对 URL），必须失效，否则 TTL 内视频页还在
  /// 往旧地址拉图；身份锚不变，封面磁盘缓存（按条目 id 键）照常命中。
  Future<void> _switchRoute(JellyfinServerConfig config, String url) async {
    if (url == config.effectiveServerUrl) return;
    setState(() => _busy = true);
    try {
      await _syncRepo.upsertJellyfinServer(
        config.copyWithRoutes(activeServerUrl: url),
      );
      widget.settingsContext.ref
          .read(remoteLibraryCacheProvider)
          .invalidateSource(_idOf(config));
      if (!mounted) return;
      // 媒体库清单按新线路重取（顺带就是这条线路的一次真实连通验证）。
      _viewsFutures.remove(_idOf(config));
      _reload();
      FushiToast.show(
        msg: t.jellyfin_route_switched(url: url),
        severity: ToastSeverity.success,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删一条备用线路（登录地址不可删——它是身份锚）。删的是正在用的那条时
  /// [JellyfinServerConfig.copyWithRoutes] 自动回落登录地址，缓存槽同样要失效。
  Future<void> _removeRoute(JellyfinServerConfig config, String url) async {
    setState(() => _busy = true);
    try {
      final bool wasActive = url == config.effectiveServerUrl;
      await _syncRepo.upsertJellyfinServer(
        config.copyWithRoutes(
          alternateUrls: <String>[
            for (final String u in config.alternateUrls)
              if (u != url) u,
          ],
        ),
      );
      if (wasActive) {
        widget.settingsContext.ref
            .read(remoteLibraryCacheProvider)
            .invalidateSource(_idOf(config));
      }
      if (!mounted) return;
      if (wasActive) _viewsFutures.remove(_idOf(config));
      _reload();
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
    // 摘要行显示**当前线路**（用户在外面切到公网地址后，一眼能看出现在走哪条）。
    final String activeUrl = config.effectiveServerUrl;
    final String serverLabel = (config.serverName?.isNotEmpty ?? false)
        ? '${config.serverName} · $activeUrl'
        : activeUrl;
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
                const SizedBox(height: 8),
                Text(
                  t.jellyfin_routes_title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  t.jellyfin_routes_hint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                _buildRoutesPanel(config),
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

  /// 线路面板：登录地址恒在首位（带「登录地址」副标题、不可删），其后按添加顺序
  /// 列备用线路；单选 = 当前线路；末行是「添加线路」输入框 + 按钮。
  Widget _buildRoutesPanel(JellyfinServerConfig config) {
    final String id = _idOf(config);
    final String activeUrl = config.effectiveServerUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String url in config.routeUrls)
          FushiListItem(
            key: ValueKey<String>('jellyfin-route-$id-$url'),
            leading: Radio<String>(
              value: url,
              groupValue: activeUrl,
              onChanged: _busy
                  ? null
                  : (String? v) {
                      if (v != null) unawaited(_switchRoute(config, v));
                    },
            ),
            title: Text(url),
            subtitle: url == config.serverUrl
                ? Text(t.jellyfin_route_primary_label)
                : (url == activeUrl
                    ? Text(t.jellyfin_route_active_label)
                    : null),
            trailing: url == config.serverUrl
                ? null
                : FushiIconButton(
                    icon: Icons.delete_outline,
                    tooltip: t.jellyfin_route_remove,
                    onTap: _busy ? null : () => _removeRoute(config, url),
                  ),
            onTap: _busy ? null : () => _switchRoute(config, url),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: FushiTextField(
                controller: _routeControllerFor(id),
                labelText: t.jellyfin_route_url,
                hintText: 'https://emby.example.com',
                keyboardType: TextInputType.url,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _addRoute(config),
              child: Text(t.jellyfin_route_add),
            ),
          ],
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
      serverUrl: config.effectiveServerUrl,
      accessToken: config.accessToken,
      deviceId: config.deviceId,
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
