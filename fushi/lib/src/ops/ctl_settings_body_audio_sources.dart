import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/audio_sources_cli.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 「管理音频来源」对话框（设置项 `lookup.audio_sources`）在控制通道上的条目：
/// 来源列表的增删改 / 启停 / 排序、重置、本地库子来源。实现见 `audio_sources_cli.dart`。
List<CtlBodyPage> buildCtlAudioSourcesBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.manage_audio_sources,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'lookup.audio_sources.items',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.manage_audio_sources,
        cliList: audioSourcesCliList,
      ),
      SettingsActionItem(
        id: 'lookup.audio_sources.reset',
        title: t.manage_audio_sources,
        destructive: true,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          confirm: true,
          run: (SettingsContext c, Map<String, String> _) async =>
              <String, Object?>{
                'sources': await resetAudioSourcesForCli(c.appModel),
              },
        ),
      ),
      SettingsActionItem(
        id: 'lookup.audio_sources.local_sources',
        title: t.manage_audio_sources,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'path',
              help: '本地音频库路径（items ls 里 local 行的 path 原样给）',
            ),
            SettingsCliParam(
              'value',
              help: '子来源顺序与启停：name1,!name2,…（! = 停用）；省略 = 只查询',
              required: false,
            ),
          ],
          run: (SettingsContext c, Map<String, String> args) =>
              localAudioSubSourcesForCli(
                c.appModel,
                path: args['path']!,
                spec: args['value'],
              ),
        ),
      ),
    ],
  ),
];
