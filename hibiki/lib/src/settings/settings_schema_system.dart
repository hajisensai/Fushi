import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_fields.dart';
import 'package:hibiki/src/utils/misc/crash_dump_locator.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

SettingsDestination buildSystemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.settings_destination_system,
    summary: t.section_update,
    icon: Icons.settings_suggest_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_update,
        // 更新分区在所有平台可见（至少能「检查→打开发布页」）；自动安装开关
        // 仅在支持应用内安装的平台显示（platformSupportsInAppInstall，见
        // platform_updater.dart 单一真相源）。
        visible: (_) => platformSupportsUpdateCheck(),
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'system.update_channel',
            title: t.settings_section_update_channel,
            icon: Icons.system_update_alt_outlined,
            controlBelow: true,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'stable',
                label: t.update_channel_stable,
                icon: Icons.verified_outlined,
                tooltip: t.update_channel_stable,
              ),
              SettingsSegmentOption<String>(
                value: 'beta',
                label: t.update_channel_beta,
                icon: Icons.science_outlined,
                tooltip: t.update_channel_beta,
              ),
              SettingsSegmentOption<String>(
                value: 'debug',
                label: t.update_channel_debug,
                icon: Icons.bug_report_outlined,
                tooltip: t.update_channel_debug,
              ),
            ],
            selected: _selectedUpdateChannel,
            onChanged: setUpdateChannel,
          ),
          // TODO-898：手动「立即检查更新」。分区已被 platformSupportsUpdateCheck()
          // 网关，按钮全平台可见（不能自装的平台仍可「检查→打开发布页」）。
          SettingsActionItem(
            id: 'system.check_update_now',
            title: t.settings_check_update_now,
            icon: Icons.system_update_outlined,
            onTap: _checkUpdateNow,
          ),
          SettingsSwitchItem(
            id: 'system.update_never_remind',
            title: t.update_never_remind,
            icon: Icons.notifications_off_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateNeverRemind,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateNeverRemind(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_auto_install',
            title: t.update_auto_install,
            icon: Icons.download_done_outlined,
            visible: (_) => platformSupportsInAppInstall(),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateAutoInstall,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateAutoInstall(value);
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'system.update_custom_proxy',
            icon: Icons.dns_outlined,
            builder: _buildUpdateCustomProxyField,
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_system,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.language',
            icon: Icons.translate_outlined,
            builder: buildLanguageSelector,
          ),
          SettingsCustomItem(
            id: 'system.app_version',
            icon: Icons.info_outline,
            builder: _buildRuntimeAppVersionRow,
          ),
          SettingsSwitchItem(
            id: 'system.low_memory_mode',
            title: t.low_memory_mode,
            subtitle: t.low_memory_mode_hint,
            icon: Icons.memory_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.lowMemoryMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setLowMemoryMode(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.focus_navigation',
            title: t.focus_navigation_enabled,
            subtitle: t.focus_navigation_enabled_hint +
                t.settings_experimental_suffix,
            icon: Icons.gamepad_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.experimentalFocusNavigationEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setExperimentalFocusNavigationEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'system.keyboard_shortcuts',
            title: t.shortcut_settings_title,
            subtitle: t.settings_experimental_suffix,
            icon: Icons.keyboard_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const ShortcutSettingsPage(),
              );
            },
          ),
          SettingsActionItem(
            id: 'system.github',
            title: t.options_github,
            icon: Icons.public_outlined,
            onTap: (_) async {
              await launchUrl(
                Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_diagnostics,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title:
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.report_problem_outlined,
            builder: (_) => const ErrorLogPage(),
          ),
          // TODO-607 P0-3：崩溃转储（native minidump）。仅 Windows 显示——native
          // 端只在 Windows runner 经 SetUnhandledExceptionFilter 写 .dmp，移动端无此
          // 机制（仿 wgc_capture_log 的 isWindows 门控）。让纯 native 闪退（嵌套查词
          // 把进程带崩等，错误日志里看不到）有可上传的二进制证据。
          SettingsNavigationItem(
            id: 'diagnostics.crash_dumps',
            title: t.crash_dump_label(
              n: CrashDumpLocator.listCurrentPlatformDumps().length,
            ),
            icon: Icons.bug_report_outlined,
            visible: (_) => Platform.isWindows,
            builder: (_) => const CrashDumpPage(),
          ),
          SettingsSwitchItem(
            id: 'diagnostics.debug_log_enabled',
            title: t.debug_log_toggle,
            icon: Icons.rule_outlined,
            value: (_) => DebugLogService.instance.enabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await DebugLogService.instance.setEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'diagnostics.debug_log',
            title: t.debug_log_title(
              count: DebugLogService.instance.entries.length,
            ),
            icon: Icons.terminal_outlined,
            visible: (_) =>
                DebugLogService.instance.enabled ||
                DebugLogService.instance.entries.isNotEmpty,
            builder: (_) => const DebugLogPage(),
          ),
        ],
      ),
    ],
  );
}

/// TODO-898：手动「立即检查更新」防连点旗标（模块级）。UI 重入保护真正靠它——
/// UpdateChecker 内部的 `_activeCheckCancellation` 是「中断」语义、不挡重入。
bool _manualCheckInFlight = false;

/// 手动「立即检查更新」编排（TODO-898）。
///
/// 手动语义：`neverRemind: false`（无视用户「免提醒」偏好，主动点就要看到结果）+
/// `autoInstall: false`（发现新版只弹确认对话框，不沿用自动安装偏好静默装）。
/// 三种反馈走 toast：点击即时「检查中」、已是最新、检查失败；发现新版复用
/// UpdateChecker 既有对话框/打开发布页（零改动）。
Future<void> _checkUpdateNow(SettingsContext settingsContext) async {
  if (_manualCheckInFlight) return;
  _manualCheckInFlight = true;
  HibikiToast.show(msg: t.update_checking_now);
  try {
    await UpdateChecker.scheduleCheck(
      settingsContext.context,
      settingsContext.appModel.packageInfo.version,
      neverRemind: false,
      autoInstall: false,
      betaChannel: settingsContext.appModel.updateBetaChannel,
      debugChannel: settingsContext.appModel.updateDebugChannel,
      customProxy: settingsContext.appModel.updateCustomProxy,
      onUpToDate: () => HibikiToast.show(msg: t.update_already_latest),
      onError: (Object _) => HibikiToast.show(msg: t.update_check_failed),
    );
  } finally {
    _manualCheckInFlight = false;
  }
}

/// 「自定义更新代理」输入框（TODO-871/862）：fake-ip/TUN 模式下系统代理写注册表、
/// Dart HttpClient 读不到时的兜底入口。空串=清除（合法）；非空但格式非法时弹 SnackBar
/// 提示并仍存原串——运行时纯函数 [normalizeUserProxyHostPort] 兜底忽略非法值、不阻断检查。
Widget _buildUpdateCustomProxyField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.update_custom_proxy_label,
    hintText: t.update_custom_proxy_hint,
    icon: Icons.dns_outlined,
    initialValue: settingsContext.appModel.updateCustomProxy,
    keyboardType: TextInputType.url,
    onChanged: (String value) async {
      final String trimmed = value.trim();
      await settingsContext.appModel.setUpdateCustomProxy(trimmed);
      // 非空且无法归一成合法 host:port → 提示（仍保存原串，运行时忽略）。
      if (trimmed.isNotEmpty && normalizeUserProxyHostPort(trimmed) == null) {
        final BuildContext ctx = settingsContext.context;
        if (!ctx.mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(t.update_custom_proxy_invalid)),
        );
      }
    },
  );
}

String _selectedUpdateChannel(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return 'debug';
  if (settingsContext.appModel.updateBetaChannel) return 'beta';
  return 'stable';
}

Widget _buildRuntimeAppVersionRow(SettingsContext settingsContext) {
  final packageInfo = settingsContext.appModel.packageInfo;
  return AdaptiveSettingsRow(
    title: t.app_version,
    subtitle: formatAppVersionDisplay(packageInfo),
    icon: Icons.info_outline,
    showIcon: true,
  );
}

/// 版本展示文案。versionName 是 semver（含 `-debug.5613` 等预发布段），
/// buildNumber 是 Android versionCode（如 `1000561300`），两者语义不同：
/// 绝不能用 semver 的 `+` build-metadata 把 versionCode 拼进 versionName，
/// 否则会渲染出畸形的 `0.11.1-debug.5613+1000561300`。用括号并列展示。
@visibleForTesting
String formatAppVersionDisplay(PackageInfo packageInfo) =>
    '${packageInfo.version} (${packageInfo.buildNumber})';
