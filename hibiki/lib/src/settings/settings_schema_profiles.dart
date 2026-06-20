import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildProfilesDestination() {
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
        ],
      ),
    ],
    // 平铺：原本「配置管理」是一层独立路由子页，现在把其正文直接接在「配置」快速
    // 选择器下方，点一次设置就能管理 Profile，不再多跳一层。
    body: (_) => const ProfileManagementBody(),
  );
}
