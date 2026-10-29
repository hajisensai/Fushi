import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';
import 'package:fushi/src/anki/anki_settings_actions.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankiconnect_port_repair.dart'
    show AnkiConnectPortWriteStatus;
import 'package:fushi/src/anki/lapis_style_editor_page.dart'
    show LapisVisualEditorResult, applyLapisVisualEditorResult;
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi/src/mining/video_online_mining_mode.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FrequencyAggregate;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show
        MiningAnimatedFormat,
        MiningClipFormat,
        MiningStillFormat,
        VideoMiningImageMode;
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart'
    show kMiningPadMaxMs;

/// Anki 设置页（`SettingsDestination.body` 逃生口，正文自绘 widget）在控制通道上的条目。
///
/// 页面里用户能做的操作逐个声明成 schema item：值类走 [SettingsSwitchItem] /
/// [SettingsSegmentedItem] / [SettingsTextItem] 等，读写的是页面同一个 [AnkiViewModel] /
/// `AppModel` setter；动作类走 [SettingsActionItem] + [SettingsCliAction]，业务取自
/// `anki_settings_actions.dart` 里与页面共用的顶层函数，或页面同一个服务方法
/// （`LapisTemplateService` / `AnkiMediaDedupRunner` / `AnkiDeckRepositionRunner` /
/// `AnkiVideoTemplateService`）。弹窗里收集的值改成参数传入；破坏性动作 `confirm: true`。
///
/// id 统一前缀 [kCtlAnkiIdPrefix]（`card_creation.anki.cli.`）：schema 里已有的
/// `card_creation.anki.*` 是设置搜索的 reveal 目标，不能重复。
const String kCtlAnkiIdPrefix = 'card_creation.anki.cli.';

String _id(String name) => '$kCtlAnkiIdPrefix$name';

String _crumb(String leaf) =>
    '${t.settings_destination_card_creation} › Anki › $leaf';

AnkiViewModel _vm(SettingsContext c) =>
    c.ref.read(ankiViewModelProvider.notifier);

AnkiSettings _cfg(SettingsContext c) =>
    c.ref.read(ankiViewModelProvider).settings;

bool _isDesktop() => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 全部 Anki 设置页条目，按页面面板分页。
List<CtlBodyPage> buildCtlAnkiBodyPages() => <CtlBodyPage>[
  _overviewPage(),
  _connectionPage(),
  _deckPage(),
  _tagsPage(),
  _lapisPage(),
  _mediaPage(),
  _maintenancePage(),
  _fieldsPage(),
];

// ── 页面 ────────────────────────────────────────────────────────────────────

CtlBodyPage _overviewPage() => CtlBodyPage(
  breadcrumb: _crumb('Anki'),
  items: <SettingsItem>[
    _action(
      id: 'fetch',
      title: t.anki_fetch,
      subtitle: t.anki_refresh_hint,
      cli: SettingsCliAction(run: _fetchConfiguration),
    ),
    _action(
      id: 'create_lapis',
      title: t.anki_create_lapis,
      subtitle: t.anki_create_lapis_hint,
      cli: SettingsCliAction(run: _createLapis),
    ),
    SettingsSwitchItem(
      id: _id('batch_mining'),
      title: t.anki_batch_mining_title,
      subtitle: t.anki_batch_mining_hint,
      value: (SettingsContext c) => _cfg(c).batchMiningEnabled,
      onChanged: (SettingsContext c, bool v) => _vm(c).setBatchMiningEnabled(v),
    ),
    SettingsSwitchItem(
      id: _id('queue_undelivered_mines'),
      title: t.anki_queue_undelivered_mines_title,
      subtitle: t.anki_queue_undelivered_mines_hint,
      value: (SettingsContext c) => _cfg(c).queueUndeliveredMinesEnabled,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).setQueueUndeliveredMinesEnabled(v),
    ),
    _action(
      id: 'pending_mine_landing',
      title: t.anki_pending_mine_landing_title,
      subtitle: t.anki_pending_mine_landing_hint,
      cli: SettingsCliAction(
        run: _pendingMineLanding,
        params: <SettingsCliParam>[
          SettingsCliParam(
            'enabled',
            help: 'true/false；省略 = 只查询当前状态',
            required: false,
          ),
        ],
      ),
    ),
    _action(
      id: 'pending_mines',
      title: t.anki_pending_mines_title,
      subtitle: t.anki_pending_mines_hint,
      cli: const SettingsCliAction.unsupported(
        '待发制卡队列用 `fushi_cli anki pending` 系列命令查看 / 发送 / 重试 / 删除',
      ),
    ),
    _choice<SrsMiningTarget>(
      id: 'srs_mining_target',
      title: t.srs_mining_target_title,
      subtitle: t.srs_mining_target_hint,
      options: <SettingsSegmentOption<SrsMiningTarget>>[
        SettingsSegmentOption<SrsMiningTarget>(
          value: SrsMiningTarget.anki,
          label: t.srs_mining_target_anki,
        ),
        SettingsSegmentOption<SrsMiningTarget>(
          value: SrsMiningTarget.srs,
          label: t.srs_mining_target_srs,
        ),
      ],
      selected: (SettingsContext c) => c.appModel.srsMiningTarget,
      onChanged: (SettingsContext c, SrsMiningTarget v) =>
          c.appModel.setSrsMiningTarget(v),
      // 复习模块（默认关）开着时才出现，与页面一致。
      visible: (SettingsContext c) => c.ref.read(srsModuleEnabledProvider),
    ),
  ],
);

CtlBodyPage _connectionPage() => CtlBodyPage(
  breadcrumb: _crumb('AnkiConnect'),
  items: <SettingsItem>[
    SettingsTextItem(
      id: _id('connect_host'),
      title: t.anki_connect_host,
      placeholder: 'localhost',
      value: (SettingsContext c) => _cfg(c).ankiConnectHost,
      onChanged: (SettingsContext c, String v) =>
          _vm(c).updateAnkiConnectHost(v),
    ),
    SettingsNumberItem(
      id: _id('connect_port'),
      title: t.anki_connect_port,
      integer: true,
      min: 1,
      max: 65535,
      value: (SettingsContext c) => _cfg(c).ankiConnectPort,
      onChanged: (SettingsContext c, num v) =>
          _vm(c).updateAnkiConnectPort('${v.toInt()}'),
    ),
    SettingsTextItem(
      id: _id('connect_api_key'),
      title: t.anki_connect_api_key,
      subtitle: t.anki_connect_api_key_hint,
      secret: true,
      value: (SettingsContext c) => _cfg(c).ankiConnectApiKey,
      onChanged: (SettingsContext c, String v) =>
          _vm(c).updateAnkiConnectApiKey(v),
    ),
    _action(
      id: 'connect_port_auto_fix',
      title: t.anki_connect_port_auto_fix,
      subtitle: t.anki_connect_port_auto_fix_hint,
      visible: (SettingsContext _) => _isDesktop(),
      cli: SettingsCliAction(run: _repairPort),
    ),
    _action(
      id: 'connect_addon_install',
      title: t.anki_connect_addon_install,
      subtitle: t.anki_connect_addon_install_hint,
      visible: (SettingsContext _) => Platform.isWindows,
      cli: SettingsCliAction(run: _installAddon),
    ),
    SettingsSwitchItem(
      id: _id('desktop_auto_launch'),
      title: t.anki_desktop_auto_launch,
      subtitle: t.anki_desktop_auto_launch_hint,
      visible: (SettingsContext _) => AnkiDesktopLauncher.isSupported,
      value: (SettingsContext c) => _cfg(c).autoLaunchAnkiDesktop,
      onChanged: (SettingsContext c, bool v) =>
          applyAutoLaunchAnkiDesktop(_vm(c), _cfg(c), v),
    ),
    SettingsTextItem(
      id: _id('desktop_executable'),
      title: t.anki_desktop_executable,
      subtitle: t.anki_desktop_executable_unset_default,
      placeholder: '',
      visible: (SettingsContext _) => AnkiDesktopLauncher.isSupported,
      value: (SettingsContext c) => _cfg(c).ankiDesktopExecutable,
      onChanged: (SettingsContext c, String v) =>
          _vm(c).setAnkiDesktopExecutable(v),
    ),
    _action(
      id: 'desktop_executable_detect',
      title: t.anki_desktop_executable_detect,
      visible: (SettingsContext _) =>
          AnkiDesktopLauncher.isSupported && Platform.isWindows,
      cli: SettingsCliAction(run: _detectExecutable),
    ),
    _action(
      id: 'desktop_launch',
      title: t.anki_desktop_launch,
      visible: (SettingsContext _) => AnkiDesktopLauncher.isSupported,
      cli: SettingsCliAction(run: _launchDesktop),
    ),
  ],
);

CtlBodyPage _deckPage() => CtlBodyPage(
  breadcrumb: _crumb(t.anki_deck),
  visible: (SettingsContext c) =>
      c.ref.read(ankiViewModelProvider).isConfigured,
  items: <SettingsItem>[
    _namedPick(
      id: 'deck',
      title: t.anki_deck,
      help: '牌组名（先用 fetch 刷新牌组列表）',
      names: (SettingsContext c) => <String>[
        for (final AnkiDeck d in _cfg(c).availableDecks) d.name,
      ],
      current: (SettingsContext c) => _cfg(c).selectedDeckName ?? '',
      write: (SettingsContext c, String name) {
        final AnkiDeck deck = _cfg(c).availableDecks.firstWhere(
          (AnkiDeck d) => d.name == name,
          orElse: () => throw ArgumentError(
            '没有牌组「$name」；可选：'
            '${_cfg(c).availableDecks.map((AnkiDeck d) => d.name).join(' | ')}',
          ),
        );
        return _vm(c).selectDeck(deck);
      },
    ),
    _namedPick(
      id: 'note_type',
      title: t.anki_note_type,
      help: '笔记类型名（先用 fetch 刷新列表）；换笔记类型会重置字段映射',
      names: (SettingsContext c) => <String>[
        for (final AnkiNoteType n in _cfg(c).availableNoteTypes) n.name,
      ],
      current: (SettingsContext c) => _cfg(c).selectedNoteTypeName ?? '',
      write: (SettingsContext c, String name) {
        final AnkiNoteType type = _cfg(c).availableNoteTypes.firstWhere(
          (AnkiNoteType n) => n.name == name,
          orElse: () => throw ArgumentError(
            '没有笔记类型「$name」；可选：'
            '${_cfg(c).availableNoteTypes.map((AnkiNoteType n) => n.name).join(' | ')}',
          ),
        );
        return _vm(c).selectNoteType(type);
      },
    ),
    _action(
      id: 'reposition_preview',
      title: '${t.anki_reposition_title} · ${t.anki_reposition_preview}',
      subtitle: t.anki_reposition_hint,
      visible: (SettingsContext c) => _vm(c).supportsDeckReposition,
      cli: SettingsCliAction(
        run: _repositionPreview,
        params: _repositionParams,
      ),
    ),
    _action(
      id: 'reposition',
      title: t.anki_reposition_title,
      subtitle: t.anki_reposition_hint,
      visible: (SettingsContext c) => _vm(c).supportsDeckReposition,
      cli: SettingsCliAction(
        run: _repositionRun,
        params: _repositionParams,
        confirm: true,
      ),
    ),
    _action(
      id: 'reposition_undo',
      title: t.anki_reposition_undo,
      subtitle: t.anki_reposition_undo_hint(time: ''),
      visible: (SettingsContext c) => _vm(c).supportsDeckReposition,
      cli: SettingsCliAction(
        run: _repositionUndo,
        params: <SettingsCliParam>[
          SettingsCliParam('deck', help: '牌组名；省略 = 当前选中的牌组', required: false),
        ],
        confirm: true,
      ),
    ),
    SettingsSwitchItem(
      id: _id('reposition_auto'),
      title: t.anki_reposition_auto_title,
      subtitle: t.anki_reposition_auto_hint,
      visible: (SettingsContext c) => _vm(c).supportsAutoReposition,
      value: (SettingsContext c) =>
          _vm(c).supportsAutoReposition && _cfg(c).autoRepositionEnabled,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).setAutoRepositionEnabled(v),
    ),
    SettingsSwitchItem(
      id: _id('allow_duplicates'),
      title: t.anki_allow_duplicates,
      subtitle: t.anki_allow_duplicates_hint,
      value: (SettingsContext c) => _cfg(c).allowDupes,
      onChanged: (SettingsContext c, bool v) => _vm(c).updateAllowDupes(v),
    ),
    _choice<AnkiDuplicateScope>(
      id: 'duplicate_scope',
      title: t.anki_duplicate_scope,
      subtitle: t.anki_duplicate_scope_hint,
      options: <SettingsSegmentOption<AnkiDuplicateScope>>[
        SettingsSegmentOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.deck,
          label: t.anki_duplicate_scope_deck,
        ),
        SettingsSegmentOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.deckRoot,
          label: t.anki_duplicate_scope_deck_root,
        ),
        SettingsSegmentOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.collection,
          label: t.anki_duplicate_scope_collection,
        ),
      ],
      selected: (SettingsContext c) => _cfg(c).duplicateScope,
      onChanged: (SettingsContext c, AnkiDuplicateScope v) =>
          _vm(c).updateDuplicateScope(v),
    ),
    _choice<AnkiOverwriteScope>(
      id: 'overwrite_scope',
      title: t.anki_overwrite_scope,
      subtitle: t.anki_overwrite_scope_hint,
      options: <SettingsSegmentOption<AnkiOverwriteScope>>[
        SettingsSegmentOption<AnkiOverwriteScope>(
          value: AnkiOverwriteScope.latest,
          label: t.anki_overwrite_scope_latest,
        ),
        SettingsSegmentOption<AnkiOverwriteScope>(
          value: AnkiOverwriteScope.all,
          label: t.anki_overwrite_scope_all,
        ),
      ],
      selected: (SettingsContext c) => _cfg(c).overwriteScope,
      onChanged: (SettingsContext c, AnkiOverwriteScope v) =>
          _vm(c).updateOverwriteScope(v),
    ),
    SettingsSwitchItem(
      id: _id('compact_glossaries'),
      title: t.anki_compact_glossaries,
      subtitle: t.anki_compact_glossaries_hint,
      value: (SettingsContext c) => _cfg(c).compactGlossaries,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).updateCompactGlossaries(v),
    ),
    SettingsSwitchItem(
      id: _id('notice_success'),
      title: t.card_creation_notice_success,
      subtitle: t.card_creation_notice_success_hint,
      value: (SettingsContext c) => c.appModel.mineNoticeSuccess,
      onChanged: (SettingsContext c, bool v) =>
          c.appModel.setMineNoticeSuccess(v),
    ),
    SettingsSwitchItem(
      id: _id('notice_duplicate'),
      title: t.card_creation_notice_duplicate,
      subtitle: t.card_creation_notice_duplicate_hint,
      value: (SettingsContext c) => c.appModel.mineNoticeDuplicate,
      onChanged: (SettingsContext c, bool v) =>
          c.appModel.setMineNoticeDuplicate(v),
    ),
    _action(
      id: 'backup_import',
      title: t.anki_backup_import,
      subtitle: t.anki_backup_import_hint(count: 0),
      visible: (SettingsContext _) => Platform.isIOS,
      cli: const SettingsCliAction.unsupported(
        '仅 iOS（AnkiMobile 查重账本）有这一项；控制通道只存在于桌面端',
      ),
    ),
  ],
);

CtlBodyPage _tagsPage() => CtlBodyPage(
  breadcrumb: _crumb(t.anki_tag_default_section),
  items: <SettingsItem>[
    SettingsTextItem(
      id: _id('global_tags'),
      title: t.anki_tags_global,
      subtitle: t.anki_tags_global_hint,
      value: (SettingsContext c) => _cfg(c).globalTags,
      onChanged: (SettingsContext c, String v) => _vm(c).updateGlobalTags(v),
    ),
    SettingsTextItem(
      id: _id('tags'),
      title: t.anki_tags,
      subtitle: t.anki_tags_hint,
      value: (SettingsContext c) => _cfg(c).tags,
      onChanged: (SettingsContext c, String v) => _vm(c).updateTags(v),
    ),
    SettingsSwitchItem(
      id: _id('tag_include_hibiki'),
      title: t.anki_tag_include_fushi,
      subtitle: t.anki_tag_include_fushi_hint,
      value: (SettingsContext c) => _cfg(c).tagIncludeHibiki,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).updateTagIncludeHibiki(v),
    ),
    SettingsSwitchItem(
      id: _id('tag_include_category'),
      title: t.anki_tag_include_category,
      subtitle: t.anki_tag_include_category_hint,
      value: (SettingsContext c) => _cfg(c).tagIncludeCategory,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).updateTagIncludeCategory(v),
    ),
    // 页面里这两项是 toggle 语义：只在目标值与当前值不同时翻转。
    SettingsSwitchItem(
      id: _id('tag_book_name'),
      title: t.auto_add_book_name_to_tags,
      value: (SettingsContext c) => c.appModel.autoAddBookNameToTags,
      onChanged: (SettingsContext c, bool v) {
        if (c.appModel.autoAddBookNameToTags != v) {
          c.appModel.toggleAutoAddBookNameToTags();
        }
      },
    ),
    SettingsSwitchItem(
      id: _id('tag_char_position'),
      title: t.auto_add_char_position_to_tags,
      subtitle: t.auto_add_char_position_to_tags_hint,
      value: (SettingsContext c) => c.appModel.autoAddCharPositionToTags,
      onChanged: (SettingsContext c, bool v) {
        if (c.appModel.autoAddCharPositionToTags != v) {
          c.appModel.toggleAutoAddCharPositionToTags();
        }
      },
    ),
  ],
);

CtlBodyPage _lapisPage() => CtlBodyPage(
  breadcrumb: _crumb(t.anki_lapis_section),
  visible: (SettingsContext c) => _vm(c).supportsNoteTypeEditing,
  items: <SettingsItem>[
    _choice<int>(
      id: 'lapis_font_scale',
      title: t.anki_lapis_font_scale,
      subtitle: t.anki_lapis_font_scale_hint,
      options: <SettingsSegmentOption<int>>[
        for (final int p in kLapisFontScalePresets)
          SettingsSegmentOption<int>(value: p, label: '$p%'),
      ],
      selected: (SettingsContext c) => _cfg(c).lapisFontScalePercent,
      onChanged: (SettingsContext c, int v) =>
          _vm(c).setLapisFontScalePercent(v),
    ),
    _customValue(
      id: 'lapis_custom_css',
      title: '${t.anki_lapis_visual_editor} · CSS',
      help: '自定义 CSS 文本（多行建议走 --stdin）；写入后用 lapis_apply 才会推到 Anki',
      read: (SettingsContext c) => _cfg(c).lapisCustomCss,
      write: (SettingsContext c, String raw) => _vm(c).setLapisCustomCss(raw),
    ),
    _customValue(
      id: 'lapis_custom_blocks',
      title: '${t.anki_lapis_visual_editor} · blocks',
      help:
          'JSON 数组，每项 {"id":"b1","anchor":"…","fields":["字段"],"rule":{…}}；'
          '写入后用 lapis_apply 才会推到 Anki',
      read: (SettingsContext c) =>
          encodeCtlLapisBlocks(_cfg(c).lapisCustomBlocks),
      write: (SettingsContext c, String raw) =>
          _vm(c).setLapisCustomBlocks(parseCtlLapisBlocks(raw)),
    ),
    _action(
      id: 'lapis_visual_editor',
      title: t.anki_lapis_visual_editor,
      subtitle: t.anki_lapis_visual_editor_hint,
      // 编辑器「保存」交回的整份结果（CSS + 区域 + 字段映射）以 JSON 读写；写入
      // 前整体校验，落盘与设置页保存同一个 applyLapisVisualEditorResult。
      cli: SettingsCliAction(
        run: _lapisVisualEditor,
        params: <SettingsCliParam>[
          SettingsCliParam(
            'value',
            help:
                'JSON {"customCss":"…","blocks":[…],"fieldMappings":{"字段":"{占位符}"}}'
                '（缺的键保持不变）；省略 = 读出当前值。写入后用 lapis_apply 推到 Anki',
            required: false,
          ),
        ],
      ),
    ),
    _action(
      id: 'lapis_apply',
      title: t.anki_lapis_apply,
      cli: SettingsCliAction(
        run: _lapisApply,
        params: <SettingsCliParam>[
          SettingsCliParam(
            'force',
            help: 'true = Anki 端模板疑似被手改时也强行覆盖（页面上对应「确认覆盖」弹窗）',
            required: false,
          ),
        ],
      ),
    ),
    _action(
      id: 'lapis_backup',
      title: t.anki_lapis_backup,
      cli: SettingsCliAction(run: _lapisBackup),
    ),
    _action(
      id: 'lapis_backup_list',
      title: '${t.anki_lapis_restore} · list',
      cli: SettingsCliAction(run: _lapisBackupList),
    ),
    _action(
      id: 'lapis_restore',
      title: t.anki_lapis_restore,
      destructive: true,
      cli: SettingsCliAction(
        run: _lapisRestore,
        params: <SettingsCliParam>[
          SettingsCliParam('file', help: '备份文件名（lapis_backup_list 列出的 name）'),
        ],
        confirm: true,
      ),
    ),
    _action(
      id: 'lapis_restore_factory',
      title: t.anki_lapis_restore_factory,
      subtitle: t.anki_lapis_restore_factory_hint,
      destructive: true,
      cli: SettingsCliAction(run: _lapisRestoreFactory, confirm: true),
    ),
  ],
);

CtlBodyPage _mediaPage() {
  final List<String> imageTiers = <String>[
    t.mining_image_quality_thrift,
    t.mining_image_quality_standard,
    t.mining_image_quality_hd,
    t.mining_image_quality_max,
  ];
  final List<String> audioTiers = <String>[
    t.mining_audio_quality_standard,
    t.mining_audio_quality_high,
    t.mining_audio_quality_max,
  ];
  return CtlBodyPage(
    breadcrumb: _crumb(t.settings_anki_media),
    items: <SettingsItem>[
      SettingsSliderItem(
        id: _id('mining_image_quality'),
        title: t.mining_image_quality,
        subtitle: t.mining_image_quality_hint,
        min: 0,
        max: (imageTiers.length - 1).toDouble(),
        divisions: imageTiers.length - 1,
        step: 1,
        label: (double v) =>
            imageTiers[v.round().clamp(0, imageTiers.length - 1)],
        value: (SettingsContext c) => c.appModel.miningImageQuality
            .clamp(0, imageTiers.length - 1)
            .toDouble(),
        onChanged: (SettingsContext c, double v) =>
            c.appModel.setMiningImageQuality(v.round()),
      ),
      SettingsSliderItem(
        id: _id('mining_audio_quality'),
        title: t.mining_audio_quality,
        subtitle: t.mining_audio_quality_hint,
        min: 0,
        max: (audioTiers.length - 1).toDouble(),
        divisions: audioTiers.length - 1,
        step: 1,
        label: (double v) =>
            audioTiers[v.round().clamp(0, audioTiers.length - 1)],
        value: (SettingsContext c) => c.appModel.miningAudioQuality
            .clamp(0, audioTiers.length - 1)
            .toDouble(),
        onChanged: (SettingsContext c, double v) =>
            c.appModel.setMiningAudioQuality(v.round()),
      ),
      _padSlider(
        id: 'mining_audio_head_pad',
        title: t.mining_audio_head_pad,
        subtitle: t.mining_audio_head_pad_hint,
        read: (SettingsContext c) => c.appModel.miningAudioHeadPadMs,
        write: (SettingsContext c, int ms) =>
            c.appModel.setMiningAudioHeadPadMs(ms),
      ),
      _padSlider(
        id: 'mining_audio_tail_pad',
        title: t.mining_audio_tail_pad,
        subtitle: t.mining_audio_tail_pad_hint,
        read: (SettingsContext c) => c.appModel.miningAudioTailPadMs,
        write: (SettingsContext c, int ms) =>
            c.appModel.setMiningAudioTailPadMs(ms),
      ),
      SettingsSwitchItem(
        id: _id('mining_audio_follow_playback_speed'),
        title: t.mining_audio_follow_playback_speed,
        subtitle: t.mining_audio_follow_playback_speed_hint,
        value: (SettingsContext c) => c.appModel.miningAudioFollowPlaybackSpeed,
        onChanged: (SettingsContext c, bool v) {
          if (c.appModel.miningAudioFollowPlaybackSpeed != v) {
            c.appModel.toggleMiningAudioFollowPlaybackSpeed();
          }
        },
      ),
      _choice<VideoMiningImageMode>(
        id: 'video_mining_image_mode',
        title: t.video_mining_image_mode,
        options: <SettingsSegmentOption<VideoMiningImageMode>>[
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.gif,
            label: t.video_mining_image_mode_gif,
          ),
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.videoClip,
            label: t.video_mining_image_mode_video_clip,
          ),
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.currentFrame,
            label: t.video_mining_image_mode_current_frame,
          ),
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.subtitleStart,
            label: t.video_mining_image_mode_subtitle_start,
          ),
        ],
        selected: (SettingsContext c) => c.appModel.videoMiningImageMode,
        onChanged: (SettingsContext c, VideoMiningImageMode v) =>
            c.appModel.setVideoMiningImageMode(v),
      ),
      _clipFormatChoice(
        id: 'video_mining_clip_format',
        title: t.video_mining_clip_format,
        read: (SettingsContext c) => c.appModel.videoMiningClipFormat,
        write: (SettingsContext c, MiningClipFormat v) =>
            c.appModel.setVideoMiningClipFormat(v),
      ),
      _animatedFormatChoice(
        id: 'video_mining_animated_format',
        title: t.video_mining_animated_format,
        read: (SettingsContext c) => c.appModel.videoMiningAnimatedFormat,
        write: (SettingsContext c, MiningAnimatedFormat v) =>
            c.appModel.setVideoMiningAnimatedFormat(v),
      ),
      SettingsSwitchItem(
        id: _id('mining_animated_play_once'),
        title: t.mining_animated_play_once,
        subtitle: t.mining_animated_play_once_hint,
        value: (SettingsContext c) => c.appModel.miningAnimatedPlayOnce,
        onChanged: (SettingsContext c, bool v) =>
            c.appModel.setMiningAnimatedPlayOnce(v),
      ),
      _stillFormatChoice(
        id: 'video_mining_still_format',
        title: t.video_mining_still_format,
        subtitle: t.video_mining_still_format_hint,
        read: (SettingsContext c) => c.appModel.videoMiningStillFormat,
        write: (SettingsContext c, MiningStillFormat v) =>
            c.appModel.setVideoMiningStillFormat(v),
      ),
      _choice<VideoOnlineMiningMode>(
        id: 'video_online_mining_mode',
        title: t.video_online_mining_mode,
        options: <SettingsSegmentOption<VideoOnlineMiningMode>>[
          SettingsSegmentOption<VideoOnlineMiningMode>(
            value: VideoOnlineMiningMode.background,
            label: t.video_online_mining_mode_background,
          ),
          SettingsSegmentOption<VideoOnlineMiningMode>(
            value: VideoOnlineMiningMode.deferred,
            label: t.video_online_mining_mode_deferred,
          ),
          SettingsSegmentOption<VideoOnlineMiningMode>(
            value: VideoOnlineMiningMode.wait,
            label: t.video_online_mining_mode_wait,
          ),
        ],
        selected: (SettingsContext c) => c.appModel.videoOnlineMiningMode,
        onChanged: (SettingsContext c, VideoOnlineMiningMode v) =>
            c.appModel.setVideoOnlineMiningMode(v),
      ),
      // galgame 制卡（页面里只在 Windows 出现）。
      _choice<VideoMiningImageMode>(
        id: 'gal_mining_image_mode',
        title: t.gal_mining_image_mode,
        visible: (SettingsContext _) => Platform.isWindows,
        options: <SettingsSegmentOption<VideoMiningImageMode>>[
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.gif,
            label: t.video_mining_image_mode_gif,
          ),
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.currentFrame,
            label: t.gal_mining_image_mode_screenshot,
          ),
          SettingsSegmentOption<VideoMiningImageMode>(
            value: VideoMiningImageMode.videoClip,
            label: t.gal_mining_image_mode_video_clip,
          ),
        ],
        // 历史值可能是 subtitleStart（与视频项共用枚举）：与页面一致，按 isStill
        // 归到静态截图。
        selected: (SettingsContext c) {
          final VideoMiningImageMode current = c.appModel.galMiningImageMode;
          return current.isVideoClip
              ? VideoMiningImageMode.videoClip
              : current.isStill
              ? VideoMiningImageMode.currentFrame
              : VideoMiningImageMode.gif;
        },
        onChanged: (SettingsContext c, VideoMiningImageMode v) =>
            c.appModel.setGalMiningImageMode(v),
      ),
      _clipFormatChoice(
        id: 'gal_mining_clip_format',
        title: t.gal_mining_clip_format,
        visible: (SettingsContext _) => Platform.isWindows,
        read: (SettingsContext c) => c.appModel.galMiningClipFormat,
        write: (SettingsContext c, MiningClipFormat v) =>
            c.appModel.setGalMiningClipFormat(v),
      ),
      _animatedFormatChoice(
        id: 'gal_mining_animated_format',
        title: t.gal_mining_animated_format,
        visible: (SettingsContext _) => Platform.isWindows,
        read: (SettingsContext c) => c.appModel.galMiningAnimatedFormat,
        write: (SettingsContext c, MiningAnimatedFormat v) =>
            c.appModel.setGalMiningAnimatedFormat(v),
      ),
      _stillFormatChoice(
        id: 'gal_mining_still_format',
        title: t.gal_mining_still_format,
        visible: (SettingsContext _) => Platform.isWindows,
        read: (SettingsContext c) => c.appModel.galMiningStillFormat,
        write: (SettingsContext c, MiningStillFormat v) =>
            c.appModel.setGalMiningStillFormat(v),
      ),
    ],
  );
}

CtlBodyPage _maintenancePage() => CtlBodyPage(
  breadcrumb: _crumb(t.anki_dedup_section),
  visible: (SettingsContext c) =>
      c.ref.read(ankiViewModelProvider).mediaMaintenanceAvailable ??
      _vm(c).supportsMediaMaintenance,
  items: <SettingsItem>[
    SettingsSwitchItem(
      id: _id('dedup_auto'),
      title: t.anki_dedup_auto,
      subtitle: t.anki_dedup_auto_hint,
      value: (SettingsContext c) => _cfg(c).mediaDedupAutoEnabled,
      onChanged: (SettingsContext c, bool v) =>
          _vm(c).setMediaDedupAutoEnabled(v),
    ),
    // 页面里它在自动处理关着时置灰；CLI 同样拒绝，避免写入一个无意义的值。
    SettingsSwitchItem(
      id: _id('dedup_auto_delete'),
      title: t.anki_dedup_auto_delete,
      subtitle: t.anki_dedup_auto_delete_hint,
      value: (SettingsContext c) => _cfg(c).mediaDedupAutoDelete,
      onChanged: (SettingsContext c, bool v) {
        if (!_cfg(c).mediaDedupAutoEnabled) {
          throw StateError('先打开 ${t.anki_dedup_auto}（dedup_auto）再设置自动直接删除');
        }
        return _vm(c).setMediaDedupAutoDelete(v);
      },
    ),
    _action(
      id: 'dedup_scan',
      title: t.anki_dedup_scan,
      cli: SettingsCliAction(run: _dedupScan),
    ),
    _action(
      id: 'dedup_run',
      title: t.anki_dedup_run,
      subtitle: t.anki_dedup_run_hint,
      destructive: true,
      cli: SettingsCliAction(run: _dedupRun, confirm: true),
    ),
  ],
);

CtlBodyPage _fieldsPage() => CtlBodyPage(
  breadcrumb: _crumb(t.anki_field_mappings),
  visible: (SettingsContext c) =>
      c.ref.read(ankiViewModelProvider).isConfigured,
  items: <SettingsItem>[
    SettingsCustomItem(
      id: _id('field_mappings'),
      builder: (SettingsContext _) => const SizedBox.shrink(),
      searchTitle: t.anki_field_mappings,
      cliList: SettingsCliList(
        list: (SettingsContext c) async => ankiFieldMappingRecords(_cfg(c)),
        update:
            (SettingsContext c, String id, Map<String, String> fields) async {
              final String mapping = fields['mapping'] ?? '';
              if (!fields.containsKey('mapping')) {
                throw ArgumentError('缺少字段 mapping');
              }
              _requireField(_cfg(c), id);
              await _vm(c).updateFieldMapping(id, mapping);
              return _fieldRecord(_cfg(c), id);
            },
        remove: (SettingsContext c, String id) async {
          _requireField(_cfg(c), id);
          await _vm(c).updateFieldMapping(id, '');
        },
        fields: <SettingsCliParam>[
          SettingsCliParam(
            'mapping',
            help: 'Anki 占位符字面量，如 {expression} / {sentence-audio}；空串 = 清除映射',
          ),
        ],
      ),
    ),
    _action(
      id: 'video_template_apply',
      title: t.anki_video_template_title,
      subtitle: t.anki_video_template_media_hint,
      cli: SettingsCliAction(
        run: _videoTemplateApply,
        params: <SettingsCliParam>[
          SettingsCliParam('field', help: '放视频播放器的字段名（图片 / 视频 / 空字段）'),
          SettingsCliParam(
            'placement',
            help: 'bottom | picture；省略 = 沿用已有适配，否则 bottom',
            required: false,
          ),
          SettingsCliParam(
            'autoplay',
            help: 'true/false；省略 = 沿用已有适配，否则 true',
            required: false,
          ),
        ],
      ),
    ),
    _action(
      id: 'video_template_restore',
      title: '${t.anki_video_template_title} · restore',
      destructive: true,
      cli: SettingsCliAction(run: _videoTemplateRestore, confirm: true),
    ),
  ],
);

// ── 构造辅助 ────────────────────────────────────────────────────────────────

/// 动作行。[SettingsActionItem.onTap] 是控制通道之外的兜底入口：没有参数要求时
/// 与 `cli.run` 同一份实现，不重复写业务。
SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  String? subtitle,
  bool destructive = false,
  SettingsVisibility? visible,
}) {
  final SettingsCliRun? run = cli.run;
  return SettingsActionItem(
    id: _id(id),
    title: title,
    subtitle: subtitle,
    destructive: destructive,
    visible: visible,
    cli: cli,
    onTap: (SettingsContext c) async {
      if (run != null) await run(c, const <String, String>{});
    },
  );
}

SettingsSegmentedItem<T> _choice<T extends Object>({
  required String id,
  required String title,
  required List<SettingsSegmentOption<T>> options,
  required SettingsValueGetter<T> selected,
  required SettingsValueChanged<T> onChanged,
  String? subtitle,
  SettingsVisibility? visible,
}) => SettingsSegmentedItem<T>(
  id: _id(id),
  title: title,
  subtitle: subtitle,
  options: options,
  selected: selected,
  onChanged: onChanged,
  visible: visible,
);

SettingsCustomItem _customValue({
  required String id,
  required String title,
  required String help,
  required String Function(SettingsContext c) read,
  required Future<void> Function(SettingsContext c, String raw) write,
}) => SettingsCustomItem(
  id: _id(id),
  builder: (SettingsContext _) => const SizedBox.shrink(),
  searchTitle: title,
  cliValue: SettingsCliValue(read: read, write: write, help: help),
);

SettingsCustomItem _namedPick({
  required String id,
  required String title,
  required String help,
  required List<String> Function(SettingsContext c) names,
  required String Function(SettingsContext c) current,
  required Future<void> Function(SettingsContext c, String name) write,
}) => SettingsCustomItem(
  id: _id(id),
  builder: (SettingsContext _) => const SizedBox.shrink(),
  searchTitle: title,
  cliValue: SettingsCliValue(
    read: current,
    write: (SettingsContext c, String raw) => write(c, raw.trim()),
    help: help,
    options: names,
  ),
);

SettingsSliderItem _padSlider({
  required String id,
  required String title,
  required String subtitle,
  required int Function(SettingsContext c) read,
  required void Function(SettingsContext c, int ms) write,
}) {
  const int step = 50;
  return SettingsSliderItem(
    id: _id(id),
    title: title,
    subtitle: subtitle,
    min: 0,
    max: kMiningPadMaxMs.toDouble(),
    divisions: kMiningPadMaxMs ~/ step,
    step: step.toDouble(),
    label: (double v) => t.mining_audio_pad_readout(ms: v.round()),
    value: (SettingsContext c) => read(c).clamp(0, kMiningPadMaxMs).toDouble(),
    onChanged: (SettingsContext c, double v) =>
        write(c, (v / step).round() * step),
  );
}

SettingsSegmentedItem<MiningClipFormat> _clipFormatChoice({
  required String id,
  required String title,
  required MiningClipFormat Function(SettingsContext c) read,
  required void Function(SettingsContext c, MiningClipFormat v) write,
  SettingsVisibility? visible,
}) => _choice<MiningClipFormat>(
  id: id,
  title: title,
  subtitle: t.mining_clip_format_hint,
  visible: visible,
  options: <SettingsSegmentOption<MiningClipFormat>>[
    SettingsSegmentOption<MiningClipFormat>(
      value: MiningClipFormat.webmVp9,
      label: t.mining_clip_format_webm_vp9,
    ),
    SettingsSegmentOption<MiningClipFormat>(
      value: MiningClipFormat.webmAv1,
      label: t.mining_clip_format_webm_av1,
    ),
    SettingsSegmentOption<MiningClipFormat>(
      value: MiningClipFormat.mp4H264,
      label: t.mining_clip_format_mp4_h264,
    ),
  ],
  selected: read,
  onChanged: write,
);

SettingsSegmentedItem<MiningAnimatedFormat> _animatedFormatChoice({
  required String id,
  required String title,
  required MiningAnimatedFormat Function(SettingsContext c) read,
  required void Function(SettingsContext c, MiningAnimatedFormat v) write,
  SettingsVisibility? visible,
}) => _choice<MiningAnimatedFormat>(
  id: id,
  title: title,
  visible: visible,
  options: <SettingsSegmentOption<MiningAnimatedFormat>>[
    SettingsSegmentOption<MiningAnimatedFormat>(
      value: MiningAnimatedFormat.avif,
      label: t.mining_animated_format_avif,
    ),
    SettingsSegmentOption<MiningAnimatedFormat>(
      value: MiningAnimatedFormat.webp,
      label: t.mining_animated_format_webp,
    ),
    SettingsSegmentOption<MiningAnimatedFormat>(
      value: MiningAnimatedFormat.gif,
      label: t.mining_animated_format_gif,
    ),
  ],
  selected: read,
  onChanged: write,
);

SettingsSegmentedItem<MiningStillFormat> _stillFormatChoice({
  required String id,
  required String title,
  required MiningStillFormat Function(SettingsContext c) read,
  required void Function(SettingsContext c, MiningStillFormat v) write,
  String? subtitle,
  SettingsVisibility? visible,
}) => _choice<MiningStillFormat>(
  id: id,
  title: title,
  subtitle: subtitle,
  visible: visible,
  options: <SettingsSegmentOption<MiningStillFormat>>[
    SettingsSegmentOption<MiningStillFormat>(
      value: MiningStillFormat.jpg,
      label: t.mining_still_format_jpg,
    ),
    SettingsSegmentOption<MiningStillFormat>(
      value: MiningStillFormat.png,
      label: t.mining_still_format_png,
    ),
  ],
  selected: read,
  onChanged: write,
);

// ── 参数辅助 ────────────────────────────────────────────────────────────────

String _requireArg(Map<String, String> args, String name) {
  final String? value = args[name]?.trim();
  if (value == null || value.isEmpty) throw ArgumentError('缺少参数 $name');
  return value;
}

bool? _optBool(Map<String, String> args, String name) {
  final String? raw = args[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;
  return switch (raw) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => throw FormatException('参数 $name 需要 true/false，收到「$raw」'),
  };
}

// ── 纯函数（可单测）────────────────────────────────────────────────────────

/// 字段映射的记录形式：笔记类型的每个字段一条，`id` = 字段名。
List<Map<String, Object?>> ankiFieldMappingRecords(AnkiSettings settings) {
  final AnkiNoteType? noteType = settings.selectedNoteType;
  if (noteType == null) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final String field in noteType.fields) _fieldRecord(settings, field),
  ];
}

Map<String, Object?> _fieldRecord(AnkiSettings settings, String field) =>
    <String, Object?>{
      'id': field,
      'mapping': settings.fieldMappings[field] ?? '',
    };

void _requireField(AnkiSettings settings, String field) {
  final List<String> fields =
      settings.selectedNoteType?.fields ?? const <String>[];
  if (!fields.contains(field)) {
    throw ArgumentError(
      fields.isEmpty
          ? '还没有选中笔记类型'
          : '笔记类型里没有字段「$field」；可选：${fields.join(' | ')}',
    );
  }
}

/// Lapis 自定义区域 → JSON 文本（与 [parseCtlLapisBlocks] 互逆）。
String encodeCtlLapisBlocks(List<LapisCustomBlock> blocks) => jsonEncode(
  <Map<String, Object?>>[for (final LapisCustomBlock b in blocks) b.toJson()],
);

/// JSON 文本 → Lapis 自定义区域；任何一项不合法整体拒绝（不猜、不丢）。
List<LapisCustomBlock> parseCtlLapisBlocks(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return const <LapisCustomBlock>[];
  final Object? decoded = jsonDecode(text);
  if (decoded is! List) {
    throw const FormatException('lapis_custom_blocks 需要 JSON 数组');
  }
  final List<LapisCustomBlock> blocks = <LapisCustomBlock>[];
  final Set<String> ids = <String>{};
  for (int i = 0; i < decoded.length; i++) {
    final LapisCustomBlock? block = LapisCustomBlock.fromJson(decoded[i]);
    if (block == null) {
      throw FormatException('第 ${i + 1} 项不是合法的自定义区域（id / anchor / fields）');
    }
    if (!ids.add(block.id)) {
      throw FormatException('区域 id「${block.id}」重复');
    }
    blocks.add(block);
  }
  return blocks;
}

/// Lapis 可视化编辑器的整份数据 → JSON（与 [parseCtlLapisVisualEditorJson] 互逆）。
Map<String, Object?> ctlLapisVisualEditorJson(AnkiSettings settings) =>
    <String, Object?>{
      'customCss': settings.lapisCustomCss,
      'blocks': <Map<String, Object?>>[
        for (final LapisCustomBlock b in settings.lapisCustomBlocks) b.toJson(),
      ],
      'fieldMappings': <String, String>{
        for (final Map<String, Object?> r in ankiFieldMappingRecords(settings))
          '${r['id']}': '${r['mapping']}',
      },
    };

/// JSON → 编辑器保存结果。结构不对 / 区域不合法 / 字段不在当前笔记类型里，整体
/// 拒绝（不猜、不丢）；缺的键沿用 [current] 的值（字段映射缺省 = 不改）。
LapisVisualEditorResult parseCtlLapisVisualEditorJson(
  String raw,
  AnkiSettings current,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw FormatException('不是 JSON：${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const FormatException(
      '需要 JSON 对象 {customCss, blocks, fieldMappings}',
    );
  }
  const Set<String> known = <String>{'customCss', 'blocks', 'fieldMappings'};
  for (final String key in decoded.keys) {
    if (!known.contains(key)) {
      throw FormatException('未知键「$key」；可用：${known.join(' / ')}');
    }
  }
  final Object? css = decoded['customCss'];
  if (css != null && css is! String) {
    throw const FormatException('customCss 必须是字符串');
  }
  final Object? blocks = decoded['blocks'];
  if (blocks != null && blocks is! List) {
    throw const FormatException('blocks 必须是数组');
  }
  final Object? mappings = decoded['fieldMappings'];
  if (mappings != null && mappings is! Map) {
    throw const FormatException('fieldMappings 必须是对象 {"字段":"占位符"}');
  }
  final Map<String, String> fieldMappings = <String, String>{};
  if (mappings is Map) {
    for (final MapEntry<Object?, Object?> e in mappings.entries) {
      if (e.value is! String) {
        throw FormatException('fieldMappings「${e.key}」的值必须是字符串');
      }
      _requireField(current, '${e.key}');
      fieldMappings['${e.key}'] = e.value! as String;
    }
  }
  return LapisVisualEditorResult(
    customCss: (css as String?) ?? current.lapisCustomCss,
    blocks: blocks == null
        ? current.lapisCustomBlocks
        : parseCtlLapisBlocks(jsonEncode(blocks)),
    fieldMappings: fieldMappings,
  );
}

// ── 动作实现 ────────────────────────────────────────────────────────────────

Future<Object?> _lapisVisualEditor(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String? raw = args['value'];
  if (raw != null && raw.trim().isNotEmpty) {
    await applyLapisVisualEditorResult(
      _vm(c),
      parseCtlLapisVisualEditorJson(raw, _cfg(c)),
    );
  }
  return ctlLapisVisualEditorJson(_cfg(c));
}

Future<Object?> _fetchConfiguration(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiViewModel vm = _vm(c);
  // 页面在刷新后还会弹「建议创建 Lapis」确认框；那是交互，这里把同一个判据
  // （canMineCards）作为字段交回去，由调用方决定要不要 run create_lapis。
  await vm.fetchConfiguration();
  final AnkiUiState state = c.ref.read(ankiViewModelProvider);
  return <String, Object?>{
    'configured': state.isConfigured,
    'error': state.errorMessage,
    'decks': <String>[for (final AnkiDeck d in state.availableDecks) d.name],
    'noteTypes': <String>[
      for (final AnkiNoteType n in state.availableNoteTypes) n.name,
    ],
    'canMineCards': state.settings.canMineCards,
  };
}

Future<Object?> _createLapis(
  SettingsContext c,
  Map<String, String> args,
) async {
  final LapisSetupResult result = await _vm(c).createLapisSetup();
  return <String, Object?>{
    'outcome': result.outcome.name,
    'message': switch (result.outcome) {
      LapisSetupOutcome.created => t.anki_create_lapis_success,
      LapisSetupOutcome.alreadyExisted => t.anki_create_lapis_exists,
      LapisSetupOutcome.failed => t.anki_create_lapis_failed(
        error: result.message ?? '',
      ),
    },
    if (result.code != null) 'code': result.code,
  };
}

Future<Object?> _pendingMineLanding(
  SettingsContext c,
  Map<String, String> args,
) async {
  final SyncRepository repo = SyncRepository(c.appModel.database);
  final bool? enabled = _optBool(args, 'enabled');
  if (enabled != null) await repo.setPendingMineLanding(enabled);
  return <String, Object?>{
    'enabled': await repo.getPendingMineLandingClaimedAt() > 0,
  };
}

Future<Object?> _repairPort(SettingsContext c, Map<String, String> args) async {
  final AnkiPortRepairOutcome outcome = await repairAnkiConnectPort(
    _vm(c),
    _cfg(c),
  );
  return <String, Object?>{
    'port': outcome.port,
    'addonConfigUpdated': outcome.status == AnkiConnectPortWriteStatus.updated,
    'message': ankiPortRepairMessage(outcome),
  };
}

Future<Object?> _installAddon(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiAddonInstallResult result = await AnkiConnectInstaller.install();
  return <String, Object?>{
    'status': result.status.name,
    'message': ankiAddonInstallMessage(result),
  };
}

Future<Object?> _detectExecutable(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String? detected = await detectAndStoreAnkiExecutable(_vm(c));
  return <String, Object?>{
    'executable': detected,
    'message': detected ?? t.anki_desktop_executable_detect_failed,
  };
}

Future<Object?> _launchDesktop(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiDesktopLaunchResult result = await launchAnkiDesktopAndLearn(
    _vm(c),
    _cfg(c),
  );
  return <String, Object?>{
    'status': result.status.name,
    'message': ankiLaunchMessage(result),
  };
}

// 重排 ────────────────────────────────────────────────────────────────────────

final List<SettingsCliParam> _repositionParams = <SettingsCliParam>[
  SettingsCliParam('deck', help: '牌组名；省略 = 当前选中的牌组', required: false),
  SettingsCliParam(
    'source',
    help: 'dictionaries | field；省略 = 沿用上次的设置',
    required: false,
  ),
  SettingsCliParam(
    'dictionaries',
    help: '词频词典名，逗号分隔；省略 = 沿用上次的设置（空 = 全部已装载）',
    required: false,
  ),
  SettingsCliParam(
    'aggregate',
    help: 'harmonic | min；省略 = 沿用上次的设置',
    required: false,
  ),
  SettingsCliParam(
    'rare_first',
    help: 'true/false，生僻词排前；省略 = 沿用上次的设置',
    required: false,
  ),
];

String _repositionDeckName(AnkiSettings settings, Map<String, String> args) {
  final List<AnkiDeck> decks = settings.availableDecks;
  final String? wanted = args['deck']?.trim();
  if (wanted != null && wanted.isNotEmpty) {
    if (!decks.any((AnkiDeck d) => d.name == wanted)) {
      throw ArgumentError(
        '没有牌组「$wanted」；可选：${decks.map((AnkiDeck d) => d.name).join(' | ')}',
      );
    }
    return wanted;
  }
  final AnkiDeck? chosen = decks
      .where((AnkiDeck d) => d.id == settings.selectedDeckId)
      .firstOrNull;
  final AnkiDeck? deck = chosen ?? decks.firstOrNull;
  if (deck == null) throw StateError(t.anki_not_configured);
  return deck.name;
}

AnkiDeckRepositionRunner _repositionRunner(SettingsContext c) {
  final AnkiViewModel vm = _vm(c);
  if (!vm.supportsDeckReposition) {
    throw StateError(t.anki_reposition_unsupported);
  }
  return vm.deckRepositionRunner;
}

/// 解析并持久化重排选项（页面在点「预览」时同样先落盘），然后算计划。
Future<AnkiRepositionPlan> _planReposition(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiDeckRepositionRunner runner = _repositionRunner(c);
  final AnkiViewModel vm = _vm(c);
  final AnkiSettings settings = vm.settings;
  final String deck = _repositionDeckName(settings, args);
  final List<String> loaded = loadedFrequencyDictionaryNames(c.appModel);

  final String? sourceRaw = args['source']?.trim();
  final AnkiRepositionSource source = switch (sourceRaw) {
    null || '' => settings.repositionSource,
    'dictionaries' => AnkiRepositionSource.dictionaries,
    'field' => AnkiRepositionSource.field,
    _ => throw ArgumentError('source 只能是 dictionaries | field，收到「$sourceRaw」'),
  };

  final String? dictsRaw = args['dictionaries'];
  final Set<String> dictionaries;
  if (dictsRaw == null) {
    // 只保留还装着的词典；一本都不剩就回到「全部」（与页面弹窗一致）。
    dictionaries = settings.repositionDictionaries
        .where(loaded.contains)
        .toSet();
  } else {
    final List<String> wanted = dictsRaw
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final List<String> missing = wanted
        .where((String s) => !loaded.contains(s))
        .toList();
    if (missing.isNotEmpty) {
      throw ArgumentError(
        '词典未装载或已隐藏：${missing.join('、')}；可选：${loaded.join(' | ')}',
      );
    }
    dictionaries = wanted.toSet();
  }

  final String? aggregateRaw = args['aggregate']?.trim();
  final FrequencyAggregate aggregate =
      aggregateRaw == null || aggregateRaw.isEmpty
      ? FrequencyAggregate.fromName(settings.repositionAggregate)
      : FrequencyAggregate.values.firstWhere(
          (FrequencyAggregate a) => a.name == aggregateRaw,
          orElse: () => throw ArgumentError(
            'aggregate 只能是 ${FrequencyAggregate.values.map((FrequencyAggregate a) => a.name).join(' | ')}，收到「$aggregateRaw」',
          ),
        );
  final bool rareFirst =
      _optBool(args, 'rare_first') ?? settings.repositionRareFirst;

  if (source == AnkiRepositionSource.dictionaries && loaded.isEmpty) {
    throw StateError(t.anki_reposition_dicts_none);
  }

  await vm.setRepositionOptions(
    source: source,
    dictionaries: dictionaries.toList()..sort(),
    aggregate: aggregate.name,
    rareFirst: rareFirst,
  );
  final AnkiRepositionPlan? plan = await runner.plan(
    deckName: deck,
    settings: vm.settings,
    options: AnkiRepositionRankOptions(
      source: source,
      dictionaries: dictionaries,
      aggregate: aggregate,
      rareFirst: rareFirst,
    ),
  );
  if (plan == null) throw StateError(t.anki_reposition_unsupported);
  return plan;
}

Map<String, Object?> _planSummary(AnkiRepositionPlan plan) => <String, Object?>{
  'deck': plan.deckName,
  'total': plan.total,
  'ranked': plan.ranked,
  'unranked': plan.unranked,
  'changed': plan.changed,
  'sample': <Map<String, Object?>>[
    for (final AnkiRepositionCard card in plan.ordered.take(20))
      <String, Object?>{'expression': card.expression, 'rank': card.rank},
  ],
};

Future<Object?> _repositionPreview(
  SettingsContext c,
  Map<String, String> args,
) async => _planSummary(await _planReposition(c, args));

Future<Object?> _repositionRun(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiRepositionPlan plan = await _planReposition(c, args);
  if (plan.total == 0) {
    return <String, Object?>{
      ..._planSummary(plan),
      'written': 0,
      'message': t.anki_reposition_empty,
    };
  }
  final AnkiRepositionOutcome outcome = await _repositionRunner(c).apply(plan);
  return <String, Object?>{
    ..._planSummary(plan),
    'written': outcome.written,
    'skipped': outcome.skipped,
    'failed': outcome.failures.length,
    if (outcome.failures.isNotEmpty)
      'firstError': outcome.failures.values.first,
    'snapshot': outcome.snapshot?.path,
  };
}

Future<Object?> _repositionUndo(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiDeckRepositionRunner runner = _repositionRunner(c);
  final String deck = _repositionDeckName(_vm(c).settings, args);
  final AnkiRepositionSnapshot? snapshot = await runner.latestSnapshot(deck);
  if (snapshot == null) {
    throw StateError('牌组「$deck」没有可撤销的重排快照');
  }
  final AnkiRepositionUndoOutcome outcome = await runner.undo(snapshot);
  return <String, Object?>{
    'deck': deck,
    'restored': outcome.restored,
    'skipped': outcome.skipped,
    'failed': outcome.failures.length,
    if (outcome.failures.isNotEmpty)
      'firstError': outcome.failures.values.first,
  };
}

// Lapis ───────────────────────────────────────────────────────────────────────

Future<Object?> _lapisApply(SettingsContext c, Map<String, String> args) async {
  final AnkiViewModel vm = _vm(c);
  final bool force = _optBool(args, 'force') ?? false;
  final LapisApplyResult result = await vm.lapisTemplateService
      .applyCustomization(force: force);
  if (result == LapisApplyResult.applied ||
      result == LapisApplyResult.upToDate) {
    await vm.refreshSettingsFromStore();
  }
  return <String, Object?>{
    'result': result.name,
    'message': switch (result) {
      LapisApplyResult.applied => t.anki_lapis_apply_done,
      LapisApplyResult.upToDate => t.anki_lapis_up_to_date,
      LapisApplyResult.needsConfirm =>
        '${t.anki_lapis_foreign_edit_body}（确认后带 force=true 重试）',
      LapisApplyResult.notFound ||
      LapisApplyResult.unsupported => t.anki_lapis_not_found,
    },
  };
}

Future<Object?> _lapisBackup(
  SettingsContext c,
  Map<String, String> args,
) async {
  final LapisBackupOutcome? outcome = await _vm(
    c,
  ).lapisTemplateService.backupNow();
  return <String, Object?>{
    'path': outcome?.file.path,
    'pruned': outcome?.prunedCount ?? 0,
    'message': lapisBackupMessage(outcome),
  };
}

String _backupName(File f) => f.uri.pathSegments.last;

Future<Object?> _lapisBackupList(
  SettingsContext c,
  Map<String, String> args,
) async {
  final List<File> backups = await _vm(c).lapisTemplateService.listBackups();
  return <String, Object?>{
    'backups': <Map<String, Object?>>[
      for (final File f in backups)
        <String, Object?>{'name': _backupName(f), 'path': f.path},
    ],
  };
}

Future<Object?> _lapisRestore(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String name = _requireArg(args, 'file');
  final AnkiViewModel vm = _vm(c);
  final List<File> backups = await vm.lapisTemplateService.listBackups();
  if (backups.isEmpty) throw StateError(t.anki_lapis_restore_empty);
  final File chosen = backups.firstWhere(
    (File f) => _backupName(f) == name || f.path == name,
    orElse: () => throw ArgumentError(
      '没有备份「$name」；可选：${backups.map(_backupName).take(30).join(' | ')}',
    ),
  );
  // 与页面同序：恢复失败也要刷新（restoreBackup 在卡模板失败前已写穿了 styling 与
  // settings，只刷成功路径会让后续读到恢复前的值）；恢复本身的错优先呈现。
  Object? failure;
  try {
    await vm.lapisTemplateService.restoreBackup(chosen);
  } catch (e) {
    failure = e;
  }
  try {
    await vm.refreshSettingsFromStore();
  } catch (e) {
    failure ??= e;
  }
  if (failure != null) {
    throw StateError(t.anki_lapis_restore_failed(error: '$failure'));
  }
  return <String, Object?>{
    'restored': _backupName(chosen),
    'message': t.anki_lapis_restore_done,
  };
}

Future<Object?> _lapisRestoreFactory(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AnkiViewModel vm = _vm(c);
  final LapisRestoreFactoryResult result = await vm.lapisTemplateService
      .restoreFactoryDefaults();
  // 恢复会清空 Fushi 侧客制化（字号 / CSS / 自定义区域），必须刷新。
  await vm.refreshSettingsFromStore();
  return <String, Object?>{
    'result': result.name,
    'message': switch (result) {
      LapisRestoreFactoryResult.restored => t.anki_lapis_restore_factory_done,
      LapisRestoreFactoryResult.notFound ||
      LapisRestoreFactoryResult.unsupported => t.anki_lapis_not_found,
    },
  };
}

// 媒体去重 ────────────────────────────────────────────────────────────────────

Map<String, Object?> _dedupJson(AnkiMediaDedupReport report) =>
    <String, Object?>{
      'dryRun': report.dryRun,
      'cancelled': report.cancelled,
      'groups': report.groupCount,
      'duplicates': report.duplicatesRemoved,
      'bytesSaved': report.bytesSaved,
      'notesRewritten': report.notesRewritten,
      'modelsRewritten': report.modelsRewritten,
      'skipped': report.skipped,
      'deletions': <Map<String, Object?>>[
        for (final MediaDedupDeletion d in report.deletions.take(50))
          <String, Object?>{
            'filename': d.filename,
            'canonical': d.canonical,
            'bytes': d.bytes,
          },
      ],
    };

Future<Object?> _dedupScan(SettingsContext c, Map<String, String> args) async {
  final AnkiMediaDedupReport? report = await _vm(
    c,
  ).mediaDedupRunner.runNow(dryRun: true);
  if (report == null) throw StateError(t.anki_dedup_unavailable);
  if (report.cancelled) throw StateError(t.anki_dedup_cancelled);
  return _dedupJson(report);
}

/// 页面「立即去重」永远先干跑、用户确认后才真删；CLI 的 `--yes`（confirm）就是
/// 那次确认，所以这里直接真跑（journal 备份由 runner 自己落盘）。
Future<Object?> _dedupRun(SettingsContext c, Map<String, String> args) async {
  final AnkiMediaDedupReport? report = await _vm(
    c,
  ).mediaDedupRunner.runNow(dryRun: false);
  if (report == null) throw StateError(t.anki_dedup_unavailable);
  return _dedupJson(report);
}

// 视频模板 ────────────────────────────────────────────────────────────────────

Future<(AnkiNoteTypeDefinition, AnkiNoteType)> _readVideoTemplateTarget(
  SettingsContext c,
) async {
  final AnkiViewModel vm = _vm(c);
  final AnkiNoteType? noteType = _cfg(c).selectedNoteType;
  if (noteType == null) throw StateError(t.anki_not_configured);
  if (!vm.videoTemplateService.supportsEditing) {
    throw StateError(t.anki_video_template_unsupported);
  }
  final AnkiNoteTypeDefinition? definition = await vm.videoTemplateService.read(
    noteType.name,
  );
  if (definition == null) throw StateError(t.anki_lapis_not_found);
  return (definition, noteType);
}

Future<Object?> _videoTemplateApply(
  SettingsContext c,
  Map<String, String> args,
) async {
  final String field = _requireArg(args, 'field');
  final (AnkiNoteTypeDefinition definition, AnkiNoteType noteType) =
      await _readVideoTemplateTarget(c);
  if (!definition.fields.contains(field)) {
    throw ArgumentError(
      '笔记类型「${noteType.name}」没有字段「$field」；可选：${definition.fields.join(' | ')}',
    );
  }
  final AnkiVideoTemplateOptions? saved = readAnkiVideoTemplateOptions(
    definition,
  );
  final String? placementRaw = args['placement']?.trim();
  final AnkiVideoPlacement placement =
      placementRaw == null || placementRaw.isEmpty
      ? (saved?.placement ?? AnkiVideoPlacement.bottom)
      : AnkiVideoPlacement.values.firstWhere(
          (AnkiVideoPlacement p) => p.name == placementRaw,
          orElse: () => throw ArgumentError(
            'placement 只能是 ${AnkiVideoPlacement.values.map((AnkiVideoPlacement p) => p.name).join(' | ')}，收到「$placementRaw」',
          ),
        );
  final bool autoplay = _optBool(args, 'autoplay') ?? saved?.autoplay ?? true;
  final AnkiViewModel vm = _vm(c);
  await vm.videoTemplateService.apply(
    expected: definition,
    options: AnkiVideoTemplateOptions(
      field: field,
      placement: placement,
      autoplay: autoplay,
    ),
  );
  await vm.refreshSettingsFromStore();
  return <String, Object?>{
    'field': field,
    'placement': placement.name,
    'autoplay': autoplay,
    'message': t.anki_video_template_applied,
  };
}

Future<Object?> _videoTemplateRestore(
  SettingsContext c,
  Map<String, String> args,
) async {
  final (AnkiNoteTypeDefinition definition, AnkiNoteType _) =
      await _readVideoTemplateTarget(c);
  final AnkiViewModel vm = _vm(c);
  await vm.videoTemplateService.restore(expected: definition);
  await vm.refreshSettingsFromStore();
  return <String, Object?>{'message': t.anki_video_template_restored};
}
