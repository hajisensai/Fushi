import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

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
  );
}
