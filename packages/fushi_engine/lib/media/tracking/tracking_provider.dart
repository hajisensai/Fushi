import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

/// How a provider failure should be treated by the sync coordinator.
///
/// The coordinator never inspects provider-specific exceptions; each adapter
/// maps its own errors to one of these kinds via [TrackingProvider.classify].
enum TrackingFailureKind {
  /// The credential was rejected (401/403). Stops this provider's batch and
  /// flags it as needing to reconnect. Other providers keep syncing.
  unauthorized,

  /// The provider asked us to slow down (429). Handled like [transient] for now
  /// (exponential backoff on the outbox row).
  rateLimited,

  /// Network or server trouble that may succeed later.
  transient,

  /// The request can never succeed as sent (bad payload, unknown subject).
  permanent,
}

/// What a provider can track. The coordinator routes an update to a provider
/// only when [accepts] is true, so a provider never has to fake an operation
/// it does not support (for example, MangaBaka has no anime).
final class TrackingProviderCapabilities {
  const TrackingProviderCapabilities({
    required this.kinds,
    required this.progressModes,
    Set<TrackingKind>? onByDefault,
  }) : _onByDefault = onByDefault;

  final Set<TrackingKind> kinds;
  final Set<TrackingProgressMode> progressModes;
  final Set<TrackingKind>? _onByDefault;

  /// Kinds switched on until the user changes the switch. Defaults to all of
  /// [kinds]. A provider that supports a kind another provider is the default
  /// site for (AniList manga, where MangaBaka is the default) leaves it out.
  bool isOnByDefault(TrackingKind kind) =>
      (_onByDefault ?? kinds).contains(kind);

  bool acceptsKind(TrackingKind kind) => kinds.contains(kind);

  bool accepts(TrackingKind kind, TrackingProgressMode mode) =>
      kinds.contains(kind) && progressModes.contains(mode);
}

/// One authenticated connection for a single sync run. The coordinator opens
/// it once per run and always closes it.
abstract interface class TrackingProviderSession {
  void close();
}

/// An external tracking service (a site that keeps the user's progress).
///
/// Adapters own everything provider-specific: HTTP clients, credentials,
/// remote payloads, and the "never lower remote progress" comparison (only the
/// adapter can read the remote entry). The coordinator
/// (`MediaTrackingService`) owns queueing, retries, isolation and status.
///
/// Deliberately has no "turn a title into a mapping" method: automatic links
/// for new providers must come from explicit identifier evidence, added as a
/// separate optional interface when a provider needs it.
abstract interface class TrackingProvider {
  /// Stable id, equal to `media_tracking_mappings.provider`.
  String get id;

  /// The site's name as shown to the user. A brand name: not translated.
  String get displayName;

  /// Host of the site's pages (`example.org`), used to recognize a link the
  /// user pastes. Empty when the site's links are not understood.
  String get siteHost;

  TrackingProviderCapabilities get capabilities;

  /// Whether credentials are present. Says nothing about whether they work.
  bool get isConfigured;

  /// Opens one authenticated session. Throws when authentication fails.
  Future<TrackingProviderSession> openSession();

  /// Sends one pending update. Must read the remote entry first and never lower
  /// remote progress. Throws on failure; the coordinator classifies the error.
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  );

  TrackingFailureKind classify(Object error);
}

/// Optional extra for a [TrackingProvider] that knows the signed-in account's
/// display name itself (tracking plugins keep it in their own account state,
/// not in a preference).
abstract interface class TrackingAccountNamed {
  /// The account's display name; empty when signed out or unknown.
  String get accountName;
}

/// The single, ordered list of tracking providers.
///
/// Adding a provider = one adapter implementing [TrackingProvider] + one entry
/// here. The coordinator iterates this list; it has no per-provider branches
/// except the legacy Bangumi auto-mapping.
final class TrackingProviderRegistry {
  /// Throws on a duplicate id: a fixed list with two providers of one id is a
  /// programming error, caught when the list is built.
  TrackingProviderRegistry(Iterable<TrackingProvider> providers)
    : _providers = List<TrackingProvider>.unmodifiable(providers),
      ignored = const <TrackingProvider>[] {
    final Set<String> ids = <String>{};
    for (final TrackingProvider provider in _providers) {
      if (!ids.add(provider.id)) {
        throw ArgumentError.value(
          provider.id,
          'providers',
          'duplicate tracking provider id',
        );
      }
    }
  }

  /// For lists that change at runtime (installed plugins): the first provider
  /// of an id is registered, later ones with the same id are left out and
  /// listed in [ignored], so a bad list never throws later.
  factory TrackingProviderRegistry.firstWins(
    Iterable<TrackingProvider> providers,
  ) {
    final Set<String> ids = <String>{};
    final List<TrackingProvider> kept = <TrackingProvider>[];
    final List<TrackingProvider> dropped = <TrackingProvider>[];
    for (final TrackingProvider provider in providers) {
      (ids.add(provider.id) ? kept : dropped).add(provider);
    }
    return TrackingProviderRegistry._(
      List<TrackingProvider>.unmodifiable(kept),
      List<TrackingProvider>.unmodifiable(dropped),
    );
  }

  TrackingProviderRegistry._(this._providers, this.ignored);

  final List<TrackingProvider> _providers;

  /// Providers left out because an earlier one has the same id
  /// ([TrackingProviderRegistry.firstWins] only).
  final List<TrackingProvider> ignored;

  List<TrackingProvider> get all => _providers;

  TrackingProvider? byId(String id) {
    for (final TrackingProvider provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }
}

/// A remote subject found from explicit identifiers.
final class TrackingLinkedSubject {
  const TrackingLinkedSubject({
    required this.subjectId,
    required this.name,
    this.episodeCount,
  });

  final int subjectId;
  final String name;

  /// Known episode count on the provider; null when unknown.
  final int? episodeCount;
}

/// Optional extra for a [TrackingProvider] that can link an anime episode from
/// an id (never from a title): a MyAnimeList id, or the provider's own id (a
/// media server may already carry it). The coordinator only links when the
/// episode number fits the provider's episode count, and when that count
/// equals the local season's count if both are known.
abstract interface class TrackingAnimeLinker {
  /// The provider's subject for MAL anime [malAnimeId]; null when there is none.
  /// Throws on network trouble (the coordinator logs it and links later).
  Future<TrackingLinkedSubject?> animeForMalId(int malAnimeId);

  /// The provider's anime [subjectId] (its own id space, named by the
  /// provider's `id`, e.g. `anilist`); null when it does not exist.
  Future<TrackingLinkedSubject?> animeById(int subjectId);
}
