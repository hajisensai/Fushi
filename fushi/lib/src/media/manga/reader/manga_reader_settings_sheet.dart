import 'package:flutter/material.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
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
    key: 'saveDirectory',
    kind: MangaReaderPreferenceKind.choice,
    title: t.manga_reader_save_directory,
    choices: const <String>['flat', 'book', 'chapter'],
  ),
];

Future<void> showMangaReaderSettingsSheet({
  required BuildContext context,
  required MangaReaderPreferences globalDefaults,
  Map<String, Object?> overrides = const <String, Object?>{},
  required Future<void> Function(Map<String, Object?>) onChanged,
  Set<String> supportedDeviceKeys = const <String>{},
}) async => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (BuildContext context) => MangaReaderSettingsSheet(
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
  });
  final MangaReaderPreferences globalDefaults;
  final Map<String, Object?> overrides;
  final Future<void> Function(Map<String, Object?>) onChanged;
  final Set<String> supportedDeviceKeys;
  @override
  State<MangaReaderSettingsSheet> createState() =>
      _MangaReaderSettingsSheetState();
}

class _MangaReaderSettingsSheetState extends State<MangaReaderSettingsSheet> {
  late Map<String, Object?> _overrides;
  @override
  void initState() {
    super.initState();
    _overrides = Map<String, Object?>.from(widget.overrides);
  }

  MangaReaderPreferences get _effective =>
      MangaReaderPreferences.resolve(widget.globalDefaults, _overrides);
  Object? _value(String key) =>
      key == 'mode' && _effective.autoMode ? 'auto' : _effective.toJson()[key];
  Future<void> _set(String key, Object? value) async {
    final Map<String, Object?> next = Map<String, Object?>.from(_overrides);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    final Map<String, Object?> previous = _overrides;
    setState(() => _overrides = next);
    try {
      await widget.onChanged(next);
    } catch (_) {
      if (mounted) {
        setState(() => _overrides = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t.manga_reader_save_failed)));
      }
    }
  }

  Future<void> _reset() async {
    setState(() => _overrides = <String, Object?>{});
    await widget.onChanged(const <String, Object?>{});
  }

  String _label(String key, Object? value) => switch (key) {
    'mode' => switch (value) {
      'auto' => t.manga_reading_mode_auto,
      'spread' => t.manga_reading_mode_spread,
      'paged_vertical' => t.manga_reading_mode_vertical,
      'webtoon_gaps' => t.manga_reading_mode_gaps,
      _ => t.manga_reading_mode_webtoon,
    },
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

  /// 这一行是否来自本作品的稀疏覆盖（`tune`）而不是全局默认（`public`）。
  IconData _sourceIcon(String key) =>
      _overrides.containsKey(key) ? Icons.tune : Icons.public;

  Widget _choice(MangaReaderPreferenceDescriptor d) =>
      AdaptiveSettingsPickerRow<String>(
        title: d.title,
        icon: _sourceIcon(d.key),
        showIcon: true,
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
              await _set('autoMode', false);
              await _set('mode', selected);
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
        icon: _sourceIcon(d.key),
        showIcon: true,
      );
  Widget _integer(MangaReaderPreferenceDescriptor d) {
    final int value = (_value(d.key) as num?)?.round() ?? 0;
    return AdaptiveSettingsRow(
      title: d.title,
      subtitle: '$value%',
      icon: _sourceIcon(d.key),
      showIcon: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            onPressed: value <= d.min! ? null : () => _set(d.key, value - 1),
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            onPressed: value >= d.max! ? null : () => _set(d.key, value + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<MangaReaderPreferenceDescriptor> ds =
        mangaReaderPreferenceDescriptors(widget.supportedDeviceKeys);
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .85,
        minChildSize: .45,
        maxChildSize: .95,
        builder: (BuildContext c, ScrollController controller) => ListView(
          controller: controller,
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.manga_reader_settings,
              subtitle: _overrides.isEmpty
                  ? t.manga_reader_global
                  : t.manga_reader_override,
              trailing: TextButton(
                onPressed: _overrides.isEmpty ? null : _reset,
                child: Text(t.manga_reader_restore),
              ),
            ),
            for (final MangaReaderPreferenceDescriptor d in ds)
              switch (d.kind) {
                MangaReaderPreferenceKind.choice => _choice(d),
                MangaReaderPreferenceKind.toggle => _toggle(d),
                MangaReaderPreferenceKind.integer => _integer(d),
              },
          ],
        ),
      ),
    );
  }
}
