import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputFormatter;
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_panel_kit.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show
        ReaderSideSheet,
        ReaderSideSheetSectionLabel,
        ReaderSideSheetSide,
        showReaderSideSheet;
import 'package:fushi/src/reader/reader_panel_kit.dart'
    show ReaderPanelTab, ReaderPanelTabs;
import 'package:fushi/src/settings/settings_kit.dart' show SettingsModifiedRow;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show fushiFloatingPillDecoration;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

enum MangaReaderPreferenceKind { choice, toggle, integer }

class MangaReaderPreferenceDescriptor {
  const MangaReaderPreferenceDescriptor({
    required this.key,
    required this.kind,
    required this.title,
    this.choices = const <String>[],
    this.min,
    this.max,
  });
  final String key;
  final MangaReaderPreferenceKind kind;
  final String title;
  final List<String> choices;
  final int? min;
  final int? max;
}

List<MangaReaderPreferenceDescriptor> mangaReaderPreferenceDescriptors(
  Set<String> supportedDeviceKeys,
) => <MangaReaderPreferenceDescriptor>[
  MangaReaderPreferenceDescriptor(
    key: 'mode',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reading_mode,
    choices: <String>[
      'auto',
      for (final MangaReadingMode m in MangaReadingMode.values) m.storageKey,
    ],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'direction',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reading_direction,
    choices: const <String>['rtl', 'ltr'],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'scaleType',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reader_scale,
    choices: const <String>[
      'fit_screen',
      'stretch',
      'fit_width',
      'fit_height',
      'original',
      'smart',
    ],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'longStripSidePadding',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_padding,
    min: 0,
    max: 24,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'tapZones',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_tap_zone_layout,
    choices: const <String>[
      'default',
      'l_shaped',
      'kindle',
      'edge',
      'right_left',
      'disabled',
    ],
  ),
  for (final MapEntry<String, String> e in <MapEntry<String, String>>[
    MapEntry<String, String>('showPageNumber', t.manga_reader_page_number),
    MapEntry<String, String>(
      'animateDoubleTap',
      t.manga_reader_double_tap_animation,
    ),
    MapEntry<String, String>('disableZoomOut', t.manga_reader_disable_zoom_out),
    MapEntry<String, String>(
      'invertHorizontal',
      t.manga_reader_invert_horizontal,
    ),
    MapEntry<String, String>('invertVertical', t.manga_reader_invert_vertical),
    MapEntry<String, String>('invertBoth', t.manga_reader_invert_both),
    MapEntry<String, String>('showReadingMode', t.manga_reader_mode_hint),
    MapEntry<String, String>('showTapZonesOverlay', t.manga_reader_tap_hint),
    // 换章时的落点规则（resolveAdjacentMangaChapter）。`skipFiltered` 与
    // `alwaysShowChapterTransition` 不露出：前者没有章节过滤可跳，后者没有章节
    // 过渡页；字段只为兼容旧覆盖 JSON 保留（显示了却不生效的开关比没有更糟）。
    MapEntry<String, String>('skipRead', t.manga_reader_skip_read),
    MapEntry<String, String>('skipDuplicate', t.manga_reader_skip_duplicate),
    MapEntry<String, String>('downloadAhead', t.manga_reader_download_ahead),
    MapEntry<String, String>('fullscreen', t.manga_reader_fullscreen),
    MapEntry<String, String>('keepScreenOn', t.manga_reader_keep_screen),
    MapEntry<String, String>('invertVolumeKeys', t.manga_reader_invert_volume),
  ])
    if (!<String>{
          'fullscreen',
          'keepScreenOn',
          'invertVolumeKeys',
        }.contains(e.key) ||
        supportedDeviceKeys.contains(e.key))
      MangaReaderPreferenceDescriptor(
        key: e.key,
        kind: MangaReaderPreferenceKind.toggle,
        title: e.value,
      ),
  MangaReaderPreferenceDescriptor(
    key: 'cropBorders',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_crop_borders,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'splitWidePages',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_split_wide_pages,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'rotateWidePages',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_rotate_wide_pages,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'automaticBackground',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_automatic_background,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'webtoonDoubleTapZoom',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_webtoon_double_tap_zoom,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'showPageGaps',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_show_page_gaps,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'autoScroll',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_auto_scroll,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'einkMode',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_eink_mode,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'invertColors',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_invert_colors,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'grayscale',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_grayscale,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'customColorFilter',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_custom_color_filter,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'flashOnPageChange',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_flash_on_page_change,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'animateTransitions',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_animate_transitions,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'lookupOnHover',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_reader_lookup_on_hover,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'showOcrBoxes',
    kind: MangaReaderPreferenceKind.toggle,
    title: t.manga_ocr_boxes_toggle,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'autoScrollSpeed',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_auto_scroll_speed,
    min: 5,
    max: 200,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'readerHideThreshold',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_hide_threshold,
    min: 1,
    max: 100,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'brightness',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_brightness,
    min: -100,
    max: 100,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'contrast',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_contrast,
    min: 0,
    max: 200,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'saturation',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_saturation,
    min: 0,
    max: 200,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'colorFilterOpacity',
    kind: MangaReaderPreferenceKind.integer,
    title: t.manga_reader_color_filter_opacity,
    min: 0,
    max: 100,
  ),
  MangaReaderPreferenceDescriptor(
    key: 'background',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_background,
    choices: const <String>['black', 'white', 'gray', 'theme'],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'ocrTrigger',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reader_ocr_trigger,
    choices: const <String>['automatic', 'manual'],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'colorFilterColor',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reader_color_filter_color,
    choices: const <String>[
      '#F4ECD8',
      '#FFE4B5',
      '#DCEEFF',
      '#E1F2DC',
      '#FFFFFF',
      '#000000',
    ],
  ),
  MangaReaderPreferenceDescriptor(
    key: 'saveDirectory',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reader_save_directory,
    choices: const <String>['flat', 'book', 'chapter'],
  ),
];

/// 漫画阅读设置面板：宽窗贴右侧（章节目录占左侧，不提供左右换边），窄窗
/// （手机竖屏）从底部升起——与小说阅读器的设置侧板同一外壳与同一判据。
///
/// [onGlobalChanged] 非空时底部作用域切换可切到「全局」：改动以稀疏补丁写进全局
/// 默认（调用方负责合并落库并重应用），没有单独设置的作品都跟着变。
Future<void> showMangaReaderSettingsSheet({
  required BuildContext context,
  required MangaReaderPreferences globalDefaults,
  Widget? ocrSettings,
  Map<String, Object?> overrides = const <String, Object?>{},
  required Future<void> Function(Map<String, Object?>) onChanged,
  Future<void> Function(Map<String, Object?> patch)? onGlobalChanged,
  Set<String> supportedDeviceKeys = const <String>{},
}) async => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  bottomSheetWhenCompact: true,
  builder: (BuildContext context) => MangaReaderSettingsSheet(
    ocrSettings: ocrSettings,
    globalDefaults: globalDefaults,
    overrides: overrides,
    onChanged: onChanged,
    onGlobalChanged: onGlobalChanged,
    supportedDeviceKeys: supportedDeviceKeys,
  ),
);

/// 面板改的是哪一层：当前作品的稀疏覆盖，还是全局默认。
enum MangaReaderSettingsScope { work, global }

class MangaReaderSettingsSheet extends StatefulWidget {
  const MangaReaderSettingsSheet({
    super.key,
    required this.globalDefaults,
    required this.overrides,
    required this.onChanged,
    this.onGlobalChanged,
    this.supportedDeviceKeys = const <String>{},
    this.ocrSettings,
  });
  final MangaReaderPreferences globalDefaults;
  final Map<String, Object?> overrides;
  final Future<void> Function(Map<String, Object?>) onChanged;

  /// 全局默认的稀疏补丁写入；null = 只能改当前作品（「全局」段置灰）。
  final Future<void> Function(Map<String, Object?> patch)? onGlobalChanged;
  final Set<String> supportedDeviceKeys;
  final Widget? ocrSettings;
  @override
  State<MangaReaderSettingsSheet> createState() =>
      _MangaReaderSettingsSheetState();
}

/// 只能按作品设置的键：全局默认里的这两项是开书时由运行态（窗口全屏、阅读器
/// 常亮偏好）现填的，不是全局偏好本身，写进全局等于把一次性的运行态钉成默认。
const Set<String> _kWorkOnlyKeys = <String>{'fullscreen', 'keepScreenOn'};

/// 浮动作用域条占的高度（含上下留白）：列表底部要让出它，最后一行（如外部
/// mokuro 路径输入框）不被压住。
const double _kScopeBarReserve = 96;

class _MangaReaderSettingsSheetState extends State<MangaReaderSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  late Map<String, Object?> _overrides;

  /// 最后一次成功落库的覆盖值：保存失败时回滚到这里，而不是回滚到「点之前」——
  /// 队列里前面的改动可能已经写成功了。
  late Map<String, Object?> _persisted;

  /// 保存进行中又来的改动只留最新一份（整份覆盖值，后写覆盖前写）。
  Map<String, Object?>? _queued;
  Future<void>? _drain;

  /// 全局层：界面立即显示的值与最后一次成功写入的值（失败回滚到后者）。
  late MangaReaderPreferences _global;
  late MangaReaderPreferences _globalPersisted;

  /// 全局补丁串行写入（先改的先落库）。
  Future<void> _globalChain = Future<void>.value();

  MangaReaderSettingsScope _scope = MangaReaderSettingsScope.work;
  final Map<String, int> _sliderValues = <String, int>{};

  /// 自定义颜色输入框里输到一半的值（失焦 / 回车才提交）。
  String? _draftColor;

  @override
  void initState() {
    super.initState();
    _overrides = Map<String, Object?>.from(widget.overrides);
    _persisted = _overrides;
    _global = widget.globalDefaults;
    _globalPersisted = _global;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  bool get _globalScope => _scope == MangaReaderSettingsScope.global;

  MangaReaderPreferences get _effective => _globalScope
      ? _global
      : MangaReaderPreferences.resolve(_global, _overrides);
  Object? _value(String key) =>
      key == 'mode' && _effective.autoMode ? 'auto' : _effective.toJson()[key];

  int _intValue(String key) =>
      _sliderValues[key] ?? (_value(key) as num?)?.round() ?? 0;

  /// 当前作品对 [key] 有自己的值（`mode` 连同 `autoMode` 一起算）。
  bool _isOverridden(String key) => key == 'mode'
      ? _overrides.containsKey('mode') || _overrides.containsKey('autoMode')
      : _overrides.containsKey(key);

  bool _editable(String key) =>
      !_globalScope ||
      (widget.onGlobalChanged != null && !_kWorkOnlyKeys.contains(key));

  /// 全局作用域下的行说明：只能按作品设置 / 当前作品另有自己的值。
  String? _scopeNote(String key) {
    if (!_globalScope) return null;
    if (_kWorkOnlyKeys.contains(key)) return t.manga_reader_scope_work_only;
    if (_isOverridden(key)) return t.manga_reader_scope_overridden;
    return null;
  }

  /// 界面立即显示 [next]，落库串行排队。
  ///
  /// 保存一次要整窗重载，耗时可观；早先的「保存中直接 return」会把这段时间里的
  /// 键盘 / 手柄改动（指针才被挡住）和滑条松手静默丢掉。现在保存中到来的改动合并
  /// 成最新一份排在后面写，永不丢。
  Future<void> _save(Map<String, Object?> next) {
    setState(() => _overrides = next);
    _queued = next;
    return _drain ??= _drainQueue();
  }

  Future<void> _drainQueue() async {
    try {
      while (_queued != null) {
        final Map<String, Object?> value = _queued!;
        _queued = null;
        try {
          await widget.onChanged(value);
          _persisted = value;
        } catch (_) {
          // 失败的这份之后若还有排队改动，它们是基于失败值算的，一并作废。
          _queued = null;
          if (mounted) {
            setState(() => _overrides = _persisted);
            _reportSaveFailure();
          }
        }
      }
    } finally {
      _drain = null;
    }
  }

  void _reportSaveFailure() {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(FushiSnackBar(content: Text(t.manga_reader_save_failed)));
  }

  /// 全局默认改一笔：界面立即显示，补丁串行写入，失败回滚到最后成功的值。
  Future<void> _setGlobal(Map<String, Object?> patch) {
    final Future<void> Function(Map<String, Object?>)? write =
        widget.onGlobalChanged;
    if (write == null) return Future<void>.value();
    setState(() => _global = _global.copyWithJson(patch));
    final Future<void> next = _globalChain.then((_) async {
      try {
        await write(patch);
        _globalPersisted = _globalPersisted.copyWithJson(patch);
      } catch (_) {
        if (!mounted) return;
        setState(() => _global = _globalPersisted);
        _reportSaveFailure();
      }
    });
    _globalChain = next;
    return next;
  }

  Future<void> _set(String key, Object? value) async {
    if (_globalScope) {
      if (value == null || !_editable(key)) return;
      await _setGlobal(<String, Object?>{key: value});
      return;
    }
    final Map<String, Object?> next = Map<String, Object?>.from(_overrides);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    await _save(next);
  }

  /// `auto` 不是一个布局值，而是「跟随作品自动判定」——写 autoMode 而不是
  /// 覆盖 mode，否则退出自动后就没有可回落的布局了。
  Future<void> _setMode(String selected) async {
    final Map<String, Object?> patch = selected == 'auto'
        ? <String, Object?>{'autoMode': true}
        : <String, Object?>{'autoMode': false, 'mode': selected};
    if (_globalScope) {
      await _setGlobal(patch);
    } else if (selected == 'auto') {
      await _set('autoMode', true);
    } else {
      await _save(<String, Object?>{..._overrides, ...patch});
    }
  }

  /// 单项恢复为全局值（只在「当前作品」作用域出现）。
  Future<void> _clear(String key) {
    final Map<String, Object?> next = Map<String, Object?>.from(_overrides);
    if (key == 'mode') {
      next
        ..remove('mode')
        ..remove('autoMode');
    } else {
      next.remove(key);
    }
    return _save(next);
  }

  Future<void> _reset() => _save(<String, Object?>{});

  String _label(String key, Object? value) => switch (key) {
    'mode' => switch (value) {
      'auto' => t.manga_reading_mode_auto,
      'spread' => t.manga_reading_mode_spread,
      'paged_vertical' => t.manga_reading_mode_vertical,
      'webtoon_gaps' => t.manga_reading_mode_gaps,
      _ => t.manga_reading_mode_webtoon,
    },
    'background' => switch (value) {
      'white' => t.manga_background_white,
      'gray' => t.manga_background_gray,
      'theme' => t.manga_background_theme,
      _ => t.manga_background_black,
    },
    'ocrTrigger' =>
      value == 'manual'
          ? t.manga_reader_ocr_manual
          : t.manga_reader_ocr_automatic,
    'direction' =>
      value == 'ltr' ? t.manga_direction_ltr : t.manga_direction_rtl,
    'scaleType' => switch (value) {
      'stretch' => t.manga_scale_stretch,
      'fit_width' => t.manga_scale_fit_width,
      'fit_height' => t.manga_scale_fit_height,
      'original' => t.manga_scale_original,
      'smart' => t.manga_scale_smart,
      _ => t.manga_scale_fit_screen,
    },
    'tapZones' => switch (value) {
      'edge' => t.manga_reader_tap_edge,
      'disabled' => t.manga_reader_tap_disabled,
      'l_shaped' => t.manga_reader_tap_l_shaped,
      'right_left' => t.manga_reader_tap_right_left,
      'kindle' => t.manga_reader_tap_kindle,
      _ => t.manga_reader_tap_default,
    },
    'saveDirectory' => switch (value) {
      'flat' => t.manga_reader_save_flat,
      'book' => t.manga_reader_save_book,
      _ => t.manga_reader_save_chapter,
    },
    _ => '$value',
  };

  /// 阅读模式选择卡的示意图标。
  static IconData _modeIcon(String mode) => switch (mode) {
    'auto' => FushiIcons.brightnessAuto,
    'spread' => FushiIcons.manga,
    'paged_vertical' => FushiIcons.swap,
    'webtoon_gaps' => FushiIcons.gridView,
    _ => FushiIcons.listView,
  };

  /// 每行的前置图标（同组行都有图标，列表读起来是一列整齐的形状底）。
  static IconData? _rowIcon(String key) => switch (key) {
    'direction' => FushiIcons.swap,
    'scaleType' => FushiIcons.zoomIn,
    'tapZones' => FushiIcons.touch,
    'longStripSidePadding' => FushiIcons.gridView,
    'splitWidePages' => FushiIcons.image,
    'rotateWidePages' => FushiIcons.refresh,
    'cropBorders' => FushiIcons.zoomOut,
    'showPageGaps' => FushiIcons.listView,
    'webtoonDoubleTapZoom' => FushiIcons.zoomIn,
    'autoScroll' => FushiIcons.play,
    'autoScrollSpeed' => FushiIcons.speed,
    'animateDoubleTap' => FushiIcons.touch,
    'disableZoomOut' => FushiIcons.zoomOut,
    'animateTransitions' => FushiIcons.forward,
    'invertHorizontal' => FushiIcons.swap,
    'invertVertical' => FushiIcons.swap,
    'invertBoth' => FushiIcons.swap,
    'invertVolumeKeys' => FushiIcons.volumeUp,
    'skipRead' => FushiIcons.check,
    'skipDuplicate' => FushiIcons.copy,
    'downloadAhead' => FushiIcons.download,
    'background' => FushiIcons.appearance,
    'automaticBackground' => FushiIcons.brightnessAuto,
    'showPageNumber' => FushiIcons.bookmark,
    'fullscreen' => FushiIcons.fullscreen,
    'keepScreenOn' => FushiIcons.lightMode,
    'einkMode' => FushiIcons.readingMode,
    'flashOnPageChange' => FushiIcons.lightMode,
    'readerHideThreshold' => FushiIcons.visibilityOff,
    'showReadingMode' => FushiIcons.info,
    'showTapZonesOverlay' => FushiIcons.touch,
    'saveDirectory' => FushiIcons.folder,
    'invertColors' => FushiIcons.darkMode,
    'grayscale' => FushiIcons.filter,
    'brightness' => FushiIcons.lightMode,
    'contrast' => FushiIcons.brightnessAuto,
    'saturation' => FushiIcons.appearance,
    'customColorFilter' => FushiIcons.filter,
    'colorFilterOpacity' => FushiIcons.visibility,
    'lookupOnHover' => FushiIcons.mouse,
    'showOcrBoxes' => FushiIcons.visibility,
    'ocrTrigger' => FushiIcons.ocr,
    _ => null,
  };

  /// 「当前作品」作用域下改过的行：行首圆点 + 行尾单项「恢复全局值」。
  Widget _modified(String key, Widget row) => SettingsModifiedRow(
    modified: !_globalScope && _isOverridden(key),
    onReset: () => unawaited(_clear(key)),
    child: row,
  );

  Widget _toggle(MangaReaderPreferenceDescriptor d) {
    final IconData? icon = _rowIcon(d.key);
    return _modified(
      d.key,
      AdaptiveSettingsSwitchRow(
        title: d.title,
        subtitle: _scopeNote(d.key),
        subtitleMaxLines: 1,
        icon: icon,
        showIcon: icon != null,
        value: _value(d.key) == true,
        onChanged: _editable(d.key) ? (bool v) => _set(d.key, v) : null,
      ),
    );
  }

  Widget _integer(MangaReaderPreferenceDescriptor d) {
    // 覆盖值可能来自同步或旧版本、落在滑条区间外（偏好解析允许的范围比滑条宽，
    // 如 readerHideThreshold 允许 0）：Slider 对越界值直接断言，先夹进区间。
    final int value =
        (_sliderValues[d.key] ?? (_value(d.key) as num?)?.round() ?? d.min!)
            .clamp(d.min!, d.max!);
    final IconData? icon = _rowIcon(d.key);
    return _modified(
      d.key,
      AdaptiveSettingsSliderRow(
        title: d.title,
        subtitle: _scopeNote(d.key),
        icon: icon,
        showIcon: icon != null,
        value: value.toDouble(),
        min: d.min!.toDouble(),
        max: d.max!.toDouble(),
        divisions: d.max! - d.min!,
        label: '$value',
        readout: '$value',
        // 拖动中只改草稿值（滤镜预览随之实时变化），松手才落库：落库要整窗重载。
        onChanged: (double v) =>
            setState(() => _sliderValues[d.key] = v.round()),
        onChangeEnd: (double v) async {
          await _set(d.key, v.round());
          if (mounted) setState(() => _sliderValues.remove(d.key));
        },
      ),
    );
  }

  List<MangaPanelOption<String>> _options(MangaReaderPreferenceDescriptor d) =>
      <MangaPanelOption<String>>[
        for (final String choice in d.choices)
          MangaPanelOption<String>(value: choice, label: _label(d.key, choice)),
      ];

  /// 少而短的选项（方向、背景、OCR 触发）用整行按钮组；其余用选择行（点开弹层）。
  static const Set<String> _segmentedKeys = <String>{
    'direction',
    'background',
    'ocrTrigger',
  };

  Widget _choice(MangaReaderPreferenceDescriptor d) {
    if (d.key == 'colorFilterColor') return _colorRow(d);
    final String selected = _value(d.key) as String? ?? d.choices.first;
    final ValueChanged<String>? onChanged = _editable(d.key)
        ? (String value) => unawaited(_set(d.key, value))
        : null;
    if (_segmentedKeys.contains(d.key)) {
      return _modified(
        d.key,
        MangaPanelSegmentedRow<String>(
          title: d.title,
          subtitle: _scopeNote(d.key),
          icon: _rowIcon(d.key),
          info: d.key == 'ocrTrigger' ? t.manga_reader_ocr_engine_note : null,
          options: _options(d),
          selected: selected,
          onChanged: onChanged,
        ),
      );
    }
    return _modified(
      d.key,
      MangaPanelChoiceRow<String>(
        title: d.title,
        icon: _rowIcon(d.key),
        options: _options(d),
        selected: selected,
        onChanged: onChanged,
      ),
    );
  }

  bool _validColor(String? value) =>
      value != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value);

  void _submitColor(String key, String? value) {
    if (!mounted || !_validColor(value)) return;
    final String normalized = value!.toUpperCase();
    setState(() => _draftColor = null);
    if (_value(key) == normalized) return;
    unawaited(_set(key, normalized));
  }

  /// 叠加色：预设色板 + 自定义 `#RRGGBB` 输入（失焦也提交：只认回车会把输到
  /// 一半的合法颜色静默丢掉）。
  Widget _colorRow(MangaReaderPreferenceDescriptor d) {
    final ThemeData theme = Theme.of(context);
    final String? current = (_value(d.key) as String?)?.toUpperCase();
    final String? draft = _draftColor;
    final bool draftInvalid =
        draft != null && draft.isNotEmpty && !_validColor(draft);
    final Color? swatch = MangaPanelColorSwatches.parse(
      _validColor(draft) ? draft : current,
    );
    return _modified(
      d.key,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(d.title, style: FushiDesignTokens.of(context).type.listTitle),
            if (_scopeNote(d.key) case final String note)
              Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fushiNeutralSecondaryForeground(context),
                ),
              ),
            const SizedBox(height: 12),
            MangaPanelColorSwatches(
              colors: d.choices,
              selected: current,
              onChanged: (String hex) => _submitColor(d.key, hex),
            ),
            const SizedBox(height: 12),
            Focus(
              skipTraversal: true,
              onFocusChange: (bool focused) {
                if (!focused) _submitColor(d.key, _draftColor);
              },
              child: FushiTextField(
                key: ValueKey<String>('manga_filter_color_$current'),
                initialValue: current,
                size: FushiInputSize.medium,
                labelText: t.manga_reader_custom_color,
                hintText: '#RRGGBB',
                errorText: draftInvalid ? '#RRGGBB' : null,
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(7),
                ],
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: AnimatedContainer(
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    width: 20,
                    height: 20,
                    decoration: ShapeDecoration(
                      color: swatch ?? Colors.transparent,
                      shape: CircleBorder(
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                onChanged: (String value) =>
                    setState(() => _draftColor = value),
                onSubmitted: (String value) => _submitColor(d.key, value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(MangaReaderPreferenceDescriptor d) => switch (d.kind) {
    MangaReaderPreferenceKind.choice => _choice(d),
    MangaReaderPreferenceKind.toggle => _toggle(d),
    MangaReaderPreferenceKind.integer => _integer(d),
  };

  /// 旧四页归属（未登记进下面分组表的项按它落到所属页末尾的「其他」组，
  /// 新加的偏好不会凭空消失）。
  int _tab(String key) {
    if (const <String>{
      'invertColors',
      'grayscale',
      'brightness',
      'contrast',
      'saturation',
      'customColorFilter',
      'colorFilterColor',
      'colorFilterOpacity',
    }.contains(key)) {
      return 2;
    }
    if (const <String>{
      'ocrTrigger',
      'showOcrBoxes',
      'lookupOnHover',
    }.contains(key)) {
      return 3;
    }
    if (const <String>{
      'background',
      'automaticBackground',
      'showPageNumber',
      'fullscreen',
      'keepScreenOn',
      'einkMode',
      'flashOnPageChange',
      'readerHideThreshold',
      'showReadingMode',
      'showTapZonesOverlay',
      'saveDirectory',
    }.contains(key)) {
      return 1;
    }
    return 0;
  }

  /// 分组表：页 → [(标题, 键…)]。顺序即页内顺序。`mode` 是页顶的选择卡，
  /// 不在表里。
  static List<(String Function(), List<String>)> _groupsFor(
    int tab,
  ) => switch (tab) {
    0 => <(String Function(), List<String>)>[
      (
        () => t.manga_reader_group_layout,
        <String>['direction', 'scaleType', 'tapZones', 'longStripSidePadding'],
      ),
      (
        () => t.manga_reader_group_wide_pages,
        <String>['splitWidePages', 'rotateWidePages', 'cropBorders'],
      ),
      (
        () => t.manga_reader_group_long_strip,
        <String>[
          'showPageGaps',
          'webtoonDoubleTapZoom',
          'autoScroll',
          'autoScrollSpeed',
        ],
      ),
      (
        () => t.manga_reader_group_controls,
        <String>[
          'animateDoubleTap',
          'disableZoomOut',
          'animateTransitions',
          'invertHorizontal',
          'invertVertical',
          'invertBoth',
          'invertVolumeKeys',
        ],
      ),
      (
        () => t.manga_reader_group_chapters,
        <String>['skipRead', 'skipDuplicate', 'downloadAhead'],
      ),
    ],
    1 => <(String Function(), List<String>)>[
      (
        () => t.manga_reader_group_page,
        <String>['background', 'automaticBackground', 'showPageNumber'],
      ),
      (
        () => t.manga_reader_group_screen,
        <String>[
          'fullscreen',
          'keepScreenOn',
          'einkMode',
          'flashOnPageChange',
          'readerHideThreshold',
        ],
      ),
      (
        () => t.manga_reader_group_hints,
        <String>['showReadingMode', 'showTapZonesOverlay'],
      ),
      (() => t.manga_reader_group_other, <String>['saveDirectory']),
    ],
    2 => <(String Function(), List<String>)>[
      (() => t.manga_reader_group_color, <String>['invertColors', 'grayscale']),
      (
        () => t.manga_reader_group_adjust,
        <String>['brightness', 'contrast', 'saturation'],
      ),
      (
        () => t.manga_reader_group_overlay,
        <String>['customColorFilter', 'colorFilterColor', 'colorFilterOpacity'],
      ),
    ],
    _ => <(String Function(), List<String>)>[
      (
        () => t.manga_reader_group_ocr_lookup,
        <String>['lookupOnHover', 'showOcrBoxes', 'ocrTrigger'],
      ),
    ],
  };

  List<Widget> _tabBlocks(
    int tab,
    Map<String, MangaReaderPreferenceDescriptor> byKey,
  ) {
    final List<(String Function(), List<String>)> groups = _groupsFor(tab);
    final Set<String> placed = <String>{
      'mode',
      for (final (String Function(), List<String>) g in groups) ...g.$2,
    };
    final List<MangaReaderPreferenceDescriptor> orphans =
        <MangaReaderPreferenceDescriptor>[
          for (final MangaReaderPreferenceDescriptor d in byKey.values)
            if (_tab(d.key) == tab && !placed.contains(d.key)) d,
        ];
    return <Widget>[
      if (tab == 0 && byKey['mode'] != null) _modeBlock(byKey['mode']!),
      if (tab == 2) _filterPreview(),
      for (final (String Function(), List<String>) g in groups)
        MangaPanelGroup(
          title: g.$1(),
          children: <Widget>[
            for (final String key in g.$2)
              if (byKey[key] case final MangaReaderPreferenceDescriptor d)
                _row(d),
          ],
        ),
      if (orphans.isNotEmpty)
        MangaPanelGroup(
          title: t.manga_reader_group_other,
          children: <Widget>[
            for (final MangaReaderPreferenceDescriptor d in orphans) _row(d),
          ],
        ),
      if (tab == 3 && widget.ocrSettings != null) widget.ocrSettings!,
    ];
  }

  /// 阅读模式：页顶一组带示意图标的选择卡（自动 + 四种布局）。
  Widget _modeBlock(MangaReaderPreferenceDescriptor d) {
    final String selected = _value('mode') as String? ?? d.choices.first;
    final bool modified = !_globalScope && _isOverridden('mode');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: ReaderSideSheetSectionLabel(d.title)),
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: modified
                    ? FushiIconButtonControl(
                        key: const ValueKey<String>('manga_mode_reset'),
                        icon: const FushiIcon(FushiIcons.restart, size: 20),
                        tooltip: t.settings_reset_to_default,
                        onPressed: () => unawaited(_clear('mode')),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          if (_scopeNote('mode') case final String note)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                note,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: fushiNeutralSecondaryForeground(context),
                ),
              ),
            ),
          MangaPanelModeCards<String>(
            options: <MangaPanelOption<String>>[
              for (final String choice in d.choices)
                MangaPanelOption<String>(
                  value: choice,
                  label: _label('mode', choice),
                  icon: _modeIcon(choice),
                  key: ValueKey<String>('manga_mode_card_$choice'),
                ),
            ],
            selected: selected,
            onChanged: (String value) {
              if (value != selected) unawaited(_setMode(value));
            },
          ),
        ],
      ),
    );
  }

  /// 滤镜页顶的实时预览：读草稿值（滑条拖动中）与当前值。
  Widget _filterPreview() {
    final String? draft = _draftColor;
    final String? color = _validColor(draft)
        ? draft
        : _value('colorFilterColor') as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MangaPanelFilterPreview(
        invert: _value('invertColors') == true,
        grayscale: _value('grayscale') == true || _value('einkMode') == true,
        brightness: _intValue('brightness'),
        contrast: _intValue('contrast'),
        saturation: _intValue('saturation'),
        overlayColor: _value('customColorFilter') == true
            ? MangaPanelColorSwatches.parse(color)
            : null,
        overlayOpacity: _intValue('colorFilterOpacity'),
      ),
    );
  }

  Widget _tabsBar() {
    final List<ReaderPanelTab> tabs = <ReaderPanelTab>[
      ReaderPanelTab(
        label: t.manga_reader_tab_mode,
        icon: FushiIcons.readingMode,
        key: const ValueKey<String>('manga_settings_tab_label_0'),
      ),
      ReaderPanelTab(
        label: t.manga_reader_general,
        icon: FushiIcons.settings,
        key: const ValueKey<String>('manga_settings_tab_label_1'),
      ),
      ReaderPanelTab(
        label: t.manga_reader_tab_filters,
        icon: FushiIcons.filter,
        key: const ValueKey<String>('manga_settings_tab_label_2'),
      ),
      ReaderPanelTab(
        label: t.manga_reader_tab_ocr,
        icon: FushiIcons.ocr,
        key: const ValueKey<String>('manga_settings_tab_label_3'),
      ),
    ];
    // 四段带图标至少要这么宽；更窄（小屏手机竖屏）就整排横滑，不压扁文字。
    const double minWidth = 384;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Widget bar = ReaderPanelTabs(controller: _tabs, tabs: tabs);
          if (constraints.maxWidth >= minWidth) return bar;
          return HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: minWidth, child: bar),
            ),
          );
        },
      ),
    );
  }

  /// 底部悬浮的作用域胶囊：「当前作品 / 全局」连接式分段 + 恢复默认（tonal）。
  Widget _scopeBar(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget bar = DecoratedBox(
      decoration: fushiFloatingPillDecoration(
        context,
        color: glass
            ? appleColorsOf(context).secondaryGroupedBackground
            : scheme.surfaceContainerHigh,
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiSegmentedButton<MangaReaderSettingsScope>(
              key: const ValueKey<String>('manga_reader_scope'),
              showSelectedIcon: false,
              segments: <ButtonSegment<MangaReaderSettingsScope>>[
                ButtonSegment<MangaReaderSettingsScope>(
                  value: MangaReaderSettingsScope.work,
                  label: Text(t.manga_reader_override),
                ),
                ButtonSegment<MangaReaderSettingsScope>(
                  value: MangaReaderSettingsScope.global,
                  enabled: widget.onGlobalChanged != null,
                  label: Text(t.manga_reader_scope_global),
                ),
              ],
              selected: <MangaReaderSettingsScope>{_scope},
              onSelectionChanged: (Set<MangaReaderSettingsScope> next) {
                if (next.isEmpty || next.first == _scope) return;
                setState(() {
                  _scope = next.first;
                  _sliderValues.clear();
                  _draftColor = null;
                });
              },
            ),
            AnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.standard,
              child: _globalScope
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsetsDirectional.only(start: 8),
                      child: Semantics(
                        hint: t.manga_reader_restore,
                        child: FushiFilledButton.tonalIcon(
                          key: const ValueKey<String>('manga_reader_restore'),
                          onPressed: _overrides.isEmpty ? null : _reset,
                          icon: const FushiIcon(FushiIcons.restart, size: 18),
                          label: Text(t.manga_reader_scope_reset),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.release,
      builder: (BuildContext context, double v, Widget? child) =>
          Transform.translate(
            offset: Offset(0, (1 - v) * 56),
            child: Opacity(opacity: v.clamp(0.0, 1.0), child: child),
          ),
      child: FittedBox(fit: BoxFit.scaleDown, child: bar),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, MangaReaderPreferenceDescriptor> byKey =
        <String, MangaReaderPreferenceDescriptor>{
          for (final MangaReaderPreferenceDescriptor d
              in mangaReaderPreferenceDescriptors(widget.supportedDeviceKeys))
            d.key: d,
        };
    final double safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ReaderSideSheet(
      title: t.manga_reader_settings,
      icon: FushiIcons.manga,
      subtitle: _globalScope
          ? t.manga_reader_scope_hint
          : (_overrides.isEmpty
                ? t.manga_reader_global
                : t.manga_reader_override),
      onClose: () => Navigator.of(context).maybePop(),
      scrollable: false,
      bottom: _tabsBar(),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                for (int tab = 0; tab < 4; tab++)
                  FushiEntranceScope(
                    child: ListView(
                      key: PageStorageKey<String>('manga_settings_tab_$tab'),
                      // 底部让出悬浮作用域条与系统手势区，最后一行不被压住。
                      padding: EdgeInsets.fromLTRB(
                        16,
                        8,
                        16,
                        _kScopeBarReserve + safeBottom,
                      ),
                      children: <Widget>[
                        for (final (int i, Widget block) in _tabBlocks(
                          tab,
                          byKey,
                        ).indexed)
                          FushiStaggeredEntrance(index: i, child: block),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          PositionedDirectional(
            start: 16,
            end: 16,
            bottom: 12 + safeBottom,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[Flexible(child: _scopeBar(context))],
            ),
          ),
        ],
      ),
    );
  }
}
