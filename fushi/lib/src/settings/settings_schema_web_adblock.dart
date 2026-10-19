import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_browser/web_module_capabilities.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

/// 内置过滤列表目录（Rust 给，进程内只取一次）。
final List<AdblockCatalogEntry> _catalog = AdblockCore.catalog();

/// 「系统 › 网页广告拦截」分组：总开关、订阅列表、立即更新、白名单。
///
/// 状态全在 Rust 核心里（订阅集、开关、白名单、列表缓存），这里**只渲染**
/// [WebAdblockService.snapshot]、把用户操作转成命令；经 [SettingsSection.liveListenable]
/// 订阅服务，快照一变只重建本分组。
SettingsSection buildWebAdblockSection() {
  WebAdblockService service(SettingsContext c) =>
      c.ref.read(webAdblockServiceProvider);
  bool enabled(SettingsContext c) => service(c).snapshot.enabled;
  return SettingsSection(
    id: 'system.section.web_adblock',
    presentation: SettingsSectionPresentation.collapsed,
    title: t.web_adblock_section_title,
    liveListenable: service,
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'system.web_adblock_enabled',
        title: t.web_adblock_enabled,
        // 只列本平台真有的网页浏览场景（iOS 没有网页漫画 / 小说，视频站点只在 Windows）。
        subtitle: webAdblockEnabledHint(WebModuleCapabilities.current()),
        icon: FushiIcons.block,
        defaultValue: true,
        value: enabled,
        onChanged: (SettingsContext c, bool value) async {
          await service(c).setEnabled(value);
          c.refresh();
        },
      ),
      for (final AdblockCatalogEntry list in _catalog)
        SettingsSwitchItem(
          id: 'system.web_adblock_list.${list.id}',
          // 列表官方名，不翻译。
          title: list.title,
          subtitle: list.host,
          icon: FushiIcons.filterList,
          defaultValue: list.defaultEnabled,
          visible: enabled,
          value: (SettingsContext c) =>
              service(c).snapshot.isListEnabled(list.id),
          onChanged: (SettingsContext c, bool value) async {
            unawaited(service(c).setListEnabled(list.id, value));
            c.refresh();
          },
        ),
      SettingsActionItem(
        id: 'system.web_adblock_update_now',
        title: t.web_adblock_update_now,
        icon: FushiIcons.refresh,
        visible: enabled,
        subtitleBuilder: (SettingsContext c) =>
            _statusSubtitle(service(c).snapshot),
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async =>
              service(c).updateNow(),
        ),
        onTap: (SettingsContext c) async {
          final bool ok = await service(c).updateNow();
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
        visible: enabled,
        value: (SettingsContext c) => service(c).snapshot.allowlist,
        onChanged: (SettingsContext c, String value) async =>
            service(c).setAllowlist(value.trim()),
      ),
    ],
  );
}

String _statusSubtitle(AdblockSnapshot s) {
  switch (s.status) {
    case AdblockEngineStatus.loading:
      return t.web_adblock_status_loading;
    case AdblockEngineStatus.failed:
      return t.web_adblock_status_failed;
    case AdblockEngineStatus.idle:
    case AdblockEngineStatus.ready:
      final DateTime? at = s.lastUpdatedAt;
      if (at == null) return t.web_adblock_status_never;
      return t.web_adblock_status_updated(time: _formatLocal(at));
  }
}

String _formatLocal(DateTime at) {
  final DateTime l = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}
