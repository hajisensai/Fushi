import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/bt_site_settings_section.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「设置 › 在线服务 › BT 站」页的目的地：正文就是 [BtSiteSettingsSection]。
/// 设置树（`services.bt_sites`）与下面的跳转入口共用这一份。
SettingsDestination buildBtSiteSettingsDestination() => SettingsDestination(
  id: SettingsDestinationId.services,
  title: t.bt_site_section_title,
  icon: FushiIcons.cloud,
  sections: const <SettingsSection>[],
  body: (SettingsContext c) => const BtSiteSettingsSection(),
);

/// 推一页独立的 BT 站设置，返回即回到原入口（同 `pushAiSettingsPage`）。
///
/// 「没有 BT 来源」的各处引导（资源搜索空态、订阅暂停、番剧下载对话框）都经
/// 这一处跳过去；用户加完站点返回，`AppModel.setBtSites` 已重建流水线并唤醒
/// 暂停的订阅。
Future<void> pushBtSiteSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => Scaffold(
        body: SafeArea(
          child: ModuleSettingsView.route(
            destinationId: SettingsDestinationId.services,
            destination: buildBtSiteSettingsDestination,
            title: t.bt_site_section_title,
          ),
        ),
      ),
    ),
  );
}
