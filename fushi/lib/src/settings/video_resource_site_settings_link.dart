/// 「添加 BT 来源」引导的**唯一**跳转目标。
///
/// 发现作品详情页的 BT 渠道没有任何适用当前作品的已启用来源时给出「添加 BT 来源」
/// 按钮，落点只在这里写一次（[kVideoResourceSiteSettingsItemId]），调用方不动。
/// 落到「在线服务」里的 BT 站设置页（用户自填站点；Torznab 在同一节的相邻条目里）。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';

/// BT 来源设置页在「在线服务」schema 里的条目 id。
const String kVideoResourceSiteSettingsItemId = 'services.bt_sites';

/// 推出 BT 来源设置页。按 id 在「在线服务」schema 里找那一行的子页（与设置页
/// 里点那一行同一份 [SettingsDestination]，不另拼一份）；找不到（id 改了却没同步
/// 这里）就退回整个「在线服务」分类，至少落在能找到它的地方。
Future<void> openVideoResourceSiteSettings(BuildContext context) async {
  final SettingsDestination services = buildServicesDestination();
  SettingsDestination Function()? child;
  for (final SettingsSection section in services.sections) {
    for (final SettingsItem item in section.items) {
      if (item is SettingsNavigationItem &&
          item.id == kVideoResourceSiteSettingsItemId) {
        child = item.child;
      }
    }
  }
  final SettingsDestination Function()? target = child;
  await Navigator.of(context, rootNavigator: true).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => target == null
          ? SettingsDetailPage(destination: services)
          : SettingsDetailPage.subPage(target),
    ),
  );
}
