import 'package:flutter/foundation.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:material_ui/material_ui.dart';

/// A library page's end of the companion's Library tab, Main mode (S5): the
/// books / manga shelf, the video library and the music library own the
/// `library` context while they are on screen, publish the item highlighted
/// on top ([CompanionLibraryMainSnapshot]) and run the panel's
/// search / sort / filter / open commands on their own state.
///
/// Kept out of the library pages (thousands of lines each) and free of the
/// AppModel layer, so the pages' companion code is a small `part` file and
/// this file stays out of the big import cycle.
///
/// **When the page owns the context.** The library pages stay mounted in the
/// home shell's tab stack and in their library shell's view stack (Offstage +
/// `TickerMode`), so "mounted" is not "on screen". The page's effective
/// [TickerMode] is exactly "this tab is the current home tab, this view is the
/// current library view, and no opaque route covers it" — the hook claims
/// while it is enabled and releases otherwise. The claim is made with the
/// page's route as well, so the registry's own "top page" rule holds too. With
/// the claim released, the registry falls back to the route-level context
/// (`companionContextForHomeTab`).
///
/// **Cost.** The snapshot builder runs only while the companion is up and
/// this page owns the context ([CompanionPageLink]); focus changes and page
/// state changes only ask the link to publish, which is one check while the
/// companion is off.
class LibraryCompanionHook {
  LibraryCompanionHook({
    required this.library,
    required CompanionLibraryMainSnapshot? Function() snapshot,
    ValueChanged<String>? onSearch,
    ValueChanged<String>? onSort,
    void Function(String id, bool selected)? onFilter,
    VoidCallback? onOpenHighlighted,
    CompanionContextRegistry? registry,
    Duration period = const Duration(seconds: 1),
  }) : _onSearch = onSearch,
       _onSort = onSort,
       _onFilter = onFilter,
       _onOpenHighlighted = onOpenHighlighted,
       _link = CompanionPageLink(registry: registry, period: period) {
    _link.startSnapshots(() => snapshot()?.toJson());
  }

  /// Which library this page is.
  final CompanionLibraryKind library;

  final ValueChanged<String>? _onSearch;
  final ValueChanged<String>? _onSort;
  final void Function(String id, bool selected)? _onFilter;
  final VoidCallback? _onOpenHighlighted;
  final CompanionPageLink _link;

  ValueListenable<bool>? _visible;
  Listenable? _focus;
  Route<Object?>? _route;
  bool _claimed = false;
  bool _publishScheduled = false;
  bool _disposed = false;

  /// The context this page claims.
  CompanionContext get companionContext =>
      CompanionContext(CompanionContextKind.library, library: library);

  /// This page owns the companion context right now.
  bool get isCurrent => _link.isCurrent;

  /// Call from the page's `didChangeDependencies`: picks up the page's route,
  /// its effective [TickerMode] (on screen or not) and [focusChanges] (the
  /// focus controller whose changes move the highlight).
  void attach(BuildContext context, {Listenable? focusChanges}) {
    if (_disposed) return;
    final ValueListenable<bool> visible = TickerMode.getNotifier(context);
    if (!identical(visible, _visible)) {
      _visible?.removeListener(_sync);
      _visible = visible..addListener(_sync);
    }
    if (!identical(focusChanges, _focus)) {
      _focus?.removeListener(_onFocusChanged);
      _focus = focusChanges?..addListener(_onFocusChanged);
    }
    final Route<Object?>? route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route = route;
      _claimed = false;
    }
    _sync();
  }

  /// The page's state changed (search text, sort, filters, selection,
  /// a long-press menu opened / closed): publish after the page rebuilt.
  void publishSoon() {
    if (_disposed || _publishScheduled || !_link.isActive || !isCurrent) {
      return;
    }
    _publishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _publishScheduled = false;
      _link.publishNow();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onFocusChanged() => _link.publishNow();

  void _sync() {
    if (_disposed) return;
    final bool onScreen = _visible?.value ?? true;
    if (onScreen && !_claimed) {
      _claimed = true;
      _link.claim(companionContext, route: _route, onCommand: _onCommand);
    } else if (!onScreen && _claimed) {
      _claimed = false;
      _link.release();
    }
  }

  void _onCommand(String action, Map<String, Object?> args) {
    switch (action) {
      case CompanionLibraryMainActions.search:
        _onSearch?.call(args.str(CompanionLibraryMainActions.argQuery));
      case CompanionLibraryMainActions.sort:
        final String id = args.str(CompanionLibraryMainActions.argId);
        if (id.isNotEmpty) _onSort?.call(id);
      case CompanionLibraryMainActions.filter:
        final String id = args.str(CompanionLibraryMainActions.argId);
        if (id.isNotEmpty) {
          _onFilter?.call(
            id,
            args.flag(CompanionLibraryMainActions.argSelected),
          );
        }
      case CompanionLibraryMainActions.openHighlighted:
        _onOpenHighlighted?.call();
      default:
        return;
    }
    publishSoon();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visible?.removeListener(_sync);
    _focus?.removeListener(_onFocusChanged);
    _link.dispose();
  }
}

/// The highlighted card of a library page: what the panel shows and what
/// "Continue" runs (the same action as activating the card).
@immutable
class LibraryCompanionHighlight {
  const LibraryCompanionHighlight({required this.item, required this.open});

  final CompanionLibraryItem item;
  final VoidCallback open;
}

/// The entity key of a card focus id: `<prefix><key>` → `key`, else null.
/// Library cards register focus ids that embed the item's identity (for
/// example `reader-shelf-book-<mediaIdentifier>`), so the page maps the
/// focused card back to its item without a hook per card.
String? libraryCompanionFocusKey(String? focusId, String prefix) {
  if (focusId == null || !focusId.startsWith(prefix)) return null;
  final String key = focusId.substring(prefix.length);
  return key.isEmpty ? null : key;
}

/// Activates the focused control exactly as Enter / controller A does on top
/// ([ActivateIntent] from the focused node): "Continue" for a highlight that
/// comes from the focused card.
void activateLibraryCompanionFocus() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return;
  Actions.maybeInvoke<ActivateIntent>(context, const ActivateIntent());
}

/// The highlight rule of Main mode: the focused card, else the card whose
/// long-press menu is open, else the selection anchor (selection mode).
LibraryCompanionHighlight? pickLibraryCompanionHighlight({
  required LibraryCompanionHighlight? Function() focused,
  required LibraryCompanionHighlight? Function() pressed,
  required LibraryCompanionHighlight? Function() selected,
}) => focused() ?? pressed() ?? selected();

/// Sort / filter options with the selected flag.
List<CompanionLibraryOption> libraryCompanionOptions<T>({
  required Iterable<T> values,
  required String Function(T value) id,
  required String Function(T value) label,
  required bool Function(T value) selected,
}) => <CompanionLibraryOption>[
  for (final T v in values)
    CompanionLibraryOption(id: id(v), label: label(v), selected: selected(v)),
];
