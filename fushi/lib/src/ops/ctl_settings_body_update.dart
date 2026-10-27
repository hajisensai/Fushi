import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/updates/app_update_cli.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/utils.dart';

/// 「发现新版本」对话框里的两次点按（下载 / 安装）在控制通道上的条目。
///
/// 检查本身是设置页的 `system.check_update_now`（schema 行，cli 已接
/// [checkAppUpdateForCli]）；这里补上对话框之后的步骤，CLI 侧对应
/// `fushi_cli update download | cancel | install --yes`。
List<CtlBodyPage> buildCtlUpdateBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.settings_destination_system_about} › ${t.section_update}',
    visible: (SettingsContext _) =>
        updaterForCurrentPlatform().supportsInAppInstall,
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'system.update.download',
        title: t.update_download,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async =>
              startAppUpdateDownloadForCli(c.appModel).toJson(),
        ),
      ),
      SettingsActionItem(
        id: 'system.update.cancel',
        title: t.dialog_cancel,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          run: (SettingsContext _, Map<String, String> _) async =>
              cancelAppUpdateDownloadForCli(),
        ),
      ),
      SettingsActionItem(
        id: 'system.update.install',
        title: t.update_installing,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          confirm: true,
          run: (SettingsContext c, Map<String, String> _) async =>
              installAppUpdateForCli(c.appModel).toJson(),
        ),
      ),
    ],
  ),
];
