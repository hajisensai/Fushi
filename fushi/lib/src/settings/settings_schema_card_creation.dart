import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

SettingsDestination buildCardCreationDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.cardCreation,
    title: t.settings_destination_card_creation,
    summary: t.anki_settings_label,
    icon: Icons.style_outlined,
    // 平铺：原本「Anki 设置」是一层独立路由子页、和「自动添加书名到标签」开关并列；
    // 现在整段 Anki 正文（含该开关，见 AnkiSettingsBody 页尾）直接平铺进本页，点一次
    // 就看到全部 Anki 配置，不再多跳一层。
    sections: const <SettingsSection>[],
    body: (_) => const AnkiSettingsBody(),
    // body 正文不走 sections，设置搜索索引器看不见其中的行；在此登记
    // AnkiSettingsBody 的主要设置行（标题与正文行同一 i18n 文案），让「牌组 /
    // 字段映射 / 音频质量」等能被搜到并跳转到本分类。快捷键页 / 应用图标页已有
    // 可搜的导航行入口，不在此重复。
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'card_creation.anki.profile',
        title: t.profile_label,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.fetch',
        title: t.anki_fetch,
        subtitle: t.anki_refresh_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.create_lapis',
        title: t.anki_create_lapis,
        subtitle: t.anki_create_lapis_hint,
      ),
      // AnkiConnect 连接参数只在非 Android 平台渲染（Android 走 AnkiDroid），
      // 搜索可见性与渲染同门控。
      SettingsBodySearchEntry(
        id: 'card_creation.anki.connect_host',
        title: t.anki_connect_host,
        subtitle: 'AnkiConnect',
        visible: (SettingsContext c) => !Platform.isAndroid,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.connect_port',
        title: t.anki_connect_port,
        subtitle: 'AnkiConnect',
        visible: (SettingsContext c) => !Platform.isAndroid,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.connect_api_key',
        title: t.anki_connect_api_key,
        subtitle: 'AnkiConnect',
        visible: (SettingsContext c) => !Platform.isAndroid,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.deck',
        title: t.anki_deck,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.note_type',
        title: t.anki_note_type,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.field_mappings',
        title: t.anki_field_mappings,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.allow_duplicates',
        title: t.anki_allow_duplicates,
        subtitle: t.anki_allow_duplicates_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.overwrite_scope',
        title: t.anki_overwrite_scope,
        subtitle: t.anki_overwrite_scope_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.compact_glossaries',
        title: t.anki_compact_glossaries,
        subtitle: t.anki_compact_glossaries_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tags',
        title: t.anki_tags,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_include_hibiki',
        title: t.anki_tag_include_fushi,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_include_category',
        title: t.anki_tag_include_category,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.tag_book_name',
        title: t.auto_add_book_name_to_tags,
        subtitle: t.anki_tag_default_section,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.mining_image_quality',
        title: t.mining_image_quality,
        subtitle: t.mining_image_quality_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.mining_audio_quality',
        title: t.mining_audio_quality,
        subtitle: t.mining_audio_quality_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.video_mining_image_mode',
        title: t.video_mining_image_mode,
        subtitle: t.video_mining_image_mode_hint,
      ),
      SettingsBodySearchEntry(
        id: 'card_creation.anki.video_mining_still_format',
        title: t.video_mining_still_format,
        subtitle: t.video_mining_still_format_hint,
      ),
    ],
  );
}
