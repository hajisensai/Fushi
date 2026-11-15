import 'package:fushi/src/utils/fushi_icons.dart';

import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/settings/database_check_action.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:fushi/i18n/strings.g.dart';

/// 「存储」一级设置分类：数据存储位置（数据根在哪）+ 数据库维护（检查数据库）+
/// 磁盘占用总览（每个类目都可展开明细，书/词典可单条删除）+ 随包组件展示。模型的选择与下载在
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
    sections: <SettingsSection>[
      buildDataStorageLocationSection(),
      // 反馈 s2fdTTmLyh：类 Anki「Check Database」——integrity_check + 已知坏数据
      // 修复 + VACUUM，动手前整库备份、失败回滚，全部在 drift 后台 isolate 跑
      // （见 fushi_core database_check.dart）。
      SettingsSection(
        id: 'storage.maintenance',
        title: t.storage_db_check_section,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'storage.db_check',
            title: t.storage_db_check_title,
            subtitle: t.storage_db_check_summary,
            icon: FushiIcons.verified,
            cli: SettingsCliAction(
              confirm: true,
              run: (SettingsContext c, Map<String, String> _) =>
                  checkDatabaseForCli(c),
            ),
            onTap: checkDatabaseFromSettings,
          ),
        ],
      ),
    ],
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
      // 反馈 jg3XoDVISk：搜「清除缓存」直达存储页（行本身在磁盘占用分组首行）。
      SettingsBodySearchEntry(
        id: 'storage.clear_cache',
        title: t.storage_clear_cache_action,
        subtitle: t.storage_category_cache,
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
