import 'dart:io' show Platform;

import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_entry_plan.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:fushi_engine/media/tracking/tracking_subject_search.dart';

/// Search and lookup results the host looks at (spec §3).
const int _maxSearchResults = 20;

/// `trackingList` pages the host reads at most (spec 2026-11-11 §2.5).
const int _maxListPages = 40;

/// `trackingList` items the host keeps at most.
const int _maxListItems = 2000;

/// An installed tracking plugin as a [TrackingProvider] (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §3, §4).
///
/// The plugin only reads and writes the list entry; this class decides what
/// to write with the shared planner ([planTrackingEntryWrite]): progress is
/// never lowered, a completed or repeating entry keeps its status. Results
/// go through the tolerant parsers of `tracking_entry_plan.dart`.
///
/// Build it with [createPluginTrackingProvider]: whether it is also a
/// [TrackingAnimeLinker] / [TrackingBookLinker] depends on the manifest.
class PluginTrackingProvider
    implements
        TrackingProvider,
        TrackingSubjectSearch,
        TrackingListReader,
        TrackingEntryReader,
        TrackingAccountNamed {
  PluginTrackingProvider._({
    required TrackingPluginManager manager,
    required TrackingPluginInfo info,
    required void Function() onAccountChanged,
  }) : _manager = manager,
       _info = info,
       _site = info.site!,
       _onAccountChanged = onAccountChanged,
       capabilities = TrackingProviderCapabilities(
         kinds: info.site!.kinds,
         progressModes: info.site!.modes,
         onByDefault: info.site!.defaultKinds,
       );

  final TrackingPluginManager _manager;
  final TrackingPluginInfo _info;
  final TrackingPluginSite _site;
  final void Function() _onAccountChanged;

  /// Plugin id (not the site id).
  String get pluginId => _info.id;

  /// Package digest this provider was built for.
  String get digest => _info.digest;

  @override
  String get id => _site.siteId;

  @override
  String get displayName => _info.name;

  @override
  String get siteHost => _site.siteHost;

  @override
  final TrackingProviderCapabilities capabilities;

  /// This device is signed in (the manager's per-device account state).
  @override
  bool get isConfigured => _manager.accountOf(pluginId).loggedIn;

  @override
  String get accountName => _manager.accountOf(pluginId).name?.trim() ?? '';

  Future<TrackingPluginRuntime> _runtime() => _manager.runtime(pluginId);

  Future<Object?> _call(
    TrackingPluginRuntime runtime,
    String method,
    Map<String, Object?> args,
  ) => runtime.invoke(method, args);

  /// Asks the plugin whether it is signed in. Signed out: the stored state is
  /// cleared and [TrackingPluginErrorCode.unauthorized] is thrown.
  @override
  Future<TrackingProviderSession> openSession() async {
    final TrackingPluginRuntime runtime = await _runtime();
    final TrackingPluginAccount account = await _readAccount(runtime);
    if (!account.loggedIn) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.unauthorized,
        'not signed in',
        pluginId: pluginId,
      );
    }
    return _PluginSession(runtime);
  }

  @override
  TrackingFailureKind classify(Object error) {
    if (error is TrackingPluginException) {
      return switch (error.code) {
        TrackingPluginErrorCode.unauthorized =>
          TrackingFailureKind.unauthorized,
        TrackingPluginErrorCode.rateLimited => TrackingFailureKind.rateLimited,
        TrackingPluginErrorCode.notFound ||
        TrackingPluginErrorCode.kindMismatch ||
        TrackingPluginErrorCode.missingCapability =>
          TrackingFailureKind.permanent,
        _ => TrackingFailureKind.transient,
      };
    }
    return TrackingFailureKind.transient;
  }

  /// Reads the subject (kind and totals) and the entry, plans, and writes
  /// exactly the planned fields. Nothing is written when the plan is empty.
  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    final TrackingPluginRuntime runtime = (session as _PluginSession).runtime;
    final MediaTrackingMappingRow mapping = update.mapping;
    final TrackingProgressMode mode = _modeOf(mapping.progressMode);
    final TrackingKind kind = _kindOf(mapping.kind);
    final int subjectId = mapping.subjectId;
    if (mode == TrackingProgressMode.status) {
      await _pushStatus(runtime, kind, subjectId, update.outbox.progress);
      return;
    }
    final TrackingPluginSubject? subject = parseTrackingSubject(
      await _call(runtime, TrackingPluginCapability.subject, <String, Object?>{
        'id': subjectId,
        'kind': kind.value,
      }),
    );
    if (subject == null) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.notFound,
        '$id subject $subjectId not found',
        pluginId: pluginId,
      );
    }
    if (subject.kind != kind) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.kindMismatch,
        '$id subject $subjectId is ${subject.kind.value}, '
        'the link says ${kind.value}',
        pluginId: pluginId,
      );
    }
    final int? total = switch (mode) {
      TrackingProgressMode.episode => subject.anime?.episodeCount,
      TrackingProgressMode.chapter => subject.book?.totalChapters,
      TrackingProgressMode.volume => subject.book?.finalVolume,
      TrackingProgressMode.status => null,
    };
    // A chapter companion (web novel chapters next to a volume link) counts
    // chapters and never finishes the series on its own.
    final bool isCompanion =
        mapping.mediaType == TrackingMediaType.bookChapter.value;
    // The site may answer with the subject an entry was merged into: its id
    // is the one the list entry lives under. The stored link is not
    // rewritten.
    final int entryId = subject.subjectId;
    final TrackingSiteEntry? entry = TrackingSiteEntry.fromJson(
      await _call(runtime, TrackingPluginCapability.entry, <String, Object?>{
        'op': 'get',
        'id': entryId,
        'kind': kind.value,
      }),
    );
    final TrackingEntryWrite? write = planTrackingEntryWrite(
      entry: entry,
      mode: mode,
      progress: update.outbox.progress,
      completed: update.outbox.completed && !isCompanion,
      companion: isCompanion,
      total: total,
      subjectFinished: subject.book?.isFinished ?? false,
      singleVolume: subject.singleVolume,
      finalVolume: subject.book?.finalVolume,
    );
    if (write == null) return;
    await _call(runtime, TrackingPluginCapability.entry, <String, Object?>{
      'op': 'set',
      'id': entryId,
      'kind': kind.value,
      ...write.toJson(),
    });
  }

  /// A `status` link (games): the outbox holds the user's play status
  /// ([TrackingEntryStatus.ofPlayStatus]); written as is when it differs.
  Future<void> _pushStatus(
    TrackingPluginRuntime runtime,
    TrackingKind kind,
    int subjectId,
    int code,
  ) async {
    final TrackingEntryStatus? status = TrackingEntryStatus.ofPlayStatus(code);
    if (status == null) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.badResult,
        'play status $code is not 1..5',
        pluginId: pluginId,
      );
    }
    final TrackingEntryWrite? write = planTrackingStatusWrite(
      entry: TrackingSiteEntry.fromJson(
        await _call(runtime, TrackingPluginCapability.entry, <String, Object?>{
          'op': 'get',
          'id': subjectId,
          'kind': kind.value,
        }),
      ),
      status: status,
    );
    if (write == null) return;
    await _call(runtime, TrackingPluginCapability.entry, <String, Object?>{
      'op': 'set',
      'id': subjectId,
      'kind': kind.value,
      ...write.toJson(),
    });
  }

  TrackingProgressMode _modeOf(String value) {
    for (final TrackingProgressMode mode in TrackingProgressMode.values) {
      if (mode.value == value && _site.modes.contains(mode)) {
        return mode;
      }
    }
    throw TrackingPluginException(
      TrackingPluginErrorCode.missingCapability,
      '$id does not track by $value',
      pluginId: pluginId,
    );
  }

  TrackingKind _kindOf(String value) {
    for (final TrackingKind kind in _site.kinds) {
      if (kind.value == value) return kind;
    }
    throw TrackingPluginException(
      TrackingPluginErrorCode.missingCapability,
      '$id does not track $value',
      pluginId: pluginId,
    );
  }

  /// `{items: [...]}` of a search or lookup, parsed; items that fail the
  /// spec §4 checks are dropped. Throws for any other shape.
  List<TrackingPluginSubject> _items(Object? result, {int? limit}) {
    final Object? items = result is Map ? result['items'] : null;
    if (items is! List) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.badResult,
        'result has no items list',
        pluginId: pluginId,
      );
    }
    final Iterable<Object?> considered = limit == null
        ? items
        : items.take(limit);
    return <TrackingPluginSubject>[
      for (final Object? item in considered)
        if (parseTrackingSubject(item) case final TrackingPluginSubject s) s,
    ];
  }

  // ---- Manual search (the Tracking page's link dialog) ----

  /// `trackingSearch` for any kind the site tracks, anime included.
  @override
  Future<List<TrackingSearchHit>> searchSubjects(
    String query,
    TrackingKind kind,
  ) async {
    final String trimmed = query.trim();
    if (!_info.can(TrackingPluginCapability.search) ||
        !_site.kinds.contains(kind) ||
        trimmed.isEmpty) {
      return const <TrackingSearchHit>[];
    }
    final TrackingPluginRuntime runtime = await _runtime();
    return <TrackingSearchHit>[
      for (final TrackingPluginSubject subject in _items(
        await _call(runtime, TrackingPluginCapability.search, <String, Object?>{
          'query': trimmed,
          'kind': kind.value,
        }),
        limit: _maxSearchResults,
      ))
        if (subject.kind == kind) _hitOf(subject),
    ];
  }

  @override
  Future<TrackingSearchHit?> subjectById(
    int subjectId,
    TrackingKind kind,
  ) async {
    if (!_site.kinds.contains(kind)) return null;
    final TrackingPluginSubject? subject = parseTrackingSubject(
      await _call(
        await _runtime(),
        TrackingPluginCapability.subject,
        <String, Object?>{'id': subjectId, 'kind': kind.value},
      ),
    );
    return subject == null || subject.kind != kind ? null : _hitOf(subject);
  }

  /// From the manifest's `tracking.subjectUrl`; null without one.
  @override
  Uri? subjectPageUrl(int subjectId, TrackingKind kind) =>
      _site.subjectPageUrl(subjectId, kind);

  static TrackingSearchHit _hitOf(TrackingPluginSubject subject) {
    if (subject.book case final TrackingBookSubject book) {
      return TrackingSearchHit.ofBook(book);
    }
    if (subject.anime case final TrackingLinkedSubject anime) {
      return TrackingSearchHit.ofAnime(anime);
    }
    return TrackingSearchHit(
      subjectId: subject.subjectId,
      name: subject.name,
      kind: subject.kind,
      altName: subject.altName ?? '',
    );
  }

  /// The entry as the plugin's `trackingEntry {op: 'get'}` reports it.
  @override
  Future<TrackingSiteEntry?> readEntry(int subjectId, TrackingKind kind) async {
    if (!_site.kinds.contains(kind)) return null;
    return TrackingSiteEntry.fromJson(
      await _call(
        await _runtime(),
        TrackingPluginCapability.entry,
        <String, Object?>{'op': 'get', 'id': subjectId, 'kind': kind.value},
      ),
    );
  }

  // ---- The user's list (optional `trackingList`) ----

  @override
  bool get canListEntries => _info.can(TrackingPluginCapability.list);

  /// The user's entries of [kind] with [status], reading `next` pages up to
  /// the host's caps. Empty when the plugin has no `trackingList`.
  @override
  Future<List<TrackingListItem>> listEntries(
    TrackingKind kind,
    TrackingEntryStatus status,
  ) async {
    if (!canListEntries || !_site.kinds.contains(kind)) {
      return const <TrackingListItem>[];
    }
    final TrackingPluginRuntime runtime = await _runtime();
    final List<TrackingListItem> all = <TrackingListItem>[];
    int offset = 0;
    for (int page = 0; page < _maxListPages; page++) {
      final TrackingListPage parsed;
      try {
        parsed = TrackingListPage.fromJson(
          await _call(runtime, TrackingPluginCapability.list, <String, Object?>{
            'kind': kind.value,
            'status': status.wire,
            'offset': offset,
          }),
        );
      } on FormatException catch (error) {
        throw TrackingPluginException(
          TrackingPluginErrorCode.badResult,
          error.message,
          pluginId: pluginId,
        );
      }
      for (final TrackingListItem item in parsed.items) {
        if (all.length >= _maxListItems) return all;
        if (item.subject.kind == kind) all.add(item);
      }
      final int? next = parsed.next;
      if (next == null || next <= offset) break;
      offset = next;
    }
    return all;
  }

  // ---- Sign-in (used by the settings UI) ----

  /// Asks the plugin for its account and stores the result on this device.
  Future<TrackingPluginAccount> account() async =>
      _readAccount(await _runtime());

  Future<TrackingPluginAccount> _readAccount(
    TrackingPluginRuntime runtime,
  ) async {
    final TrackingPluginAccount account = TrackingPluginAccount.fromJson(
      await _call(
        runtime,
        TrackingPluginCapability.account,
        <String, Object?>{},
      ),
    );
    await _storeAccount(account);
    return account;
  }

  Future<void> _storeAccount(TrackingPluginAccount account) async {
    final TrackingPluginAccount before = _manager.accountOf(pluginId);
    if (before == account) return;
    await _manager.setAccount(pluginId, account);
    _onAccountChanged();
  }

  /// The `form` sign-in methods the plugin offers (other types are dropped).
  Future<List<TrackingPluginLoginMethod>> loginMethods() async =>
      TrackingPluginLoginMethod.listFrom(
        await _call(
          await _runtime(),
          TrackingPluginCapability.login,
          <String, Object?>{'op': 'methods', 'platform': _platform},
        ),
      );

  /// Starts sign-in method [method].
  Future<TrackingPluginLoginChallenge> beginLogin(String method) => _challenge(
    <String, Object?>{'op': 'begin', 'method': method, 'platform': _platform},
  );

  /// Sends the form: [action] is the pressed button, [inputs] field id ->
  /// text. A `done` step stores the account (asked from the plugin) and tells
  /// the tracking service.
  Future<TrackingPluginLoginChallenge> submitLogin(
    String method, {
    required String? session,
    required String action,
    required Map<String, String> inputs,
  }) => _challenge(<String, Object?>{
    'op': 'submit',
    'method': method,
    'platform': _platform,
    'session': ?session,
    'action': action,
    'inputs': inputs,
  });

  /// Hands a sign-in saved by the app to the plugin with the optional login
  /// op `import` (no network; spec 2026-11-11 §2): [inputs] field id -> text.
  /// A `done` step stores the account like [submitLogin]. Returns the step.
  Future<TrackingPluginLoginChallenge> importLogin(
    Map<String, String> inputs,
  ) => _challenge(<String, Object?>{
    'op': 'import',
    'platform': _platform,
    'inputs': inputs,
  });

  /// Signs out in the plugin and forgets this device's account state.
  Future<void> logout() async {
    await _call(
      await _runtime(),
      TrackingPluginCapability.login,
      <String, Object?>{'op': 'logout'},
    );
    await _storeAccount(TrackingPluginAccount.signedOut);
  }

  Future<TrackingPluginLoginChallenge> _challenge(
    Map<String, Object?> args,
  ) async {
    final TrackingPluginRuntime runtime = await _runtime();
    final TrackingPluginLoginChallenge challenge =
        TrackingPluginLoginChallenge.fromJson(
          await _call(runtime, TrackingPluginCapability.login, args),
          allowAppUrl: runtime.allowsUrl,
        );
    if (challenge.state == TrackingPluginLoginState.done) {
      await _readAccount(runtime);
    }
    return challenge;
  }

  static String get _platform => Platform.operatingSystem;
}

/// Anime linking through `trackingSubject` and `trackingLookup {idType: mal}`.
mixin _AnimeLinking on PluginTrackingProvider implements TrackingAnimeLinker {
  @override
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId) async {
    if (!_info.can(TrackingPluginCapability.lookup)) return null;
    final TrackingPluginRuntime runtime = await _runtime();
    final List<TrackingPluginSubject> found = _items(
      await _call(runtime, TrackingPluginCapability.lookup, <String, Object?>{
        'idType': 'mal',
        'id': malAnimeId,
        'kind': TrackingKind.anime.value,
      }),
      limit: _maxSearchResults,
    );
    for (final TrackingPluginSubject subject in found) {
      if (subject.anime case final TrackingLinkedSubject anime) return anime;
    }
    return null;
  }

  @override
  Future<TrackingLinkedSubject?> animeById(int subjectId) async {
    final TrackingPluginRuntime runtime = await _runtime();
    return parseTrackingSubject(
      await _call(runtime, TrackingPluginCapability.subject, <String, Object?>{
        'id': subjectId,
        'kind': TrackingKind.anime.value,
      }),
    )?.anime;
  }
}

/// Book and manga linking through `trackingSubject`, `trackingSearch` and
/// `trackingLookup`.
mixin _BookLinking on PluginTrackingProvider implements TrackingBookLinker {
  @override
  Future<List<TrackingBookSubject>> searchBooks(
    String query,
    TrackingKind kind,
  ) async {
    final String trimmed = query.trim();
    if (!_info.can(TrackingPluginCapability.search) ||
        !_site.kinds.contains(kind) ||
        kind == TrackingKind.anime ||
        trimmed.isEmpty) {
      return const <TrackingBookSubject>[];
    }
    final TrackingPluginRuntime runtime = await _runtime();
    final List<TrackingPluginSubject> found = _items(
      await _call(runtime, TrackingPluginCapability.search, <String, Object?>{
        'query': trimmed,
        'kind': kind.value,
      }),
      limit: _maxSearchResults,
    );
    return <TrackingBookSubject>[
      for (final TrackingPluginSubject subject in found)
        if (subject.book case final TrackingBookSubject book
            when book.kind == kind)
          book,
    ];
  }

  @override
  Future<TrackingBookSubject?> bookById(int subjectId) async {
    final TrackingPluginRuntime runtime = await _runtime();
    return parseTrackingSubject(
      await _call(runtime, TrackingPluginCapability.subject, <String, Object?>{
        'id': subjectId,
      }),
    )?.book;
  }

  /// Only an unambiguous answer links: exactly one book subject.
  @override
  Future<TrackingBookSubject?> bookForLinkedId(
    String providerId,
    int subjectId,
  ) async {
    if (!_info.can(TrackingPluginCapability.lookup) || providerId == id) {
      return null;
    }
    final TrackingPluginRuntime runtime = await _runtime();
    final List<TrackingBookSubject> books = <TrackingBookSubject>[
      for (final TrackingPluginSubject subject in _items(
        await _call(runtime, TrackingPluginCapability.lookup, <String, Object?>{
          'idType': providerId,
          'id': subjectId,
        }),
        limit: _maxSearchResults,
      ))
        if (subject.book case final TrackingBookSubject book) book,
    ];
    return books.length == 1 ? books.single : null;
  }
}

final class _AnimePluginTrackingProvider = PluginTrackingProvider
    with _AnimeLinking;

final class _BookPluginTrackingProvider = PluginTrackingProvider
    with _BookLinking;

final class _AnimeBookPluginTrackingProvider = PluginTrackingProvider
    with _AnimeLinking, _BookLinking;

/// The provider for an installed plugin whose [InstalledTrackingPlugin.info]
/// has a site. Also a [TrackingAnimeLinker] when the site tracks anime, and a
/// [TrackingBookLinker] when it tracks manga or novels.
///
/// [onAccountChanged] runs after this device's sign-in state changed (the
/// app bumps the tracking service's status).
PluginTrackingProvider createPluginTrackingProvider({
  required TrackingPluginManager manager,
  required TrackingPluginInfo info,
  required void Function() onAccountChanged,
}) {
  final TrackingPluginSite? site = info.site;
  if (site == null) {
    throw ArgumentError.value(info.id, 'info', 'plugin has no tracking site');
  }
  final bool anime = site.kinds.contains(TrackingKind.anime);
  final bool books =
      site.kinds.contains(TrackingKind.manga) ||
      site.kinds.contains(TrackingKind.novel);
  if (anime && books) {
    return _AnimeBookPluginTrackingProvider._(
      manager: manager,
      info: info,
      onAccountChanged: onAccountChanged,
    );
  }
  if (anime) {
    return _AnimePluginTrackingProvider._(
      manager: manager,
      info: info,
      onAccountChanged: onAccountChanged,
    );
  }
  if (books) {
    return _BookPluginTrackingProvider._(
      manager: manager,
      info: info,
      onAccountChanged: onAccountChanged,
    );
  }
  return PluginTrackingProvider._(
    manager: manager,
    info: info,
    onAccountChanged: onAccountChanged,
  );
}

/// Keeps one provider object per installed plugin package, so re-applying
/// the same plugin list does not look like a new site to the tracking service
/// (a replaced provider resets its caches and starts a sync).
final class PluginTrackingProviders {
  PluginTrackingProviders({
    required TrackingPluginManager manager,
    required void Function() onAccountChanged,
  }) : _manager = manager,
       _onAccountChanged = onAccountChanged;

  final TrackingPluginManager _manager;
  final void Function() _onAccountChanged;
  final Map<String, PluginTrackingProvider> _byPlugin =
      <String, PluginTrackingProvider>{};

  /// Providers of the manager's registered plugins, in its order. A plugin
  /// reinstalled with another package gets a new provider.
  List<PluginTrackingProvider> current() {
    final List<PluginTrackingProvider> result = <PluginTrackingProvider>[];
    final Set<String> seen = <String>{};
    for (final InstalledTrackingPlugin plugin in _manager.registered) {
      final TrackingPluginInfo info = plugin.info!;
      seen.add(plugin.id);
      final PluginTrackingProvider? known = _byPlugin[plugin.id];
      result.add(
        known != null &&
                known.digest == info.digest &&
                known.id == info.site!.siteId
            ? known
            : (_byPlugin[plugin.id] = createPluginTrackingProvider(
                manager: _manager,
                info: info,
                onAccountChanged: _onAccountChanged,
              )),
      );
    }
    _byPlugin.removeWhere((String id, _) => !seen.contains(id));
    return result;
  }

  /// The provider of plugin [pluginId] when it is registered (for sign-in).
  PluginTrackingProvider? byPluginId(String pluginId) {
    for (final PluginTrackingProvider provider in current()) {
      if (provider.pluginId == pluginId) return provider;
    }
    return null;
  }
}

final class _PluginSession implements TrackingProviderSession {
  _PluginSession(this.runtime);

  final TrackingPluginRuntime runtime;

  /// The runtime belongs to the manager and outlives the session.
  @override
  void close() {}
}
