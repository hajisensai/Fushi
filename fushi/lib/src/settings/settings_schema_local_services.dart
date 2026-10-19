import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/port_kill_confirm.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/fushi_api_access_policy.dart';
import 'package:fushi/src/sync/fushi_api_port_conflict_notice.dart'
    show fushiApiPortInUseMessage;
import 'package:fushi/src/sync/port_process_terminator.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart'
    show SyncServerPortInUseException;

/// 「设置 › 连接 › 本机服务」：Fushi 对外开放的本机 HTTP 服务（Fushi API，兼
/// yomitan-api 与 AnkiConnect 兼容端点）的唯一的家——开关、允许谁连、端口、密钥。
///
/// 此前这组设置寄生在「查词 › 外部集成」：服务不只给查词用（制卡、字幕搜索、复习
/// 加卡都走它），监听范围与端口也根本没有入口（服务恒绑 0.0.0.0、端口偏好无 UI）。
SettingsDestination buildLocalServicesDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.localServices,
    title: t.settings_local_services_title,
    summary: t.settings_local_services_summary,
    icon: FushiIcons.server,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'local_services.section.fushi_api',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.fushi_api_server,
        items: <SettingsItem>[
          // 浏览器扩展「安装助手」是桌面专属顶层页（BrowserExtensionPage）；扩展就是
          // 本服务最主要的客户端，入口跟着服务走（审计 K：保留可搜索的导航项）。
          SettingsNavigationItem(
            id: 'local_services.browser_extension',
            title: t.nav_browser_extension,
            icon: Icons.extension_outlined,
            showIcon: true,
            visible: (SettingsContext settingsContext) =>
                DesktopLookupService.isDesktop,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const BrowserExtensionPage(),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'local_services.fushi_api_server',
            title: t.fushi_api_server,
            subtitle: t.fushi_api_server_hint,
            icon: Icons.api_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.fushiApiServerEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              // 从关到开时空 key 自动播种（见 setFushiApiServerEnabledByUser）。
              await settingsContext.appModel.setFushiApiServerEnabledByUser(
                value,
              );
              if (value) {
                try {
                  await settingsContext.appModel.startFushiApiServer();
                } on SyncServerPortInUseException {
                  // startFushiApiServer 已在抛出前把开关复位为 false。
                  _showFushiApiPortConflictSnackBar(settingsContext);
                }
              } else {
                await settingsContext.appModel.stopFushiApiServer();
              }
              settingsContext.refresh();
            },
          ),
          // 按「开关 × 允许范围 × 有没有密钥」说清此刻**实际**谁能连——判据与
          // [FushiApiAccessPolicy.decide] 同一条（非本机必须带密钥）。空 key 时就地
          // 给「生成密钥」入口（绝不覆盖已有 key）。
          SettingsStatusItem(
            id: 'local_services.fushi_api_reach',
            title: t.fushi_api_reach_title,
            icon: Icons.shield_outlined,
            subtitleBuilder: fushiApiReachDescription,
            actionLabel: t.fushi_api_key_generate,
            actionVisible: (SettingsContext c) =>
                c.appModel.fushiApiKey.isEmpty,
            onAction: (SettingsContext settingsContext) async {
              final bool seeded = await settingsContext.appModel
                  .seedFushiApiKeyIfEmpty();
              if (seeded) await _applyConfigChange(settingsContext);
              settingsContext.refresh();
            },
          ),
          SettingsSegmentedItem<FushiApiAccessMode>(
            id: 'local_services.fushi_api_access',
            title: t.fushi_api_access_title,
            subtitle: t.fushi_api_access_hint,
            icon: Icons.lan_outlined,
            options: <SettingsSegmentOption<FushiApiAccessMode>>[
              SettingsSegmentOption<FushiApiAccessMode>(
                value: FushiApiAccessMode.localOnly,
                label: t.fushi_api_access_local_only,
              ),
              SettingsSegmentOption<FushiApiAccessMode>(
                value: FushiApiAccessMode.lan,
                label: t.fushi_api_access_lan,
              ),
              SettingsSegmentOption<FushiApiAccessMode>(
                value: FushiApiAccessMode.allowList,
                label: t.fushi_api_access_allow_list,
              ),
            ],
            defaultValue: FushiApiAccessMode.lan,
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.fushiApiAccessMode,
            onChanged:
                (
                  SettingsContext settingsContext,
                  FushiApiAccessMode value,
                ) async {
                  await settingsContext.appModel.setFushiApiAccessMode(value);
                  await _applyConfigChange(settingsContext);
                  settingsContext.refresh();
                },
          ),
          SettingsStatusItem(
            id: 'local_services.fushi_api_allowed_networks',
            title: t.fushi_api_allowed_networks_title,
            icon: Icons.rule_outlined,
            visible: (SettingsContext c) =>
                c.appModel.fushiApiAccessMode == FushiApiAccessMode.allowList,
            subtitleBuilder: (SettingsContext c) {
              final List<FushiIpNetwork> networks = parseFushiIpNetworks(
                c.appModel.fushiApiAllowedNetworks,
              ).networks;
              if (networks.isEmpty) return t.fushi_api_allowed_networks_empty;
              return networks.map((FushiIpNetwork n) => n.source).join('\n');
            },
            actionLabel: t.dialog_edit,
            onAction: _editAllowedNetworks,
          ),
          SettingsStatusItem(
            id: 'local_services.fushi_api_port',
            title: t.fushi_api_port_title,
            icon: Icons.settings_ethernet_outlined,
            subtitleBuilder: (SettingsContext c) =>
                t.fushi_api_port_value(port: c.appModel.fushiApiPort),
            actionLabel: t.dialog_edit,
            onAction: _editPort,
          ),
          // 一等文本项（secret）：行尾眼睛显隐 + 复制。写穿后按新 key 重启服务，并把
          // 新 key 写进本机已解压的浏览器扩展副本（扩展据此自动跟上）。
          SettingsTextItem(
            id: 'local_services.fushi_api_key',
            title: t.fushi_api_key,
            subtitle: t.fushi_api_key_hint,
            icon: Icons.key_outlined,
            secret: true,
            copyable: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.fushiApiKey,
            onChanged: (SettingsContext settingsContext, String value) async {
              await settingsContext.appModel.setFushiApiKey(value);
              await _applyConfigChange(settingsContext);
              settingsContext.refresh();
            },
          ),
          // 复习模块（SRS，默认关）开着时，Fushi API 根路径同时是 AnkiConnect v6 兼容
          // 端点：Yomitan / asbplayer 等只认 AnkiConnect 的工具填这个地址即可往 Fushi
          // 复习里加卡。谁能连、要不要密钥与上面同一套（见「当前谁能连接」）。
          SettingsStatusItem(
            id: 'local_services.srs_ankiconnect',
            visible: (SettingsContext c) =>
                c.appModel.moduleVisibility.isEnabled(ModuleId.srs),
            title: t.srs_ankiconnect_title,
            icon: FushiIcons.hub,
            subtitleBuilder: (SettingsContext c) =>
                t.srs_ankiconnect_hint(port: c.appModel.fushiApiPort),
          ),
        ],
      ),
    ],
  );
}

/// 「当前谁能连接」的状态文案。判据与 [FushiApiAccessPolicy.decide] 一致：本机恒可连；
/// 非本机须在允许范围内**且**已设密钥。
String fushiApiReachDescription(SettingsContext c) {
  final AppModel appModel = c.appModel;
  if (!appModel.fushiApiServerEnabled) return t.fushi_api_reach_server_off;
  final FushiApiAccessMode mode = appModel.fushiApiAccessMode;
  if (mode == FushiApiAccessMode.localOnly) {
    return t.fushi_api_reach_local_only;
  }
  if (appModel.fushiApiKey.isEmpty) return t.fushi_api_reach_no_key;
  if (mode == FushiApiAccessMode.allowList) {
    final bool hasNetworks = parseFushiIpNetworks(
      appModel.fushiApiAllowedNetworks,
    ).networks.isNotEmpty;
    return hasNetworks
        ? t.fushi_api_reach_allow_list
        : t.fushi_api_reach_local_only;
  }
  return t.fushi_api_reach_lan;
}

Future<void> _editAllowedNetworks(SettingsContext settingsContext) async {
  final String? raw = await showFushiTextInputDialog(
    context: settingsContext.context,
    title: t.fushi_api_allowed_networks_title,
    message: t.fushi_api_allowed_networks_dialog_hint,
    initialValue: settingsContext.appModel.fushiApiAllowedNetworks,
    hintText: '192.168.1.0/24',
    allowEmpty: true,
    maxLines: 6,
    keyboardType: TextInputType.multiline,
    validator: (String value) {
      final List<String> invalid = parseFushiIpNetworks(value).invalid;
      if (invalid.isEmpty) return null;
      return t.fushi_api_allowed_networks_invalid(entries: invalid.join(', '));
    },
  );
  if (raw == null) return;
  // 归一化成每行一条，回显与偏好一致。
  final String normalized = parseFushiIpNetworks(
    raw,
  ).networks.map((FushiIpNetwork n) => n.source).join('\n');
  await settingsContext.appModel.setFushiApiAllowedNetworks(normalized);
  await _applyConfigChange(settingsContext);
  settingsContext.refresh();
}

Future<void> _editPort(SettingsContext settingsContext) async {
  final AppModel appModel = settingsContext.appModel;
  final String? raw = await showFushiTextInputDialog(
    context: settingsContext.context,
    title: t.fushi_api_port_title,
    initialValue: '${appModel.fushiApiPort}',
    keyboardType: TextInputType.number,
    validator: (String value) =>
        parseFushiApiPort(value) == null ? t.fushi_api_port_invalid : null,
  );
  if (raw == null) return;
  final int? port = parseFushiApiPort(raw);
  if (port == null || port == appModel.fushiApiPort) return;
  final bool changed = await appModel.changeFushiApiPort(port);
  _showSnackBar(
    settingsContext,
    changed ? t.fushi_api_port_changed : t.fushi_api_port_reverted(port: port),
  );
  settingsContext.refresh();
}

/// 端口输入解析：1–65535 的整数，其余返回 null。
int? parseFushiApiPort(String raw) {
  final int? port = int.tryParse(raw.trim());
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

Future<void> _applyConfigChange(SettingsContext settingsContext) async {
  try {
    await settingsContext.appModel.applyFushiApiServerConfigChange();
  } on SyncServerPortInUseException {
    _showFushiApiPortConflictSnackBar(settingsContext);
  }
}

void _showSnackBar(SettingsContext settingsContext, String message) {
  final BuildContext ctx = settingsContext.context;
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(FushiSnackBar(content: Text(message)));
}

/// 端口冲突提示：说明占用者（默认端口时通常是浏览器拉起的 yomitan-api Python
/// 进程），并在支持的桌面平台附「结束进程并重试」action——直接结束占用进程后
/// 自动重试开启，免去用户去 Yomitan 高级设置绕一圈。
void _showFushiApiPortConflictSnackBar(SettingsContext settingsContext) {
  final BuildContext ctx = settingsContext.context;
  if (!ctx.mounted) return;
  final int port = settingsContext.appModel.fushiApiPort;
  ScaffoldMessenger.of(ctx).showSnackBar(
    FushiSnackBar(
      content: Text(fushiApiPortInUseMessage(port)),
      duration: const Duration(seconds: 10),
      action: PortProcessTerminator.isSupported
          ? SnackBarAction(
              label: t.yomitan_port_kill_action,
              onPressed: () =>
                  unawaited(_terminatePortOwnerAndRetry(settingsContext, port)),
            )
          : null,
    ),
  );
}

Future<void> _terminatePortOwnerAndRetry(
  SettingsContext settingsContext,
  int port,
) async {
  final AppModel appModel = settingsContext.appModel;
  // 杀前必须确认：弹窗展示实际占用者（进程名 + PID + 路径；Fushi 旧实例
  // 特别标注），关键系统进程直接拒杀。端口是用户可配置偏好，占用者完全可能
  // 是 IDE 辅助进程/dev server，未经确认一键 taskkill 不可接受。
  final PortKillDecision decision = await decidePortKill(
    settingsContext.context,
    port: port,
  );
  switch (decision.kind) {
    case PortKillDecisionKind.cancelled:
      return;
    case PortKillDecisionKind.refusedProtected:
      _showSnackBar(
        settingsContext,
        t.yomitan_port_kill_protected(
          process: describePortListener(decision.listener!),
        ),
      );
      return;
    case PortKillDecisionKind.listenerChanged:
      // 占用者换人：重走冲突提示，让用户对新占用者重新发起并确认。
      _showFushiApiPortConflictSnackBar(settingsContext);
      return;
    case PortKillDecisionKind.confirmed:
      final PortListenerInfo listener = decision.listener!;
      final bool killed = await PortProcessTerminator.terminate(listener);
      if (!killed) {
        _showSnackBar(
          settingsContext,
          t.yomitan_port_kill_failed(process: describePortListener(listener)),
        );
        return;
      }
    case PortKillDecisionKind.noListener:
      break;
  }
  // 占用进程已结束（或本就已退出）：重试开启。进程退出后 OS 释放端口可能有极短
  // 延迟，端口仍占时再等一拍重试一次，仍失败按端口冲突报出。
  await appModel.setFushiApiServerEnabled(true);
  for (int attempt = 0; ; attempt++) {
    try {
      await appModel.startFushiApiServer();
      break;
    } on SyncServerPortInUseException {
      if (attempt >= 1) {
        _showSnackBar(settingsContext, fushiApiPortInUseMessage(port));
        settingsContext.refresh();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // startFushiApiServer 抛出前把开关复位成 false，重试前需重新置位。
      await appModel.setFushiApiServerEnabled(true);
    }
  }
  _showSnackBar(settingsContext, t.fushi_api_server_started);
  settingsContext.refresh();
}
