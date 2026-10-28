import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/settings/overlay_color_setting_item.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage_provider.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
import 'package:fushi/utils.dart';

// 「浏览器设置」里扩展的那几组：查词 / 字幕 / 字幕外观 / 外观 / 快捷键 / 沉浸时间。
//
// 应用内浏览器每个标签页里跑的就是浏览器扩展自己的页内脚本，`chrome.storage` 落在
// [WebBrowserExtensionStorage]。所以这里的每一项：键名、取值、缺省值都以扩展为准
// （`tools/browser-extension/options.js` 的 settingDefaults / selectSettings、
// `subtitle-style.js` 的 DEFAULTS / LIMITS、`video-shortcuts.js` 的 DEFAULT_COMBOS），
// 文案直接用扩展自己的界面字典（[WebBrowserExtensionStrings]），控件类型与扩展设置页一致。
// 写入经共享存储实例广播给所有打开着的标签页（页内脚本的 storage.onChanged 立即生效）。
//
// 扩展设置页里**在 app 内没有意义**的项不在这里（见 [kWebBrowserExtensionOmittedSettings]）。

/// 扩展设置页里刻意不搬进 app 的项 → 原因（守卫测试据此核对「每一项都有去处」）。
const Map<String, String> kWebBrowserExtensionOmittedSettings =
    <String, String>{
      'host / port / token':
          '连接 Fushi 服务器：app 内是进程内直连 FushiExtensionApiCore，没有连接要配',
      'connection status / restore auto config': '同上，没有连接状态',
      'lookupPerfPanel': '查词性能日志记录的是扩展 background 的 HTTP 查词，app 内查词不经它',
      'updateCard': '扩展自更新：app 内脚本随 app 资产更新',
      'popupFontSize': '页内查词弹窗字号覆盖：app 内查词用 app 自己的查词弹窗（字号在「查词」设置）',
      'popupSizeWidth / popupSizeHeight': '同上，弹窗尺寸本就是 app 偏好（「查词」设置）',
      'touchLookupTap / touchLookupHold':
          'touch-lookup.js 不装进 app 宿主（网页正文取词由宿主自己的取词脚本负责）',
      'mobileSubtitleDrawer': 'mobile-drawer.js 不装进 app 宿主（字幕列表是 app 原生侧栏）',
      'subtitleLookupOnPage':
          '扩展 Side Panel 是浏览器的独立窗口、面板内弹窗只能有面板那么宽，才要把查词交给网页渲染；'
          'app 原生侧栏点词用的是 app 查词弹窗（不受侧栏宽度限制），没有这层取舍',
      'subtitleFontLibrary': '字体库下载列表（后续再接；已下载字体若被选中仍会列在字体下拉里）',
      'extensionStyle': '界面风格（M3E / 液态玻璃）：app 内跟随 Fushi 的设计系统，宿主把它算成只读键',
      'customThemeEditor': '自定义配色编辑器（后续再接；已有自定义主题可在配色主题里选中）',
    };

WebBrowserExtensionStorage _storage(SettingsContext c) =>
    c.ref.read(webBrowserExtensionStorageProvider);

String _x(String key, [Map<String, String>? params]) =>
    WebBrowserExtensionStrings.instance.tr(key, params);

String? _d(String key) => WebBrowserExtensionStrings.instance.plain(key);

Object? _read(SettingsContext c, String key) =>
    _storage(c).get(<String>[key])[key];

bool _readBool(SettingsContext c, String key, bool fallback) {
  final Object? v = _read(c, key);
  return v is bool ? v : fallback;
}

String _readString(SettingsContext c, String key, String fallback) {
  final Object? v = _read(c, key);
  return v is String && v.isNotEmpty ? v : fallback;
}

Future<void> _write(SettingsContext c, Map<String, Object?> items) async {
  await _storage(c).set(items);
  c.refresh();
}

Future<void> _remove(SettingsContext c, List<String> keys) async {
  await _storage(c).remove(keys);
  c.refresh();
}

/// 扩展组的分组：订阅共享存储，页内脚本 / 播放器菜单改了值，本组就地重画。
SettingsSection _section({
  required String id,
  required List<SettingsItem> items,
  String? title,
}) => SettingsSection(
  id: 'web_browser.extension.section.$id',
  title: title,
  liveListenable: _storage,
  items: items,
);

SettingsSwitchItem _switch(
  String key, {
  required bool fallback,
  required String label,
  required IconData icon,
  bool Function(SettingsContext c)? legacy,
}) => SettingsSwitchItem(
  id: 'web_browser.extension.$key',
  title: _x('${label}_title'),
  subtitle: _d('${label}_desc'),
  icon: icon,
  defaultValue: fallback,
  value: (SettingsContext c) {
    final Object? v = _read(c, key);
    if (v is bool) return v;
    return legacy?.call(c) ?? fallback;
  },
  onChanged: (SettingsContext c, bool value) =>
      _write(c, <String, Object?>{key: value}),
);

SettingsSegmentedItem<String> _choice(
  String key, {
  required String fallback,
  required String label,
  required IconData icon,
  required List<SettingsSegmentOption<String>> options,
  bool dropdown = true,
}) => SettingsSegmentedItem<String>(
  id: 'web_browser.extension.$key',
  title: _x('${label}_title'),
  subtitle: _d('${label}_desc'),
  icon: icon,
  dropdown: dropdown,
  defaultValue: fallback,
  options: options,
  selected: (SettingsContext c) {
    final String v = _readString(c, key, fallback);
    return options.any((SettingsSegmentOption<String> o) => o.value == v)
        ? v
        : fallback;
  },
  onChanged: (SettingsContext c, String value) =>
      _write(c, <String, Object?>{key: value}),
);

// ── 查词 ──────────────────────────────────────────────────────────────

SettingsDestination _lookupDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_lookup'),
  summary: _d('opt_group_lookup_desc'),
  icon: FushiIcons.search,
  sections: <SettingsSection>[
    _section(
      id: 'lookup',
      items: <SettingsItem>[
        _switch(
          'shiftHoverLookup',
          fallback: true,
          label: 'opt_shiftHoverLookup',
          icon: FushiIcons.mouse,
        ),
        // 两个键桥接 app 真源（与 app 视频页 / 阅读器同一个偏好）。
        _switch(
          'subtitlePauseOnLookup',
          fallback: true,
          label: 'opt_subtitlePauseOnLookup',
          icon: FushiIcons.pause,
        ),
        _switch(
          'subtitleResumeOnLookupLeave',
          fallback: true,
          label: 'opt_subtitleResumeOnLookupLeave',
          icon: FushiIcons.play,
        ),
        _switch(
          'subtitleOverlayAutoLookup',
          fallback: false,
          label: 'opt_subtitleOverlayAutoLookup',
          icon: FushiIcons.lookup,
        ),
      ],
    ),
  ],
);

// ── 字幕 ──────────────────────────────────────────────────────────────

/// 「Fushi 字幕」总开关的复合语义（与扩展 player-controls.js `overlayToggleWrite` 同义）：
/// 显示开 = 覆盖层开 **且** 字幕能力总门（`netflixSubtitlePanel`，缺省关）开。
const String kWebBrowserExtensionOverlayKey = 'subtitleOverlayEnabled';
const String kWebBrowserExtensionGateKey = 'netflixSubtitlePanel';

SettingsDestination _subtitleDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_subtitle'),
  summary: _d('opt_group_subtitle_desc'),
  icon: FushiIcons.subtitles,
  sections: <SettingsSection>[
    _section(
      id: 'subtitle',
      items: <SettingsItem>[
        SettingsSwitchItem(
          id: 'web_browser.extension.$kWebBrowserExtensionOverlayKey',
          title: _x('opt_subtitleOverlayEnabled_title'),
          subtitle: _d('opt_subtitleOverlayEnabled_desc'),
          icon: FushiIcons.subtitles,
          value: (SettingsContext c) =>
              _readBool(c, kWebBrowserExtensionOverlayKey, true) &&
              _readBool(c, kWebBrowserExtensionGateKey, false),
          onChanged: (SettingsContext c, bool on) => _write(
            c,
            on
                ? <String, Object?>{
                    kWebBrowserExtensionOverlayKey: true,
                    kWebBrowserExtensionGateKey: true,
                  }
                : <String, Object?>{kWebBrowserExtensionOverlayKey: false},
          ),
        ),
        _switch(
          kWebBrowserExtensionGateKey,
          fallback: false,
          label: 'opt_nfSubList',
          icon: FushiIcons.sidebar,
        ),
        _switch(
          'subtitleReplaceNative',
          fallback: false,
          label: 'opt_subtitleReplaceNative',
          icon: FushiIcons.swap,
        ),
        _switch(
          'playerControls',
          fallback: true,
          label: 'opt_playerControls',
          icon: FushiIcons.playCircle,
        ),
        _switch(
          'subtitleHidden',
          fallback: false,
          label: 'opt_subtitleHidden',
          icon: FushiIcons.subtitlesOff,
        ),
      ],
    ),
    _section(
      id: 'subtitle_more',
      title: _x('opt_more_options'),
      items: <SettingsItem>[
        _switch(
          'subtitleOverlayBlur',
          fallback: false,
          label: 'opt_subtitleOverlayBlur',
          icon: FushiIcons.blur,
        ),
        _switch(
          'subtitleOverlayAllTracks',
          fallback: false,
          label: 'opt_subtitleOverlayAllTracks',
          icon: FushiIcons.playlist,
        ),
        _switch(
          'subtitleDragDropEnabled',
          fallback: true,
          label: 'opt_subtitleDragDropEnabled',
          icon: FushiIcons.upload,
        ),
        // 页内字幕面板与 app 原生字幕侧栏共用（侧栏的「跟随」钮写的也是它）。
        _switch(
          'subtitleAutoScroll',
          fallback: true,
          label: 'opt_subtitleAutoScroll',
          icon: FushiIcons.myLocation,
        ),
        _switch(
          'netflixHideNextEpisode',
          fallback: true,
          label: 'opt_nfHideNext',
          icon: FushiIcons.visibilityOff,
        ),
        // 拖过的位置存 subtitleOverlayPosition（视频分数坐标）；删键即回默认位置。
        SettingsActionItem(
          id: 'web_browser.extension.subtitleOverlayPosition',
          title: _x('opt_resetSubtitleOverlayPosition_button'),
          subtitle: _d('opt_subtitleOverlayPosition_desc'),
          icon: FushiIcons.dragIndicator,
          cli: const SettingsCliAction.tap(),
          onTap: (SettingsContext c) =>
              _remove(c, <String>['subtitleOverlayPosition']),
        ),
      ],
    ),
  ],
);

// ── 字幕外观 ───────────────────────────────────────────────────────────

/// 扩展字幕样式（`subtitle-style.js`）的存储键：整体一个对象，只存改过的字段。
const String kWebBrowserSubtitleStyleKey = 'subtitleStyle';

/// `subtitle-style.js` 的 DEFAULTS。
const Map<String, Object> kWebBrowserSubtitleStyleDefaults = <String, Object>{
  'fontFamily': '',
  'fontScale': 100,
  'fontWeight': 600,
  'letterSpacing': 1,
  'lineHeight': 145,
  'textAlign': 'center',
  'textColor': '',
  'shadow': 'soft',
  'backgroundColor': '',
  'backgroundOpacity': 72,
  'borderRadius': 8,
  'padding': 100,
  'boxWidth': 0,
  'boxHeight': 0,
  'boxAutoFit': true,
};

/// `subtitle-style.js` 的 LIMITS（闭区间）。
const Map<String, (int, int)> kWebBrowserSubtitleStyleLimits =
    <String, (int, int)>{
      'fontScale': (50, 300),
      'fontWeight': (100, 900),
      'letterSpacing': (-5, 30),
      'lineHeight': (100, 250),
      'backgroundOpacity': (0, 100),
      'borderRadius': (0, 32),
      'padding': (0, 300),
      'boxWidth': (0, 100),
      'boxHeight': (0, 60),
    };

/// 底板宽 / 高非 0 时的下限（`subtitle-style.js` BOX_FLOOR）；0 = 随内容。
const Map<String, int> kWebBrowserSubtitleBoxFloor = <String, int>{
  'boxWidth': 20,
  'boxHeight': 5,
};

/// 字体下拉的「本机字体栈」（`subtitle-style.js` FONT_SUGGESTIONS）。
const List<String> kWebBrowserSubtitleFontSuggestions = <String>[
  '"Hiragino Sans", "Yu Gothic UI", sans-serif',
  '"Hiragino Maru Gothic ProN", "BIZ UDPGothic", "Yu Gothic UI", sans-serif',
  '"Hiragino Mincho ProN", "Yu Mincho", serif',
  '"Noto Sans JP", "Noto Sans CJK JP", sans-serif',
  '"Noto Serif JP", "Noto Serif CJK JP", serif',
  'system-ui, sans-serif',
  'sans-serif',
  'serif',
  'monospace',
];

/// 主题缺省的字幕字色 / 底板色（`subtitle-style.js` DEFAULT_TEXT_COLOR / DEFAULT_BACKGROUND_COLOR）。
const int kWebBrowserSubtitleDefaultTextColor = 0xFFF7F8F2;
const int kWebBrowserSubtitleDefaultBackgroundColor = 0xFF0C0F0D;

int _clampInt(Object? v, String field) {
  final (int lo, int hi) = kWebBrowserSubtitleStyleLimits[field]!;
  final int fallback = kWebBrowserSubtitleStyleDefaults[field]! as int;
  num? n = v is num ? v : (v is String ? num.tryParse(v) : null);
  if (n == null || !n.isFinite) return fallback;
  return n.round().clamp(lo, hi);
}

int _clampBox(Object? v, String field) {
  final int n = _clampInt(v, field);
  return n == 0
      ? 0
      : (n < kWebBrowserSubtitleBoxFloor[field]!
            ? kWebBrowserSubtitleBoxFloor[field]!
            : n);
}

String _normalizeHex(Object? v) {
  if (v is! String) return '';
  final String s = v.trim();
  final RegExpMatch? six = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(s);
  if (six != null) return '#${six.group(1)!.toLowerCase()}';
  final RegExpMatch? three = RegExp(r'^#?([0-9a-fA-F]{3})$').firstMatch(s);
  if (three == null) return '';
  final String t = three.group(1)!.toLowerCase();
  return '#${t[0]}${t[0]}${t[1]}${t[1]}${t[2]}${t[2]}';
}

String _normalizeFontFamily(Object? v) {
  if (v is! String) return '';
  final String s = v
      .replaceAll(RegExp('[^\\w\\s,"\'\\-.\u00a0-\uffff]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.length > 200 ? s.substring(0, 200) : s;
}

/// 与 `subtitle-style.js` `normalize` 同义：缺字段 / 越界 / 写歪的值一律夹回或回落默认。
Map<String, Object> normalizeWebBrowserSubtitleStyle(Object? raw) {
  final Map<Object?, Object?> c = raw is Map ? raw : const <Object?, Object?>{};
  final int weight = _clampInt(c['fontWeight'], 'fontWeight');
  final Object? align = c['textAlign'];
  final Object? shadow = c['shadow'];
  return <String, Object>{
    'fontFamily': _normalizeFontFamily(c['fontFamily']),
    'fontScale': _clampInt(c['fontScale'], 'fontScale'),
    'fontWeight': (weight / 100).round() * 100,
    'letterSpacing': _clampInt(c['letterSpacing'], 'letterSpacing'),
    'lineHeight': _clampInt(c['lineHeight'], 'lineHeight'),
    'textAlign': align == 'left' || align == 'center' || align == 'right'
        ? align! as String
        : 'center',
    'textColor': _normalizeHex(c['textColor']),
    'shadow': shadow == 'none' || shadow == 'soft' || shadow == 'strong'
        ? shadow! as String
        : 'soft',
    'backgroundColor': _normalizeHex(c['backgroundColor']),
    'backgroundOpacity': _clampInt(c['backgroundOpacity'], 'backgroundOpacity'),
    'borderRadius': _clampInt(c['borderRadius'], 'borderRadius'),
    'padding': _clampInt(c['padding'], 'padding'),
    'boxWidth': _clampBox(c['boxWidth'], 'boxWidth'),
    'boxHeight': _clampBox(c['boxHeight'], 'boxHeight'),
    'boxAutoFit': c['boxAutoFit'] != false,
  };
}

bool _isDefaultStyle(Map<String, Object> s) {
  for (final MapEntry<String, Object> e
      in kWebBrowserSubtitleStyleDefaults.entries) {
    if (s[e.key] != e.value) return false;
  }
  return true;
}

Map<String, Object> _style(SettingsContext c) =>
    normalizeWebBrowserSubtitleStyle(_read(c, kWebBrowserSubtitleStyleKey));

/// 改一个字段：规整后整体写回；回到全默认就删键（与扩展设置页同一写法）。
Future<void> writeWebBrowserSubtitleStyleField(
  WebBrowserExtensionStorage storage,
  String field,
  Object value,
) async {
  final Map<String, Object> next = normalizeWebBrowserSubtitleStyle(
    <String, Object?>{
      ...normalizeWebBrowserSubtitleStyle(
        storage.get(<String>[
          kWebBrowserSubtitleStyleKey,
        ])[kWebBrowserSubtitleStyleKey],
      ),
      field: value,
    },
  );
  if (_isDefaultStyle(next)) {
    await storage.remove(<String>[kWebBrowserSubtitleStyleKey]);
  } else {
    await storage.set(<String, Object?>{kWebBrowserSubtitleStyleKey: next});
  }
}

Future<void> _writeStyle(SettingsContext c, String field, Object value) async {
  await writeWebBrowserSubtitleStyleField(_storage(c), field, value);
  c.refresh();
}

SettingsSliderItem _styleSlider(
  String field, {
  required String label,
  required IconData icon,
  required int step,
  required String Function(int value) format,
}) {
  final (int lo, int hi) = kWebBrowserSubtitleStyleLimits[field]!;
  return SettingsSliderItem(
    id: 'web_browser.extension.subtitleStyle.$field',
    title: _x('${label}_title'),
    subtitle: _d('${label}_desc'),
    icon: icon,
    min: lo.toDouble(),
    max: hi.toDouble(),
    divisions: (hi - lo) ~/ step,
    titleReadout: true,
    commitOnRelease: true,
    defaultValue: (kWebBrowserSubtitleStyleDefaults[field]! as int).toDouble(),
    label: (double v) => format(v.round()),
    value: (SettingsContext c) => (_style(c)[field]! as int).toDouble(),
    onChanged: (SettingsContext c, double v) =>
        _writeStyle(c, field, v.round()),
  );
}

String _percent(int v) => '$v%';

String _boxLabel(int v) => v == 0 ? _x('opt_subtitleStyle_auto') : '$v%';

String _fontLabel(String family) =>
    family.split(',').first.replaceAll('"', '').replaceAll("'", '').trim();

SettingsCustomItem _styleColor(
  String field, {
  required String label,
  required IconData icon,
  required int themed,
}) => overlayColorSettingItem(
  id: 'web_browser.extension.subtitleStyle.$field',
  title: _x('${label}_title'),
  icon: icon,
  // 存 '' = 跟随主题；颜色恒为不透明 #rrggbb，0 不会与真实颜色撞。
  followThemeValue: 0,
  followsTheme: (int stored) => stored == 0,
  value: (SettingsContext c) {
    final String hex = _style(c)[field]! as String;
    if (hex.isEmpty) return 0;
    return 0xFF000000 | int.parse(hex.substring(1), radix: 16);
  },
  themedColor: (ThemeData _) => themed,
  commit: (SettingsContext c, int value) => _writeStyle(
    c,
    field,
    value == 0
        ? ''
        : '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
  ),
);

SettingsDestination _subtitleStyleDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_subtitle_style'),
  summary: _d('opt_group_subtitle_style_desc'),
  icon: FushiIcons.textFields,
  sections: <SettingsSection>[
    _section(
      id: 'subtitle_style',
      items: <SettingsItem>[
        SettingsSegmentedItem<String>(
          id: 'web_browser.extension.subtitleStyle.fontFamily',
          title: _x('opt_subtitleStyleFontFamily_title'),
          subtitle: _d('opt_subtitleStyleFontFamily_desc'),
          icon: FushiIcons.font,
          dropdown: true,
          defaultValue: '',
          options: <SettingsSegmentOption<String>>[
            SettingsSegmentOption<String>(
              value: '',
              label: _x('opt_subtitleStyleFontFamily_option_default'),
            ),
            for (final String f in kWebBrowserSubtitleFontSuggestions)
              SettingsSegmentOption<String>(value: f, label: _fontLabel(f)),
          ],
          // 扩展里从字体库选的字体不在静态表里：把当前值也列出来，别把它显示成「默认」。
          optionsBuilder: (SettingsContext c) {
            final String current = _style(c)['fontFamily']! as String;
            return <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: '',
                label: _x('opt_subtitleStyleFontFamily_option_default'),
              ),
              for (final String f in kWebBrowserSubtitleFontSuggestions)
                SettingsSegmentOption<String>(value: f, label: _fontLabel(f)),
              if (current.isNotEmpty &&
                  !kWebBrowserSubtitleFontSuggestions.contains(current))
                SettingsSegmentOption<String>(
                  value: current,
                  label: _fontLabel(current),
                ),
            ];
          },
          selected: (SettingsContext c) => _style(c)['fontFamily']! as String,
          onChanged: (SettingsContext c, String v) =>
              _writeStyle(c, 'fontFamily', v),
        ),
        _styleSlider(
          'fontScale',
          label: 'opt_subtitleStyleFontScale',
          icon: FushiIcons.fontSize,
          step: 5,
          format: _percent,
        ),
        _switch(
          'subtitleOverlayBackground',
          fallback: true,
          label: 'opt_subtitleOverlayBackground',
          icon: FushiIcons.formatShapes,
        ),
        SettingsSegmentedItem<String>(
          id: 'web_browser.extension.subtitleStyle.shadow',
          title: _x('opt_subtitleStyleShadow_title'),
          subtitle: _d('opt_subtitleStyleShadow_desc'),
          icon: FushiIcons.outline,
          defaultValue: 'soft',
          options: <SettingsSegmentOption<String>>[
            for (final String v in <String>['none', 'soft', 'strong'])
              SettingsSegmentOption<String>(
                value: v,
                label: _x('opt_shadow_$v'),
              ),
          ],
          selected: (SettingsContext c) => _style(c)['shadow']! as String,
          onChanged: (SettingsContext c, String v) =>
              _writeStyle(c, 'shadow', v),
        ),
      ],
    ),
    _section(
      id: 'subtitle_style_more',
      title: _x('opt_more_options'),
      items: <SettingsItem>[
        SettingsSegmentedItem<String>(
          id: 'web_browser.extension.subtitleStyle.fontWeight',
          title: _x('opt_subtitleStyleFontWeight_title'),
          subtitle: _d('opt_subtitleStyleFontWeight_desc'),
          icon: FushiIcons.title,
          dropdown: true,
          defaultValue: '600',
          options: <SettingsSegmentOption<String>>[
            for (int w = 300; w <= 900; w += 100)
              SettingsSegmentOption<String>(
                value: '$w',
                label: _x('opt_fontWeight_$w'),
              ),
          ],
          selected: (SettingsContext c) {
            final int w = _style(c)['fontWeight']! as int;
            return w < 300 ? '300' : '$w';
          },
          onChanged: (SettingsContext c, String v) =>
              _writeStyle(c, 'fontWeight', int.parse(v)),
        ),
        _styleSlider(
          'letterSpacing',
          label: 'opt_subtitleStyleLetterSpacing',
          icon: FushiIcons.spaceBar,
          step: 1,
          format: (int v) => '${(v / 100).toStringAsFixed(2)} em',
        ),
        _styleSlider(
          'lineHeight',
          label: 'opt_subtitleStyleLineHeight',
          icon: FushiIcons.lineSpacing,
          step: 5,
          format: _percent,
        ),
        SettingsSegmentedItem<String>(
          id: 'web_browser.extension.subtitleStyle.textAlign',
          title: _x('opt_subtitleStyleTextAlign_title'),
          subtitle: _d('opt_subtitleStyleTextAlign_desc'),
          icon: FushiIcons.alignJustify,
          defaultValue: 'center',
          options: <SettingsSegmentOption<String>>[
            SettingsSegmentOption<String>(
              value: 'left',
              label: _x('opt_align_left'),
              icon: FushiIcons.alignLeft,
            ),
            SettingsSegmentOption<String>(
              value: 'center',
              label: _x('opt_align_center'),
              icon: FushiIcons.alignJustify,
            ),
            SettingsSegmentOption<String>(
              value: 'right',
              label: _x('opt_align_right'),
              icon: FushiIcons.alignRight,
            ),
          ],
          selected: (SettingsContext c) => _style(c)['textAlign']! as String,
          onChanged: (SettingsContext c, String v) =>
              _writeStyle(c, 'textAlign', v),
        ),
        _styleColor(
          'textColor',
          label: 'opt_subtitleStyleTextColor',
          icon: FushiIcons.outlineColor,
          themed: kWebBrowserSubtitleDefaultTextColor,
        ),
        _styleColor(
          'backgroundColor',
          label: 'opt_subtitleStyleBackgroundColor',
          icon: FushiIcons.appearance,
          themed: kWebBrowserSubtitleDefaultBackgroundColor,
        ),
        _styleSlider(
          'backgroundOpacity',
          label: 'opt_subtitleStyleBackgroundOpacity',
          icon: FushiIcons.blurLinear,
          step: 1,
          format: _percent,
        ),
        _styleSlider(
          'borderRadius',
          label: 'opt_subtitleStyleBorderRadius',
          icon: FushiIcons.crop,
          step: 1,
          format: (int v) => '$v px',
        ),
        _styleSlider(
          'padding',
          label: 'opt_subtitleStylePadding',
          icon: FushiIcons.zoomOut,
          step: 10,
          format: _percent,
        ),
        _styleSlider(
          'boxWidth',
          label: 'opt_subtitleStyleBoxWidth',
          icon: FushiIcons.textHorizontal,
          step: 5,
          format: _boxLabel,
        ),
        _styleSlider(
          'boxHeight',
          label: 'opt_subtitleStyleBoxHeight',
          icon: FushiIcons.textVertical,
          step: 1,
          format: _boxLabel,
        ),
        SettingsSwitchItem(
          id: 'web_browser.extension.subtitleStyle.boxAutoFit',
          title: _x('opt_subtitleStyleBoxAutoFit_title'),
          subtitle: _d('opt_subtitleStyleBoxAutoFit_desc'),
          icon: FushiIcons.zoomIn,
          defaultValue: true,
          value: (SettingsContext c) => _style(c)['boxAutoFit']! as bool,
          onChanged: (SettingsContext c, bool v) =>
              _writeStyle(c, 'boxAutoFit', v),
        ),
        SettingsActionItem(
          id: 'web_browser.extension.subtitleStyle.reset',
          title: _x('opt_resetSubtitleStyle_title'),
          subtitle: _d('opt_resetSubtitleStyle_desc'),
          icon: FushiIcons.restart,
          cli: const SettingsCliAction.tap(),
          onTap: (SettingsContext c) =>
              _remove(c, <String>[kWebBrowserSubtitleStyleKey]),
        ),
      ],
    ),
  ],
);

// ── 外观 ──────────────────────────────────────────────────────────────

/// `theme-palette.js` PRESETS 的 key 与文案键（顺序同扩展的主题卡网格）。
const List<(String, String)> kWebBrowserExtensionPalettePresets =
    <(String, String)>[
      ('m3-baseline', 'theme_preset_baseline'),
      ('m3-indigo', 'theme_preset_indigo'),
      ('m3-blue', 'theme_preset_blue'),
      ('m3-teal', 'theme_preset_teal'),
      ('m3-green', 'theme_preset_green'),
      ('m3-yellow', 'theme_preset_yellow'),
      ('m3-orange', 'theme_preset_orange'),
      ('m3-red', 'theme_preset_red'),
      ('m3-pink', 'theme_preset_pink'),
      ('m3-neutral', 'theme_preset_neutral'),
    ];

/// 扩展界面语言（options.html `#extensionLanguage`；语言名不翻译）。
const List<(String, String?)> kWebBrowserExtensionLanguages =
    <(String, String?)>[
      ('app', null),
      ('browser', null),
      ('en', 'English'),
      ('ja', '日本語'),
      ('zh-CN', '简体中文'),
      ('zh-HK', '繁體中文（香港）'),
      ('ko', '한국어'),
      ('de', 'Deutsch'),
      ('es', 'Español'),
      ('fr', 'Français'),
      ('it', 'Italiano'),
      ('nl', 'Nederlands'),
      ('pt-BR', 'Português (Brasil)'),
      ('ru', 'Русский'),
      ('tr', 'Türkçe'),
      ('vi', 'Tiếng Việt'),
      ('id', 'Bahasa Indonesia'),
      ('th', 'ภาษาไทย'),
      ('ar', 'العربية'),
    ];

List<SettingsSegmentOption<String>> _paletteOptions(SettingsContext? c) {
  final List<SettingsSegmentOption<String>>
  out = <SettingsSegmentOption<String>>[
    SettingsSegmentOption<String>(value: 'app', label: _x('theme_palette_app')),
    for (final (String key, String label) in kWebBrowserExtensionPalettePresets)
      SettingsSegmentOption<String>(value: key, label: _x(label)),
  ];
  if (c == null) return out;
  // 扩展里建的自定义主题（extensionCustomThemes：[{id, name, …}]）。
  final Object? custom = _read(c, 'extensionCustomThemes');
  if (custom is List) {
    for (final Object? t in custom) {
      if (t is! Map || t['id'] is! String) continue;
      final String name =
          t['name'] is String && (t['name'] as String).isNotEmpty
          ? t['name'] as String
          : _x('theme_custom_untitled');
      out.add(
        SettingsSegmentOption<String>(value: 'custom:${t['id']}', label: name),
      );
    }
  }
  // 旧预设 id（theme-palette.js LEGACY_PRESETS）：扩展读的时候会映射，这里原样列出不改值。
  final String current = _readString(c, 'extensionPalette', 'app');
  if (!out.any((SettingsSegmentOption<String> o) => o.value == current)) {
    out.add(SettingsSegmentOption<String>(value: current, label: current));
  }
  return out;
}

SettingsDestination _appearanceDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_appearance'),
  summary: _d('opt_group_appearance_desc'),
  icon: FushiIcons.appearance,
  sections: <SettingsSection>[
    _section(
      id: 'appearance',
      items: <SettingsItem>[
        SettingsSegmentedItem<String>(
          id: 'web_browser.extension.extensionPalette',
          title: _x('opt_palette_title'),
          subtitle: _d('opt_palette_desc'),
          icon: FushiIcons.appearance,
          dropdown: true,
          defaultValue: 'app',
          options: _paletteOptions(null),
          optionsBuilder: _paletteOptions,
          selected: (SettingsContext c) =>
              _readString(c, 'extensionPalette', 'app'),
          // 只写调色板，不碰明暗（与扩展 selectPalette 同义）。
          onChanged: (SettingsContext c, String v) =>
              _write(c, <String, Object?>{'extensionPalette': v}),
        ),
        _choice(
          'extensionTheme',
          fallback: 'auto',
          label: 'opt_extensionBrightness',
          icon: FushiIcons.brightnessAuto,
          dropdown: false,
          options: <SettingsSegmentOption<String>>[
            SettingsSegmentOption<String>(
              value: 'auto',
              label: _x('opt_extensionTheme_option_auto'),
              icon: FushiIcons.brightnessAuto,
            ),
            SettingsSegmentOption<String>(
              value: 'light',
              label: _x('opt_extensionTheme_option_light'),
              icon: FushiIcons.lightMode,
            ),
            SettingsSegmentOption<String>(
              value: 'dark',
              label: _x('opt_extensionTheme_option_dark'),
              icon: FushiIcons.darkMode,
            ),
          ],
        ),
        SettingsSwitchItem(
          id: 'web_browser.extension.extensionPureBlack',
          title: _x('theme_pure_black'),
          subtitle: _d('theme_pure_black_hint'),
          icon: FushiIcons.darkMode,
          defaultValue: false,
          // 没写过：旧「纯黑」预设用户缺省开（与 theme.js pureBlackFrom 同律）。
          value: (SettingsContext c) {
            final Object? v = _read(c, 'extensionPureBlack');
            if (v is bool) return v;
            return _read(c, 'extensionPalette') == 'black-theme';
          },
          onChanged: (SettingsContext c, bool v) =>
              _write(c, <String, Object?>{'extensionPureBlack': v}),
        ),
        _choice(
          'extensionLanguage',
          fallback: 'app',
          label: 'opt_extensionLanguage',
          icon: FushiIcons.language,
          options: <SettingsSegmentOption<String>>[
            for (final (String value, String? name)
                in kWebBrowserExtensionLanguages)
              SettingsSegmentOption<String>(
                value: value,
                label: name ?? _x('opt_extensionLanguage_option_$value'),
              ),
          ],
        ),
      ],
    ),
  ],
);

// ── 快捷键 ─────────────────────────────────────────────────────────────

/// 自定义组合键的存储键（`video-shortcuts.js` KEYS_SETTING）：`{action: combo}`，只存改过的。
const String kWebBrowserShortcutKeysSetting = 'videoShortcutKeys';

/// 视频页快捷键：动作 → (开关键, 文案前缀, 默认组合)。`video-shortcuts.js` DEFAULT_COMBOS。
const List<(String, String, String, String)> kWebBrowserVideoShortcuts =
    <(String, String, String, String)>[
      (
        'prev-cue',
        'videoShortcutPrevCue',
        'opt_videoShortcutPrevCue',
        'ArrowLeft',
      ),
      (
        'next-cue',
        'videoShortcutNextCue',
        'opt_videoShortcutNextCue',
        'ArrowRight',
      ),
      (
        'replay-cue',
        'videoShortcutReplayCue',
        'opt_videoShortcutReplayCue',
        'ArrowUp',
      ),
      (
        'toggle-panel',
        'videoShortcutTogglePanel',
        'opt_videoShortcutTogglePanel',
        'Shift+KeyS',
      ),
      (
        'toggle-subtitle-hide',
        'videoShortcutToggleSubtitleHide',
        'opt_videoShortcutToggleSubtitleHide',
        'Shift+KeyH',
      ),
      (
        'copy-cue',
        'videoShortcutCopyCue',
        'opt_videoShortcutCopyCue',
        'Ctrl+Shift+KeyZ',
      ),
      (
        'offset-minus',
        'videoShortcutOffsetMinus',
        'opt_videoShortcutOffsetMinus',
        'Ctrl+Shift+ArrowLeft',
      ),
      (
        'offset-plus',
        'videoShortcutOffsetPlus',
        'opt_videoShortcutOffsetPlus',
        'Ctrl+Shift+ArrowRight',
      ),
      (
        'offset-reset',
        'videoShortcutOffsetReset',
        'opt_videoShortcutOffsetReset',
        'Ctrl+Shift+ArrowDown',
      ),
      (
        'rate-down',
        'videoShortcutRateDown',
        'opt_videoShortcutRateDown',
        'Ctrl+Shift+BracketLeft',
      ),
      (
        'rate-up',
        'videoShortcutRateUp',
        'opt_videoShortcutRateUp',
        'Ctrl+Shift+BracketRight',
      ),
    ];

final RegExp _kShortcutTokenRe = RegExp(
  r'^(Key[A-Z]|Digit[0-9]|Numpad[A-Za-z0-9]+|F([1-9]|1[0-9]|2[0-4])|'
  r'Arrow(Left|Right|Up|Down)|Home|End|PageUp|PageDown|Insert|Delete|Backspace|Enter|Escape|'
  r'Space|Tab|Backquote|Minus|Equal|BracketLeft|BracketRight|Backslash|Semicolon|Quote|Comma|'
  r'Period|Slash|IntlBackslash|IntlRo|IntlYen|ContextMenu|Pause)$',
);

/// 组合串规整（`video-shortcuts.js` normalizeCombo）：修饰键按 Ctrl / Alt / Shift 排、去重；
/// 不成立返回 ''。
String normalizeWebBrowserShortcutCombo(Object? raw) {
  if (raw is! String || raw.isEmpty) return '';
  final List<String> segs = raw.split('+');
  final String token = segs.removeLast();
  if (token.isEmpty || !_kShortcutTokenRe.hasMatch(token)) return '';
  bool ctrl = false;
  bool alt = false;
  bool shift = false;
  for (final String s in segs) {
    switch (s) {
      case 'Ctrl':
        ctrl = true;
      case 'Alt':
        alt = true;
      case 'Shift':
        shift = true;
      default:
        return '';
    }
  }
  return <String>[
    if (ctrl) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    token,
  ].join('+');
}

const Map<String, String> _kShortcutTokenLabels = <String, String>{
  'ArrowLeft': '←',
  'ArrowRight': '→',
  'ArrowUp': '↑',
  'ArrowDown': '↓',
  'BracketLeft': '[',
  'BracketRight': ']',
  'Backslash': r'\',
  'Semicolon': ';',
  'Quote': "'",
  'Comma': ',',
  'Period': '.',
  'Slash': '/',
  'Minus': '-',
  'Equal': '=',
  'Backquote': '`',
  'Space': 'Space',
  'Enter': 'Enter',
  'Escape': 'Esc',
  'Backspace': 'Backspace',
  'Tab': 'Tab',
};

/// 给人看的组合键文字（`video-shortcuts.js` formatCombo）。
String formatWebBrowserShortcutCombo(String combo) {
  final String c = normalizeWebBrowserShortcutCombo(combo);
  if (c.isEmpty) return '';
  final List<String> segs = c.split('+');
  final String token = segs.removeLast();
  final String label =
      _kShortcutTokenLabels[token] ??
      (RegExp(r'^Key[A-Z]$').hasMatch(token)
          ? token.substring(3)
          : RegExp(r'^Digit\d$').hasMatch(token)
          ? token.substring(5)
          : token.startsWith('Numpad')
          ? 'Num ${token.substring(6)}'
          : token);
  return <String>[...segs, label].join('+');
}

/// 生效的动作 → 组合键表：默认表叠用户覆盖（非法覆盖忽略）。
Map<String, String> resolveWebBrowserShortcutCombos(Object? custom) =>
    <String, String>{
      for (final (String action, String _, String _, String fallback)
          in kWebBrowserVideoShortcuts)
        action: switch (custom) {
          final Map<Object?, Object?> m
              when normalizeWebBrowserShortcutCombo(m[action]).isNotEmpty =>
            normalizeWebBrowserShortcutCombo(m[action]),
          _ => fallback,
        },
    };

/// Flutter 物理键 → `KeyboardEvent.code`（布局无关）。只收扩展认得的主键（[_kShortcutTokenRe]）。
final Map<PhysicalKeyboardKey, String> _kPhysicalToCode =
    <PhysicalKeyboardKey, String>{
      PhysicalKeyboardKey.keyA: 'KeyA',
      PhysicalKeyboardKey.keyB: 'KeyB',
      PhysicalKeyboardKey.keyC: 'KeyC',
      PhysicalKeyboardKey.keyD: 'KeyD',
      PhysicalKeyboardKey.keyE: 'KeyE',
      PhysicalKeyboardKey.keyF: 'KeyF',
      PhysicalKeyboardKey.keyG: 'KeyG',
      PhysicalKeyboardKey.keyH: 'KeyH',
      PhysicalKeyboardKey.keyI: 'KeyI',
      PhysicalKeyboardKey.keyJ: 'KeyJ',
      PhysicalKeyboardKey.keyK: 'KeyK',
      PhysicalKeyboardKey.keyL: 'KeyL',
      PhysicalKeyboardKey.keyM: 'KeyM',
      PhysicalKeyboardKey.keyN: 'KeyN',
      PhysicalKeyboardKey.keyO: 'KeyO',
      PhysicalKeyboardKey.keyP: 'KeyP',
      PhysicalKeyboardKey.keyQ: 'KeyQ',
      PhysicalKeyboardKey.keyR: 'KeyR',
      PhysicalKeyboardKey.keyS: 'KeyS',
      PhysicalKeyboardKey.keyT: 'KeyT',
      PhysicalKeyboardKey.keyU: 'KeyU',
      PhysicalKeyboardKey.keyV: 'KeyV',
      PhysicalKeyboardKey.keyW: 'KeyW',
      PhysicalKeyboardKey.keyX: 'KeyX',
      PhysicalKeyboardKey.keyY: 'KeyY',
      PhysicalKeyboardKey.keyZ: 'KeyZ',
      PhysicalKeyboardKey.digit0: 'Digit0',
      PhysicalKeyboardKey.digit1: 'Digit1',
      PhysicalKeyboardKey.digit2: 'Digit2',
      PhysicalKeyboardKey.digit3: 'Digit3',
      PhysicalKeyboardKey.digit4: 'Digit4',
      PhysicalKeyboardKey.digit5: 'Digit5',
      PhysicalKeyboardKey.digit6: 'Digit6',
      PhysicalKeyboardKey.digit7: 'Digit7',
      PhysicalKeyboardKey.digit8: 'Digit8',
      PhysicalKeyboardKey.digit9: 'Digit9',
      PhysicalKeyboardKey.f1: 'F1',
      PhysicalKeyboardKey.f2: 'F2',
      PhysicalKeyboardKey.f3: 'F3',
      PhysicalKeyboardKey.f4: 'F4',
      PhysicalKeyboardKey.f5: 'F5',
      PhysicalKeyboardKey.f6: 'F6',
      PhysicalKeyboardKey.f7: 'F7',
      PhysicalKeyboardKey.f8: 'F8',
      PhysicalKeyboardKey.f9: 'F9',
      PhysicalKeyboardKey.f10: 'F10',
      PhysicalKeyboardKey.f11: 'F11',
      PhysicalKeyboardKey.f12: 'F12',
      PhysicalKeyboardKey.arrowLeft: 'ArrowLeft',
      PhysicalKeyboardKey.arrowRight: 'ArrowRight',
      PhysicalKeyboardKey.arrowUp: 'ArrowUp',
      PhysicalKeyboardKey.arrowDown: 'ArrowDown',
      PhysicalKeyboardKey.home: 'Home',
      PhysicalKeyboardKey.end: 'End',
      PhysicalKeyboardKey.pageUp: 'PageUp',
      PhysicalKeyboardKey.pageDown: 'PageDown',
      PhysicalKeyboardKey.insert: 'Insert',
      PhysicalKeyboardKey.delete: 'Delete',
      PhysicalKeyboardKey.backspace: 'Backspace',
      PhysicalKeyboardKey.enter: 'Enter',
      PhysicalKeyboardKey.escape: 'Escape',
      PhysicalKeyboardKey.space: 'Space',
      PhysicalKeyboardKey.tab: 'Tab',
      PhysicalKeyboardKey.backquote: 'Backquote',
      PhysicalKeyboardKey.minus: 'Minus',
      PhysicalKeyboardKey.equal: 'Equal',
      PhysicalKeyboardKey.bracketLeft: 'BracketLeft',
      PhysicalKeyboardKey.bracketRight: 'BracketRight',
      PhysicalKeyboardKey.backslash: 'Backslash',
      PhysicalKeyboardKey.semicolon: 'Semicolon',
      PhysicalKeyboardKey.quote: 'Quote',
      PhysicalKeyboardKey.comma: 'Comma',
      PhysicalKeyboardKey.period: 'Period',
      PhysicalKeyboardKey.slash: 'Slash',
      PhysicalKeyboardKey.intlBackslash: 'IntlBackslash',
      PhysicalKeyboardKey.contextMenu: 'ContextMenu',
      PhysicalKeyboardKey.pause: 'Pause',
    };

/// 一次按键 → 规范组合串（`video-shortcuts.js` comboFromEvent）；纯修饰键 / 不认的主键返回 ''。
String webBrowserShortcutComboFromKey(
  PhysicalKeyboardKey key, {
  required bool ctrl,
  required bool alt,
  required bool shift,
}) {
  final String? token = _kPhysicalToCode[key];
  if (token == null) return '';
  return <String>[
    if (ctrl) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    token,
  ].join('+');
}

/// 写某个动作的组合键：[combo] 为 '' 或等于默认 = 删该项（全删则删键），与扩展同一写法。
Future<void> writeWebBrowserShortcutCombo(
  WebBrowserExtensionStorage storage,
  String action,
  String combo,
) async {
  final Object? raw = storage.get(<String>[
    kWebBrowserShortcutKeysSetting,
  ])[kWebBrowserShortcutKeysSetting];
  final Map<String, Object?> next = raw is Map
      ? <String, Object?>{
          for (final MapEntry<Object?, Object?> e in raw.entries)
            '${e.key}': e.value,
        }
      : <String, Object?>{};
  final String fallback = kWebBrowserVideoShortcuts
      .firstWhere(((String, String, String, String) s) => s.$1 == action)
      .$4;
  if (combo.isEmpty || combo == fallback) {
    next.remove(action);
  } else {
    next[action] = combo;
  }
  if (next.isEmpty) {
    await storage.remove(<String>[kWebBrowserShortcutKeysSetting]);
  } else {
    await storage.set(<String, Object?>{kWebBrowserShortcutKeysSetting: next});
  }
}

/// 快捷键行：开关（与扩展 videoShortcut* 同键）+ 键帽（点它录入新组合）。
SettingsCustomItem _shortcutRow(String action, String key, String label) =>
    SettingsCustomItem(
      id: 'web_browser.extension.$key',
      searchTitle: _x('${label}_title'),
      builder: (SettingsContext c) {
        final Object? custom = _read(c, kWebBrowserShortcutKeysSetting);
        final Map<String, String> combos = resolveWebBrowserShortcutCombos(
          custom,
        );
        final Object? legacy = _read(c, 'videoShortcutsEnabled');
        return AdaptiveSettingsSwitchActionRow(
          title: _x('${label}_title'),
          icon: FushiIcons.keyboard,
          value: _readBool(c, key, legacy is bool ? legacy : true),
          onChanged: (bool v) =>
              unawaited(_write(c, <String, Object?>{key: v})),
          actions: <Widget>[
            Tooltip(
              message: _x('opt_shortcut_edit_title'),
              child: FushiTextButton(
                key: ValueKey<String>('web_browser.extension.shortcut.$action'),
                onPressed: () =>
                    unawaited(_recordShortcut(c, action, label, combos)),
                child: Text(formatWebBrowserShortcutCombo(combos[action]!)),
              ),
            ),
          ],
        );
      },
    );

Future<void> _recordShortcut(
  SettingsContext c,
  String action,
  String label,
  Map<String, String> combos,
) async {
  final String? picked = await showAppDialog<String>(
    context: c.context,
    builder: (BuildContext _) => _ShortcutRecordDialog(
      action: action,
      title: _x('${label}_title'),
      combos: combos,
    ),
  );
  if (picked == null) return;
  await writeWebBrowserShortcutCombo(_storage(c), action, picked);
  c.refresh();
}

/// 录入新组合：按下组合即保存；Esc 取消；Backspace / Delete 恢复默认；与别的动作撞键时
/// 留在录入态并提示（与扩展设置页同一套交互）。返回 '' = 恢复默认，null = 取消。
class _ShortcutRecordDialog extends StatefulWidget {
  const _ShortcutRecordDialog({
    required this.action,
    required this.title,
    required this.combos,
  });

  final String action;
  final String title;
  final Map<String, String> combos;

  @override
  State<_ShortcutRecordDialog> createState() => _ShortcutRecordDialogState();
}

class _ShortcutRecordDialogState extends State<_ShortcutRecordDialog> {
  String? _error;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final bool ctrl = kb.isControlPressed || kb.isMetaPressed;
    final bool bare = !ctrl && !kb.isShiftPressed && !kb.isAltPressed;
    final PhysicalKeyboardKey key = event.physicalKey;
    if (bare && key == PhysicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (bare &&
        (key == PhysicalKeyboardKey.backspace ||
            key == PhysicalKeyboardKey.delete)) {
      Navigator.of(context).pop('');
      return KeyEventResult.handled;
    }
    final String combo = webBrowserShortcutComboFromKey(
      key,
      ctrl: ctrl,
      alt: kb.isAltPressed,
      shift: kb.isShiftPressed,
    );
    if (combo.isEmpty) return KeyEventResult.handled; // 只按了修饰键：继续等。
    for (final MapEntry<String, String> e in widget.combos.entries) {
      if (e.key != widget.action && e.value == combo) {
        final String other = kWebBrowserVideoShortcuts
            .firstWhere(((String, String, String, String) s) => s.$1 == e.key)
            .$3;
        setState(
          () => _error = _x('opt_toast_shortcut_conflict', <String, String>{
            'combo': formatWebBrowserShortcutCombo(combo),
            'name': _x('${other}_title'),
          }),
        );
        return KeyEventResult.handled;
      }
    }
    Navigator.of(context).pop(combo);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiAlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _x('opt_shortcut_recording'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _x('opt_shortcut_edit_title'),
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(_x('opt_resetSubtitleStyle_button')),
          ),
          FushiTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
  }
}

SettingsDestination _shortcutDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_shortcut'),
  summary: _d('opt_group_shortcut_desc'),
  icon: FushiIcons.keyboard,
  sections: <SettingsSection>[
    _section(
      id: 'shortcut',
      items: <SettingsItem>[
        for (final (String action, String key, String label, String _)
            in kWebBrowserVideoShortcuts)
          _shortcutRow(action, key, label),
      ],
    ),
  ],
);

// ── 沉浸时间（扩展「高级」里在 app 内有意义的部分）──────────────────────

SettingsDestination _studyDestination() => SettingsDestination(
  id: SettingsDestinationId.system,
  title: _x('opt_group_advanced'),
  icon: FushiIcons.timer,
  sections: <SettingsSection>[
    _section(
      id: 'study',
      items: <SettingsItem>[
        _switch(
          'studyTrackVideo',
          fallback: true,
          label: 'opt_studyTrackVideo',
          icon: FushiIcons.statistics,
        ),
        _choice(
          'studyTrackVideoCondition',
          fallback: 'fushiSubtitle',
          label: 'opt_studyTrackVideoCondition',
          icon: FushiIcons.filterList,
          options: <SettingsSegmentOption<String>>[
            for (final String v in <String>[
              'fushiSubtitle',
              'anySubtitle',
              'always',
            ])
              SettingsSegmentOption<String>(
                value: v,
                label: _x('opt_studyTrackVideoCondition_option_$v'),
              ),
          ],
        ),
      ],
    ),
  ],
);

/// 扩展的分组（顺序同扩展设置页左侧导航）。
enum WebBrowserExtensionSettingsGroup {
  lookup,
  subtitle,
  subtitleStyle,
  appearance,
  shortcuts,
  study;

  /// 本组的子页（每次调用现建：文案取自扩展字典，调用前须 [WebBrowserExtensionStrings.ensureLoaded]）。
  SettingsDestination destination() => switch (this) {
    lookup => _lookupDestination(),
    subtitle => _subtitleDestination(),
    subtitleStyle => _subtitleStyleDestination(),
    appearance => _appearanceDestination(),
    shortcuts => _shortcutDestination(),
    study => _studyDestination(),
  };
}
