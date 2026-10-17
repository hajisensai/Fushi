import 'package:fushi/src/utils/fushi_icons.dart';

import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:fushi/utils.dart';

/// 「存储」一级设置分类：数据存储位置（数据根在哪）+ 磁盘占用总览（每个类目
/// 都可展开明细，书/词典可单条删除）+ 随包组件展示。模型的选择与下载在
/// 「设置 › 模型」（2026-10-13 从这里迁出）。
///
/// 「数据存储位置」回答「数据放哪」，模型与组件管理全局资源，与下面「占了多少」放在
/// 一起才成一页；item id 仍是 'sync.data_storage_location'，构建函数留在
/// sync_settings_schema（行 widget 是该库私有 part）。
///
/// 正文经 [SettingsDestination.body] 逃生口渲染 [StorageUsageView]；取数与所有
/// 删除接线在 [StorageUsageActions]（书 `ReaderFushiSource.deleteBook`、词典
/// `AppModel.deleteDictionary`…，控制通道 `storage.cli.*` 共用同一份），widget
/// 自身零裸磁盘删除。
SettingsDestination buildStorageDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.storage,
    title: t.settings_destination_storage,
    summary: t.settings_destination_storage_summary,
    icon: FushiIcons.sdStorage,
    sections: <SettingsSection>[buildDataStorageLocationSection()],
    // 原语逐个透传收口在 [StorageUsageView.fromActions]，这里不再手写逐参转发
    // （曾漏传 videosProvider / deleteVideo，视频明细在设置页里退回空列表）。
    body: (SettingsContext c) => StorageUsageView.fromActions(
      service: StorageUsageService(),
      actions: StorageUsageActions.of(c),
    ),
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'storage.overview',
        title: t.storage_overview_section,
        subtitle: t.storage_overview_total,
      ),
      SettingsBodySearchEntry(
        id: 'storage.shaders',
        title: t.storage_category_shaders,
        subtitle:
            '${t.storage_modules_anime4k_title} · '
            '${t.storage_shaders_delete_anime4k}',
      ),
      SettingsBodySearchEntry(
        id: 'storage.bundled',
        title: t.storage_bundled_section,
        subtitle: t.storage_bundled_hint,
      ),
    ],
  );
}
