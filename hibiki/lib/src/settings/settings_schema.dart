import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _readingDestination(),
    _audiobookDestination(),
    _dictionaryAndCardsDestination(),
    _systemDestination(),
    _diagnosticsDestination(),
  ];
}

SettingsDestination buildReaderQuickSettingsDestination(
    SettingsContext context) {
  final List<SettingsDestination> destinations = buildSettingsSchema(context);
  final SettingsDestination appearance = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.appearance,
  );
  final SettingsDestination reading = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.reading,
  );
  final SettingsSection readingEntrySection = reading.sections.first;
  final List<SettingsItem> readingEntries = readingEntrySection.items
      .where(
        (SettingsItem item) =>
            item.id == 'reading.display' || item.id == 'reading.fonts',
      )
      .toList(growable: false);

  return SettingsDestination(
    id: SettingsDestinationId.reading,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      appearance.sections.first,
      SettingsSection(
        title: readingEntrySection.title,
        items: readingEntries,
      ),
      ...reading.sections.skip(1),
    ],
  );
}

SettingsDestination _appearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.section_interface,
    summary: t.design_system_hint,
    icon: Icons.palette_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_interface,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: Icons.devices_outlined,
            builder: buildDesignSystemSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.theme',
            icon: Icons.color_lens_outlined,
            builder: buildThemeSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            icon: Icons.contrast_outlined,
            builder: buildBrightnessSelector,
          ),
        ],
      ),
      SettingsSection(
        title: t.profile_label,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'appearance.profile_selector',
            icon: Icons.person_outline,
            builder: buildProfileSelectorRow,
          ),
          SettingsNavigationItem(
            id: 'appearance.profile_management',
            title: t.profile_management,
            icon: Icons.manage_accounts_outlined,
            builder: (_) => const ProfileManagementPage(),
          ),
          SettingsActionItem(
            id: 'appearance.language',
            title: t.options_language,
            icon: Icons.translate_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => const LanguageDialogPage(),
              );
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _readingDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.reading,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.auto_stories_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'reading.display',
            title: t.display_settings,
            icon: Icons.text_fields,
            builder: (_) => const DisplaySettingsPage(),
          ),
          SettingsNavigationItem(
            id: 'reading.fonts',
            title: customFontsTitlePlaceholder,
            icon: Icons.font_download_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsNavigationItem(
            id: 'reading.book_css',
            title: t.book_css_editor_title,
            subtitle: t.book_css_editor_no_extract_dir,
            icon: Icons.code_outlined,
            visible: (_) => false,
            builder: (_) => const BookCssEditorPage(extractDir: ''),
          ),
        ],
      ),
      SettingsSection(
        title: t.section_navigation,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading.highlight_on_tap',
            title: t.highlight_on_tap,
            icon: Icons.touch_app_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.highlightOnTap,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleHighlightOnTap();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading.volume_page_turning',
            title: t.volume_button_page_turning,
            icon: Icons.volume_up_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumePageTurningEnabled();
              VolumeKeyChannel.instance.setInterceptEnabled(
                settingsContext.readerSource.volumePageTurningEnabled,
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading.invert_volume_buttons',
            title: t.invert_volume_buttons,
            icon: Icons.swap_vert_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningInverted,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumePageTurningInverted();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'reading.invert_swipe_direction',
            title: t.invert_swipe_direction,
            icon: Icons.swipe_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.invertSwipeDirection,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleInvertSwipeDirection();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading.volume_page_turning_speed',
            title: t.volume_button_turning_speed,
            icon: Icons.speed_outlined,
            min: 10,
            max: 500,
            divisions: 49,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumePageTurningSpeed.toDouble(),
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.readerSource
                  .setVolumePageTurningSpeed(value.round());
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading.dismiss_swipe_sensitivity',
            title: t.dismiss_swipe_sensitivity,
            icon: Icons.swipe_down_outlined,
            min: 0.1,
            max: 1,
            divisions: 9,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.dismissSwipeSensitivity,
            label: (double value) => value.toStringAsFixed(1),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.readerSource
                  .setDismissSwipeSensitivity(value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.dictionary_media_type,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading.auto_read_on_lookup',
            title: t.auto_read_on_lookup,
            icon: Icons.record_voice_over_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.autoReadOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleAutoReadOnLookup();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSliderItem(
            id: 'reading.popup_max_width',
            title: t.popup_max_width,
            icon: Icons.open_in_full_outlined,
            min: 250,
            max: 1000,
            divisions: 75,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.popupMaxWidth,
            label: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) {
              settingsContext.appModel.setPopupMaxWidth(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'reading.keep_screen_awake',
            title: t.keep_screen_awake,
            icon: Icons.lightbulb_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.keepScreenAwake,
            onChanged: setKeepScreenAwake,
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _audiobookDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.audiobook,
    title: t.audiobook_settings,
    summary: t.floating_lyric_hint,
    icon: Icons.headphones_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_audiobook,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'audiobook.media_notification',
            title: t.show_media_notification,
            icon: Icons.notifications_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showMediaNotification,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowMediaNotification(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'audiobook.floating_lyric',
            title: t.show_floating_lyric,
            subtitle: t.floating_lyric_hint,
            icon: Icons.subtitles_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showFloatingLyric,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowFloatingLyric(value);
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'audiobook.floating_lyric_font_size',
            title: t.floating_lyric_font_size,
            icon: Icons.format_size,
            min: 8,
            max: 64,
            step: 1,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.floatingLyricFontSize,
            format: (double value) => value.round().toString(),
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setFloatingLyricFontSize(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'audiobook.volume_key_sentence_nav',
            title: t.volume_key_sentence_nav,
            icon: Icons.skip_next_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.volumeKeySentenceNavEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleVolumeKeySentenceNavEnabled();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _dictionaryAndCardsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.dictionaryAndCards,
    title: '${t.dictionaries} / ${t.anki_settings_label}',
    summary: t.card_creator,
    icon: Icons.style_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.anki_settings_label,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'dictionary_cards.anki',
            title: t.anki_settings_label,
            icon: Icons.style_outlined,
            builder: (_) => const AnkiSettingsPage(),
          ),
          SettingsNavigationItem(
            id: 'dictionary_cards.anki_profiles',
            title: t.anki_manage_profiles,
            subtitle: t.anki_manage_profiles_hint,
            icon: Icons.account_tree_outlined,
            builder: (_) => const ProfileManagementPage(),
          ),
        ],
      ),
      SettingsSection(
        title: t.dictionary_settings,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'dictionary_cards.dictionary_settings',
            title: t.dictionary_settings,
            icon: Icons.auto_stories_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => const DictionarySettingsDialogPage(),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.auto_search',
            title: t.auto_search,
            icon: Icons.manage_search_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.autoSearchEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleAutoSearchEnabled();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.collapse_dictionaries',
            title: t.collapse_dictionaries,
            icon: Icons.unfold_less_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.collapseDictionaries,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleCollapseDictionaries();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.show_expression_tags',
            title: t.show_expression_tags,
            icon: Icons.sell_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showExpressionTags,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleShowExpressionTags();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.deduplicate_pitch_accents',
            title: t.deduplicate_pitch_accents,
            icon: Icons.filter_alt_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.deduplicatePitchAccents,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleDeduplicatePitchAccents();
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.harmonic_frequency',
            title: t.harmonic_frequency,
            icon: Icons.bar_chart_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.harmonicFrequency,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleHarmonicFrequency();
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.local_audio,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'dictionary_cards.audio_sources',
            title: t.manage_audio_sources,
            icon: Icons.volume_up_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => AudioSourcesDialog(
                  sources: List<String>.from(
                    settingsContext.appModel.audioSources,
                  ),
                  onSave: settingsContext.appModel.setAudioSources,
                ),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'dictionary_cards.local_audio',
            title: t.local_audio,
            icon: Icons.library_music_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.localAudioEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleLocalAudio();
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _systemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.miscellaneous_settings,
    summary: t.section_update,
    icon: Icons.settings_suggest_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_update,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'system.update_never_remind',
            title: t.update_never_remind,
            icon: Icons.notifications_off_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateNeverRemind,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateNeverRemind(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_auto_install',
            title: t.update_auto_install,
            icon: Icons.system_update_alt_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateAutoInstall,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateAutoInstall(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_beta_channel',
            title: t.update_beta_channel,
            icon: Icons.science_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateBetaChannel,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateBetaChannel(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_debug_channel',
            title: t.update_debug_channel,
            icon: Icons.bug_report_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateDebugChannel,
            onChanged: confirmDebugChannel,
          ),
        ],
      ),
      SettingsSection(
        title: t.miscellaneous_settings,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'system.low_memory_mode',
            title: t.low_memory_mode,
            subtitle: t.low_memory_mode_hint,
            icon: Icons.memory_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.lowMemoryMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setLowMemoryMode(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'system.app_icon',
            title: t.app_icon_label,
            icon: Icons.widgets_outlined,
            builder: (_) => const MiscellaneousSettingsPage(),
          ),
          SettingsActionItem(
            id: 'system.github',
            title: t.options_github,
            icon: Icons.public_outlined,
            onTap: (_) async {
              await launchUrl(
                Uri.parse('https://github.com/hdjsadgfwtg/hibiki'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _diagnosticsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.diagnostics,
    title: t.debug_log_toggle,
    summary: t.error_log_label(n: ErrorLogService.instance.entries.length),
    icon: Icons.bug_report_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.debug_log_toggle,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title:
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.bug_report_outlined,
            builder: (_) => const ErrorLogPage(),
          ),
          SettingsSwitchItem(
            id: 'diagnostics.debug_log_enabled',
            title: t.debug_log_toggle,
            icon: Icons.rule_outlined,
            value: (_) => DebugLogService.instance.enabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await DebugLogService.instance.setEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'diagnostics.debug_log',
            title: t.debug_log_title(
              count: DebugLogService.instance.entries.length,
            ),
            icon: Icons.terminal_outlined,
            visible: (_) =>
                DebugLogService.instance.enabled ||
                DebugLogService.instance.entries.isNotEmpty,
            builder: (_) => const DebugLogPage(),
          ),
        ],
      ),
    ],
  );
}

String get customFontsTitlePlaceholder => t.custom_fonts;
