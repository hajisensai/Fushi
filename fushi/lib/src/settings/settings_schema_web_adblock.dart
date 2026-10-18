import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

/// 「系统 › 网页广告拦截」分组：总开关、订阅列表、立即更新、白名单。
///
/// 行的值都是偏好（经 AppModel 读写）；状态副标题读 [WebAdblockService]，经
/// [SettingsSection.liveListenable] 订阅它，加载 / 更新进度只重建本分组。
SettingsSection buildWebAdblockSection() {
  return SettingsSection(
    id: 'system.section.web_adblock',
    presentation: SettingsSectionPresentation.collapsed,
    title: t.web_adblock_section_title,
    liveListenable: (SettingsContext c) =>
        c.ref.read(webAdblockServiceProvider),
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'system.web_adblock_enabled',
        title: t.web_adblock_enabled,
        subtitle: t.web_adblock_enabled_hint,
        subtitleBuilder: (SettingsContext c) =>
            c.ref.read(webAdblockServiceProvider).isNativeAvailable
            ? null
            : t.web_adblock_unavailable,
        icon: FushiIcons.block,
        defaultValue: true,
        value: (SettingsContext c) => c.appModel.webAdblockEnabled,
        onChanged: (SettingsContext c, bool value) async {
          await c.appModel.setWebAdblockEnabled(value);
          if (value) {
            unawaited(c.ref.read(webAdblockServiceProvider).ensureLoaded());
          }
          c.refresh();
        },
      ),
      for (final AdblockFilterList list in kDefaultAdblockFilterLists)
        SettingsSwitchItem(
          id: 'system.web_adblock_list.${list.id}',
          // 列表官方名，不翻译。
          title: list.title,
          subtitle: list.url.host,
          icon: FushiIcons.filterList,
          defaultValue: list.defaultEnabled,
          visible: (SettingsContext c) => c.appModel.webAdblockEnabled,
          value: (SettingsContext c) =>
              c.appModel.webAdblockListIds.contains(list.id),
          onChanged: (SettingsContext c, bool value) async {
            final List<String> ids = <String>[
              for (final AdblockFilterList l in kDefaultAdblockFilterLists)
                if (l.id == list.id
                    ? value
                    : c.appModel.webAdblockListIds.contains(l.id))
                  l.id,
            ];
            await c.appModel.setWebAdblockListIds(ids);
            unawaited(c.ref.read(webAdblockServiceProvider).reload());
            c.refresh();
          },
        ),
      SettingsActionItem(
        id: 'system.web_adblock_update_now',
        title: t.web_adblock_update_now,
        icon: FushiIcons.refresh,
        visible: (SettingsContext c) => c.appModel.webAdblockEnabled,
        subtitleBuilder: _statusSubtitle,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async =>
              c.ref.read(webAdblockServiceProvider).updateNow(),
        ),
        onTap: (SettingsContext c) async {
          final bool ok = await c.ref
              .read(webAdblockServiceProvider)
              .updateNow();
          final BuildContext ctx = c.context;
          if (!ctx.mounted) return;
          ScaffoldMessenger.of(ctx).showSnackBar(
            FushiSnackBar(
              content: Text(
                ok ? t.web_adblock_update_done : t.web_adblock_update_failed,
              ),
            ),
          );
        },
      ),
      SettingsTextItem(
        id: 'system.web_adblock_allowlist',
        title: t.web_adblock_allowlist,
        subtitle: t.web_adblock_allowlist_hint,
        icon: FushiIcons.verified,
        placeholder: 'example.com, example.org',
        keyboardType: TextInputType.url,
        visible: (SettingsContext c) => c.appModel.webAdblockEnabled,
        value: (SettingsContext c) => c.appModel.webAdblockAllowlist,
        onChanged: (SettingsContext c, String value) =>
            c.appModel.setWebAdblockAllowlist(value.trim()),
      ),
    ],
  );
}

String? _statusSubtitle(SettingsContext c) {
  final WebAdblockService service = c.ref.read(webAdblockServiceProvider);
  switch (service.status) {
    case WebAdblockStatus.unavailable:
      return t.web_adblock_unavailable;
    case WebAdblockStatus.loading:
      return t.web_adblock_status_loading;
    case WebAdblockStatus.failed:
      return t.web_adblock_status_failed;
    case WebAdblockStatus.idle:
    case WebAdblockStatus.ready:
      final DateTime? at = service.lastUpdatedAt;
      if (at == null) return t.web_adblock_status_never;
      return t.web_adblock_status_updated(time: _formatLocal(at));
  }
}

String _formatLocal(DateTime at) {
  final DateTime l = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
