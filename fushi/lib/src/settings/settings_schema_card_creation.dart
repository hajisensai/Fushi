import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/pages/implementations/anki_settings_page.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
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
    icon: Icons.style_outlined,
    body: (_) => const AnkiSettingsBody(),
    bodyBeforeSections: true,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'card_creation.connection',
        title: 'AnkiConnect',
        presentation: Platform.isAndroid || Platform.isIOS
            ? SettingsSectionPresentation.collapsed
            : SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'card_creation.connection.open',
            title: 'AnkiConnect',
            subtitleBuilder: (SettingsContext c) {
              final settings = c.ref.watch(ankiViewModelProvider).settings;
              return '${settings.ankiConnectHost}:${settings.ankiConnectPort}';
            },
            child: () =>
                _buildAnkiPanel(AnkiSettingsPanel.connection, 'AnkiConnect'),
          ),
        ],
      ),
      SettingsSection(
        id: 'card_creation.configuration',
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'card_creation.fields.open',
            title: t.anki_field_mappings,
            visible: (SettingsContext c) =>
                c.ref.watch(ankiViewModelProvider).isConfigured,
            subtitleBuilder: (SettingsContext c) => c.ref
                .watch(ankiViewModelProvider)
                .settings
                .selectedNoteTypeName,
            child: () => _buildAnkiPanel(
              AnkiSettingsPanel.fields,
              t.anki_field_mappings,
            ),
          ),
          SettingsNavigationItem(
            id: 'card_creation.lapis.open',
            title: t.anki_lapis_section,
            visible: (SettingsContext c) => c.ref
                .read(ankiViewModelProvider.notifier)
                .supportsNoteTypeEditing,
            subtitle: t.anki_lapis_visual_editor_hint,
            child: () =>
                _buildAnkiPanel(AnkiSettingsPanel.lapis, t.anki_lapis_section),
          ),
          SettingsNavigationItem(
            id: 'card_creation.media.open',
            title: t.settings_anki_media,
            subtitle: '${t.mining_image_quality} · ${t.mining_audio_quality}',
            child: () =>
                _buildAnkiPanel(AnkiSettingsPanel.media, t.settings_anki_media),
          ),
          SettingsNavigationItem(
            id: 'card_creation.maintenance.open',
            title: t.anki_dedup_section,
            subtitle: t.anki_dedup_run_hint,
            visible: (SettingsContext c) =>
                c.ref.watch(ankiViewModelProvider).mediaMaintenanceAvailable ??
                c.ref
                    .read(ankiViewModelProvider.notifier)
                    .supportsMediaMaintenance,
            child: () => _buildAnkiPanel(
              AnkiSettingsPanel.maintenance,
              t.anki_dedup_section,
            ),
          ),
        ],
      ),
    ],
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'card_creation.anki.duplicate_scope',
        title: t.anki_duplicate_scope,
        hasRevealTarget: true,
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.reposition',
        title: t.anki_reposition_title,
        hasRevealTarget: true,
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.profile',
        hasRevealTarget: true,
        title: t.profile_label,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.fetch',
        hasRevealTarget: true,
        title: t.anki_fetch,
        subtitle: t.anki_refresh_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.create_lapis',
        hasRevealTarget: true,
        title: t.anki_create_lapis,
        subtitle: t.anki_create_lapis_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.deck',
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
        hasRevealTarget: true,
        title: t.anki_deck,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.note_type',
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
        hasRevealTarget: true,
        title: t.anki_note_type,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.allow_duplicates',
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
        hasRevealTarget: true,
        title: t.anki_allow_duplicates,
        subtitle: t.anki_allow_duplicates_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.overwrite_scope',
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
        hasRevealTarget: true,
        title: t.anki_overwrite_scope,
        subtitle: t.anki_overwrite_scope_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.compact_glossaries',
        visible: (SettingsContext c) =>
            c.ref.watch(ankiViewModelProvider).isConfigured,
        hasRevealTarget: true,
        title: t.anki_compact_glossaries,
        subtitle: t.anki_compact_glossaries_hint,
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
    icon: Icons.style_outlined,
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
      ],
      if (panel == AnkiSettingsPanel.media) ...[
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_animated_format',
          title: t.video_mining_animated_format,
          hasRevealTarget: true,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.gal_mining_image_mode',
          title: t.gal_mining_image_mode,
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
          id: 'card_creation.anki.video_mining_image_mode',
          hasRevealTarget: true,
          title: t.video_mining_image_mode,
          subtitle: t.video_mining_image_mode_hint,
        ),
        SettingsBodySearchEntry(
          id: 'card_creation.anki.video_mining_still_format',
          hasRevealTarget: true,
          title: t.video_mining_still_format,
          subtitle: t.video_mining_still_format_hint,
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
