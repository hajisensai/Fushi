import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_settings_actions.dart';
import 'package:fushi/src/anki/ankiconnect_port_repair.dart'
    show AnkiConnectPortWriteStatus;
import 'package:fushi/src/ops/ctl_settings_body_anki.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';

List<SettingsItem> _allItems() => <SettingsItem>[
  for (final CtlBodyPage page in buildCtlAnkiBodyPages()) ...page.items,
];

String _name(SettingsItem item) => item.id.substring(kCtlAnkiIdPrefix.length);

void main() {
  group('buildCtlAnkiBodyPages 声明的完整性', () {
    test('每页有面包屑与条目；id 全局唯一且都带 card_creation.anki.cli. 前缀', () {
      final List<CtlBodyPage> pages = buildCtlAnkiBodyPages();
      expect(pages, isNotEmpty);
      for (final CtlBodyPage page in pages) {
        expect(page.breadcrumb, isNotEmpty);
        expect(page.items, isNotEmpty, reason: page.breadcrumb);
      }
      final List<String> ids = <String>[
        for (final SettingsItem item in _allItems()) item.id,
      ];
      expect(ids.toSet().length, ids.length, reason: '存在重复 id');
      for (final String id in ids) {
        expect(id, startsWith('card_creation.anki.'));
        expect(id, startsWith(kCtlAnkiIdPrefix));
        expect(id, matches(RegExp(r'^[a-z0-9_.]+$')), reason: id);
      }
    });

    test('不与 schema 现有的 card_creation.* id 重复', () {
      final String schema = File(
        'lib/src/settings/settings_schema_card_creation.dart',
      ).readAsStringSync();
      final Set<String> existing = RegExp(
        r"'(card_creation\.[a-z0-9_.]+)'",
      ).allMatches(schema).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(existing, isNotEmpty);
      for (final SettingsItem item in _allItems()) {
        expect(existing, isNot(contains(item.id)), reason: item.id);
      }
    });

    test('每个 SettingsActionItem 都声明了 cli；破坏性动作要求 confirm', () {
      final List<SettingsActionItem> actions = _allItems()
          .whereType<SettingsActionItem>()
          .toList();
      expect(actions, isNotEmpty);
      for (final SettingsActionItem action in actions) {
        final SettingsCliAction? cli = action.cli;
        expect(cli, isNotNull, reason: action.id);
        expect(
          cli!.run != null || cli.sameAsTap || cli.unsupportedHint != null,
          isTrue,
          reason: action.id,
        );
        if (action.destructive) {
          expect(cli.confirm, isTrue, reason: '${action.id} 是破坏性动作');
        }
      }
    });

    test('会改写 Anki 数据 / 卡片的动作都要 confirm；只读动作不强制', () {
      final Map<String, SettingsActionItem> byName =
          <String, SettingsActionItem>{
            for (final SettingsActionItem a
                in _allItems().whereType<SettingsActionItem>())
              _name(a): a,
          };
      for (final String name in <String>[
        'dedup_run',
        'lapis_restore',
        'lapis_restore_factory',
        'reposition',
        'reposition_undo',
        'video_template_restore',
      ]) {
        expect(byName[name], isNotNull, reason: name);
        expect(byName[name]!.cli!.confirm, isTrue, reason: name);
      }
      for (final String name in <String>[
        'fetch',
        'dedup_scan',
        'reposition_preview',
        'lapis_backup_list',
      ]) {
        expect(byName[name], isNotNull, reason: name);
        expect(byName[name]!.cli!.confirm, isFalse, reason: name);
      }
    });

    test('机密文本 secret:true；动作参数里没有 secret 参数', () {
      final SettingsTextItem apiKey = _allItems()
          .whereType<SettingsTextItem>()
          .singleWhere((SettingsTextItem i) => _name(i) == 'connect_api_key');
      expect(apiKey.secret, isTrue);
      for (final SettingsTextItem item
          in _allItems().whereType<SettingsTextItem>()) {
        if (item.id.contains('api_key') || item.id.contains('password')) {
          expect(item.secret, isTrue, reason: item.id);
        }
      }
      for (final SettingsActionItem action
          in _allItems().whereType<SettingsActionItem>()) {
        for (final SettingsCliParam p
            in action.cli?.params ?? const <SettingsCliParam>[]) {
          expect(p.secret, isFalse, reason: '${action.id}.${p.name}');
        }
      }
    });

    test('自绘行恰好声明 cliValue 或 cliList 之一，并带搜索标题', () {
      final List<SettingsCustomItem> customs = _allItems()
          .whereType<SettingsCustomItem>()
          .toList();
      expect(customs, isNotEmpty);
      for (final SettingsCustomItem item in customs) {
        expect(
          (item.cliValue != null) != (item.cliList != null),
          isTrue,
          reason: item.id,
        );
        expect(item.searchTitle, isNotEmpty, reason: item.id);
      }
    });

    test('页面里用户能做的操作都有对应条目（覆盖清单）', () {
      final Set<String> names = <String>{
        for (final SettingsItem i in _allItems()) _name(i),
      };
      const List<String> expected = <String>[
        'connect_host',
        'connect_port',
        'connect_api_key',
        'connect_port_auto_fix',
        'connect_addon_install',
        'desktop_auto_launch',
        'desktop_executable',
        'desktop_executable_detect',
        'desktop_launch',
        'srs_mining_target',
        'batch_mining',
        'pending_mine_landing',
        'fetch',
        'create_lapis',
        'deck',
        'note_type',
        'reposition',
        'reposition_auto',
        'allow_duplicates',
        'duplicate_scope',
        'overwrite_scope',
        'compact_glossaries',
        'tags',
        'tag_include_hibiki',
        'tag_include_category',
        'tag_book_name',
        'tag_char_position',
        'lapis_font_scale',
        'lapis_apply',
        'lapis_backup',
        'lapis_restore',
        'lapis_restore_factory',
        'dedup_auto',
        'dedup_auto_delete',
        'dedup_scan',
        'dedup_run',
        'mining_image_quality',
        'mining_audio_quality',
        'mining_audio_head_pad',
        'mining_audio_tail_pad',
        'mining_audio_follow_playback_speed',
        'video_mining_image_mode',
        'video_mining_clip_format',
        'video_mining_animated_format',
        'video_mining_still_format',
        'video_online_mining_mode',
        'gal_mining_image_mode',
        'gal_mining_clip_format',
        'gal_mining_animated_format',
        'gal_mining_still_format',
        'field_mappings',
        'video_template_apply',
      ];
      for (final String name in expected) {
        expect(names, contains(name));
      }
    });
  });

  group('Lapis 自定义区域 JSON', () {
    const String valid =
        '[{"id":"b1","anchor":"top","fields":["Sentence","Picture"]}]';

    test('解析后再编码保持语义不变', () {
      final List<LapisCustomBlock> blocks = parseCtlLapisBlocks(valid);
      expect(blocks, hasLength(1));
      expect(blocks.single.id, 'b1');
      expect(blocks.single.anchor, LapisBlockAnchor.top);
      expect(blocks.single.fields, <String>['Sentence', 'Picture']);
      expect(
        parseCtlLapisBlocks(encodeCtlLapisBlocks(blocks)).single.fields,
        blocks.single.fields,
      );
    });

    test('空串 = 清空全部区域', () {
      expect(parseCtlLapisBlocks('  '), isEmpty);
      expect(parseCtlLapisBlocks('[]'), isEmpty);
    });

    test('不合法输入整体拒绝，不静默丢弃', () {
      expect(() => parseCtlLapisBlocks('{}'), throwsFormatException);
      expect(() => parseCtlLapisBlocks('not json'), throwsFormatException);
      expect(
        () => parseCtlLapisBlocks('[{"id":"B 1","anchor":"top","fields":[]}]'),
        throwsFormatException,
      );
      expect(
        () =>
            parseCtlLapisBlocks('[{"id":"b1","anchor":"nowhere","fields":[]}]'),
        throwsFormatException,
      );
      expect(
        () => parseCtlLapisBlocks(
          '[{"id":"b1","anchor":"top","fields":[]},'
          '{"id":"b1","anchor":"bottom","fields":[]}]',
        ),
        throwsFormatException,
      );
    });
  });

  group('字段映射记录', () {
    const AnkiNoteType noteType = AnkiNoteType(
      id: 7,
      name: 'Lapis',
      fields: <String>['Expression', 'Sentence'],
    );
    final AnkiSettings settings = const AnkiSettings().copyWith(
      selectedNoteTypeId: 7,
      selectedNoteTypeName: 'Lapis',
      availableNoteTypes: const <AnkiNoteType>[noteType],
      fieldMappings: const <String, String>{'Expression': '{expression}'},
    );

    test('每个字段一条，未映射的 mapping 为空串', () {
      expect(ankiFieldMappingRecords(settings), <Map<String, Object?>>[
        <String, Object?>{'id': 'Expression', 'mapping': '{expression}'},
        <String, Object?>{'id': 'Sentence', 'mapping': ''},
      ]);
    });

    test('没选笔记类型时为空', () {
      expect(ankiFieldMappingRecords(const AnkiSettings()), isEmpty);
    });
  });

  group('与页面共用的文案映射', () {
    test('端口修复：没找到空闲端口 / 写入成功 / 插件配置缺失', () {
      expect(
        ankiPortRepairMessage(const AnkiPortRepairOutcome()),
        t.anki_connect_port_auto_fix_none,
      );
      expect(
        ankiPortRepairMessage(
          const AnkiPortRepairOutcome(
            port: 8800,
            status: AnkiConnectPortWriteStatus.updated,
          ),
        ),
        t.anki_connect_port_auto_fix_done(port: 8800),
      );
      expect(
        ankiPortRepairMessage(
          const AnkiPortRepairOutcome(
            port: 8800,
            status: AnkiConnectPortWriteStatus.addonNotFound,
          ),
        ),
        t.anki_connect_port_auto_fix_manual(port: 8800),
      );
    });

    test('启动 Anki 与代装插件的每个状态都有文案', () {
      for (final AnkiDesktopLaunchStatus status
          in AnkiDesktopLaunchStatus.values) {
        expect(
          ankiLaunchMessage(AnkiDesktopLaunchResult(status, detail: 'x')),
          isNotEmpty,
          reason: status.name,
        );
      }
      for (final AnkiAddonInstallStatus status
          in AnkiAddonInstallStatus.values) {
        expect(
          ankiAddonInstallMessage(AnkiAddonInstallResult(status, detail: 'x')),
          isNotEmpty,
          reason: status.name,
        );
      }
    });

    test('Lapis 备份：Anki 里没有 Lapis 时给「找不到」', () {
      expect(lapisBackupMessage(null), t.anki_lapis_not_found);
    });
  });
}
