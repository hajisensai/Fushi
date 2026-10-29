/// 插件音源登录（docs/specs/2026-10-28-music-plugins.md §4.1）：方式由插件声明，界面由宿主按
/// 三种类型渲染——扫码（二维码 + 轮询 + 可选「在本机 App 中确认」）、表单（短信验证码 / 粘贴
/// Cookie 等）、网页登录（内嵌浏览器，出现插件指定的 Cookie 即自动交回）。插件不提供任何 UI，
/// 也看不到宿主界面；宿主不解读平台 Cookie，凭据由插件自己经 `fushi.credentials` 加密保存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/utils.dart';

/// 交给插件的平台名（契约 `login({op:'methods', platform})`）。
String musicPluginHostPlatform() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isIOS) return 'ios';
  return 'windows';
}

/// 打开登录页；返回 true = 登录成功。
Future<bool> openMusicPluginLogin(
  BuildContext context, {
  required AppModel appModel,
  required MusicPluginManifest manifest,
}) async {
  final bool? ok = await Navigator.of(context).push<bool>(
    adaptivePageRoute<bool>(
      context: context,
      builder: (_) =>
          MusicPluginLoginPage(appModel: appModel, manifest: manifest),
    ),
  );
  if (ok ?? false) appModel.onMusicPluginAccountChanged(manifest.id);
  return ok ?? false;
}

class MusicPluginLoginPage extends StatefulWidget {
  const MusicPluginLoginPage({
    super.key,
    required this.appModel,
    required this.manifest,
  });

  final AppModel appModel;
  final MusicPluginManifest manifest;

  @override
  State<MusicPluginLoginPage> createState() => _MusicPluginLoginPageState();
}

class _MusicPluginLoginPageState extends State<MusicPluginLoginPage> {
  late final MusicPluginSource _source = widget.appModel.musicPluginManager
      .source(widget.manifest.id);
  final String _platform = musicPluginHostPlatform();
  late Future<List<MusicPluginLoginMethod>> _methods = _loadMethods();
  MusicPluginLoginMethod? _method;

  /// 取登录方式；第一种默认选中（插件按推荐顺序排）。
  Future<List<MusicPluginLoginMethod>> _loadMethods() async {
    final List<MusicPluginLoginMethod> methods = await _source.loginMethods(
      _platform,
    );
    if (mounted && _method == null && methods.isNotEmpty) {
      unawaited(_select(methods.first));
    }
    return methods;
  }

  MusicPluginLoginChallenge? _challenge;
  Object? _error;
  bool _busy = false;
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};

  /// 每换一次方式 / 重新开始 +1：在途的轮询与提交结果按代次丢弃。
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _select(MusicPluginLoginMethod method) async {
    final int gen = ++_generation;
    setState(() {
      _method = method;
      _challenge = null;
      _error = null;
      _busy = true;
    });
    try {
      final MusicPluginLoginChallenge c = await _source.loginBegin(
        method.id,
        _platform,
      );
      if (gen != _generation || !mounted) return;
      _apply(c, gen);
    } on Object catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  void _apply(MusicPluginLoginChallenge c, int gen) {
    if (c.state == MusicPluginLoginState.done) {
      FushiToast.show(
        msg: t.music_plugin_login_success(
          name: c.account?.name ?? widget.manifest.name,
        ),
        severity: ToastSeverity.success,
      );
      Navigator.of(context).pop(true);
      return;
    }
    for (final MusicPluginLoginField f in c.fields) {
      _fields.putIfAbsent(f.id, () => TextEditingController(text: f.value));
    }
    setState(() => _challenge = c);
    if (c.state == MusicPluginLoginState.pending &&
        _method?.type == MusicPluginLoginType.qr &&
        c.hasQr) {
      unawaited(_poll(c, gen));
    }
  }

  Future<void> _poll(MusicPluginLoginChallenge c, int gen) async {
    await Future<void>.delayed(Duration(milliseconds: c.pollMs ?? 2000));
    if (gen != _generation || !mounted) return;
    try {
      final MusicPluginLoginChallenge next = await _source.loginPoll(
        _method!.id,
        c.session,
        _platform,
      );
      if (gen != _generation || !mounted) return;
      _apply(next, gen);
    } on Object catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    }
  }

  Future<void> _submit(String action, Map<String, String> inputs) async {
    final MusicPluginLoginMethod method = _method!;
    final int gen = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final MusicPluginLoginChallenge c = await _source.loginSubmit(
        method.id,
        _challenge?.session,
        _platform,
        action: action,
        inputs: inputs,
      );
      if (gen != _generation || !mounted) return;
      _apply(c, gen);
    } on Object catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    } finally {
      if (gen == _generation && mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWeb(MusicPluginLoginChallenge c) async {
    final String? cookie = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => FushiAppUiScaleNeutralizer(
          child: MusicPluginWebLoginPage(
            title: widget.manifest.name,
            url: Uri.parse(c.webUrl!),
            cookieUrl: Uri.parse(c.webCookieUrl!),
            doneCookie: c.webDoneCookie!,
          ),
        ),
      ),
    );
    if (cookie == null || !mounted) return;
    await _submit('web', <String, String>{'cookie': cookie});
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiPageScaffold(
      title: t.music_plugin_login_title(name: widget.manifest.name),
      body: FutureBuilder<List<MusicPluginLoginMethod>>(
        future: _methods,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<MusicPluginLoginMethod>> snap,
            ) {
              if (snap.hasError) {
                return Center(
                  child: FushiPlaceholderMessage(
                    icon: FushiIcons.error,
                    message: musicPluginErrorText(snap.error!),
                    action: FushiFilledButton(
                      onPressed: () => setState(() {
                        _methods = _loadMethods();
                      }),
                      child: Text(t.music_server_retry),
                    ),
                  ),
                );
              }
              final List<MusicPluginLoginMethod>? methods = snap.data;
              if (methods == null) return const FushiLoadingView();
              if (methods.isEmpty) {
                return Center(
                  child: FushiPlaceholderMessage(
                    icon: FushiIcons.login,
                    message: t.music_plugin_login_no_methods,
                  ),
                );
              }
              return ListView(
                padding: withBottomSafeInset(
                  context,
                  EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    MediaQuery.paddingOf(context).top + tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                ),
                children: <Widget>[
                  if (methods.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: adaptiveSegmentedButton<String>(
                        context: context,
                        segments: <ButtonSegment<String>>[
                          for (final MusicPluginLoginMethod m in methods)
                            ButtonSegment<String>(
                              value: m.id,
                              label: Text(m.label),
                            ),
                        ],
                        selected: <String>{_method?.id ?? methods.first.id},
                        onSelectionChanged: (Set<String> v) => unawaited(
                          _select(
                            methods.firstWhere(
                              (MusicPluginLoginMethod m) => m.id == v.first,
                            ),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(height: tokens.spacing.section),
                  AnimatedSwitcher(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    child: KeyedSubtree(
                      key: ValueKey<String>(
                        '${_method?.id}|${_challenge?.session}|${_challenge?.state}',
                      ),
                      child: FushiEntranceScope(child: _body(context)),
                    ),
                  ),
                ],
              );
            },
      ),
    );
  }

  Widget _body(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginLoginMethod? method = _method;
    final MusicPluginLoginChallenge? c = _challenge;
    final List<Widget> children = <Widget>[];
    if (method?.description != null) {
      children.add(
        Text(method!.description!, style: context.fushiType.bodyMedium),
      );
    }
    if (c == null) {
      if (_busy) children.add(const FushiLinearProgressIndicator());
    } else if (c.state == MusicPluginLoginState.failed) {
      children.add(
        Text(
          t.music_plugin_login_failed(error: c.message ?? ''),
          style: context.fushiType.bodyMedium.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    } else {
      switch (method?.type) {
        case MusicPluginLoginType.qr:
          children.addAll(_qr(context, c));
        case MusicPluginLoginType.form:
          children.addAll(_form(context, c));
        case MusicPluginLoginType.web:
          children.addAll(_web(context, c));
        case null:
          break;
      }
    }
    if (_error != null) {
      children.add(
        Text(
          t.music_plugin_login_failed(error: musicPluginErrorText(_error!)),
          style: context.fushiType.bodyMedium.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }
    if (method != null &&
        (c?.state == MusicPluginLoginState.failed || _error != null)) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: FushiPressScale(
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('music_plugin_login_retry'),
              onPressed: () => unawaited(_select(method)),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.music_plugin_login_retry),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        for (int i = 0; i < children.length; i++)
          FushiStaggeredEntrance(index: i, child: children[i]),
      ],
    );
  }

  List<Widget> _qr(BuildContext context, MusicPluginLoginChallenge c) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget code = c.qrImageBase64 != null
        ? Image.memory(base64.decode(c.qrImageBase64!), width: 220, height: 220)
        : QrImageView(
            data: c.qrContent!,
            size: 220,
            // 二维码必须深色码点 + 浅色底才扫得出来：不跟主题反色。
            backgroundColor: Colors.white,
          );
    return <Widget>[
      Center(
        child: Container(
          key: const ValueKey<String>('music_plugin_login_qr'),
          padding: EdgeInsets.all(tokens.spacing.gap),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: tokens.radii.cardRadius,
          ),
          child: Opacity(opacity: c.qrScanned ? 0.35 : 1, child: code),
        ),
      ),
      Text(
        c.message ?? t.music_plugin_login_qr_hint,
        textAlign: TextAlign.center,
        style: context.fushiType.bodyMedium,
      ),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          if (c.appUrl != null)
            FushiPressScale(
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('music_plugin_login_open_app'),
                onPressed: () => unawaited(
                  launchUrl(
                    Uri.parse(c.appUrl!),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                icon: const FushiIcon(FushiIcons.openInNew),
                label: Text(t.music_plugin_login_open_app),
              ),
            ),
          FushiPressScale(
            child: FushiOutlinedButton.icon(
              onPressed: () => unawaited(_select(_method!)),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.music_plugin_login_qr_refresh),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _form(BuildContext context, MusicPluginLoginChallenge c) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Map<String, String> inputs() => <String, String>{
      for (final MusicPluginLoginField f in c.fields)
        f.id: _fields[f.id]?.text ?? '',
    };
    return <Widget>[
      if (c.message != null)
        Text(c.message!, style: context.fushiType.bodyMedium),
      for (final MusicPluginLoginField f in c.fields)
        FushiTextField(
          key: ValueKey<String>('music_plugin_login_field_${f.id}'),
          controller: _fields[f.id],
          labelText: f.label,
          hintText: f.placeholder,
          obscureText: f.secret && !f.multiline,
          minLines: f.multiline ? 3 : 1,
          maxLines: f.multiline ? 6 : 1,
          enabled: !_busy,
        ),
      Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: <Widget>[
          for (final MusicPluginLoginAction a in c.actions)
            FushiPressScale(
              child: a.primary
                  ? FushiFilledButton(
                      key: ValueKey<String>(
                        'music_plugin_login_action_${a.id}',
                      ),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_submit(a.id, inputs())),
                      child: Text(a.label),
                    )
                  : FushiOutlinedButton(
                      key: ValueKey<String>(
                        'music_plugin_login_action_${a.id}',
                      ),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_submit(a.id, inputs())),
                      child: Text(a.label),
                    ),
            ),
        ],
      ),
      if (_busy) const FushiLinearProgressIndicator(),
    ];
  }

  List<Widget> _web(
    BuildContext context,
    MusicPluginLoginChallenge c,
  ) => <Widget>[
    Text(
      c.message ?? t.music_plugin_login_web_waiting,
      style: context.fushiType.bodyMedium,
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: FushiPressScale(
        child: FushiFilledButton.icon(
          key: const ValueKey<String>('music_plugin_login_open_web'),
          onPressed: c.hasWeb && !_busy ? () => unawaited(_openWeb(c)) : null,
          icon: const FushiIcon(FushiIcons.globe),
          label: Text(t.music_plugin_login_web_open),
        ),
      ),
    ),
    if (_busy) const FushiLinearProgressIndicator(),
  ];
}

/// 网页登录：内嵌浏览器打开插件给的登录页，每秒读一次 [cookieUrl] 下的 Cookie，出现
/// [doneCookie] 就把该站全部 Cookie 拼成 `a=b; c=d` 交回（`pop`）。WebView 与 CookieManager
/// 绑同一个站点浏览器环境（[MangaWebViewEnvironment]，Windows 上不绑会读不到对方的 Cookie）。
class MusicPluginWebLoginPage extends StatefulWidget {
  const MusicPluginWebLoginPage({
    super.key,
    required this.title,
    required this.url,
    required this.cookieUrl,
    required this.doneCookie,
  });

  final String title;
  final Uri url;
  final Uri cookieUrl;
  final String doneCookie;

  @override
  State<MusicPluginWebLoginPage> createState() =>
      _MusicPluginWebLoginPageState();
}

class _MusicPluginWebLoginPageState extends State<MusicPluginWebLoginPage> {
  WebViewEnvironment? _environment;
  bool _ready = false;
  Timer? _timer;
  bool _done = false;

  // 只救命、不重建：登录页没有可恢复的进度，renderer 死后让用户自己重开，
  // 比自动重建悄悄清空已填的表单更清楚。
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'music-plugin-login',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final WebViewEnvironment? env = await MangaWebViewEnvironment.obtain();
    if (!mounted) return;
    setState(() {
      _environment = env;
      _ready = true;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_done) return;
    final List<Cookie> cookies = await CookieManager.instance(
      webViewEnvironment: _environment,
    ).getCookies(url: WebUri.uri(widget.cookieUrl));
    final bool hit = cookies.any(
      (Cookie c) => c.name == widget.doneCookie && '${c.value}'.isNotEmpty,
    );
    if (!hit || !mounted || _done) return;
    _done = true;
    _timer?.cancel();
    Navigator.of(
      context,
    ).pop(cookies.map((Cookie c) => '${c.name}=${c.value}').join('; '));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiPageScaffold(
      title: widget.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              MediaQuery.paddingOf(context).top + tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            child: Text(
              t.music_plugin_login_web_waiting,
              style: context.fushiType.bodySmall,
            ),
          ),
          Expanded(
            child: !_ready
                ? const FushiLoadingView()
                : KeyedSubtree(
                    // 重建 key 挂在 WebView 之上，与其它登录页同构。
                    key: _deathGuard.rebuildKey,
                    child: InAppWebView(
                      key: const ValueKey<String>('music_plugin_login_webview'),
                      webViewEnvironment: _environment,
                      initialUrlRequest: URLRequest(
                        url: WebUri.uri(widget.url),
                      ),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        sharedCookiesEnabled: true,
                        // 登录页的 WebView 历史就是用户的站点导航，后退手势合理。
                      ),
                      onLoadStop: (InAppWebViewController _, WebUri? _) =>
                          unawaited(_check()),
                      // 非 null 本身就是救命动作：Java 侧据此 `return true`，
                      // 不再连坐杀 app。
                      onWebContentProcessDidTerminate:
                          (InAppWebViewController _) => unawaited(
                            _deathGuard.handleWebContentTerminated(),
                          ),
                      onRenderProcessGone:
                          (
                            InAppWebViewController _,
                            RenderProcessGoneDetail detail,
                          ) => unawaited(
                            _deathGuard.handleDeath(
                              didCrash: detail.didCrash,
                              rendererPriorityAtExit:
                                  detail.rendererPriorityAtExit,
                            ),
                          ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
