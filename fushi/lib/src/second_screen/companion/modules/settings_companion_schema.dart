/// Settings module of the companion (the Settings tab): the values that cross
/// between the main engine (`companion_settings_service.dart`, built on the
/// shared settings index `ops/settings_index.dart` that `fushi_cli config`
/// uses) and `CompanionSettingsTab` (companion engine). Pure Dart.
///
/// Requests (`CompanionRequestMethods.settings*`, answered in the MAIN
/// process):
/// - `settings.list` `{}` → [CompanionSettingsOverview] (the settings of the
///   top screen's context first, then all categories);
///   `{category: id}` → [CompanionSettingsPage];
///   `{query: text}` → [CompanionSettingsPage] without a category (search
///   over every visible row, [CompanionSettingsArgs.searchLimit] at most).
/// - `settings.get` `{key}` → one [CompanionSettingRow].
/// - `settings.set` `{key, value}` → the row re-read after the write (setters
///   may clamp / normalise). Only the [CompanionSettingControl.isDirect] rows
///   are written from the companion; values use the same tokens as
///   `fushi_cli config set` (`true` / `false`, numbers, choice tokens).
/// - `settings.openOnMain` `{key}` (that row's page, row highlighted) or
///   `{category: id}` → null; the main screen navigates there.
///
/// The main engine pings `settingsChanged` when a setting may have changed
/// (any preference write, a companion write): the tab reloads what it shows.
library;

import 'package:meta/meta.dart';

/// Argument keys of the settings requests.
abstract final class CompanionSettingsArgs {
  static const String category = 'category';
  static const String query = 'query';
  static const String key = 'key';
  static const String value = 'value';

  /// Search replies carry at most this many rows.
  static const int searchLimit = 60;
}

/// How the companion shows a row.
enum CompanionSettingControl {
  /// On / off ([CompanionSettingRow.value] is a bool).
  toggle,

  /// One of [CompanionSettingRow.options] (value = the option token).
  choice,

  /// A continuous / divided range (value is a double).
  slider,

  /// − / + by [CompanionSettingRow.step] (value is a double).
  stepper,

  /// A number field (value is a num; [CompanionSettingRow.integer]).
  number,

  /// Text, secret, custom, list, action and status rows: shown with their
  /// display value and "Open on main screen".
  open;

  String get wire => name;

  /// Edited on the companion itself (everything but [open]).
  bool get isDirect => this != open;

  static CompanionSettingControl fromWire(Object? value) {
    for (final CompanionSettingControl c in CompanionSettingControl.values) {
      if (c.wire == value) return c;
    }
    return open;
  }
}

/// One choice of a [CompanionSettingControl.choice] row.
@immutable
class CompanionSettingOption {
  const CompanionSettingOption({required this.value, required this.label});

  factory CompanionSettingOption.fromJson(Map<String, Object?> json) =>
      CompanionSettingOption(
        value: _str(json, 'value'),
        label: _str(json, 'label'),
      );

  /// The token written back with `settings.set`.
  final String value;
  final String label;

  Map<String, Object?> toJson() => <String, Object?>{
    'value': value,
    'label': label,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionSettingOption &&
      other.value == value &&
      other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// One setting as the companion shows it.
@immutable
class CompanionSettingRow {
  const CompanionSettingRow({
    required this.key,
    required this.title,
    required this.control,
    required this.display,
    this.value,
    this.subtitle,
    this.section,
    this.options = const <CompanionSettingOption>[],
    this.min,
    this.max,
    this.divisions,
    this.step,
    this.integer = false,
    this.enabled = true,
  });

  factory CompanionSettingRow.fromJson(Map<String, Object?> json) =>
      CompanionSettingRow(
        key: _str(json, 'key'),
        title: _str(json, 'title'),
        control: CompanionSettingControl.fromWire(json['control']),
        display: _str(json, 'display'),
        value: json['value'],
        subtitle: _strOrNull(json, 'subtitle'),
        section: _strOrNull(json, 'section'),
        options: <CompanionSettingOption>[
          for (final Map<String, Object?> o in _maps(json['options']))
            CompanionSettingOption.fromJson(o),
        ],
        min: _num(json['min'])?.toDouble(),
        max: _num(json['max'])?.toDouble(),
        divisions: _num(json['divisions'])?.toInt(),
        step: _num(json['step'])?.toDouble(),
        integer: json['integer'] == true,
        enabled: json['enabled'] != false,
      );

  /// The settings schema id (the `fushi_cli config` key).
  final String key;
  final String title;
  final CompanionSettingControl control;

  /// The current value: bool (toggle), option token (choice), num (slider,
  /// stepper, number); null for [CompanionSettingControl.open] rows.
  final Object? value;

  /// Human-readable current value (formatted number, option label, masked
  /// secret, a status line).
  final String display;

  final String? subtitle;

  /// Where the row sits inside its category (`Section` or
  /// `Sub-page › Section`); search results also lead with the category.
  final String? section;

  final List<CompanionSettingOption> options;
  final double? min;
  final double? max;
  final int? divisions;
  final double? step;
  final bool integer;

  /// False when the row is greyed out on the main screen too.
  final bool enabled;

  bool? get boolValue => value is bool ? value! as bool : null;

  double? get doubleValue => value is num ? (value! as num).toDouble() : null;

  String? get choiceValue => value is String ? value! as String : null;

  /// The same row with [value] / [display] replaced (optimistic UI before
  /// the main engine's echo arrives).
  CompanionSettingRow withValue(Object? value, String display) =>
      CompanionSettingRow(
        key: key,
        title: title,
        control: control,
        display: display,
        value: value,
        subtitle: subtitle,
        section: section,
        options: options,
        min: min,
        max: max,
        divisions: divisions,
        step: step,
        integer: integer,
        enabled: enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'title': title,
    'control': control.wire,
    'display': display,
    if (value != null) 'value': value,
    if (subtitle != null) 'subtitle': subtitle,
    if (section != null) 'section': section,
    if (options.isNotEmpty)
      'options': <Map<String, Object?>>[
        for (final CompanionSettingOption o in options) o.toJson(),
      ],
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (divisions != null) 'divisions': divisions,
    if (step != null) 'step': step,
    if (integer) 'integer': true,
    if (!enabled) 'enabled': false,
  };
}

/// A top-level settings category (a settings schema destination).
@immutable
class CompanionSettingsCategory {
  const CompanionSettingsCategory({required this.id, required this.title});

  factory CompanionSettingsCategory.fromJson(Map<String, Object?> json) =>
      CompanionSettingsCategory(
        id: _str(json, 'id'),
        title: _str(json, 'title'),
      );

  /// The destination id (`SettingsDestinationId.name`).
  final String id;
  final String title;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'title': title};

  @override
  bool operator ==(Object other) =>
      other is CompanionSettingsCategory &&
      other.id == id &&
      other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

/// A list of rows: one category's rows, the top screen's settings, or search
/// results ([category] null).
@immutable
class CompanionSettingsPage {
  const CompanionSettingsPage({required this.rows, this.category});

  factory CompanionSettingsPage.fromJson(Map<String, Object?> json) {
    final Object? category = json['category'];
    return CompanionSettingsPage(
      category: category is Map
          ? CompanionSettingsCategory.fromJson(_object(category))
          : null,
      rows: <CompanionSettingRow>[
        for (final Map<String, Object?> r in _maps(json['rows']))
          CompanionSettingRow.fromJson(r),
      ],
    );
  }

  final CompanionSettingsCategory? category;
  final List<CompanionSettingRow> rows;

  Map<String, Object?> toJson() => <String, Object?>{
    if (category != null) 'category': category!.toJson(),
    'rows': <Map<String, Object?>>[
      for (final CompanionSettingRow r in rows) r.toJson(),
    ],
  };
}

/// The Settings tab's first page: the top screen's settings ([context], null
/// when the top screen has none: home, a page without settings) and every
/// visible category.
@immutable
class CompanionSettingsOverview {
  const CompanionSettingsOverview({required this.categories, this.context});

  factory CompanionSettingsOverview.fromJson(Map<String, Object?> json) {
    final Object? context = json['context'];
    return CompanionSettingsOverview(
      context: context is Map
          ? CompanionSettingsPage.fromJson(_object(context))
          : null,
      categories: <CompanionSettingsCategory>[
        for (final Map<String, Object?> c in _maps(json['categories']))
          CompanionSettingsCategory.fromJson(c),
      ],
    );
  }

  /// The top screen's settings; its [CompanionSettingsPage.category] is the
  /// category they come from ("For this screen · <title>").
  final CompanionSettingsPage? context;
  final List<CompanionSettingsCategory> categories;

  Map<String, Object?> toJson() => <String, Object?>{
    if (context != null) 'context': context!.toJson(),
    'categories': <Map<String, Object?>>[
      for (final CompanionSettingsCategory c in categories) c.toJson(),
    ],
  };
}

Map<String, Object?> _object(Object? value) => value is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries)
          if (e.key is String) e.key! as String: e.value,
      }
    : const <String, Object?>{};

List<Map<String, Object?>> _maps(Object? raw) => raw is List
    ? <Map<String, Object?>>[
        for (final Object? e in raw)
          if (e is Map) _object(e),
      ]
    : const <Map<String, Object?>>[];

String _str(Map<String, Object?> json, String key) {
  final Object? v = json[key];
  return v is String ? v : '';
}

String? _strOrNull(Map<String, Object?> json, String key) {
  final Object? v = json[key];
  return v is String && v.isNotEmpty ? v : null;
}

num? _num(Object? v) => v is num ? v : null;
