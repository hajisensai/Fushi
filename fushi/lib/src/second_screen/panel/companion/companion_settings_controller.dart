import 'package:flutter/foundation.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';

/// What one Settings tab page shows: the overview (the top screen's rows +
/// every category), one category's rows, or search results. Built from the
/// main engine's `settings.list` replies; rows are replaced in place on
/// writes.
@immutable
class CompanionSettingsView {
  const CompanionSettingsView({
    required this.rows,
    this.category,
    this.categories = const <CompanionSettingsCategory>[],
  });

  factory CompanionSettingsView.overview(CompanionSettingsOverview overview) {
    final CompanionSettingsPage? context = overview.context;
    return CompanionSettingsView(
      category: context?.category,
      rows: context?.rows ?? const <CompanionSettingRow>[],
      categories: overview.categories,
    );
  }

  factory CompanionSettingsView.page(CompanionSettingsPage page) =>
      CompanionSettingsView(category: page.category, rows: page.rows);

  /// Overview: the category the context rows come from (null = the top
  /// screen has no settings). Category page: that category. Search: null.
  final CompanionSettingsCategory? category;
  final List<CompanionSettingRow> rows;

  /// Overview only.
  final List<CompanionSettingsCategory> categories;

  /// The same view with the row of [row]'s key replaced by [row].
  CompanionSettingsView replacing(CompanionSettingRow row) =>
      CompanionSettingsView(
        category: category,
        categories: categories,
        rows: <CompanionSettingRow>[
          for (final CompanionSettingRow r in rows) r.key == row.key ? row : r,
        ],
      );
}

/// A number as the companion writes / shows it: whole numbers without a
/// fraction, others with at most four decimals and no trailing zeros.
String companionSettingNumber(double value, {required bool integer}) {
  if (integer || value == value.roundToDouble()) {
    return value.round().toString();
  }
  String text = value.toStringAsFixed(4);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

/// The `settings.set` value token of [value] for [row] (the same tokens as
/// `fushi_cli config set`).
String companionSettingToken(CompanionSettingRow row, Object value) =>
    switch (value) {
      final bool b => b ? 'true' : 'false',
      final num n => companionSettingNumber(n.toDouble(), integer: row.integer),
      _ => '$value',
    };

/// The display text shown until the main engine echoes the written row.
String companionSettingDisplay(CompanionSettingRow row, Object value) {
  switch (value) {
    case final num n:
      return companionSettingNumber(n.toDouble(), integer: row.integer);
    case final String token:
      for (final CompanionSettingOption o in row.options) {
        if (o.value == token) return o.label;
      }
      return token;
    default:
      return row.display;
  }
}

Map<String, Object?> _replyObject(Object? reply) {
  if (reply is! Map) {
    throw const CompanionRequestException('unexpected settings reply');
  }
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> e in reply.entries)
      if (e.key is String) e.key! as String: e.value,
  };
}

/// Asks the top screen to open [key]'s page (or [category]). Returns false
/// when the main engine could not.
Future<bool> companionSettingsOpenOnMain(
  CompanionPanelSession session, {
  String? key,
  String? category,
}) async {
  try {
    await session.request(
      CompanionRequestMethods.settingsOpenOnMain,
      <String, Object?>{
        CompanionSettingsArgs.key: ?key,
        CompanionSettingsArgs.category: ?category,
      },
    );
    return true;
  } on CompanionRequestException {
    return false;
  }
}

/// One Settings tab page's data: loads it from the main engine, reloads on
/// demand ([refresh]) one fetch at a time, and writes rows optimistically.
///
/// A [refresh] while a fetch is running marks the data stale; when the fetch
/// returns, its (outdated) result is dropped and exactly one more fetch runs.
class CompanionSettingsFeed extends ChangeNotifier {
  CompanionSettingsFeed._(this.session, this._args);

  /// The overview: the top screen's settings and every category.
  factory CompanionSettingsFeed.overview(CompanionPanelSession session) =>
      CompanionSettingsFeed._(session, () => const <String, Object?>{})
        .._parse = (Map<String, Object?> json) =>
            CompanionSettingsView.overview(
              CompanionSettingsOverview.fromJson(json),
            );

  /// One category's rows.
  factory CompanionSettingsFeed.category(
    CompanionPanelSession session,
    String id,
  ) => CompanionSettingsFeed._(
    session,
    () => <String, Object?>{CompanionSettingsArgs.category: id},
  );

  /// Search results for [query] (set it with [search]).
  factory CompanionSettingsFeed.search(CompanionPanelSession session) {
    late final CompanionSettingsFeed feed;
    feed = CompanionSettingsFeed._(
      session,
      () => <String, Object?>{CompanionSettingsArgs.query: feed._query},
    );
    return feed;
  }

  final CompanionPanelSession session;
  final Map<String, Object?> Function() _args;
  CompanionSettingsView Function(Map<String, Object?> json) _parse =
      (Map<String, Object?> json) =>
          CompanionSettingsView.page(CompanionSettingsPage.fromJson(json));

  CompanionSettingsView? _view;
  bool _failed = false;
  bool _fetching = false;
  bool _stale = false;
  bool _disposed = false;
  String _query = '';

  /// Rows written but not yet echoed (key → optimistic row), so a reload
  /// that crosses a write does not flash the old value.
  final Map<String, CompanionSettingRow> _optimistic =
      <String, CompanionSettingRow>{};
  final Map<String, int> _writes = <String, int>{};

  /// The last loaded data; null until the first fetch returns.
  CompanionSettingsView? get view => _view;

  /// The last fetch failed (the view, if any, is older data).
  bool get failed => _failed;

  /// Nothing to show yet and a fetch is running.
  bool get loading => _view == null && !_failed;

  /// The search query (search feeds).
  String get query => _query;

  /// Search feeds: fetches the results for [query].
  Future<void> search(String query) {
    _query = query;
    return refresh();
  }

  /// Loads the data again (see the class doc for overlapping calls).
  Future<void> refresh() async {
    if (_fetching) {
      _stale = true;
      return;
    }
    _fetching = true;
    do {
      _stale = false;
      try {
        final Object? reply = await session.request(
          CompanionRequestMethods.settingsList,
          _args(),
        );
        if (_stale || _disposed) continue;
        CompanionSettingsView view = _parse(_replyObject(reply));
        for (final CompanionSettingRow row in _optimistic.values) {
          view = view.replacing(row);
        }
        _view = view;
        _failed = false;
      } on CompanionRequestException {
        if (_stale || _disposed) continue;
        _failed = true;
      }
    } while (_stale && !_disposed);
    _fetching = false;
    _notify();
  }

  /// After a failed load: shows the spinner again and reloads.
  Future<void> retry() {
    if (_failed) {
      _failed = false;
      _notify();
    }
    return refresh();
  }

  /// Writes [value] (bool / option token / num) to [row]: shown at once,
  /// then replaced by the row the main engine re-read. Returns false (and
  /// puts the old row back) when the write failed.
  Future<bool> write(CompanionSettingRow row, Object value) async {
    final CompanionSettingRow optimistic = row.withValue(
      value,
      companionSettingDisplay(row, value),
    );
    _optimistic[row.key] = optimistic;
    _writes[row.key] = (_writes[row.key] ?? 0) + 1;
    _replace(optimistic);
    bool ok;
    CompanionSettingRow? echo;
    try {
      final Object? reply = await session
          .request(CompanionRequestMethods.settingsSet, <String, Object?>{
            CompanionSettingsArgs.key: row.key,
            CompanionSettingsArgs.value: companionSettingToken(row, value),
          });
      echo = reply is Map
          ? CompanionSettingRow.fromJson(_replyObject(reply))
          : null;
      ok = true;
    } on CompanionRequestException {
      ok = false;
    }
    final int left = (_writes[row.key] ?? 1) - 1;
    if (left > 0) {
      // A newer write of the same row is on its way; its echo decides.
      _writes[row.key] = left;
      return ok;
    }
    _writes.remove(row.key);
    _optimistic.remove(row.key);
    if (_disposed) return ok;
    if (!ok) {
      _replace(row);
    } else if (echo != null) {
      _replace(echo);
    }
    return ok;
  }

  void _replace(CompanionSettingRow row) {
    final CompanionSettingsView? view = _view;
    if (view == null || _disposed) return;
    _view = view.replacing(row);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
