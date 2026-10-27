import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';

/// 网页申请的平台权限资源 → 按站点记住的权限种类。认不出的资源（MIDI、传感器……）
/// 返回 null，一律拒绝，不弹框。
WebBrowserSitePermission? webBrowserSitePermissionFor(
  PermissionResourceType resource,
) {
  if (resource == PermissionResourceType.CAMERA) {
    return WebBrowserSitePermission.camera;
  }
  if (resource == PermissionResourceType.MICROPHONE) {
    return WebBrowserSitePermission.microphone;
  }
  if (resource == PermissionResourceType.GEOLOCATION) {
    return WebBrowserSitePermission.geolocation;
  }
  if (resource == PermissionResourceType.NOTIFICATIONS) {
    return WebBrowserSitePermission.notifications;
  }
  if (resource == PermissionResourceType.CLIPBOARD_READ) {
    return WebBrowserSitePermission.clipboard;
  }
  // Android WebView 起播 Widevine（EME `requestMediaKeySystemAccess`）前申请的资源；
  // 拒了站点就拿不到许可证，加密视频整段放不了。
  if (resource == PermissionResourceType.PROTECTED_MEDIA_ID) {
    return WebBrowserSitePermission.protectedContent;
  }
  return null;
}

/// 一次申请里涉及的权限种类（`CAMERA_AND_MICROPHONE` 拆成两项）。含认不出的资源时
/// 返回 null（整条拒绝）。
List<WebBrowserSitePermission>? webBrowserSitePermissionsFor(
  List<PermissionResourceType> resources,
) {
  final List<WebBrowserSitePermission> out = <WebBrowserSitePermission>[];
  for (final PermissionResourceType r in resources) {
    if (r == PermissionResourceType.CAMERA_AND_MICROPHONE) {
      out
        ..add(WebBrowserSitePermission.camera)
        ..add(WebBrowserSitePermission.microphone);
      continue;
    }
    final WebBrowserSitePermission? p = webBrowserSitePermissionFor(r);
    if (p == null) return null;
    if (!out.contains(p)) out.add(p);
  }
  return out.isEmpty ? null : out;
}

/// 合并各项已记住的决定：任一项被阻止 → 阻止；全部允许 → 允许；否则要问。
WebBrowserPermissionDecision combineWebBrowserPermissionDecisions(
  Iterable<WebBrowserPermissionDecision> decisions,
) {
  bool allAllowed = true;
  for (final WebBrowserPermissionDecision d in decisions) {
    if (d == WebBrowserPermissionDecision.block) {
      return WebBrowserPermissionDecision.block;
    }
    if (d != WebBrowserPermissionDecision.allow) allAllowed = false;
  }
  return allAllowed
      ? WebBrowserPermissionDecision.allow
      : WebBrowserPermissionDecision.ask;
}

String _labelFor(List<WebBrowserSitePermission> permissions) {
  final Set<WebBrowserSitePermission> set = permissions.toSet();
  if (set.length == 2 &&
      set.contains(WebBrowserSitePermission.camera) &&
      set.contains(WebBrowserSitePermission.microphone)) {
    return t.web_browser_permission_request_camera_microphone;
  }
  return permissions
      .map(
        (WebBrowserSitePermission p) => switch (p) {
          WebBrowserSitePermission.camera =>
            t.web_browser_permission_request_camera,
          WebBrowserSitePermission.microphone =>
            t.web_browser_permission_request_microphone,
          WebBrowserSitePermission.geolocation =>
            t.web_browser_permission_request_geolocation,
          WebBrowserSitePermission.notifications =>
            t.web_browser_permission_request_notifications,
          WebBrowserSitePermission.clipboard =>
            t.web_browser_permission_request_clipboard,
          WebBrowserSitePermission.protectedContent =>
            t.web_browser_permission_request_protected_content,
          WebBrowserSitePermission.autoplay ||
          WebBrowserSitePermission.popups => p.name,
        },
      )
      .join(', ');
}

IconData _iconFor(List<WebBrowserSitePermission> permissions) =>
    switch (permissions.first) {
      WebBrowserSitePermission.camera => FushiIcons.camera,
      WebBrowserSitePermission.microphone => FushiIcons.mic,
      WebBrowserSitePermission.geolocation => FushiIcons.myLocation,
      WebBrowserSitePermission.notifications => FushiIcons.notifications,
      WebBrowserSitePermission.clipboard => FushiIcons.paste,
      _ => FushiIcons.lock,
    };

/// 网页层允许之后还要的**系统**运行时权限（app 自己没有，WebView 拿不到设备）。
///
/// 只有 Android 需要 app 先拿到：WebView 的 `PermissionRequest.grant` 只是网页层
/// 授权，app 没有 `CAMERA` / `RECORD_AUDIO` 时 getUserMedia 照样失败。iOS 的
/// WKWebView 自己按 Info.plist 的用途说明弹系统框，桌面由 WebView2 / WebKit 管。
/// 其它种类（定位、通知……）不在这条链路上申请。
List<Permission> webBrowserSystemPermissionsFor(
  List<WebBrowserSitePermission> permissions, {
  required TargetPlatform platform,
}) {
  if (platform != TargetPlatform.android) return const <Permission>[];
  return <Permission>[
    if (permissions.contains(WebBrowserSitePermission.camera))
      Permission.camera,
    if (permissions.contains(WebBrowserSitePermission.microphone))
      Permission.microphone,
  ];
}

/// 一次申请若干系统权限，返回各自的结果。默认走 permission_handler（一次合并申请：
/// 它同一时刻只允许一个在途申请）。
typedef WebBrowserSystemPermissionRequester =
    Future<Map<Permission, PermissionStatus>> Function(List<Permission>);

Future<Map<Permission, PermissionStatus>> _requestSystemPermissions(
  List<Permission> permissions,
) => permissions.request();

/// 网页层允许后补齐系统权限：已有的直接过，没有的弹系统框；任一项没给（拒绝 /
/// 永久拒绝 / 受限）就整条拒绝，网页收到 NotAllowedError。
Future<bool> ensureWebBrowserSystemPermissions(
  List<WebBrowserSitePermission> permissions, {
  required TargetPlatform platform,
  WebBrowserSystemPermissionRequester request = _requestSystemPermissions,
}) async {
  final List<Permission> needed = webBrowserSystemPermissionsFor(
    permissions,
    platform: platform,
  );
  if (needed.isEmpty) return true;
  try {
    final Map<Permission, PermissionStatus> result = await request(needed);
    return needed.every((Permission p) => result[p]?.isGranted ?? false);
  } on Object {
    // 在途申请冲突 / 插件不可用：拿不到系统权限就不能假装允许。
    return false;
  }
}

/// 按站点设置决定一次权限申请；记住的直接答，没记住的弹「允许 / 阻止 / 记住」框。
/// 返回是否允许。
Future<bool> resolveWebBrowserPermission({
  required BuildContext context,
  required WebBrowserSiteSettings settings,
  required String origin,
  required List<WebBrowserSitePermission> permissions,
}) async {
  final WebBrowserPermissionDecision remembered =
      combineWebBrowserPermissionDecisions(
        permissions.map(
          (WebBrowserSitePermission p) =>
              webBrowserEffectiveDecision(p, settings.decision(origin, p)),
        ),
      );
  switch (remembered) {
    case WebBrowserPermissionDecision.allow:
      return true;
    case WebBrowserPermissionDecision.block:
      return false;
    case WebBrowserPermissionDecision.ask:
      break;
  }
  if (!context.mounted) return false;
  final ({bool allow, bool remember})? answer = await _askPermission(
    context,
    site: Uri.tryParse(origin)?.host ?? origin,
    permissions: permissions,
  );
  if (answer == null) return false;
  if (answer.remember) {
    final WebBrowserPermissionDecision decision = answer.allow
        ? WebBrowserPermissionDecision.allow
        : WebBrowserPermissionDecision.block;
    for (final WebBrowserSitePermission p in permissions) {
      await settings.setDecision(origin, p, decision);
    }
  }
  return answer.allow;
}

Future<({bool allow, bool remember})?> _askPermission(
  BuildContext context, {
  required String site,
  required List<WebBrowserSitePermission> permissions,
}) {
  bool remember = false;
  return showAppDialog<({bool allow, bool remember})>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => FushiAlertDialog(
        icon: FushiDialogHeroIcon(icon: _iconFor(permissions)),
        title: Text(
          t.web_browser_permission_request_title(
            site: site,
            what: _labelFor(permissions),
          ),
        ),
        content: FushiCheckboxListTile(
          key: const ValueKey<String>('web-browser-permission-remember'),
          value: remember,
          contentPadding: EdgeInsets.zero,
          title: Text(t.web_browser_permission_request_remember),
          onChanged: (bool? value) => setState(() => remember = value ?? false),
        ),
        actions: <Widget>[
          FushiDialogAction(
            key: const ValueKey<String>('web-browser-permission-block'),
            label: t.web_browser_permission_request_block,
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop((allow: false, remember: remember)),
          ),
          FushiDialogAction(
            key: const ValueKey<String>('web-browser-permission-allow'),
            label: t.web_browser_permission_request_allow,
            kind: FushiDialogActionKind.primary,
            autofocus: true,
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop((allow: true, remember: remember)),
          ),
        ],
      ),
    ),
  );
}
