import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_bundle.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_host_feature.dart';
import 'package:fushi/utils.dart';

/// 扩展设置页的一项开关：存储键、缺省值、文案键（扩展自己的界面字典）。
typedef WebBrowserExtensionSwitch = ({String key, bool fallback, String label});

/// 「Fushi 字幕」总开关的复合语义（与扩展 player-controls.js `overlayToggleWrite` 同义）：
/// 显示开 = 覆盖层开 **且** 字幕能力总门（`netflixSubtitlePanel`，缺省关）开。
const String kWebBrowserExtensionOverlayKey = 'subtitleOverlayEnabled';
const String kWebBrowserExtensionGateKey = 'netflixSubtitlePanel';

/// 设置页列出的其余开关（与扩展设置页 / 播放器菜单同键同缺省；文案沿用扩展字典，
/// 同一个开关在扩展与 app 里叫同一个名字）。
const List<WebBrowserExtensionSwitch>
kWebBrowserExtensionSwitches = <WebBrowserExtensionSwitch>[
  (
    key: 'subtitleReplaceNative',
    fallback: false,
    label: 'opt_subtitleReplaceNative_title',
  ),
  (
    key: 'subtitleOverlayAllTracks',
    fallback: false,
    label: 'opt_subtitleOverlayAllTracks_title',
  ),
  (
    key: 'subtitleOverlayBackground',
    fallback: true,
    label: 'opt_subtitleOverlayBackground_title',
  ),
  (
    key: 'subtitleOverlayAutoLookup',
    fallback: false,
    label: 'opt_subtitleOverlayAutoLookup_title',
  ),
  (
    key: 'subtitleOverlayBlur',
    fallback: false,
    label: 'opt_subtitleOverlayBlur_title',
  ),
  (key: 'subtitleHidden', fallback: false, label: 'opt_subtitleHidden_title'),
  (
    key: 'subtitlePauseOnLookup',
    fallback: true,
    label: 'opt_subtitlePauseOnLookup_title',
  ),
  (key: 'studyTrackVideo', fallback: true, label: 'opt_studyTrackVideo_title'),
  (key: 'playerControls', fallback: true, label: 'opt_playerControls_title'),
];

/// 解析扩展的英文源字典 `locales/en.js`（对象字面量，`key: '…',` 一行一条）。
Map<String, String> parseWebBrowserExtensionEnglishLocale(String source) {
  final Map<String, String> out = <String, String>{};
  final RegExp line = RegExp(
    r"^\s*([A-Za-z0-9_]+):\s*'((?:[^'\\]|\\.)*)',?\s*$",
    multiLine: true,
  );
  for (final RegExpMatch m in line.allMatches(source)) {
    out[m.group(1)!] = m
        .group(2)!
        .replaceAllMapped(RegExp(r'\\(.)'), (Match e) => e.group(1)!);
  }
  return out;
}

/// 读扩展界面字典：app 当前语言的 `locales/<tag>.json`，缺的键回落英文源字典。
Future<Map<String, String>> loadWebBrowserExtensionStrings({
  String? languageTag,
  Future<String> Function(String asset)? loadString,
}) async {
  final Future<String> Function(String) load =
      loadString ?? rootBundle.loadString;
  final Map<String, String> out = <String, String>{};
  try {
    out.addAll(
      parseWebBrowserExtensionEnglishLocale(
        await load('${kWebBrowserExtensionRoot}locales/en.js'),
      ),
    );
  } catch (_) {
    // 没有英文字典：文案退回键名。
  }
  final String tag = languageTag ?? LocaleSettings.currentLocale.languageTag;
  if (tag != 'en') {
    try {
      final Object? decoded = jsonDecode(
        await load('${kWebBrowserExtensionRoot}locales/$tag.json'),
      );
      if (decoded is Map<String, dynamic>) {
        for (final MapEntry<String, dynamic> e in decoded.entries) {
          if (e.value is String) out[e.key] = e.value as String;
        }
      }
    } catch (_) {
      // 该语言没有扩展字典：用英文。
    }
  }
  return out;
}

/// 应用内浏览器的「扩展设置」：扩展播放器菜单里「扩展设置」打开它。列出网页视频字幕与
/// 查词的关键开关，读写与页内扩展脚本同一份存储（改了立即推给打开着的页面）。字幕样式
/// （字号 / 颜色 / 底板……）在播放器菜单的「字幕样式」子页里就地调。
class WebBrowserExtensionSettingsPage extends StatefulWidget {
  const WebBrowserExtensionSettingsPage({
    required this.feature,
    super.key,
    this.loadStrings,
  });

  final WebBrowserExtensionHostFeature feature;

  /// 测试注入：扩展界面字典。
  final Future<Map<String, String>> Function()? loadStrings;

  @override
  State<WebBrowserExtensionSettingsPage> createState() =>
      _WebBrowserExtensionSettingsPageState();
}

class _WebBrowserExtensionSettingsPageState
    extends State<WebBrowserExtensionSettingsPage> {
  Map<String, String> _strings = const <String, String>{};
  late Map<String, Object?> _values;

  @override
  void initState() {
    super.initState();
    _values = widget.feature.readStorage(null);
    unawaited(() async {
      final Map<String, String> s =
          await (widget.loadStrings ?? loadWebBrowserExtensionStrings)();
      if (mounted) setState(() => _strings = s);
    }());
  }

  String _tr(String key) => _strings[key] ?? key;

  bool _bool(String key, bool fallback) {
    final Object? v = _values[key];
    return v is bool ? v : fallback;
  }

  Future<void> _write(Map<String, Object?> items) async {
    setState(() => _values = <String, Object?>{..._values, ...items});
    await widget.feature.setStorage(items);
  }

  @override
  Widget build(BuildContext context) {
    final bool overlayOn =
        _bool(kWebBrowserExtensionOverlayKey, true) &&
        _bool(kWebBrowserExtensionGateKey, false);
    return AdaptiveSettingsScaffold(
      title: Text(_tr('sp_settings_title')),
      children: <Widget>[
        AdaptiveSettingsSection(
          title: _tr('opt_group_subtitle'),
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              title: _tr('ap_hp_overlay_toggle_label'),
              value: overlayOn,
              onChanged: (bool on) => unawaited(
                _write(
                  on
                      ? <String, Object?>{
                          kWebBrowserExtensionOverlayKey: true,
                          kWebBrowserExtensionGateKey: true,
                        }
                      : <String, Object?>{
                          kWebBrowserExtensionOverlayKey: false,
                        },
                ),
              ),
            ),
            for (final WebBrowserExtensionSwitch s
                in kWebBrowserExtensionSwitches)
              AdaptiveSettingsSwitchRow(
                title: _tr(s.label),
                value: _bool(s.key, s.fallback),
                onChanged: (bool on) =>
                    unawaited(_write(<String, Object?>{s.key: on})),
              ),
          ],
        ),
      ],
    );
  }
}
