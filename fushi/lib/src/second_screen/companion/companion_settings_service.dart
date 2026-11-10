import 'package:fushi/src/ops/ctl_settings_body_items.dart' show CtlBodyPage;
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:material_ui/material_ui.dart';

/// The settings category that belongs to what the top screen shows; null
/// when the top screen has no settings of its own (home, dictionary, browse,
/// the settings category list, the game stream).
///
/// | context | category |
/// |---|---|
/// | reader | reading |
/// | audiobook (the reader's audiobook view) | listening (reading when the listening category is not on this device) |
/// | manga | manga |
/// | video | video |
/// | music | music |
/// | srs (review) | cardCreation (its "Review" section) |
/// | library books / manga / video / music / games | reading / manga / video / music / game |
/// | settings | the category open on top ([CompanionContext.settingsCategory]) |
SettingsDestinationId? companionSettingsCategoryFor(CompanionContext context) {
  return switch (context.kind) {
    CompanionContextKind.reader => SettingsDestinationId.reading,
    CompanionContextKind.audiobook => SettingsDestinationId.listening,
    CompanionContextKind.manga => SettingsDestinationId.manga,
    CompanionContextKind.video => SettingsDestinationId.video,
    CompanionContextKind.music => SettingsDestinationId.music,
    CompanionContextKind.srs => SettingsDestinationId.cardCreation,
    CompanionContextKind.library => switch (context.library) {
      CompanionLibraryKind.books => SettingsDestinationId.reading,
      CompanionLibraryKind.manga => SettingsDestinationId.manga,
      CompanionLibraryKind.video => SettingsDestinationId.video,
      CompanionLibraryKind.music => SettingsDestinationId.music,
      CompanionLibraryKind.games => SettingsDestinationId.game,
      null => null,
    },
    CompanionContextKind.settings => _destinationIdOf(context.settingsCategory),
    CompanionContextKind.none ||
    CompanionContextKind.home ||
    CompanionContextKind.gameStream => null,
  };
}

SettingsDestinationId? _destinationIdOf(String? name) {
  if (name == null) return null;
  for (final SettingsDestinationId id in SettingsDestinationId.values) {
    if (id.name == name) return id;
  }
  return null;
}

/// Opens a settings page on the main screen: [entry] (its page, row
/// highlighted) or a whole category.
typedef CompanionSettingsOpener =
    void Function(
      SettingsContext context, {
      SettingsSearchEntry? entry,
      SettingsDestination? destination,
    });

/// Main engine's side of the companion Settings tab. Built on the shared
/// settings index ([buildSettingsIndex], the one `fushi_cli config` uses):
/// rows are read through the same value closures as the settings pages and
/// written with [applySettingsIndexValue] (same setters, same follow-up
/// notifications). Failures throw [CtlFailure]; the bridge turns them into
/// error replies.
class CompanionSettingsService {
  CompanionSettingsService({
    required SettingsContext Function() settingsContext,
    required CompanionContext Function() currentContext,
    List<SettingsDestination> Function(SettingsContext context)? destinations,
    List<CtlBodyPage>? bodyPages,
    CompanionSettingsOpener? open,
  }) : _settingsContext = settingsContext,
       _currentContext = currentContext,
       _destinations = destinations ?? buildSettingsSchema,
       _bodyPages = bodyPages,
       _open = open ?? openCompanionSettingsOnMain;

  final SettingsContext Function() _settingsContext;
  final CompanionContext Function() _currentContext;
  final List<SettingsDestination> Function(SettingsContext context)
  _destinations;
  final List<CtlBodyPage>? _bodyPages;
  final CompanionSettingsOpener _open;

  Map<String, SettingsIndexEntry> _index(SettingsContext context) =>
      buildSettingsIndex(
        context,
        destinations: _destinations(context),
        bodyPages: _bodyPages,
      );

  List<SettingsDestination> _visibleDestinations(SettingsContext context) =>
      <SettingsDestination>[
        for (final SettingsDestination d in _destinations(context))
          if (_safe(() => d.isVisible(context))) d,
      ];

  /// The tab's first page: the top screen's settings, then every visible
  /// category.
  CompanionSettingsOverview overview() {
    final SettingsContext context = _settingsContext();
    final List<SettingsDestination> destinations = _visibleDestinations(
      context,
    );
    final CompanionContext top = _currentContext();
    final SettingsDestinationId? contextId = companionSettingsCategoryFor(top);
    SettingsDestination? visible(SettingsDestinationId? id) =>
        destinations.where((SettingsDestination d) => d.id == id).firstOrNull;
    // The audiobook view lives inside the reader: with the listening category
    // hidden on this device its settings still show, under reading.
    final SettingsDestination? contextDestination =
        visible(contextId) ??
        (top.kind == CompanionContextKind.audiobook
            ? visible(SettingsDestinationId.reading)
            : null);
    CompanionSettingsPage? contextPage;
    if (contextDestination != null) {
      final Map<String, SettingsIndexEntry> index = _index(context);
      final List<CompanionSettingRow> rows = <CompanionSettingRow>[
        for (final String key in _contextKeys(
          contextDestination,
          top,
          destinations,
        ))
          if (index[key] case final SettingsIndexEntry entry
              when _listed(entry))
            companionSettingRow(entry, context),
      ];
      if (rows.isNotEmpty) {
        contextPage = CompanionSettingsPage(
          category: _category(contextDestination),
          rows: rows,
        );
      }
    }
    return CompanionSettingsOverview(
      context: contextPage,
      categories: <CompanionSettingsCategory>[
        for (final SettingsDestination d in destinations) _category(d),
      ],
    );
  }

  /// Every visible row of category [id], in schema order (sub-pages
  /// included; [CompanionSettingRow.section] says where).
  CompanionSettingsPage category(String id) {
    final SettingsContext context = _settingsContext();
    final SettingsDestination destination = _requireDestination(context, id);
    return CompanionSettingsPage(
      category: _category(destination),
      rows: <CompanionSettingRow>[
        for (final SettingsIndexEntry entry in _index(context).values)
          if (entry.destinationId == destination.id && _listed(entry))
            companionSettingRow(entry, context),
      ],
    );
  }

  /// Rows matching [query], ranked like the settings search page (titles,
  /// subtitles, option labels, synonyms); sections lead with the category.
  CompanionSettingsPage search(String query) {
    final SettingsContext context = _settingsContext();
    final Map<String, SettingsIndexEntry> index = _index(context);
    final List<SettingsSearchEntry> hits = filterSettingsEntries(
      flattenVisibleSettings(_destinations(context), context),
      query,
      maxResults: CompanionSettingsArgs.searchLimit,
    );
    final Set<String> seen = <String>{};
    return CompanionSettingsPage(
      rows: <CompanionSettingRow>[
        for (final SettingsSearchEntry hit in hits)
          if (index[hit.item.id] case final SettingsIndexEntry entry
              when _listed(entry) && seen.add(entry.key))
            companionSettingRow(
              entry,
              context,
              categoryTitle: hit.destination.title,
            ),
      ],
    );
  }

  /// One row (for a refresh of a single row).
  CompanionSettingRow get(String key) {
    final SettingsContext context = _settingsContext();
    return companionSettingRow(
      requireSettingsIndexEntry(_index(context), key),
      context,
    );
  }

  /// Writes [raw] (a `fushi_cli config set` token) through the row's own
  /// setter and returns the row re-read (setters may clamp / normalise).
  /// Only rows the companion edits directly are accepted.
  Future<CompanionSettingRow> set(String key, String raw) async {
    final SettingsContext context = _settingsContext();
    final SettingsIndexEntry entry = requireSettingsIndexEntry(
      _index(context),
      key,
    );
    if (!entry.visible && !entry.offPage) {
      throw CtlFailure.rejected('setting "$key" is not shown on this device');
    }
    if (!companionSettingControlOf(entry).isDirect) {
      throw CtlFailure.badRequest(
        'setting "$key" (${entry.type}) is changed on the main screen',
      );
    }
    final CompanionSettingRow before = companionSettingRow(entry, context);
    if (!before.enabled) {
      throw CtlFailure.rejected('setting "$key" is disabled');
    }
    await applySettingsIndexValue(entry, context, raw);
    return companionSettingRow(entry, context);
  }

  /// Shows row [key] (its page, highlighted) or category [category] on the
  /// main screen.
  void openOnMain({String? key, String? category}) {
    final SettingsContext context = _settingsContext();
    if (key != null) {
      final SettingsSearchEntry? entry = flattenVisibleSettings(
        _destinations(context),
        context,
      ).where((SettingsSearchEntry e) => e.item.id == key).firstOrNull;
      if (entry == null) {
        throw CtlFailure.notFound('setting "$key" has no page on this device');
      }
      _open(context, entry: entry);
      return;
    }
    if (category != null) {
      _open(context, destination: _requireDestination(context, category));
      return;
    }
    throw const CtlFailure.badRequest('key or category missing');
  }

  SettingsDestination _requireDestination(SettingsContext context, String id) {
    final SettingsDestination? destination = _visibleDestinations(
      context,
    ).where((SettingsDestination d) => d.id.name == id).firstOrNull;
    if (destination == null) {
      throw CtlFailure.notFound('no settings category "$id" on this device');
    }
    return destination;
  }

  /// The top screen's settings inside [destination]: the reader's quick
  /// settings (the rows the in-book panel shows; the audiobook group for the
  /// audiobook view), else the rows on the category's first page.
  ///
  /// The in-book panel draws its rows from both the reading and the listening
  /// category (a reader row may sit in either), so the quick rows are
  /// collected from those of the two that are among [destinations].
  List<String> _contextKeys(
    SettingsDestination destination,
    CompanionContext context,
    List<SettingsDestination> destinations,
  ) {
    final List<SettingsItem> firstPage = <SettingsItem>[
      for (final SettingsSection section in destination.sections)
        ...section.items,
    ];
    final bool readerCategory =
        destination.id == SettingsDestinationId.reading ||
        destination.id == SettingsDestinationId.listening;
    if (readerCategory &&
        (context.kind == CompanionContextKind.reader ||
            context.kind == CompanionContextKind.audiobook)) {
      final bool audiobook = context.kind == CompanionContextKind.audiobook;
      final List<SettingsItem> quick = <SettingsItem>[];
      void collect(SettingsDestination page, int depth) {
        for (final SettingsSection section in page.sections) {
          for (final SettingsItem item in section.items) {
            final ReaderPlacement? placement = item.reader;
            if (placement != null &&
                (placement.group == ReaderGroup.audiobook) == audiobook) {
              quick.add(item);
            }
            if (item is SettingsNavigationItem &&
                item.child != null &&
                depth < 3) {
              collect(item.child!(), depth + 1);
            }
          }
        }
      }

      for (final SettingsDestination page in destinations) {
        if (page.id == SettingsDestinationId.reading ||
            page.id == SettingsDestinationId.listening) {
          collect(page, 0);
        }
      }
      if (quick.isNotEmpty) {
        return <String>[for (final SettingsItem item in quick) item.id];
      }
    }
    return <String>[for (final SettingsItem item in firstPage) item.id];
  }
}

CompanionSettingsCategory _category(SettingsDestination d) =>
    CompanionSettingsCategory(id: d.id.name, title: d.title);

bool _safe(bool Function() predicate) {
  try {
    return predicate();
  } catch (_) {
    return false;
  }
}

/// Rows the companion lists: visible on the main screen, inside a settings
/// category (not a `fushi_cli`-only body page), with a real title (custom
/// rows without a search title are only drawn widgets).
bool _listed(SettingsIndexEntry entry) =>
    entry.visible &&
    entry.destinationId != null &&
    entry.title.isNotEmpty &&
    entry.title != entry.key;

/// How the companion shows [entry]: the value kinds directly, everything
/// else (text, secret, custom, list, action, status; the theme swatches)
/// as "Open on main screen".
CompanionSettingControl companionSettingControlOf(SettingsIndexEntry entry) {
  if (entry.virtual != null) {
    return _directVirtuals.contains(entry.key)
        ? CompanionSettingControl.choice
        : CompanionSettingControl.open;
  }
  return switch (entry.item) {
    SettingsSwitchItem() => CompanionSettingControl.toggle,
    SettingsSegmentedItem<Object>() => CompanionSettingControl.choice,
    SettingsSliderItem() => CompanionSettingControl.slider,
    SettingsStepperItem() => CompanionSettingControl.stepper,
    SettingsNumberItem() => CompanionSettingControl.number,
    _ => CompanionSettingControl.open,
  };
}

/// The drawn appearance selectors the companion edits as choices. The theme
/// picker (swatches, custom themes) stays on the main screen; its row shows
/// the current theme's name.
const Set<String> _directVirtuals = <String>{
  'appearance.design_system',
  'appearance.brightness',
  'appearance.language',
};

/// [entry] as a companion row. Values, display, options and ranges come
/// from [settingsIndexEntryJson] (what `fushi_cli config get` prints); option
/// and value labels from [settingsIndexChoices] / [settingsIndexValueLabel]
/// (the settings page's strings in the main screen's language); the companion
/// adds steps and the enabled state.
CompanionSettingRow companionSettingRow(
  SettingsIndexEntry entry,
  SettingsContext context, {
  String? categoryTitle,
}) {
  final Map<String, Object?> json = settingsIndexEntryJson(entry, context);
  final bool failed = json['error'] != null;
  final CompanionSettingControl control = failed
      ? CompanionSettingControl.open
      : companionSettingControlOf(entry);
  final SettingsItem? item = entry.item;
  final List<CompanionSettingOption> options = <CompanionSettingOption>[
    if (control == CompanionSettingControl.choice)
      for (final SettingsIndexChoice choice
          in settingsIndexChoices(entry, context) ??
              const <SettingsIndexChoice>[])
        CompanionSettingOption(value: choice.token, label: choice.label),
  ];
  final String display = failed
      ? '${json['display'] ?? ''}'
      : settingsIndexValueLabel(entry, context, json['value']) ??
            '${json['display'] ?? ''}';
  final String? section = entry.pagePath;
  return CompanionSettingRow(
    key: entry.key,
    title: item == null ? entry.title : settingsItemSearchTitle(item, context),
    control: control,
    value: control.isDirect ? json['value'] : null,
    display: display,
    subtitle: item == null ? null : _subtitle(item, context),
    section: categoryTitle == null
        ? section
        : section == null
        ? categoryTitle
        : '$categoryTitle › $section',
    options: options,
    min: (json['min'] as num?)?.toDouble(),
    max: (json['max'] as num?)?.toDouble(),
    divisions: item is SettingsSliderItem ? item.divisions : null,
    step: switch (item) {
      SettingsSliderItem(:final double? step) => step,
      SettingsStepperItem(:final double step) => step,
      _ => null,
    },
    integer: item is SettingsNumberItem && item.integer,
    enabled: !failed && _enabled(item, context),
  );
}

String? _subtitle(SettingsItem item, SettingsContext context) {
  try {
    final String? s = item.resolveSubtitle(context);
    return s == null || s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

bool _enabled(SettingsItem? item, SettingsContext context) => switch (item) {
  SettingsSwitchItem(:final bool Function(SettingsContext)? enabled) ||
  SettingsSegmentedItem<Object>(
    :final bool Function(SettingsContext)? enabled,
  ) => enabled == null || _safe(() => enabled(context)),
  _ => true,
};

/// Default [CompanionSettingsOpener]: the settings search's "go to this
/// row" path, or a category's detail page, pushed on the main navigator.
void openCompanionSettingsOnMain(
  SettingsContext context, {
  SettingsSearchEntry? entry,
  SettingsDestination? destination,
}) {
  final NavigatorState? navigator = context.appModel.navigatorKey.currentState;
  if (navigator == null) {
    throw const CtlFailure.conflict('the main screen is not ready');
  }
  if (entry != null) {
    openSettingsSearchEntry(navigator, entry);
  } else if (destination != null) {
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsDetailPage(destination: destination),
      ),
    );
  }
}

/// Registers the `settings.*` request methods on [bridge]. A write also
/// pings `settingsChanged`, so other rows that depend on it refresh.
void registerCompanionSettingsHandlers(
  CompanionBridge bridge,
  CompanionSettingsService service,
) {
  String requireString(Map<String, Object?> args, String key) {
    final Object? v = args[key];
    if (v is String && v.isNotEmpty) return v;
    if (v is num || v is bool) return '$v';
    throw CtlFailure.badRequest('$key missing');
  }

  bridge
    ..registerRequestHandler(CompanionRequestMethods.settingsList, (
      Map<String, Object?> args,
    ) async {
      final Object? category = args[CompanionSettingsArgs.category];
      final Object? query = args[CompanionSettingsArgs.query];
      if (category is String && category.isNotEmpty) {
        return service.category(category).toJson();
      }
      if (query is String && query.trim().isNotEmpty) {
        return service.search(query).toJson();
      }
      return service.overview().toJson();
    })
    ..registerRequestHandler(
      CompanionRequestMethods.settingsGet,
      (Map<String, Object?> args) async =>
          service.get(requireString(args, CompanionSettingsArgs.key)).toJson(),
    )
    ..registerRequestHandler(CompanionRequestMethods.settingsSet, (
      Map<String, Object?> args,
    ) async {
      final CompanionSettingRow row = await service.set(
        requireString(args, CompanionSettingsArgs.key),
        requireString(args, CompanionSettingsArgs.value),
      );
      bridge.notifySettingsChanged();
      return row.toJson();
    })
    ..registerRequestHandler(CompanionRequestMethods.settingsOpenOnMain, (
      Map<String, Object?> args,
    ) async {
      final Object? key = args[CompanionSettingsArgs.key];
      final Object? category = args[CompanionSettingsArgs.category];
      service.openOnMain(
        key: key is String ? key : null,
        category: category is String ? category : null,
      );
      return null;
    });
}
