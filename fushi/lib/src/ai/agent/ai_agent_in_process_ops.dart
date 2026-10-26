import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';

/// 「设置 › 模型 › LLM」提供商列表的落点 id（没指派提供商时引导到这里）。
const String kAiAgentProviderSettingsItem = 'ai.providers';

/// 只在进程内有意义的操作（spec §6.2）：不进 HTTP / CLI（`inProcessOnly`）。
///
/// `ui.ask_choice` 是 agent loop 的元工具，不在这里；这里是需要 app 界面的
/// 导航类操作。
List<FushiOp> buildAiAgentInProcessOps(OpContext context) => <FushiOp>[
  FushiOp(
    id: 'nav.open',
    summary:
        'Open a settings row in the app and highlight it so the user can see or '
        'change it themselves (use for secrets such as API keys, or when the '
        'user asks "where is X"). Key from settings.search.',
    inProcessOnly: true,
    params: const <OpParam>[
      OpParam.string(
        'settingsKey',
        description: 'Settings row key to reveal.',
        required: true,
      ),
    ],
    route: CtlRoute.post('/inproc/nav/open', (CtlCall call) async {
      final String key = call.requireString('settingsKey');
      if (!await openAiAgentSettingsRow(context, key)) {
        throw CtlFailure.notFound('设置项「$key」当前不可见');
      }
      return <String, Object?>{'opened': key};
    }),
  ),
];

/// 打开设置并滚到 / 高亮 [itemId] 所在行（与设置搜索点结果同一条路径）。
/// 当前平台 / 状态下不可见返回 false。
Future<bool> openAiAgentSettingsRow(OpContext context, String itemId) async {
  final NavigatorState? navigator = context.navigator;
  final BuildContext? buildContext = navigator?.context;
  if (navigator == null || buildContext == null || !buildContext.mounted) {
    return false;
  }
  final SettingsContext settings = SettingsContext(
    context: buildContext,
    appModel: context.appModel,
    ref: context.ref,
    readerSource: ReaderFushiSource.instance,
    refresh: () {},
  );
  final List<SettingsSearchEntry> entries = flattenVisibleSettings(
    buildSettingsSchema(settings),
    settings,
  );
  for (final SettingsSearchEntry entry in entries) {
    if (entry.item.id != itemId) continue;
    await context.focusMainWindow();
    openSettingsSearchEntry(navigator, entry);
    return true;
  }
  return false;
}
