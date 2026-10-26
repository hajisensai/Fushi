import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/utils.dart';

/// 权限的显示名。
String webBrowserSitePermissionLabel(WebBrowserSitePermission p) => switch (p) {
  WebBrowserSitePermission.camera => t.web_browser_permission_camera,
  WebBrowserSitePermission.microphone => t.web_browser_permission_microphone,
  WebBrowserSitePermission.geolocation => t.web_browser_permission_geolocation,
  WebBrowserSitePermission.notifications =>
    t.web_browser_permission_notifications,
  WebBrowserSitePermission.clipboard => t.web_browser_permission_clipboard,
  WebBrowserSitePermission.protectedContent =>
    t.web_browser_permission_protected_content,
  WebBrowserSitePermission.autoplay => t.web_browser_permission_autoplay,
  WebBrowserSitePermission.popups => t.web_browser_permission_popups,
};

IconData webBrowserSitePermissionIcon(WebBrowserSitePermission p) =>
    switch (p) {
      WebBrowserSitePermission.camera => FushiIcons.camera,
      WebBrowserSitePermission.microphone => FushiIcons.mic,
      WebBrowserSitePermission.geolocation => FushiIcons.pin,
      WebBrowserSitePermission.notifications => FushiIcons.notifications,
      WebBrowserSitePermission.clipboard => FushiIcons.paste,
      WebBrowserSitePermission.protectedContent => FushiIcons.lock,
      WebBrowserSitePermission.autoplay => FushiIcons.playCircle,
      WebBrowserSitePermission.popups => FushiIcons.openInNew,
    };

/// 决定的显示名。
String webBrowserPermissionDecisionLabel(
  WebBrowserPermissionDecision d,
) => switch (d) {
  WebBrowserPermissionDecision.ask => t.web_browser_permission_ask,
  WebBrowserPermissionDecision.allow => t.web_browser_permission_request_allow,
  WebBrowserPermissionDecision.block => t.web_browser_permission_request_block,
};

/// 网站设置：按站点列出记住的权限决定，可改、可按站点重置、可全部重置。
class WebBrowserSiteSettingsPage extends StatefulWidget {
  const WebBrowserSiteSettingsPage({required this.settings, super.key});

  final WebBrowserSiteSettings settings;

  @override
  State<WebBrowserSiteSettingsPage> createState() =>
      _WebBrowserSiteSettingsPageState();
}

class _WebBrowserSiteSettingsPageState
    extends State<WebBrowserSiteSettingsPage> {
  late Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>
  _sites = widget.settings.all();

  void _refresh() => setState(() => _sites = widget.settings.all());

  Future<void> _change(String origin, WebBrowserSitePermission p) async {
    final WebBrowserPermissionDecision current = widget.settings.decision(
      origin,
      p,
    );
    final WebBrowserPermissionDecision? next =
        await showFushiChoiceDialog<WebBrowserPermissionDecision>(
          context: context,
          title: webBrowserSitePermissionLabel(p),
          message: origin,
          icon: webBrowserSitePermissionIcon(p),
          selected: current,
          options: <FushiChoiceOption<WebBrowserPermissionDecision>>[
            for (final WebBrowserPermissionDecision d
                in WebBrowserPermissionDecision.values)
              FushiChoiceOption<WebBrowserPermissionDecision>(
                value: d,
                label: webBrowserPermissionDecisionLabel(d),
              ),
          ],
        );
    if (next == null || next == current) return;
    await widget.settings.setDecision(origin, p, next);
    if (mounted) _refresh();
  }

  Future<void> _clearSite(String origin) async {
    await widget.settings.clearSite(origin);
    if (mounted) _refresh();
  }

  Future<void> _clearAll() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.web_browser_site_settings_clear_all_confirm,
      icon: FushiIcons.deleteSweep,
      confirmLabel: t.reset,
      destructive: true,
    );
    if (!ok) return;
    await widget.settings.clearAll();
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> origins = _sites.keys.toList();
    return FushiPageScaffold(
      title: t.web_browser_site_settings_title,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('web_browser_site_settings_clear_all'),
          icon: FushiIcons.deleteSweep,
          tooltip: t.web_browser_site_settings_clear_all,
          enabled: origins.isNotEmpty,
          onTap: () => unawaited(_clearAll()),
        ),
      ],
      body: webBrowserPageListView(
        replayKey: 0,
        key: const ValueKey<String>('web_browser_site_settings_list'),
        children: <Widget>[
          if (origins.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: Text(t.web_browser_site_settings_empty)),
            ),
          for (int i = 0; i < origins.length; i++) ...<Widget>[
            FushiSectionTitle.group(
              origins[i],
              padding: const EdgeInsets.fromLTRB(32, 16, 16, 6),
              trailing: FushiTextButton(
                key: ValueKey<String>(
                  'web_browser_site_settings_clear_${origins[i]}',
                ),
                onPressed: () => unawaited(_clearSite(origins[i])),
                child: Text(t.web_browser_site_settings_clear_site),
              ),
            ),
            FushiStaggeredEntrance(
              index: i,
              child: FushiGroupedList(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: <Widget>[
                  for (final WebBrowserSitePermission p
                      in WebBrowserSitePermission.values)
                    FushiListItem(
                      key: ValueKey<String>(
                        'web_browser_site_settings_${origins[i]}_${p.name}',
                      ),
                      leading: FushiListLeadingIcon(
                        webBrowserSitePermissionIcon(p),
                      ),
                      title: Text(webBrowserSitePermissionLabel(p)),
                      subtitle: Text(
                        // 显示生效的决定：受保护内容没记住时实际是允许，别写成「询问」。
                        webBrowserPermissionDecisionLabel(
                          webBrowserEffectiveDecision(
                            p,
                            _sites[origins[i]]![p] ??
                                WebBrowserPermissionDecision.ask,
                          ),
                        ),
                      ),
                      trailing: const FushiIcon(FushiIcons.chevronRight),
                      onTap: () => unawaited(_change(origins[i], p)),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
