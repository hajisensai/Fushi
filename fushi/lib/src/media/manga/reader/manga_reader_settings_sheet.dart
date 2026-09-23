import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheetSide, showReaderSideSheet;

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
    MapEntry<String, String>('skipRead', t.manga_reader_skip_read),
    MapEntry<String, String>('skipFiltered', t.manga_reader_skip_filtered),
    MapEntry<String, String>('skipDuplicate', t.manga_reader_skip_duplicate),
    MapEntry<String, String>(
      'alwaysShowChapterTransition',
      t.manga_reader_transition,
    ),
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

/// 漫画阅读设置面板：固定在右侧（章节目录占左侧），不提供左右换边。
Future<void> showMangaReaderSettingsSheet({
  required BuildContext context,
  required MangaReaderPreferences globalDefaults,
  Widget? ocrSettings,
  Map<String, Object?> overrides = const <String, Object?>{},
  required Future<void> Function(Map<String, Object?>) onChanged,
  Set<String> supportedDeviceKeys = const <String>{},
}) async => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  builder: (BuildContext context) => MangaReaderSettingsSheet(
    ocrSettings: ocrSettings,
    globalDefaults: globalDefaults,
    overrides: overrides,
    onChanged: onChanged,
    supportedDeviceKeys: supportedDeviceKeys,
  ),
);

class MangaReaderSettingsSheet extends StatefulWidget {
  const MangaReaderSettingsSheet({
    super.key,
    required this.globalDefaults,
    required this.overrides,
    required this.onChanged,
    this.supportedDeviceKeys = const <String>{},
    this.ocrSettings,
  });
  final MangaReaderPreferences globalDefaults;
  final Map<String, Object?> overrides;
  final Future<void> Function(Map<String, Object?>) onChanged;
  final Set<String> supportedDeviceKeys;
  final Widget? ocrSettings;
  @override
  State<MangaReaderSettingsSheet> createState() =>
      _MangaReaderSettingsSheetState();
}

class _MangaReaderSettingsSheetState extends State<MangaReaderSettingsSheet> {
  late Map<String, Object?> _overrides;

  /// 最后一次成功落库的覆盖值：保存失败时回滚到这里，而不是回滚到「点之前」——
  /// 队列里前面的改动可能已经写成功了。
  late Map<String, Object?> _persisted;

  /// 保存进行中又来的改动只留最新一份（整份覆盖值，后写覆盖前写）。
  Map<String, Object?>? _queued;
  Future<void>? _drain;
  final Map<String, int> _sliderValues = <String, int>{};
  @override
  void initState() {
    super.initState();
    _overrides = Map<String, Object?>.from(widget.overrides);
    _persisted = _overrides;
  }

  MangaReaderPreferences get _effective =>
      MangaReaderPreferences.resolve(widget.globalDefaults, _overrides);
  Object? _value(String key) =>
      key == 'mode' && _effective.autoMode ? 'auto' : _effective.toJson()[key];

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
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(t.manga_reader_save_failed)));
          }
        }
      }
    } finally {
      _drain = null;
    }
  }

  Future<void> _set(String key, Object? value) async {
    final Map<String, Object?> next = Map<String, Object?>.from(_overrides);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    await _save(next);
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

  String? _draftColor;

  void _submitColor(String key, String? value) {
    if (!mounted ||
        value == null ||
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      return;
    }
    final String normalized = value.toUpperCase();
    if (_value(key) == normalized) return;
    unawaited(_set(key, normalized));
  }

  Widget _choice(MangaReaderPreferenceDescriptor d) =>
      d.key == 'colorFilterColor'
      ? Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          // 失焦（Tab 走开、点别处）也提交：只认回车会把输到一半的合法颜色静默丢掉。
          child: Focus(
            skipTraversal: true,
            onFocusChange: (bool focused) {
              if (!focused) _submitColor(d.key, _draftColor);
            },
            child: TextFormField(
              key: ValueKey<String>('manga_filter_color_${_value(d.key)}'),
              initialValue: _value(d.key) as String?,
              decoration: InputDecoration(
                labelText: d.title,
                hintText: '#RRGGBB',
              ),
              maxLength: 7,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (String? value) =>
                  RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value ?? '')
                  ? null
                  : '#RRGGBB',
              onFieldSubmitted: (String value) => _submitColor(d.key, value),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              onChanged: (String value) => _draftColor = value,
            ),
          ),
        )
      : AdaptiveSettingsPickerRow<String>(
          title: d.title,
          options: <AdaptiveSettingsPickerOption<String>>[
            for (final String choice in d.choices)
              AdaptiveSettingsPickerOption<String>(
                value: choice,
                label: _label(d.key, choice),
              ),
          ],
          selected: _value(d.key) as String? ?? d.choices.first,
          onChanged: (String selected) async {
            // `auto` 不是一个布局值，而是「跟随作品自动判定」——写 autoMode 而不是
            // 覆盖 mode，否则退出自动后就没有可回落的布局了。
            if (d.key == 'mode') {
              if (selected == 'auto') {
                await _set('autoMode', true);
              } else {
                await _save(<String, Object?>{
                  ..._overrides,
                  'autoMode': false,
                  'mode': selected,
                });
              }
            } else {
              await _set(d.key, selected);
            }
          },
        );
  Widget _toggle(MangaReaderPreferenceDescriptor d) =>
      AdaptiveSettingsSwitchRow(
        title: d.title,
        value: _value(d.key) == true,
        onChanged: (bool v) => _set(d.key, v),
      );
  Widget _integer(MangaReaderPreferenceDescriptor d) {
    // 覆盖值可能来自同步或旧版本、落在滑条区间外（偏好解析允许的范围比滑条宽，
    // 如 readerHideThreshold 允许 0）：Slider 对越界值直接断言，先夹进区间。
    final int value =
        (_sliderValues[d.key] ?? (_value(d.key) as num?)?.round() ?? d.min!)
            .clamp(d.min!, d.max!);
    return AdaptiveSettingsSliderRow(
      title: d.title,
      value: value.toDouble(),
      min: d.min!.toDouble(),
      max: d.max!.toDouble(),
      divisions: d.max! - d.min!,
      label: '$value',
      readout: '$value',
      onChanged: (double v) => setState(() => _sliderValues[d.key] = v.round()),
      onChangeEnd: (double v) async {
        await _set(d.key, v.round());
        if (mounted) setState(() => _sliderValues.remove(d.key));
      },
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final List<MangaReaderPreferenceDescriptor> ds =
        mangaReaderPreferenceDescriptors(widget.supportedDeviceKeys);
    return DefaultTabController(
      length: 4,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.manga_reader_settings,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          TabBar(
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: <Widget>[
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(t.manga_reading_mode),
                ),
              ),
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(t.manga_reader_general),
                ),
              ),
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(t.manga_reader_filters),
                ),
              ),
              Tab(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(t.manga_ocr_section),
                ),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                for (int tab = 0; tab < 4; tab++)
                  ListView(
                    key: PageStorageKey<String>('manga_settings_tab_$tab'),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    children: <Widget>[
                      for (final MangaReaderPreferenceDescriptor d in ds.where(
                        (MangaReaderPreferenceDescriptor d) =>
                            _tab(d.key) == tab,
                      ))
                        switch (d.kind) {
                          MangaReaderPreferenceKind.choice => _choice(d),
                          MangaReaderPreferenceKind.toggle => _toggle(d),
                          MangaReaderPreferenceKind.integer => _integer(d),
                        },
                      if (tab == 3)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            t.manga_reader_ocr_engine_note,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (tab == 3 && widget.ocrSettings != null)
                        widget.ocrSettings!,
                    ],
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _overrides.isEmpty
                      ? t.manga_reader_global
                      : t.manga_reader_override,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _overrides.isEmpty ? null : _reset,
                    child: Text(
                      t.manga_reader_restore,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
