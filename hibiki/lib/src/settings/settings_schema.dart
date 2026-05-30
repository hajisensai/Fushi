import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/utils.dart';
import 'package:url_launcher/url_launcher.dart';

List<SettingsDestination> buildSettingsSchema(SettingsContext context) {
  return <SettingsDestination>[
    _appearanceDestination(),
    _profilesDestination(),
    _readingDisplayDestination(),
    _readingControlsDestination(),
    _lookupDestination(),
    _cardCreationDestination(),
    _listeningDestination(),
    buildSyncBackupDestination(),
    _systemDestination(),
    _diagnosticsDestination(),
  ];
}

SettingsDestination buildReaderQuickSettingsDestination(
  SettingsContext context,
) {
  final List<SettingsDestination> destinations = buildSettingsSchema(context);
  final SettingsDestination appearance = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.appearance,
  );
  final SettingsDestination readingDisplay = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.readingDisplay,
  );
  final SettingsDestination readingControls = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.readingControls,
  );
  final SettingsDestination lookup = destinations.firstWhere(
    (SettingsDestination destination) =>
        destination.id == SettingsDestinationId.lookup,
  );
  final List<SettingsItem> quickLookupItems =
      lookup.sections.expand((SettingsSection section) => section.items).where(
    (SettingsItem item) {
      return item.id == 'lookup.auto_read_on_lookup' ||
          item.id == 'lookup.popup_max_width';
    },
  ).toList(growable: false);

  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      appearance.sections.first,
      ...readingDisplay.sections,
      ...readingControls.sections,
      SettingsSection(
        title: t.settings_section_lookup_behavior,
        items: quickLookupItems,
      ),
    ],
  );
}

SettingsDestination _appearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance,
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
        title: t.settings_section_app_shell,
        items: <SettingsItem>[
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
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            icon: Icons.widgets_outlined,
            visible: (_) => Platform.isAndroid,
            builder: (_) => const MiscellaneousSettingsPage(),
          ),
          SettingsSwitchItem(
            id: 'appearance.reverse_navigation_bar',
            title: t.reverse_navigation_bar,
            icon: Icons.swap_horiz_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.reverseNavigationBar,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleReverseNavigationBar();
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _profilesDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.profiles,
    title: t.settings_destination_profiles,
    summary: t.profile_management,
    icon: Icons.manage_accounts_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.profile_label,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'profiles.current',
            icon: Icons.person_outline,
            builder: buildProfilePickerRow,
          ),
          SettingsNavigationItem(
            id: 'profiles.management',
            title: t.profile_management,
            icon: Icons.manage_accounts_outlined,
            builder: (_) => const ProfileManagementPage(),
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _readingDisplayDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.readingDisplay,
    title: t.settings_destination_reading_display,
    summary: t.section_layout,
    icon: Icons.auto_stories_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'reading_display.display',
            title: t.display_settings,
            icon: Icons.text_fields,
            builder: (_) => const DisplaySettingsPage(),
          ),
          SettingsNavigationItem(
            id: 'reading_display.fonts',
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
            id: 'reading_display.book_css',
            title: t.book_css_editor_title,
            subtitle: t.book_css_editor_no_extract_dir,
            icon: Icons.code_outlined,
            visible: (_) => false,
            builder: (_) => const BookCssEditorPage(extractDir: ''),
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _readingControlsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.readingControls,
    title: t.settings_destination_reading_controls,
    summary: t.section_navigation,
    icon: Icons.touch_app_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_navigation,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'reading_controls.highlight_on_tap',
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
            id: 'reading_controls.volume_page_turning',
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
            id: 'reading_controls.invert_volume_buttons',
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
            id: 'reading_controls.invert_swipe_direction',
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
            id: 'reading_controls.volume_page_turning_speed',
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
            id: 'reading_controls.dismiss_swipe_sensitivity',
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
          SettingsSwitchItem(
            id: 'reading_controls.keep_screen_awake',
            title: t.keep_screen_awake,
            icon: Icons.lightbulb_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.keepScreenAwake,
            onChanged: setKeepScreenAwake,
          ),
          SettingsNavigationItem(
            id: 'reading_controls.keyboard_shortcuts',
            title: t.shortcut_settings_title,
            icon: Icons.keyboard_outlined,
            builder: (BuildContext context) => const ShortcutSettingsPage(),
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _lookupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.lookup,
    title: t.settings_destination_lookup,
    summary: t.dictionary_settings,
    icon: Icons.manage_search_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.manager,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'lookup.dictionaries',
            title: t.dictionaries,
            icon: Icons.auto_stories_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const DictionaryDialogPage(),
              );
              settingsContext.refresh();
            },
          ),
          SettingsActionItem(
            id: 'lookup.custom_css',
            title: t.custom_dict_css,
            icon: Icons.code_outlined,
            onTap: (SettingsContext settingsContext) {
              return showSettingsDialog(
                settingsContext,
                (_) => const DictCssEditorDialog(),
              );
            },
          ),
          SettingsActionItem(
            id: 'lookup.audio_sources',
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
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_behavior,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.auto_search',
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
            id: 'lookup.auto_read_on_lookup',
            title: t.auto_read_on_lookup,
            icon: Icons.record_voice_over_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.autoReadOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.readerSource.toggleAutoReadOnLookup();
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsSwitchItem(
            id: 'lookup.pause_on_lookup',
            title: t.pause_on_lookup,
            icon: Icons.pause_circle_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.readerSource.pauseOnLookup,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.readerSource.setPauseOnLookup(value: value);
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
          SettingsCustomItem(
            id: 'lookup.auto_search_debounce_delay',
            icon: Icons.timer_outlined,
            builder: _buildSearchDebounceField,
          ),
          SettingsCustomItem(
            id: 'lookup.maximum_terms',
            icon: Icons.format_list_numbered_outlined,
            builder: _buildMaximumTermsField,
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_section_lookup_display,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.collapse_dictionaries',
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
            id: 'lookup.show_expression_tags',
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
            id: 'lookup.deduplicate_pitch_accents',
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
            id: 'lookup.harmonic_frequency',
            title: t.harmonic_frequency,
            icon: Icons.bar_chart_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.harmonicFrequency,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleHarmonicFrequency();
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.dictionary_font_size',
            icon: Icons.format_size,
            builder: _buildDictionaryFontSizeField,
          ),
          SettingsSliderItem(
            id: 'lookup.popup_max_width',
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
        ],
      ),
      SettingsSection(
        title: t.local_audio,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'lookup.local_audio',
            title: t.local_audio,
            icon: Icons.library_music_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.localAudioEnabled,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleLocalAudio();
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'lookup.local_audio_databases',
            icon: Icons.storage_outlined,
            builder: (SettingsContext settingsContext) =>
                _LocalAudioDatabasesRow(settingsContext: settingsContext),
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _cardCreationDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.cardCreation,
    title: t.settings_destination_card_creation,
    summary: t.anki_settings_label,
    icon: Icons.style_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.anki_settings_label,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'card_creation.anki',
            title: t.anki_settings_label,
            icon: Icons.style_outlined,
            builder: (_) => const AnkiSettingsPage(),
          ),
          SettingsSwitchItem(
            id: 'card_creation.auto_add_book_name_to_tags',
            title: t.auto_add_book_name_to_tags,
            icon: Icons.label_outline,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.autoAddBookNameToTags,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleAutoAddBookNameToTags();
              settingsContext.refresh();
            },
          ),
        ],
      ),
    ],
  );
}

SettingsDestination _listeningDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.listening,
    title: t.settings_destination_listening,
    summary: t.floating_lyric_hint,
    icon: Icons.headphones_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_audiobook,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'listening.media_notification',
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
            id: 'listening.floating_lyric',
            title: t.show_floating_lyric,
            subtitle: t.floating_lyric_hint,
            icon: Icons.subtitles_outlined,
            visible: (_) => Platform.isAndroid,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.showFloatingLyric,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setShowFloatingLyric(value);
              settingsContext.refresh();
            },
          ),
          SettingsStepperItem(
            id: 'listening.floating_lyric_font_size',
            title: t.floating_lyric_font_size,
            icon: Icons.format_size,
            visible: (_) => Platform.isAndroid,
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
            id: 'listening.volume_key_sentence_nav',
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

SettingsDestination _systemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.settings_destination_system,
    summary: t.section_update,
    icon: Icons.settings_suggest_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_update,
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'system.update_channel',
            title: t.settings_section_update_channel,
            icon: Icons.system_update_alt_outlined,
            controlBelow: true,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'stable',
                label: t.update_channel_stable,
                icon: Icons.verified_outlined,
                tooltip: t.update_channel_stable,
              ),
              SettingsSegmentOption<String>(
                value: 'beta',
                label: t.update_channel_beta,
                icon: Icons.science_outlined,
                tooltip: t.update_channel_beta,
              ),
              SettingsSegmentOption<String>(
                value: 'debug',
                label: t.update_channel_debug,
                icon: Icons.bug_report_outlined,
                tooltip: t.update_channel_debug,
              ),
            ],
            selected: _selectedUpdateChannel,
            onChanged: setUpdateChannel,
          ),
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
            icon: Icons.download_done_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateAutoInstall,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateAutoInstall(value);
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_system,
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
    title: t.settings_destination_diagnostics,
    summary: t.error_log_label(n: ErrorLogService.instance.entries.length),
    icon: Icons.bug_report_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.settings_destination_diagnostics,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title:
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.report_problem_outlined,
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

String _selectedUpdateChannel(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return 'debug';
  if (settingsContext.appModel.updateBetaChannel) return 'beta';
  return 'stable';
}

Widget _buildSearchDebounceField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.auto_search_debounce_delay,
    icon: Icons.timer_outlined,
    suffixText: t.unit_milliseconds,
    initialValue: appModel.searchDebounceDelay.toString(),
    resetValue: appModel.defaultSearchDebounceDelay.toString(),
    onChanged: (String value) {
      int newDelay = int.tryParse(value) ?? appModel.defaultSearchDebounceDelay;
      if (newDelay.isNegative) newDelay = appModel.defaultSearchDebounceDelay;
      appModel.setSearchDebounceDelay(newDelay);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setSearchDebounceDelay(appModel.defaultSearchDebounceDelay);
      settingsContext.refresh();
    },
  );
}

Widget _buildDictionaryFontSizeField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.dictionary_font_size,
    icon: Icons.format_size,
    suffixText: t.unit_pixels,
    initialValue: appModel.dictionaryFontSize.toString(),
    resetValue: appModel.defaultDictionaryFontSize.toString(),
    onChanged: (String value) {
      double newSize =
          double.tryParse(value) ?? appModel.defaultDictionaryFontSize;
      if (newSize.isNegative) newSize = appModel.defaultDictionaryFontSize;
      appModel.setDictionaryFontSize(newSize);
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setDictionaryFontSize(appModel.defaultDictionaryFontSize);
      settingsContext.refresh();
    },
  );
}

Widget _buildMaximumTermsField(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return _SettingsNumberField(
    title: t.maximum_terms,
    icon: Icons.format_list_numbered_outlined,
    initialValue: appModel.maximumTerms.toString(),
    resetValue: appModel.defaultMaximumDictionaryTermsInResult.toString(),
    onChanged: (String value) {
      int newAmount =
          int.tryParse(value) ?? appModel.defaultMaximumDictionaryTermsInResult;
      if (newAmount.isNegative) {
        newAmount = appModel.defaultMaximumDictionaryTermsInResult;
      }
      appModel.setMaximumTerms(newAmount);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
    onReset: () {
      appModel.setMaximumTerms(appModel.defaultMaximumDictionaryTermsInResult);
      appModel.clearDictionaryResultsCache();
      settingsContext.refresh();
    },
  );
}

class _SettingsNumberField extends StatefulWidget {
  const _SettingsNumberField({
    required this.title,
    required this.icon,
    required this.initialValue,
    required this.resetValue,
    required this.onChanged,
    required this.onReset,
    this.suffixText,
  });

  final String title;
  final IconData icon;
  final String initialValue;
  final String resetValue;
  final String? suffixText;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  @override
  State<_SettingsNumberField> createState() => _SettingsNumberFieldState();
}

class _SettingsNumberFieldState extends State<_SettingsNumberField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.title,
      icon: widget.icon,
      controlBelow: true,
      trailing: HibikiTextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        suffixText: widget.suffixText,
        suffixIcon: HibikiIconButton(
          tooltip: t.reset,
          size: 18,
          icon: Icons.undo_outlined,
          onTap: () {
            _controller.text = widget.resetValue;
            widget.onReset();
            FocusScope.of(context).unfocus();
          },
        ),
        labelText: widget.title,
        onChanged: widget.onChanged,
      ),
    );
  }
}

class _LocalAudioDatabasesRow extends StatefulWidget {
  const _LocalAudioDatabasesRow({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  State<_LocalAudioDatabasesRow> createState() =>
      _LocalAudioDatabasesRowState();
}

class _LocalAudioDatabasesRowState extends State<_LocalAudioDatabasesRow> {
  SettingsContext get settingsContext => widget.settingsContext;
  AppModel get appModel => settingsContext.appModel;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<LocalAudioDbEntry> dbs = appModel.localAudioDbs;
    return AdaptiveSettingsRow(
      title: t.local_audio_add_db,
      icon: Icons.storage_outlined,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (dbs.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
              child: Text(
                t.local_audio_not_set,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          for (int index = 0; index < dbs.length; index++)
            _buildDbTile(dbs, index),
          SizedBox(height: tokens.spacing.gap / 2),
          TextButton.icon(
            icon: Icon(
              Icons.add,
              size: Theme.of(context).textTheme.bodyMedium?.fontSize,
            ),
            label: Text(t.local_audio_add_db),
            onPressed: _pickAndAddAudioDb,
          ),
        ],
      ),
    );
  }

  Widget _buildDbTile(List<LocalAudioDbEntry> dbs, int index) {
    final LocalAudioDbEntry entry = dbs[index];
    final String label = entry.displayName.isNotEmpty
        ? entry.displayName
        : entry.path.split('/').last;
    final bool enabled = entry.enabled;
    final TextStyle? counterStyle = Theme.of(context).textTheme.bodySmall;

    return AdaptiveSettingsRow(
      title: label,
      icon: enabled ? Icons.storage_outlined : Icons.block,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('${index + 1}', style: counterStyle),
          HibikiIconButton(
            tooltip: enabled ? t.options_hide : t.options_show,
            size: 18,
            icon: enabled ? Icons.check_circle_outline : Icons.block,
            onTap: () async {
              await appModel.toggleLocalAudioDbEnabled(index);
              _refresh();
            },
          ),
          if (index > 0)
            HibikiIconButton(
              tooltip: t.increase,
              size: 18,
              icon: Icons.arrow_upward_outlined,
              onTap: () async {
                await appModel.reorderLocalAudioDbs(index, index - 1);
                _refresh();
              },
            ),
          if (index < dbs.length - 1)
            HibikiIconButton(
              tooltip: t.decrease,
              size: 18,
              icon: Icons.arrow_downward_outlined,
              onTap: () async {
                await appModel.reorderLocalAudioDbs(index, index + 2);
                _refresh();
              },
            ),
          HibikiIconButton(
            tooltip: t.dialog_delete,
            size: 18,
            icon: Icons.delete_outline,
            onTap: () => _confirmRemove(index, label),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(int index, String label) async {
    final bool confirmed = await showSettingsConfirmationDialog(
      settingsContext,
      title: t.dialog_delete,
      body: label,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await appModel.removeLocalAudioDb(index);
    _refresh();
  }

  Future<void> _pickAndAddAudioDb() async {
    bool importDialogShown = false;

    void showImportDialog() {
      if (importDialogShown || !mounted) return;
      importDialogShown = true;
      showSettingsProgressDialog(
        settingsContext,
        message: t.dialog_importing,
      );
    }

    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        onFileLoading: (FilePickerStatus status) {
          if (status == FilePickerStatus.picking) showImportDialog();
        },
      );
      if (result != null && result.files.single.path != null && mounted) {
        final PlatformFile file = result.files.single;
        showImportDialog();
        await appModel.addLocalAudioDb(
          file.path!,
          displayName: file.name,
        );
        _refresh();
      }
    } finally {
      if (importDialogShown && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
    settingsContext.refresh();
  }
}

String get customFontsTitlePlaceholder => t.custom_fonts;
