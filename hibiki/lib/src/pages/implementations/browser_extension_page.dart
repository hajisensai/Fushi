import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/lookup/browser_extension_installer.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/sync/yomitan_api_server.dart'
    show kYomitanApiDefaultPort;
import 'package:hibiki/utils.dart';

/// 桌面专属「浏览器扩展」页（顶层导航目的地，仅桌面显示）。
///
/// 把原来埋在「设置 → 查词」里的安装入口独立成页，并在原「半自动安装引导」之上补：
/// ① 服务 + 连接状态卡；② 加载扩展后「验证插件已正常启用」的连接检测（扩展 SW 启动时
/// 主动打 `/api/extension/status`，server 刷新 last-seen，这里据此判断已连上）；
/// ③ 扩展版本（内容指纹）与「重新准备/刷新」。自建 MV3 无真·一键（浏览器封侧载），故仍为
/// 半自动引导；但 host/port/token 已由安装助手自动写入扩展，用户无需手填。
class BrowserExtensionPage extends ConsumerStatefulWidget {
  const BrowserExtensionPage({super.key});

  @override
  ConsumerState<BrowserExtensionPage> createState() =>
      _BrowserExtensionPageState();
}

class _BrowserExtensionPageState extends ConsumerState<BrowserExtensionPage> {
  /// 解压出的扩展目录绝对路径（已复制到剪贴板）；null 表示尚未准备。
  String? _extensionDir;
  bool _preparing = false;

  // 准备时的一次性快照，驱动引导横幅文案（成功 / 先开 server / 端口冲突）。
  bool _serverEnabled = false;
  bool _hasToken = false;
  int _serverPort = kYomitanApiDefaultPort;
  bool _portConflict = false;

  // 连接检测（验证插件已正常启用）状态。
  bool _verifying = false;
  bool? _verifyConnected;

  // 连接状态卡片的轻量刷新（扩展 last-seen 由 server 端异步更新，这里定时重绘显示）。
  Timer? _statusTimer;

  /// 判定「插件近期连上过」的时间窗：扩展 SW 启动/查词/心跳时打本机 server 刷新 last-seen，
  /// 加载/重新加载扩展后这段窗口内即可检测到。BUG-1043：扩展改用 chrome.alarms 每 60s
  /// 心跳保活，此窗口取 150s（> 一个心跳周期 + 抖动余量），单次心跳丢包不会误判「未连接」。
  static const Duration _seenWindow = Duration(seconds: 150);

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isRecentlySeen(AppModel appModel) {
    final DateTime? seen = appModel.browserExtensionLastSeenAt;
    if (seen == null) return false;
    return DateTime.now().difference(seen) < _seenWindow;
  }

  /// 准备扩展：幂等开启 yomitan-api server（token 为空才播种、绝不覆盖）→ 用当前 server
  /// 真值解压扩展到本机 → 路径复制剪贴板。与原设置里的安装动作同一流程，仅换到页面里。
  Future<void> _prepare() async {
    if (_preparing) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _preparing = true);
    // TODO-1266：装扩展即默认开启 yomitan-api server（省得装完 401 连不上）。
    final bool serverReady =
        await appModel.ensureYomitanApiServerForBrowserExtension();
    // TODO-1087：解压时注入当前 server 真值，扩展默认即连本机 app，无需手填。
    final String dir = await prepareBundledBrowserExtension(
      serverConfig: BrowserExtensionServerConfig(
        host: '127.0.0.1',
        port: appModel.yomitanApiPort,
        token: appModel.yomitanApiKey,
      ),
    );
    await Clipboard.setData(ClipboardData(text: dir));
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _extensionDir = dir;
      _serverEnabled = serverReady && appModel.yomitanApiServerEnabled;
      _hasToken = appModel.yomitanApiKey.isNotEmpty;
      _serverPort = appModel.yomitanApiPort;
      _portConflict = !serverReady;
      _verifyConnected = null;
    });
    _snack(t.copied);
  }

  /// 验证插件已正常启用：加载/重新加载扩展后，其 SW 会主动打本机 server，刷新 last-seen。
  /// 这里点一下后短轮询若干秒，检测到近期活跃即判定已连接。
  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _verifyConnected = null;
    });
    final AppModel appModel = ref.read(appProvider);
    final DateTime start = DateTime.now();
    bool connected = _isRecentlySeen(appModel);
    while (!connected &&
        DateTime.now().difference(start) < const Duration(seconds: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      connected = _isRecentlySeen(appModel);
    }
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _verifyConnected = connected;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppModel appModel = ref.watch(appProvider);
    final bool serverOn = appModel.yomitanApiServerEnabled;
    final bool connected = _isRecentlySeen(appModel);
    final String? build = appModel.browserExtensionBuild;

    return Scaffold(
      appBar: AppBar(title: Text(t.nav_browser_extension)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(t.browser_extension_page_intro,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          _statusCard(theme,
              serverOn: serverOn,
              connected: connected,
              port: appModel.yomitanApiPort),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _preparing ? null : _prepare,
            icon: _preparing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.extension_outlined, size: 18),
            label: Text(_extensionDir == null
                ? t.browser_extension_prepare_button
                : t.browser_extension_reinstall_button),
          ),
          const SizedBox(height: 8),
          Text(
            t.browser_extension_prepare_hint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_extensionDir != null) ...<Widget>[
            const Divider(height: 32),
            BrowserExtensionInstallSteps(
              path: _extensionDir!,
              serverEnabled: _serverEnabled,
              hasToken: _hasToken,
              serverPort: _serverPort,
              portConflict: _portConflict,
            ),
            const SizedBox(height: 8),
            _verifyStep(theme),
          ],
          const Divider(height: 32),
          _versionCard(theme, build),
        ],
      ),
    );
  }

  Widget _statusCard(
    ThemeData theme, {
    required bool serverOn,
    required bool connected,
    required int port,
  }) {
    return HibikiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                serverOn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 20,
                color: serverOn
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(serverOn
                    ? '${t.browser_extension_server_on} · $port'
                    : t.browser_extension_server_off),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(
                connected ? Icons.link : Icons.link_off,
                size: 20,
                color: connected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(connected
                    ? t.browser_extension_status_connected
                    : t.browser_extension_status_never),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 引导之后的第 6 步：验证插件已加载并连上（连接检测）。
  Widget _verifyStep(ThemeData theme) {
    final bool? result = _verifyConnected;
    Color? tone;
    String? resultText;
    IconData? resultIcon;
    if (result == true) {
      tone = theme.colorScheme.primary;
      resultText = t.browser_extension_verify_connected;
      resultIcon = Icons.check_circle;
    } else if (result == false) {
      tone = theme.colorScheme.error;
      resultText = t.browser_extension_verify_not_detected;
      resultIcon = Icons.error_outline;
    }
    return HibikiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.verified_outlined,
                  size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(t.browser_extension_step_verify)),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _verifying ? null : _verify,
              icon: _verifying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(_verifying
                  ? t.browser_extension_verify_checking
                  : t.browser_extension_verify_button),
            ),
          ),
          if (resultText != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(resultIcon, size: 18, color: tone),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(resultText, style: TextStyle(color: tone)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _versionCard(ThemeData theme, String? build) {
    return HibikiCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${t.browser_extension_version_label} · ${build ?? '—'}',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 半自动安装引导的分步图文（横幅 + 5 步）。原为 `settings_schema_lookup.dart` 的私有
/// AlertDialog 内容，抽出复用于 [BrowserExtensionPage] 并暴露给 widget 测试。
class BrowserExtensionInstallSteps extends StatelessWidget {
  const BrowserExtensionInstallSteps({
    super.key,
    required this.path,
    required this.serverEnabled,
    required this.hasToken,
    required this.serverPort,
    required this.portConflict,
  });

  /// 解压出的扩展目录绝对路径（供「加载已解压」时选择）。
  final String path;

  /// yomitan-api server 是否已开启（决定自动配置横幅是成功还是提醒）。
  final bool serverEnabled;

  /// 是否已设 API token（未设时连接虽通但鉴权会失败，一并提醒）。
  final bool hasToken;

  /// 安装助手自动启服失败时的端口及冲突态，用于给出 Yomitan 专项修复路径。
  final int serverPort;
  final bool portConflict;

  String _portInUseMessage() {
    return serverPort == kYomitanApiDefaultPort
        ? t.browser_extension_yomitan_port_conflict(port: serverPort)
        : t.sync_server_port_in_use(port: serverPort);
  }

  /// 一步：编号圆点 + 图标 + 正文（可含尾随可复制字段）。
  Widget _step(
    BuildContext context, {
    required int index,
    required IconData icon,
    required String text,
    Widget? trailing,
  }) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(text),
                if (trailing != null) ...<Widget>[
                  const SizedBox(height: 6),
                  trailing,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 可复制字段：等宽显示 [value]，尾随复制按钮，复制后 SnackBar 反馈。
  Widget _copyableField(BuildContext context, String value) {
    return HibikiCard(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          HibikiIconButton(
            icon: Icons.copy,
            size: 18,
            tooltip: t.copy,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t.copied)),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool autoReady = serverEnabled && hasToken;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 自动配置状态横幅：仅在未就绪时提醒（端口冲突 / 先开 server）。
        // 就绪时不再显示——「完成」由步骤 5 承担，横幅重复它反而是句废话。
        if (!autoReady) ...<Widget>[
          HibikiCard(
            color: theme.colorScheme.tertiaryContainer,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.info_outline,
                  color: theme.colorScheme.onTertiaryContainer,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    portConflict
                        ? _portInUseMessage()
                        : t.browser_extension_enable_server_first,
                    style: TextStyle(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        // 步骤 1：打开扩展管理页（chrome:// / edge:// 无法程序化导航，给可复制文本）。
        _step(
          context,
          index: 1,
          icon: Icons.open_in_browser_outlined,
          text: t.browser_extension_step_open_page,
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _copyableField(
                  context, browserExtensionsPageUrl(BrowserKind.chrome)),
              const SizedBox(height: 6),
              _copyableField(
                  context, browserExtensionsPageUrl(BrowserKind.edge)),
            ],
          ),
        ),
        _step(
          context,
          index: 2,
          icon: Icons.developer_mode_outlined,
          text: t.browser_extension_step_dev_mode,
        ),
        _step(
          context,
          index: 3,
          icon: Icons.drive_folder_upload_outlined,
          text: t.browser_extension_step_load_unpacked,
        ),
        _step(
          context,
          index: 4,
          icon: Icons.folder_open_outlined,
          text: t.browser_extension_step_pick_folder,
          trailing: _copyableField(context, path),
        ),
        _step(
          context,
          index: 5,
          icon: Icons.check_circle_outline,
          text: t.browser_extension_step_done_auto,
        ),
      ],
    );
  }
}

/// TODO-1087：暴露安装引导分步 widget 给测试（验证可复制字段 + 分步渲染 + 横幅），
/// 不改变生产调用路径（生产由 [BrowserExtensionPage] 使用）。
@visibleForTesting
Widget buildBrowserExtensionInstallStepsForTest({
  required String path,
  required bool serverEnabled,
  required bool hasToken,
  int serverPort = kYomitanApiDefaultPort,
  bool portConflict = false,
}) {
  return BrowserExtensionInstallSteps(
    path: path,
    serverEnabled: serverEnabled,
    hasToken: hasToken,
    serverPort: serverPort,
    portConflict: portConflict,
  );
}
