import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_compare_cli.dart';
import 'package:fushi/utils.dart';

/// 「同步差异对比」对话框的「应用」按钮在控制通道上的条目（列出差异是 schema 行
/// `sync.compare` 本身）。实现见 `sync_compare_cli.dart`。
List<CtlBodyPage> buildCtlSyncBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.sync_compare,
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'sync.compare_apply',
        title: t.sync_compare,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          confirm: true,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'keep',
              help:
                  '没点名的书：auto（缺省，同对话框默认：两端已一致的跳过，其余按时间戳取较新的一侧）'
                  '/ local / remote / skip',
              required: false,
            ),
            SettingsCliParam(
              'items',
              help:
                  '逐条选择，JSON：{"<id>":"local|remote|skip"}（id 见 sync compare；'
                  '远端独有的书给 remote = 下载）',
              required: false,
            ),
          ],
          run: (SettingsContext c, Map<String, String> args) =>
              applySyncCompareForCli(
                c.appModel,
                keep: args['keep'],
                itemsJson: args['items'],
              ),
        ),
      ),
    ],
  ),
];
