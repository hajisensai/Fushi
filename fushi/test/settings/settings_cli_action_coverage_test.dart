import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_cli_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';

import '../helpers/test_platform_services.dart';

/// 控制通道（`fushi_cli config run`）只走动作声明的 [SettingsActionItem.cli]，
/// 不再去调可能弹确认框 / 选择器的 onTap。于是「新加一个动作却忘了声明 cli」在
/// CLI 上表现为「只能在设置页里点」——静默的覆盖缺口。本守卫遍历整棵 schema
/// （含子页）与逃生口页面条目，要求每个动作都显式声明怎么在 CLI 上执行。
void main() {
  late SettingsContext settings;

  Future<void> captureContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              settings = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  List<SettingsItem> allItems() {
    final List<SettingsItem> items = <SettingsItem>[];
    void walk(SettingsDestination page, int depth) {
      for (final SettingsSection section in page.sections) {
        for (final SettingsItem item in section.items) {
          items.add(item);
          if (item is SettingsNavigationItem &&
              item.child != null &&
              depth < 3) {
            walk(item.child!(), depth + 1);
          }
        }
      }
    }

    for (final SettingsDestination destination in buildSettingsSchema(
      settings,
    )) {
      walk(destination, 0);
    }
    for (final CtlBodyPage page in buildCtlBodyPages()) {
      items.addAll(page.items);
    }
    return items;
  }

  testWidgets('每个动作行都声明了控制通道入口', (WidgetTester tester) async {
    await captureContext(tester);
    final List<SettingsActionItem> actions = allItems()
        .whereType<SettingsActionItem>()
        .toList();
    expect(actions.length, greaterThan(20), reason: '遍历没走到 schema');
    final List<String> missing = <String>[
      for (final SettingsActionItem action in actions)
        if (action.cli == null) action.id,
    ];
    expect(missing, isEmpty, reason: '这些动作没有 cli：$missing');
    for (final SettingsActionItem action in actions) {
      final SettingsCliAction cli = action.cli!;
      final int modes =
          (cli.run != null ? 1 : 0) +
          (cli.sameAsTap ? 1 : 0) +
          (cli.unsupportedHint != null ? 1 : 0);
      expect(modes, 1, reason: '${action.id} 的 cli 必须恰好是三种之一');
      if (cli.unsupportedHint != null) {
        expect(cli.unsupportedHint, isNotEmpty, reason: action.id);
      }
      final Set<String> names = <String>{};
      for (final SettingsCliParam param in cli.params) {
        expect(names.add(param.name), isTrue, reason: '${action.id} 参数重名');
      }
    }
  });

  testWidgets('点名要求可经 CLI 读写的自绘行都声明了 cliValue / cliList', (
    WidgetTester tester,
  ) async {
    await captureContext(tester);
    final Map<String, SettingsCustomItem> custom = <String, SettingsCustomItem>{
      for (final SettingsCustomItem item
          in allItems().whereType<SettingsCustomItem>())
        item.id: item,
    };
    const List<String> valueRows = <String>[
      'video.player.subtitle_text_color',
      'video.player.subtitle_shadow_color',
      'video.player.subtitle_outline_color',
      'video.player.subtitle_bg_color',
      'video.player.mpv_raw',
      'video.player.danmaku_block_rules',
      'video.player.controls_editor',
      'reading_controls.controls_editor',
      'manga.controls_editor',
      'game.gal_hook_text_color',
      'listening.floating_lyric_color_text',
    ];
    const List<String> listRows = <String>[
      'video.player.mpv_lua_scripts_list',
      'video.player.shaders',
      'ai.web_knowledge.custom',
      'services.media_server.jellyfin',
      'services.media_server.plex',
    ];
    for (final String id in valueRows) {
      expect(custom[id]?.cliValue, isNotNull, reason: '$id 缺 cliValue');
    }
    for (final String id in listRows) {
      expect(custom[id]?.cliList, isNotNull, reason: '$id 缺 cliList');
    }
  });

  test('颜色写法：#RRGGBB 补不透明、#AARRGGBB 原样、坏写法抛 FormatException', () {
    expect(parseSettingsCliColor('#112233'), 0xFF112233);
    expect(parseSettingsCliColor('#80112233'), 0x80112233);
    expect(parseSettingsCliColor('0xff000000'), 0xFF000000);
    expect(() => parseSettingsCliColor('red'), throwsFormatException);
    expect(() => parseSettingsCliColor('#12345'), throwsFormatException);
    expect(formatSettingsCliColor(0x80112233), '#80112233');
  });
}
