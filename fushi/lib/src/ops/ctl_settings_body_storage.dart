import 'package:flutter/widgets.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储」页（`StorageUsageView`，经 `SettingsDestination.body` 逃生口
/// 渲染）在控制通道上的条目。
///
/// - `storage.cli.categories`（`config items … ls`）：各类目占用；
/// - `storage.cli.entries`（`config items … ls|rm`）：全部明细，`rm` 走页面同一条
///   删除分流 [deleteStorageEntry]（书 / 词典 / 快照 / 派生文件），只读明细拒删；
/// - `storage.cli.bundled`（`config items … ls`）：随包组件（只读——更新会被
///   安装器整体重写，没有删除入口，与页面一致）；
/// - `storage.cli.anime4k_delete`（`config run --yes`）：删除 Anime4K 预设文件。
///
/// 取数 / 删除原语与页面共用 [StorageUsageActions]；测试经参数注入。
const String kCtlStorageIdPrefix = 'storage.cli.';

/// 明细 id 的类目分隔符：`<类目>:<条目 id>`（条目 id 可能是带冒号的绝对路径，
/// 只按第一个冒号切）。
const String _kEntryIdSeparator = ':';

List<CtlBodyPage> buildCtlStorageBodyPages({
  StorageUsageService Function()? service,
  StorageUsageActions Function(SettingsContext c)? actions,
}) {
  final StorageUsageService Function() serviceOf =
      service ?? StorageUsageService.new;
  final StorageUsageActions Function(SettingsContext c) actionsOf =
      actions ?? StorageUsageActions.of;

  Future<List<StorageCategoryUsage>> scan(SettingsContext c) =>
      scanAllStorageCategories(serviceOf(), actionsOf(c));

  return <CtlBodyPage>[
    CtlBodyPage(
      breadcrumb: t.settings_destination_storage,
      items: <SettingsItem>[
        SettingsCustomItem(
          id: '${kCtlStorageIdPrefix}categories',
          builder: (SettingsContext _) => const SizedBox.shrink(),
          searchTitle: t.storage_overview_section,
          cliList: SettingsCliList(
            list: (SettingsContext c) async {
              final StorageUsageActions a = actionsOf(c);
              final List<StorageCategoryUsage> usage = await scan(c);
              final int anime4k = await a.anime4kBytesProvider();
              return <Map<String, Object?>>[
                for (final StorageCategoryUsage u in usage)
                  <String, Object?>{
                    'id': u.id.name,
                    'title': storageCategoryTitle(u.id),
                    'bytes': u.bytes,
                    'size': formatStorageBytes(u.bytes),
                    'entries': u.entries.length,
                    'deletableEntries': u.entries
                        .where(isStorageEntryDeletable)
                        .length,
                    if (u.id == StorageCategoryId.shaders)
                      'anime4kBytes': anime4k,
                  },
              ];
            },
          ),
        ),
        SettingsCustomItem(
          id: '${kCtlStorageIdPrefix}entries',
          builder: (SettingsContext _) => const SizedBox.shrink(),
          searchTitle: '${t.storage_overview_section} · entries',
          cliList: SettingsCliList(
            list: (SettingsContext c) async => <Map<String, Object?>>[
              for (final StorageCategoryUsage u in await scan(c))
                for (final StorageEntryUsage e in u.entries)
                  _entryRecord(u.id, e),
            ],
            remove: (SettingsContext c, String id) async {
              final StorageUsageActions a = actionsOf(c);
              final StorageEntryUsage entry = _requireEntry(
                await scanAllStorageCategories(serviceOf(), a),
                id,
              );
              if (!isStorageEntryDeletable(entry)) {
                throw ArgumentError(
                  '「${storageEntryTitle(entry)}」是只读明细（删它会绕过墓碑 / '
                  '引用护栏），不能在这里删除',
                );
              }
              final StorageEntryDeleteOutcome outcome =
                  await deleteStorageEntry(a, entry);
              if (outcome.failure != null) {
                throw StateError(
                  t.storage_entry_delete_failed(reason: outcome.failure!),
                );
              }
            },
          ),
        ),
        SettingsCustomItem(
          id: '${kCtlStorageIdPrefix}bundled',
          builder: (SettingsContext _) => const SizedBox.shrink(),
          searchTitle: t.storage_bundled_section,
          cliList: SettingsCliList(
            list: (SettingsContext c) async => <Map<String, Object?>>[
              for (final BundledComponentUsage b
                  in await serviceOf().scanBundledComponents())
                <String, Object?>{
                  'id': b.name,
                  'bytes': b.bytes,
                  'size': formatStorageBytes(b.bytes),
                  'path': b.path,
                },
            ],
          ),
        ),
        SettingsActionItem(
          id: '${kCtlStorageIdPrefix}anime4k_delete',
          title: t.storage_shaders_delete_anime4k,
          subtitle: t.storage_modules_anime4k_hint,
          destructive: true,
          cli: SettingsCliAction(
            confirm: true,
            run: (SettingsContext c, Map<String, String> _) async {
              final StorageUsageActions a = actionsOf(c);
              final int before = await a.anime4kBytesProvider();
              final List<String> deleted = await a.anime4kDelete();
              return <String, Object?>{
                'deleted': deleted,
                'freedBytes': before,
                'freed': formatStorageBytes(before),
              };
            },
          ),
          // 页面里的删除入口带确认框；控制通道只走 cli.run（confirm=true）。
          onTap: (SettingsContext c) async {
            await actionsOf(c).anime4kDelete();
          },
        ),
      ],
    ),
  ];
}

Map<String, Object?> _entryRecord(
  StorageCategoryId category,
  StorageEntryUsage entry,
) => <String, Object?>{
  'id': '${category.name}$_kEntryIdSeparator${entry.id}',
  'category': category.name,
  'kind': entry.kind.name,
  'label': storageEntryTitle(entry),
  'bytes': entry.bytes,
  'size': formatStorageBytes(entry.bytes),
  'deletable': isStorageEntryDeletable(entry),
  if (entry.externalPaths.isNotEmpty) 'externalPaths': entry.externalPaths,
};

StorageEntryUsage _requireEntry(List<StorageCategoryUsage> usage, String id) {
  final int cut = id.indexOf(_kEntryIdSeparator);
  if (cut <= 0) {
    throw ArgumentError('明细 id 写成 <类目>:<条目 id>（见 ls 的 id 列），收到「$id」');
  }
  final String category = id.substring(0, cut);
  final String entryId = id.substring(cut + 1);
  for (final StorageCategoryUsage u in usage) {
    if (u.id.name != category) continue;
    for (final StorageEntryUsage e in u.entries) {
      if (e.id == entryId) return e;
    }
  }
  throw ArgumentError('没有明细「$id」（可能已被删除，先 ls 重新列出）');
}
