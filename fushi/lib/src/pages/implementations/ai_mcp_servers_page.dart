/// 「设置 › AI › AI 助手 › MCP 服务器」：AI 助手接入的外部 MCP server 清单与编辑页
/// （spec `docs/specs/2026-11-05-ai-mcp-client-design.md` §3）。
///
/// - 列表页：每个 server 一行（开关 + 状态），「添加服务器」给网络地址 / 本地程序（仅桌面）/
///   粘贴配置。没有内置预设：用的是哪个 server 由用户自己决定、自己添加。
/// - 编辑页：名称、地址与请求头（或命令、参数、环境变量）、「每次调用前都询问」、
///   「测试连接」（列出工具，逐个开关）、删除。改动按「保存」才落盘。
///
/// 配置只经这里写（设备本地偏好 `ai_mcp_client_servers`）；AI 自己没有任何改它的入口。
library;

import 'dart:async';

import 'package:fushi_engine/ai/mcp_client/mcp_client_config.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_session.dart';
import 'package:fushi_engine/ai/mcp_client/mcp_client_toolbox.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/mcp_client/ai_mcp_client_form.dart';
import 'package:fushi/src/ai/mcp_client/ai_mcp_client_runtime.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/settings/settings_section_footer.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 打开 MCP 服务器页。[liveStatuses] 由调用方注入（生产接 AI 助手控制器的 MCP
/// 工具箱）：本页不 import 控制器，免得经 `op_context → app_model` 被拖进 lib/ 的
/// 大 import 环（守卫 `import_cycle_guard_test.dart`）。
Future<void> openAiMcpServersPage(
  BuildContext context,
  PreferencesRepository prefs, {
  required Map<String, McpServerStatus> Function() liveStatuses,
}) => Navigator.of(context).push(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => AiMcpServersPage(prefs: prefs, liveStatuses: liveStatuses),
  ),
);

/// 状态行文案（列表页与编辑页共用）。
String aiMcpServerStatusText(McpServerStatus? status) {
  switch (status?.state) {
    case null:
    case McpServerState.connecting:
      return t.ai_mcp_client_status_unchecked;
    case McpServerState.disabled:
      return t.ai_mcp_client_status_off;
    case McpServerState.unsupported:
      return t.ai_mcp_client_status_unsupported;
    case McpServerState.incomplete:
      return t.ai_mcp_client_status_incomplete;
    case McpServerState.connected:
      return t.ai_mcp_client_status_connected(n: status!.toolCount);
    case McpServerState.failed:
      return t.ai_mcp_client_status_failed(
        reason: status!.errorMessage ?? status.errorCode ?? '?',
      );
  }
}

/// 「添加服务器」的选项。
enum _AddKind { http, stdio, paste }

class AiMcpServersPage extends StatefulWidget {
  const AiMcpServersPage({
    required this.prefs,
    this.liveStatuses,
    this.openEditor,
    super.key,
  });

  final PreferencesRepository prefs;

  /// 对话里实际连接的状态（生产接 AI 助手控制器的 MCP 工具箱，见
  /// [openAiMcpServersPage]）。不给时当作都还没连过。
  final Map<String, McpServerStatus> Function()? liveStatuses;

  /// 打开编辑页（测试注入以免真的推路由）。
  final Future<void> Function(BuildContext context, String serverId)?
  openEditor;

  @override
  State<AiMcpServersPage> createState() => _AiMcpServersPageState();
}

class _AiMcpServersPageState extends State<AiMcpServersPage> {
  @override
  void initState() {
    super.initState();
    widget.prefs.addListener(_onPrefs);
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefs);
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  Map<String, McpServerStatus> _statuses() =>
      widget.liveStatuses?.call() ?? const <String, McpServerStatus>{};

  List<McpServerConfig> get _servers => widget.prefs.aiMcpClientServers;

  Future<void> _save(List<McpServerConfig> servers) =>
      widget.prefs.setAiMcpClientServers(servers);

  Future<void> _setEnabled(McpServerConfig server, bool enabled) =>
      _save(<McpServerConfig>[
        for (final McpServerConfig s in _servers)
          s.id == server.id ? s.copyWith(enabled: enabled) : s,
      ]);

  Future<void> _openEditor(String id) async {
    final Future<void> Function(BuildContext, String)? injected =
        widget.openEditor;
    if (injected != null) return injected(context, id);
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiMcpServerEditPage(prefs: widget.prefs, serverId: id),
      ),
    );
  }

  Future<void> _add() async {
    final List<String> taken = <String>[
      for (final McpServerConfig s in _servers) s.id,
    ];
    final _AddKind? kind = await showFushiChoiceDialog<_AddKind>(
      context: context,
      title: t.ai_mcp_client_add,
      icon: FushiIcons.add,
      options: <FushiChoiceOption<_AddKind>>[
        FushiChoiceOption<_AddKind>(
          value: _AddKind.http,
          label: t.ai_mcp_client_add_http,
          subtitle: t.ai_mcp_client_add_http_hint,
          icon: FushiIcons.globe,
        ),
        if (isDesktopPlatform)
          FushiChoiceOption<_AddKind>(
            value: _AddKind.stdio,
            label: t.ai_mcp_client_add_stdio,
            subtitle: t.ai_mcp_client_add_stdio_hint,
            icon: FushiIcons.code,
          ),
        FushiChoiceOption<_AddKind>(
          value: _AddKind.paste,
          label: t.ai_mcp_client_add_paste,
          subtitle: t.ai_mcp_client_add_paste_hint,
          icon: FushiIcons.paste,
        ),
      ],
    );
    if (kind == null || !mounted) return;
    switch (kind) {
      case _AddKind.http:
      case _AddKind.stdio:
        final String name = t.ai_mcp_client_new_server;
        final McpServerConfig created = McpServerConfig(
          id: mcpServerIdFor(name, taken),
          name: name,
          // 没填完前不连（isComplete 为 false），所以可以先开着。
          transport: kind == _AddKind.stdio
              ? McpTransportKind.stdio
              : McpTransportKind.http,
        );
        await _save(<McpServerConfig>[..._servers, created]);
        if (mounted) await _openEditor(created.id);
      case _AddKind.paste:
        await _paste(taken);
    }
  }

  Future<void> _paste(List<String> taken) async {
    final String? raw = await showFushiTextInputDialog(
      context: context,
      title: t.ai_mcp_client_add_paste,
      message: t.ai_mcp_client_add_paste_hint,
      icon: FushiIcons.paste,
      maxLines: 8,
      trim: true,
    );
    if (raw == null || !mounted) return;
    List<McpServerConfig> imported;
    try {
      imported = importMcpServersFromJson(raw, taken: taken);
    } on FormatException {
      _snack(t.ai_mcp_client_paste_invalid);
      return;
    }
    // 手机上不收本地程序（拉不起来）。导入的条目一律是关着的（见
    // [importMcpServersFromJson]）：用户在列表里看过命令 / 地址、亲手打开后才会连。
    imported = <McpServerConfig>[
      for (final McpServerConfig c in imported)
        if (aiMcpServerSupported(c)) c,
    ];
    if (imported.isEmpty) {
      _snack(t.ai_mcp_client_paste_none);
      return;
    }
    await _save(<McpServerConfig>[..._servers, ...imported]);
    _snack(t.ai_mcp_client_paste_added(n: imported.length));
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final List<McpServerConfig> servers = _servers;
    final Map<String, McpServerStatus> statuses = _statuses();
    return SettingsKitScaffold(
      title: t.ai_mcp_client_title,
      leadingIcon: FushiIcons.hub,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final double top = MediaQuery.paddingOf(context).top;
            final List<Widget> children = <Widget>[
              SettingsSectionFooter(t.ai_mcp_client_intro),
              if (servers.isEmpty)
                SettingsEmptyState(
                  key: const ValueKey<String>('ai_mcp_servers_empty'),
                  icon: FushiIcons.hub,
                  title: t.ai_mcp_client_empty_title,
                  message: t.ai_mcp_client_empty_message,
                )
              else ...<Widget>[
                SettingsSectionHeader(t.ai_mcp_client_title),
                for (int i = 0; i < servers.length; i++)
                  _row(servers[i], statuses[servers[i].id], i, servers.length),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(
                  child: FushiPressScale(
                    child: FushiFilledButton.tonalIcon(
                      key: const ValueKey<String>('ai_mcp_servers_add'),
                      onPressed: _add,
                      icon: const FushiIcon(FushiIcons.add),
                      label: Text(t.ai_mcp_client_add),
                    ),
                  ),
                ),
              ),
            ];
            return FushiEntranceScope(
              child: ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 24),
                itemCount: children.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => children[index],
                ),
              ),
            );
          },
    );
  }

  Widget _row(
    McpServerConfig server,
    McpServerStatus? live,
    int index,
    int count,
  ) {
    // 关着的、本平台不支持的、没填完的，不看对话里的旧状态。
    final McpServerStatus? status = !server.enabled
        ? const McpServerStatus(McpServerState.disabled)
        : !aiMcpServerSupported(server)
        ? const McpServerStatus(McpServerState.unsupported)
        : !server.isComplete
        ? const McpServerStatus(McpServerState.incomplete)
        : live;
    final bool failed = status?.state == McpServerState.failed;
    final String target = server.transport == McpTransportKind.http
        ? server.url
        : <String>[server.command, ...server.args].join(' ');
    return FushiGroupedListItem(
      key: ValueKey<String>('ai_mcp_server_${server.id}'),
      index: index,
      count: count,
      child: FushiPressScale(
        child: FushiListItem(
          onTap: () => _openEditor(server.id),
          leading: FushiListLeadingIcon(
            failed
                ? FushiIcons.cloudOff
                : server.transport == McpTransportKind.http
                ? FushiIcons.globe
                : FushiIcons.code,
            shape: FushiLeadingShape.square,
            tone: failed ? FushiCardTone.error : FushiCardTone.secondary,
          ),
          title: Text(server.name),
          subtitle: Text(
            target.trim().isEmpty
                ? aiMcpServerStatusText(status)
                : '${target.trim()}\n${aiMcpServerStatusText(status)}',
          ),
          trailing: FushiSwitch(
            key: ValueKey<String>('ai_mcp_server_switch_${server.id}'),
            value: server.enabled,
            onChanged: (bool value) => _setEnabled(server, value),
          ),
        ),
      ),
    );
  }
}

/// 编辑一个 server。
class AiMcpServerEditPage extends StatefulWidget {
  const AiMcpServerEditPage({
    required this.prefs,
    required this.serverId,
    this.probe = probeAiMcpServer,
    super.key,
  });

  final PreferencesRepository prefs;
  final String serverId;

  /// 「测试连接」（测试注入假 server）。
  final Future<McpProbeResult> Function(McpServerConfig config) probe;

  @override
  State<AiMcpServerEditPage> createState() => _AiMcpServerEditPageState();
}

class _AiMcpServerEditPageState extends State<AiMcpServerEditPage> {
  late McpServerConfig _draft;
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _headers;
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _env;
  McpProbeResult? _probe;
  bool _probing = false;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    final McpServerConfig? found = widget.prefs.aiMcpClientServers
        .where((McpServerConfig s) => s.id == widget.serverId)
        .firstOrNull;
    _missing = found == null;
    _draft = found ?? McpServerConfig(id: widget.serverId, name: '');
    _name = TextEditingController(text: _draft.name);
    _url = TextEditingController(text: _draft.url);
    _headers = TextEditingController(
      text: formatMcpHeaderLines(_draft.headers),
    );
    _command = TextEditingController(text: _draft.command);
    _args = TextEditingController(text: _draft.args.join('\n'));
    _env = TextEditingController(text: formatMcpEnvLines(_draft.env));
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _url,
      _headers,
      _command,
      _args,
      _env,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isHttp => _draft.transport == McpTransportKind.http;

  /// 表单 → 配置（工具开关与确认策略已在 [_draft] 里）。
  McpServerConfig _collect() {
    final String name = _name.text.trim();
    return _draft.copyWith(
      name: name.isEmpty ? _draft.name : name,
      url: _isHttp ? _url.text.trim() : '',
      headers: _isHttp
          ? parseMcpHeaderLines(_headers.text)
          : const <String, String>{},
      command: _isHttp ? '' : _command.text.trim(),
      args: _isHttp ? const <String>[] : parseMcpArgLines(_args.text),
      env: _isHttp ? const <String, String>{} : parseMcpEnvLines(_env.text),
    );
  }

  String? get _fieldError {
    final McpServerConfig config = _collect();
    if (config.isComplete) return null;
    return _isHttp
        ? t.ai_mcp_client_invalid_url
        : t.ai_mcp_client_invalid_command;
  }

  Future<void> _test() async {
    final McpServerConfig config = _collect();
    setState(() {
      _probing = true;
      _probe = null;
    });
    final McpProbeResult result = await widget.probe(config);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probe = result;
    });
  }

  Future<void> _save() async {
    final McpServerConfig config = _collect();
    final List<McpServerConfig> all = widget.prefs.aiMcpClientServers;
    await widget.prefs.setAiMcpClientServers(<McpServerConfig>[
      for (final McpServerConfig s in all) s.id == config.id ? config : s,
      if (!all.any((McpServerConfig s) => s.id == config.id)) config,
    ]);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.ai_mcp_client_delete_confirm(name: _draft.name),
      icon: FushiIcons.delete,
      confirmLabel: t.ai_mcp_client_delete,
      destructive: true,
    );
    if (!ok) return;
    await widget.prefs.setAiMcpClientServers(<McpServerConfig>[
      for (final McpServerConfig s in widget.prefs.aiMcpClientServers)
        if (s.id != _draft.id) s,
    ]);
    if (mounted) Navigator.of(context).maybePop();
  }

  void _setToolEnabled(String tool, bool enabled) => setState(() {
    final Set<String> disabled = <String>{..._draft.disabledTools};
    enabled ? disabled.remove(tool) : disabled.add(tool);
    _draft = _draft.copyWith(disabledTools: disabled);
  });

  @override
  Widget build(BuildContext context) {
    return SettingsKitScaffold(
      title: _missing ? t.ai_mcp_client_new_server : t.ai_mcp_client_edit_title,
      leadingIcon: FushiIcons.hub,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final double top = MediaQuery.paddingOf(context).top;
            final List<Widget> children = <Widget>[
              ..._fields(),
              _confirmSwitch(),
              ..._toolsSection(),
              _actions(),
            ];
            return FushiEntranceScope(
              child: ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 24),
                itemCount: children.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => children[index],
                ),
              ),
            );
          },
    );
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
    String? error,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    child: FushiTextField(
      key: ValueKey<String>(key),
      controller: controller,
      labelText: label,
      helperText: hint,
      errorText: error,
      maxLines: maxLines,
      minLines: maxLines > 1 ? 2 : null,
      keyboardType: maxLines > 1 ? TextInputType.multiline : TextInputType.text,
      onChanged: (_) => setState(() {}),
    ),
  );

  List<Widget> _fields() {
    final String? error = _fieldError;
    return <Widget>[
      _field('ai_mcp_edit_name', _name, t.ai_mcp_client_field_name),
      if (_isHttp) ...<Widget>[
        _field(
          'ai_mcp_edit_url',
          _url,
          t.ai_mcp_client_field_url,
          hint: 'https://…',
          error: _url.text.trim().isEmpty ? null : error,
        ),
        _field(
          'ai_mcp_edit_headers',
          _headers,
          t.ai_mcp_client_field_headers,
          hint: t.ai_mcp_client_field_headers_hint,
          maxLines: 4,
        ),
      ] else ...<Widget>[
        _field(
          'ai_mcp_edit_command',
          _command,
          t.ai_mcp_client_field_command,
          hint: 'npx / uvx / …',
        ),
        _field(
          'ai_mcp_edit_args',
          _args,
          t.ai_mcp_client_field_args,
          hint: t.ai_mcp_client_field_args_hint,
          maxLines: 4,
        ),
        _field(
          'ai_mcp_edit_env',
          _env,
          t.ai_mcp_client_field_env,
          hint: t.ai_mcp_client_field_env_hint,
          maxLines: 4,
        ),
      ],
    ];
  }

  Widget _confirmSwitch() => FushiGroupedListItem(
    index: 0,
    count: 1,
    child: FushiListItem(
      title: Text(t.ai_mcp_client_confirm_every_call),
      subtitle: Text(t.ai_mcp_client_confirm_every_call_hint),
      subtitleMaxLines: 3,
      trailing: FushiSwitch(
        key: const ValueKey<String>('ai_mcp_edit_confirm_every_call'),
        value: _draft.confirmEveryCall,
        onChanged: (bool value) =>
            setState(() => _draft = _draft.copyWith(confirmEveryCall: value)),
      ),
    ),
  );

  List<Widget> _toolsSection() {
    final McpProbeResult? probe = _probe;
    final List<Widget> out = <Widget>[
      SettingsSectionHeader(t.ai_mcp_client_tools_section),
      if (probe == null)
        SettingsSectionFooter(
          _probing ? t.ai_mcp_client_testing : t.ai_mcp_client_tools_hint,
        )
      else
        SettingsSectionFooter(
          aiMcpServerStatusText(probe.status),
          key: const ValueKey<String>('ai_mcp_edit_probe_status'),
        ),
    ];
    if (probe == null) return out;
    final List<McpRemoteTool> tools = probe.tools;
    for (int i = 0; i < tools.length; i++) {
      final McpRemoteTool tool = tools[i];
      final String tags = tool.readOnly
          ? t.ai_mcp_client_tool_read_only
          : t.ai_mcp_client_tool_asks;
      out.add(
        FushiGroupedListItem(
          key: ValueKey<String>('ai_mcp_edit_tool_${tool.name}'),
          index: i,
          count: tools.length,
          child: FushiListItem(
            title: Text(tool.title ?? tool.name),
            subtitle: Text('${tool.name} · $tags'),
            trailing: FushiSwitch(
              key: ValueKey<String>('ai_mcp_edit_tool_switch_${tool.name}'),
              value: !_draft.disabledTools.contains(tool.name),
              onChanged: (bool value) => _setToolEnabled(tool.name, value),
            ),
          ),
        ),
      );
    }
    return out;
  }

  Widget _actions() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: <Widget>[
        FushiPressScale(
          child: FushiOutlinedButton.icon(
            key: const ValueKey<String>('ai_mcp_edit_test'),
            onPressed: _probing || _fieldError != null ? null : _test,
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.ai_mcp_client_test),
          ),
        ),
        FushiPressScale(
          child: FushiFilledButton.icon(
            key: const ValueKey<String>('ai_mcp_edit_save'),
            onPressed: _save,
            icon: const FushiIcon(FushiIcons.save),
            label: Text(t.ai_mcp_client_save),
          ),
        ),
        if (!_missing)
          FushiPressScale(
            child: FushiTextButton.icon(
              key: const ValueKey<String>('ai_mcp_edit_delete'),
              onPressed: _delete,
              icon: const FushiIcon(FushiIcons.delete),
              label: Text(t.ai_mcp_client_delete),
            ),
          ),
      ],
    ),
  );
}
