import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/anki/sync_client/anki_sync_host.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_mined_ledger.dart'
    show ankiMobileLedgerIsDuplicateSource;
import 'package:fushi/src/pages/implementations/anki_settings_page.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart'
    show srsMiningToReviewProvider;
import 'package:fushi/utils.dart';

SettingsDestination buildCardCreationDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.cardCreation,
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.cardCreation,
      c.appModel.moduleVisibility,
    ),
    title: t.settings_destination_card_creation,
    summary: t.anki_settings_label,
    icon: FushiIcons.ankiCard,
    body: (_) => const AnkiSettingsBody(),
    bodyBeforeSections: true,
    // 层级（2026-10-31 重排）：正文只有目标切换条（+ Fushi 复习分组），紧接着是当前
    // 目标的配置——「Anki」分组（连接 / 牌组 / 笔记类型等）与「发送与待发卡片」；之后
    // 才是两种目标都生效的「卡片内容」「制卡提示」「默认标签」「媒体」。此前 Anki 配置
    // 排在这些通用分组之后，切到 Anki 的用户要翻过三组才看到自己的牌组。
    sections: <SettingsSection>[
      // 「Anki」分组：全部 Anki 专属设置，只在目标为 Anki 时出现（目标切换在正文顶部
      // 的分段条里；发往 Fushi 复习时非空的待发队列在「Fushi 复习」分组末尾）。
      _ankiSection(),
      _ankiDeliverySection(),
      _rowsSection(
        id: 'card_creation.content',
        title: t.card_creation_section_content,
        rows: const <AnkiSectionRow>[
          AnkiSectionRow.allowDuplicates,
          AnkiSectionRow.overwriteScope,
          AnkiSectionRow.compactGlossaries,
        ],
      ),
      _rowsSection(
        id: 'card_creation.notices',
        title: t.card_creation_section_notices,
        rows: const <AnkiSectionRow>[
          AnkiSectionRow.noticeSuccess,
          AnkiSectionRow.noticeDuplicate,
        ],
      ),
      _rowsSection(
        id: 'card_creation.tags',
        title: t.anki_tag_default_section,
        rows: const <AnkiSectionRow>[
          AnkiSectionRow.globalTags,
          AnkiSectionRow.tags,
          AnkiSectionRow.tagIncludeFushi,
          AnkiSectionRow.tagIncludeCategory,
          AnkiSectionRow.tagBookName,
          AnkiSectionRow.tagCharPosition,
        ],
      ),
      // 两种目标都生效：截图 / 动图 / 音频片段参数（SRS 制卡走同一条采集链路）。
      SettingsSection(
        id: 'card_creation.configuration',
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'card_creation.media.open',
            title: t.settings_anki_media,
            subtitle: '${t.mining_image_quality} · ${t.mining_audio_quality}',
            child: () =>
                _buildAnkiPanel(AnkiSettingsPanel.media, t.settings_anki_media),
          ),
        ],
      ),
    ],
    bodySearchEntries: <SettingsBodySearchEntry>[
      // 挖词目标（Anki / Fushi 复习，二选一）：只在复习模块开着时存在。目标为
      // Fushi 复习时，下面只作用于 Anki 发送链路的条目（_ankiOnly）不进索引。
      // 「Fushi 复习」分组首行：复习模块开着时是目标单选行，关着时是「开启 Fushi
      // 复习」入口——两种形态都在这个 reveal target 上。
      SettingsBodySearchEntry(
        id: 'card_creation.anki.srs_mining_target',
        title: t.srs_mining_target_title,
        subtitle: t.srs_mining_target_hint,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.srs.card_look',
        visible: _toReview,
        title: t.srs_card_appearance_title,
        subtitle: t.srs_mining_target_srs,
        hasRevealTarget: true,
      ),
      // 目标为 Fushi 复习时替代 Anki 牌组 / 笔记类型的两行。
      SettingsBodySearchEntry(
        id: 'card_creation.srs.deck',
        visible: _toReview,
        title: t.anki_deck,
        subtitle: t.srs_mining_target_srs,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.srs.note_type',
        visible: _toReview,
        title: t.anki_note_type,
        subtitle: t.srs_mining_target_srs,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.mine_to_server',
        visible: _ankiOnly(_mineToServerVisible),
        title: t.anki_mine_to_server,
        subtitle: t.anki_mine_to_server_hint,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.batch_mining',
        visible: _ankiOnly(),
        title: t.anki_batch_mining_title,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.queue_undelivered_mines',
        visible: _ankiOnly(),
        title: t.anki_queue_undelivered_mines_title,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.pending_mine_landing',
        visible: _ankiOnly(),
        title: t.anki_pending_mine_landing_title,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.pending_mines',
        visible: _ankiOnly(),
        title: t.anki_pending_mines_title,
        hasRevealTarget: true,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.duplicate_scope',
        title: t.anki_duplicate_scope,
        hasRevealTarget: true,
        visible: _ankiOnly(
          (SettingsContext c) =>
              c.ref.watch(ankiViewModelProvider).isConfigured,
        ),
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.reposition',
        title: t.anki_reposition_title,
        hasRevealTarget: true,
        // 两种目标都有：Anki 目标在「Anki」分组（要 Anki 已配置），Fushi 复习目标在
        // 「Fushi 复习」分组（复习层自己读写新卡位置）。
        visible: _repositionVisible,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.reposition_auto',
        title: t.anki_reposition_auto_title,
        hasRevealTarget: true,
        // 只有 Anki 目标有：Fushi 复习出卡直接按词频名次排，不需要制卡后改写位置。
        visible: _ankiOnly(
          (SettingsContext c) =>
              c.ref.watch(ankiViewModelProvider).isConfigured,
        ),
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.profile',
        visible: _ankiOnly(),
        hasRevealTarget: true,
        title: t.profile_label,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.fetch',
        visible: _ankiOnly(),
        hasRevealTarget: true,
        title: t.anki_fetch,
        subtitle: t.anki_refresh_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.create_lapis',
        visible: _ankiOnly(),
        hasRevealTarget: true,
        title: t.anki_create_lapis,
        subtitle: t.anki_create_lapis_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.deck',
        visible: _ankiOnly(_ankiDecksLoaded),
        hasRevealTarget: true,
        title: t.anki_deck,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.note_type',
        visible: _ankiOnly(_ankiDecksLoaded),
        hasRevealTarget: true,
        title: t.anki_note_type,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.allow_duplicates',
        // 「卡片内容」分组：两种目标都生效、不看 Anki 连没连上。
        hasRevealTarget: true,
        title: t.anki_allow_duplicates,
        subtitle: t.anki_allow_duplicates_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.backup_import',
        visible: (SettingsContext c) =>
            Platform.isIOS &&
            !_toReview(c) &&
            c.ref.watch(ankiViewModelProvider).isConfigured &&
            ankiMobileLedgerIsDuplicateSource(
              useAnkiConnectOnMobile: c.ref
                  .watch(ankiViewModelProvider)
                  .settings
                  .useAnkiConnectOnMobile,
              mineToServer: c.appModel.mineToServerEnabled,
            ),
        hasRevealTarget: true,
        title: t.anki_backup_import,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.overwrite_scope',
        // 复习覆写同样按它决定 ✓ 能不能改更早的卡（全部 = 按查重找到的复习笔记）。
        hasRevealTarget: true,
        title: t.anki_overwrite_scope,
        subtitle: t.anki_overwrite_scope_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.compact_glossaries',
        // 「卡片内容」分组：两种目标都生效、不看 Anki 连没连上。
        hasRevealTarget: true,
        title: t.anki_compact_glossaries,
        subtitle: t.anki_compact_glossaries_hint,
      ),
      // 「制卡提示」分组：两种目标都生效。
      SettingsBodySearchEntry(
        id: 'card_creation.notice.success',
        hasRevealTarget: true,
        title: t.card_creation_notice_success,
        subtitle: t.card_creation_notice_success_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.notice.duplicate',
        hasRevealTarget: true,
        title: t.card_creation_notice_duplicate,
        subtitle: t.card_creation_notice_duplicate_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.global_tags',
        hasRevealTarget: true,
        title: t.anki_tags_global,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tags',
        hasRevealTarget: true,
        title: t.anki_tags,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_include_hibiki',
        hasRevealTarget: true,
        title: t.anki_tag_include_fushi,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_include_category',
        hasRevealTarget: true,
        title: t.anki_tag_include_category,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_book_name',
        hasRevealTarget: true,
        title: t.auto_add_book_name_to_tags,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_char_position',
        hasRevealTarget: true,
        title: t.auto_add_char_position_to_tags,
        subtitle: t.anki_tag_default_section,
      ),
    ],
  );
}

SettingsDestination _buildAnkiPanel(AnkiSettingsPanel panel, String title) {
  return SettingsDestination(
    id: SettingsDestinationId.cardCreation,
    title: title,
    icon: FushiIcons.ankiCard,
    sections: const <SettingsSection>[],
    body: (_) => AnkiSettingsBody(panel: panel),
    bodySearchEntries: <SettingsBodySearchEntry>[
      if (panel == AnkiSettingsPanel.lapis) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_font_scale',
          title: t.anki_lapis_font_scale,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_visual_editor',
          title: t.anki_lapis_visual_editor,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_apply',
          title: t.anki_lapis_apply,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_backup',
          title: t.anki_lapis_backup,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_restore',
          title: t.anki_lapis_restore,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.lapis_restore_factory',
          title: t.anki_lapis_restore_factory,
          hasRevealTarget: true,
        ),
      ],
      if (panel == AnkiSettingsPanel.maintenance) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.dedup_auto',
          title: t.anki_dedup_auto,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.dedup_auto_delete',
          title: t.anki_dedup_auto_delete,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.dedup_scan',
          title: t.anki_dedup_scan,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.dedup_run',
          title: t.anki_dedup_run,
          hasRevealTarget: true,
        ),
      ],
      if (panel == AnkiSettingsPanel.connection) ...[
        // 只有带了 fushi-anki-sync 的安装包才有这一节（目前是桌面端）。
        SettingsBodySearchEntry(
          id: 'card_creation.anki.sync_client',
          title: t.anki_sync_client_use_title,
          subtitle: t.anki_sync_client_section_title,
          hasRevealTarget: true,
          visible: (_) => sharedAnkiSyncSession != null,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_port_auto_fix',
          title: t.anki_connect_port_auto_fix,
          hasRevealTarget: true,
          visible: (_) =>
              Platform.isWindows || Platform.isMacOS || Platform.isLinux,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_addon_install',
          title: t.anki_connect_addon_install,
          hasRevealTarget: true,
          visible: (_) => Platform.isWindows,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.desktop_auto_launch',
          title: t.anki_desktop_auto_launch,
          subtitle: t.anki_desktop_auto_launch_hint,
          hasRevealTarget: true,
          visible: (_) =>
              Platform.isWindows || Platform.isMacOS || Platform.isLinux,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.desktop_executable',
          title: t.anki_desktop_executable,
          hasRevealTarget: true,
          visible: (_) =>
              Platform.isWindows || Platform.isMacOS || Platform.isLinux,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.desktop_launch',
          title: t.anki_desktop_launch,
          hasRevealTarget: true,
          visible: (_) =>
              Platform.isWindows || Platform.isMacOS || Platform.isLinux,
        ),
      ],
      if (panel == AnkiSettingsPanel.media) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_animated_format',
          title: t.video_mining_animated_format,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_animated_play_once',
          title: t.mining_animated_play_once,
          subtitle: t.mining_animated_play_once_hint,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.gal_mining_image_mode',
          title: t.gal_mining_image_mode,
          hasRevealTarget: true,
          visible: (_) => Platform.isWindows,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.gal_mining_clip_format',
          title: t.gal_mining_clip_format,
          subtitle: t.mining_clip_format_hint,
          hasRevealTarget: true,
          visible: (_) => Platform.isWindows,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.gal_mining_animated_format',
          title: t.gal_mining_animated_format,
          hasRevealTarget: true,
          visible: (_) => Platform.isWindows,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.gal_mining_still_format',
          title: t.gal_mining_still_format,
          hasRevealTarget: true,
          visible: (_) => Platform.isWindows,
        ),
      ],
      if (panel == AnkiSettingsPanel.connection) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_host',
          hasRevealTarget: true,
          title: t.anki_connect_host,
          subtitle: 'AnkiConnect',
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_port',
          hasRevealTarget: true,
          title: t.anki_connect_port,
          subtitle: 'AnkiConnect',
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_api_key',
          hasRevealTarget: true,
          title: t.anki_connect_api_key,
          subtitle: 'AnkiConnect',
        ),
      ],
      if (panel == AnkiSettingsPanel.fields) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.field_mappings',
          hasRevealTarget: true,
          title: t.anki_field_mappings,
        ),
      ],
      if (panel == AnkiSettingsPanel.media) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_image_quality',
          hasRevealTarget: true,
          title: t.mining_image_quality,
          subtitle: t.mining_image_quality_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_audio_quality',
          hasRevealTarget: true,
          title: t.mining_audio_quality,
          subtitle: t.mining_audio_quality_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_audio_head_pad',
          hasRevealTarget: true,
          title: t.mining_audio_head_pad,
          subtitle: t.mining_audio_head_pad_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_audio_tail_pad',
          hasRevealTarget: true,
          title: t.mining_audio_tail_pad,
          subtitle: t.mining_audio_tail_pad_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.mining_audio_follow_playback_speed',
          hasRevealTarget: true,
          title: t.mining_audio_follow_playback_speed,
          subtitle: t.mining_audio_follow_playback_speed_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_audio_source',
          hasRevealTarget: true,
          title: t.video_mining_audio_source,
          subtitle: t.video_mining_audio_source_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_image_mode',
          hasRevealTarget: true,
          title: t.video_mining_image_mode,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_clip_format',
          hasRevealTarget: true,
          title: t.video_mining_clip_format,
          subtitle: t.mining_clip_format_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_still_format',
          hasRevealTarget: true,
          title: t.video_mining_still_format,
          subtitle: t.video_mining_still_format_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_online_mining_mode',
          hasRevealTarget: true,
          title: t.video_online_mining_mode,
        ),
      ],
      if (panel == AnkiSettingsPanel.connection &&
          (Platform.isAndroid || Platform.isIOS))
        SettingsBodySearchEntry(
          id: 'card_creation.anki.connect_mobile',
          title: t.anki_connect_use_on_mobile,
          subtitle: t.anki_connect_use_on_mobile_hint,
          hasRevealTarget: true,
        ),
    ],
  );
}

/// 制卡此刻发往 Fushi 复习：只作用于 Anki 发送链路的项不显示、不进搜索索引。
/// 与正文 [AnkiSettingsBody] 的 [srsMiningToReviewProvider] 同一判据，但直接读
/// [SettingsContext.appModel]（宿主 watch 着它，目标一改就重建；搜索索引在没有
/// 平台服务装配的宿主里也能求值）。
bool _toReview(SettingsContext c) =>
    c.appModel.moduleVisibility.isEnabled(ModuleId.srs) &&
    c.appModel.srsMiningTarget == SrsMiningTarget.srs;

/// 只作用于 Anki 的项：目标为 Fushi 复习时隐藏，否则再看 [inner]（默认恒可见）。
SettingsVisibility _ankiOnly([SettingsVisibility? inner]) =>
    (SettingsContext c) => !_toReview(c) && (inner?.call(c) ?? true);

/// 「按词频重排新卡」：目标为 Fushi 复习时恒在（「Fushi 复习」分组），否则跟着
/// 「Anki」分组里的条件（Anki 已配置）。
bool _repositionVisible(SettingsContext c) =>
    _toReview(c) ||
    _ankiOnly(
      (SettingsContext c) => c.ref.watch(ankiViewModelProvider).isConfigured,
    )(c);

/// Anki 牌组 / 笔记类型已从 Anki 拉到（或已选好）：牌组 / 笔记类型两行可选。还没
/// 加载到任何东西时只给「点刷新加载」提示。
bool _ankiDecksLoaded(SettingsContext c) {
  final AnkiUiState s = c.ref.watch(ankiViewModelProvider);
  return s.isConfigured || s.settings.availableDecks.isNotEmpty;
}

/// 「制卡到 Fushi 互联服务端」镜像行：开着时露出——这时卡片落在服务端的 Anki，用户
/// 在 Anki 配置里必须看得到这一点并能就地关掉（此前它只在互联设置里，制卡页上的牌组 /
/// 笔记类型看起来生效、其实不用）。打开它仍在互联设置里（要先配对）。
bool _mineToServerVisible(SettingsContext c) => c.appModel.mineToServerEnabled;

/// 「Anki」分组首段：制卡去向（互联服务端 / 本机）。
List<AnkiSectionRow> _ankiRouteRows(SettingsContext c) => <AnkiSectionRow>[
  if (!_toReview(c) && _mineToServerVisible(c)) AnkiSectionRow.mineToServer,
];

/// 「Anki」分组中段：档案、刷新、牌组与笔记类型。
List<AnkiSectionRow> _ankiDeckRows(SettingsContext c) {
  if (_toReview(c)) return const <AnkiSectionRow>[];
  final AnkiUiState s = c.ref.watch(ankiViewModelProvider);
  final bool loaded = _ankiDecksLoaded(c);
  return <AnkiSectionRow>[
    AnkiSectionRow.profile,
    AnkiSectionRow.fetch,
    AnkiSectionRow.createLapis,
    if (s.errorMessage != null || !loaded) AnkiSectionRow.notice,
    if (loaded) ...<AnkiSectionRow>[
      AnkiSectionRow.deck,
      AnkiSectionRow.noteType,
    ],
  ];
}

/// 「Anki」分组末段：Anki 已配置后才有意义的项（重排、查重范围、备份查重）。
List<AnkiSectionRow> _ankiConfiguredRows(SettingsContext c) {
  if (_toReview(c)) return const <AnkiSectionRow>[];
  final AnkiUiState s = c.ref.watch(ankiViewModelProvider);
  if (!s.isConfigured) return const <AnkiSectionRow>[];
  return <AnkiSectionRow>[
    AnkiSectionRow.reposition,
    AnkiSectionRow.autoReposition,
    AnkiSectionRow.duplicateScope,
    if (Platform.isIOS &&
        ankiMobileLedgerIsDuplicateSource(
          useAnkiConnectOnMobile: s.settings.useAnkiConnectOnMobile,
          mineToServer: c.appModel.mineToServerEnabled,
        ))
      AnkiSectionRow.backupImport,
  ];
}

/// 「Anki」分组里此刻出现的自绘行（顺序即显示顺序；子页入口行穿插其间）。
@visibleForTesting
List<AnkiSectionRow> ankiSectionRowsFor(SettingsContext c) => <AnkiSectionRow>[
  ..._ankiRouteRows(c),
  ..._ankiDeckRows(c),
  ..._ankiConfiguredRows(c),
];

/// 「发送与待发卡片」分组里此刻出现的行。待发队列不受「Anki 已配置」门控——恰恰
/// 是连不上 Anki 的时候卡会攒在这里；目标为 Fushi 复习时它在「Fushi 复习」分组末尾。
@visibleForTesting
List<AnkiSectionRow> ankiDeliveryRowsFor(SettingsContext c) => _toReview(c)
    ? const <AnkiSectionRow>[]
    : const <AnkiSectionRow>[
        AnkiSectionRow.batchMining,
        AnkiSectionRow.queueUndelivered,
        AnkiSectionRow.pendingLanding,
        AnkiSectionRow.pendingMines,
      ];

/// 一组 [AnkiSectionRow] 渲染成分组里的独立行（每行一个 [AnkiSettingsBody]）。
SettingsCustomItem _rowsItem(
  String id,
  List<AnkiSectionRow> Function(SettingsContext c) rows,
) => SettingsCustomItem.rows(
  id: id,
  visible: (SettingsContext c) => rows(c).isNotEmpty,
  rowsBuilder: (SettingsContext c) => <Widget>[
    for (final AnkiSectionRow row in rows(c))
      AnkiSettingsBody(key: ValueKey<String>('anki-row-${row.name}'), row: row),
  ],
);

/// 两种目标都生效的固定行分组（卡片内容 / 制卡提示 / 默认标签）。
SettingsSection _rowsSection({
  required String id,
  required String title,
  required List<AnkiSectionRow> rows,
}) => SettingsSection(
  id: id,
  title: title,
  items: <SettingsItem>[_rowsItem('$id.rows', (_) => rows)],
);

/// 「Anki」分组（目标为 Fushi 复习时整组不显示）：制卡去向 → 连接 → 牌组 / 笔记类型
/// → 字段映射 / Lapis → 重排与查重 → 媒体维护。
SettingsSection _ankiSection() => SettingsSection(
  id: 'card_creation.anki',
  title: t.srs_mining_target_anki,
  visible: (SettingsContext c) => !_toReview(c),
  presentation: SettingsSectionPresentation.alwaysExpanded,
  items: <SettingsItem>[
    _rowsItem('card_creation.anki.route_rows', _ankiRouteRows),
    SettingsNavigationItem(
      id: 'card_creation.connection.open',
      title: 'AnkiConnect',
      icon: FushiIcons.link,
      showIcon: true,
      visible: _ankiOnly(),
      subtitleBuilder: (SettingsContext c) {
        final settings = c.ref.watch(ankiViewModelProvider).settings;
        return '${settings.ankiConnectHost}:${settings.ankiConnectPort}';
      },
      child: () => _buildAnkiPanel(AnkiSettingsPanel.connection, 'AnkiConnect'),
    ),
    _rowsItem('card_creation.anki.rows', _ankiDeckRows),
    SettingsNavigationItem(
      id: 'card_creation.fields.open',
      title: t.anki_field_mappings,
      icon: FushiIcons.swap,
      showIcon: true,
      visible: _ankiOnly(
        (SettingsContext c) => c.ref.watch(ankiViewModelProvider).isConfigured,
      ),
      subtitleBuilder: (SettingsContext c) =>
          c.ref.watch(ankiViewModelProvider).settings.selectedNoteTypeName,
      child: () =>
          _buildAnkiPanel(AnkiSettingsPanel.fields, t.anki_field_mappings),
    ),
    SettingsNavigationItem(
      id: 'card_creation.lapis.open',
      title: t.anki_lapis_section,
      icon: FushiIcons.appearance,
      showIcon: true,
      visible: _ankiOnly(
        (SettingsContext c) =>
            c.ref.read(ankiViewModelProvider.notifier).supportsNoteTypeEditing,
      ),
      subtitle: t.anki_lapis_visual_editor_hint,
      child: () =>
          _buildAnkiPanel(AnkiSettingsPanel.lapis, t.anki_lapis_section),
    ),
    _rowsItem('card_creation.anki.configured_rows', _ankiConfiguredRows),
    SettingsNavigationItem(
      id: 'card_creation.maintenance.open',
      title: t.anki_dedup_section,
      subtitle: t.anki_dedup_run_hint,
      icon: FushiIcons.deleteSweep,
      showIcon: true,
      visible: _ankiOnly(
        (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).mediaMaintenanceAvailable ??
            c.ref.read(ankiViewModelProvider.notifier).supportsMediaMaintenance,
      ),
      child: () =>
          _buildAnkiPanel(AnkiSettingsPanel.maintenance, t.anki_dedup_section),
    ),
  ],
);

/// 「发送与待发卡片」分组：批量制卡、连不上时暂存、接收其他设备的卡、待发队列。
SettingsSection _ankiDeliverySection() => SettingsSection(
  id: 'card_creation.anki.delivery',
  title: t.anki_delivery_section,
  visible: (SettingsContext c) => !_toReview(c),
  items: <SettingsItem>[
    _rowsItem('card_creation.anki.delivery_rows', ankiDeliveryRowsFor),
  ],
);
