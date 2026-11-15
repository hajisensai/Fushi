/// The one write planner for tracking sites that only read and write a list
/// entry (tracking plugins), and the tolerant parsers for what such a site
/// returns. Fushi decides what to write; a site never does.
///
/// Spec: `docs/specs/2026-11-10-tracking-plugins.md` §3 (entities) and §4
/// (host rules).
library;

import 'package:fushi_engine/media/tracking/book_tracking_link.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';

/// Status of a list entry on a tracking site, with its wire string.
enum TrackingEntryStatus {
  planned('planned'),
  current('current'),
  completed('completed'),
  paused('paused'),
  dropped('dropped'),
  repeating('repeating');

  const TrackingEntryStatus(this.wire);

  /// The string a plugin sends and receives.
  final String wire;

  /// The status for [value] (trimmed, exact wire string); null for anything
  /// else. Callers treat null as "unknown", never as a default status.
  static TrackingEntryStatus? tryParse(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    for (final TrackingEntryStatus status in values) {
      if (status.wire == trimmed) return status;
    }
    return null;
  }

  /// Statuses a new watch / read event never changes: a finished entry is not
  /// reopened and a rewatch is not turned back into "watching".
  bool get isKept => this == completed || this == repeating;

  /// The status of a `status` link (games) from the outbox value: 1 planned,
  /// 2 completed, 3 current, 4 paused, 5 dropped (`galgames.playStatus`, the
  /// frozen Bangumi collection codes). Null for anything else.
  static TrackingEntryStatus? ofPlayStatus(int code) => switch (code) {
    1 => planned,
    2 => completed,
    3 => current,
    4 => paused,
    5 => dropped,
    _ => null,
  };
}

/// The largest count accepted from a site (keeps every count a safe int).
const int _maxCount = 0x7fffffff;

/// A non-negative integer from untrusted JSON: an `int`, or a `double` with
/// an integral value. Null for anything else (missing, negative, fractional,
/// text, too large).
int? _countOf(Object? value) {
  final int? count = switch (value) {
    final int whole => whole,
    final double real when real.isFinite && real == real.truncateToDouble() =>
      real.toInt(),
    _ => null,
  };
  if (count == null || count < 0 || count > _maxCount) return null;
  return count;
}

/// The user's entry on the site, as read before planning a write.
final class TrackingSiteEntry {
  const TrackingSiteEntry({
    required this.status,
    required this.progress,
    this.progressVolume,
  });

  /// Null when the site sent a status Fushi does not know, or a count it could
  /// not read. Such an entry is left alone by [planTrackingEntryWrite]: Fushi
  /// cannot tell whether a write would reopen it or lower its progress.
  final TrackingEntryStatus? status;

  /// Episodes (anime) or chapters.
  final int progress;

  /// Volumes; null when the site gave none (planned as 0).
  final int? progressVolume;

  /// Parses a plugin's `trackingEntry` `get` result (spec §3 `Entry`).
  ///
  /// - `null` = not on the user's list: returns null;
  /// - an object: missing / bad `status` or `progress`, or a `progressVolume`
  ///   that is present but not a non-negative integer, give an entry with
  ///   [status] null (left alone). A missing `progressVolume` is fine;
  /// - anything else throws [FormatException]: treating garbage as "not on
  ///   the list" would create an entry over the real one.
  static TrackingSiteEntry? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) {
      throw FormatException('tracking entry is not an object: $json');
    }
    TrackingEntryStatus? status = TrackingEntryStatus.tryParse(json['status']);
    final int? progress = _countOf(json['progress']);
    final Object? rawVolume = json['progressVolume'];
    final int? progressVolume = _countOf(rawVolume);
    if (progress == null || (rawVolume != null && progressVolume == null)) {
      status = null;
    }
    return TrackingSiteEntry(
      status: status,
      progress: progress ?? 0,
      progressVolume: progressVolume,
    );
  }
}

/// The fields to send to the site; fields left null are not sent, so the
/// site keeps them as they are.
final class TrackingEntryWrite {
  const TrackingEntryWrite({
    required this.create,
    required this.status,
    this.progress,
    this.progressVolume,
  });

  /// The entry is not on the user's list yet.
  final bool create;
  final TrackingEntryStatus status;

  /// Episodes or chapters; null = not sent.
  final int? progress;

  /// Volumes; null = not sent.
  final int? progressVolume;

  /// The `set` fields of spec §3 (the caller adds `op` and `id`).
  Map<String, Object?> toJson() => <String, Object?>{
    'create': create,
    'status': status.wire,
    if (progress != null) 'progress': progress,
    if (progressVolume != null) 'progressVolume': progressVolume,
  };

  @override
  bool operator ==(Object other) =>
      other is TrackingEntryWrite &&
      other.create == create &&
      other.status == status &&
      other.progress == progress &&
      other.progressVolume == progressVolume;

  @override
  int get hashCode => Object.hash(create, status, progress, progressVolume);

  @override
  String toString() => 'TrackingEntryWrite(${toJson()})';
}

/// The write for "[progress] episodes / chapters / volumes ([mode]) done"
/// against the site's current [entry] (null = not on the list), or null when
/// nothing would change.
///
/// [total] is the site's count for the unit of [mode] (episodes, chapters or
/// the final volume); null or 0 = unknown. [subjectFinished] = the work itself
/// is complete on the site (spec `Subject.finished`). [completed] = Fushi's
/// item is finished (a chapter companion passes false).
///
/// Rules (the same as the AniList and MangaBaka planners):
/// - only the unit of [mode] is written, never lowered; the other unit is not
///   sent at all;
/// - an episode count is trusted as is (it is the planned count, even while
///   airing): progress is capped at it and reaching it completes the entry;
///   with no count, [completed] alone completes it;
/// - a chapter or volume total is trusted only when [subjectFinished]: then
///   progress is capped at it, and the entry completes when [completed] and
///   the total is reached (finishing volume 3 of 18 stays current); a
///   releasing work never completes and is not capped;
/// - `completed` and `repeating` entries keep their status;
/// - any other status (planned, paused, dropped) becomes `current` on any
///   write, as on both sites today, except for a [companion] write;
/// - a [companion] write (the chapter count kept next to a volume link, a
///   secondary progress number) only moves that number: an existing entry
///   keeps its status whatever it is, it never completes, and a new entry is
///   created as `current` (the built-in Bangumi writer's rule);
/// - no entry is created at progress 0; an entry with an unreadable status or
///   count ([TrackingSiteEntry.status] null) is left alone.
///
/// - chapter mode on a [singleVolume] subject (one book): the entry completes
///   when [completed] even without a chapter total; when it completes that
///   way and [finalVolume] is 1, volume 1 is sent too if the site has less.
///
/// Throws [ArgumentError] for [TrackingProgressMode.status]: a status link
/// (games) is planned by [planTrackingStatusWrite].
TrackingEntryWrite? planTrackingEntryWrite({
  required TrackingSiteEntry? entry,
  required TrackingProgressMode mode,
  required int progress,
  required bool completed,
  int? total,
  bool subjectFinished = false,
  bool singleVolume = false,
  int? finalVolume,
  bool companion = false,
}) {
  if (mode == TrackingProgressMode.status) {
    throw ArgumentError.value(mode, 'mode', 'use planTrackingStatusWrite');
  }
  final TrackingEntryStatus? current = entry?.status;
  if (entry != null && current == null) return null;
  final bool byVolume = mode == TrackingProgressMode.volume;
  final bool byEpisode = mode == TrackingProgressMode.episode;
  final int? known = (total != null && total > 0) ? total : null;
  final int? trusted = (byEpisode || subjectFinished) ? known : null;
  final int remote = byVolume
      ? (entry?.progressVolume ?? 0)
      : (entry?.progress ?? 0);
  int target = progress < 0 ? 0 : progress;
  if (trusted != null && target > trusted) target = trusted;
  final int next = target > remote ? target : remote;
  final bool reachesTotal = trusted != null && next >= trusted;
  final bool asOneBook =
      !companion &&
      mode == TrackingProgressMode.chapter &&
      singleVolume &&
      completed &&
      !reachesTotal;
  final bool finishes =
      !companion &&
      (byEpisode
          ? (trusted != null ? next >= trusted : completed)
          : (completed && (reachesTotal || asOneBook)));
  final TrackingEntryStatus status =
      current != null && (current.isKept || companion)
      ? current
      : (finishes
            ? TrackingEntryStatus.completed
            : TrackingEntryStatus.current);
  final int? oneVolume =
      asOneBook && finalVolume == 1 && (entry?.progressVolume ?? 0) < 1
      ? 1
      : null;
  if (entry != null &&
      next == remote &&
      status == current &&
      oneVolume == null) {
    return null;
  }
  if (entry == null && next == 0 && oneVolume == null) return null;
  return TrackingEntryWrite(
    create: entry == null,
    status: status,
    progress: byVolume ? null : next,
    progressVolume: byVolume ? next : oneVolume,
  );
}

/// The write for a `status` link (games): [status] is the user's choice and
/// is written as is, with no progress (no keep rule: going back from
/// completed to current, or dropping, must reach the site). Null when the
/// entry already has it, or when its status could not be read (left alone).
TrackingEntryWrite? planTrackingStatusWrite({
  required TrackingSiteEntry? entry,
  required TrackingEntryStatus status,
}) {
  if (entry == null) {
    return TrackingEntryWrite(create: true, status: status);
  }
  final TrackingEntryStatus? current = entry.status;
  if (current == null || current == status) return null;
  return TrackingEntryWrite(create: false, status: status);
}

/// Caps of spec §4 for untrusted subject text.
const int _maxTextLength = 500;
const int _maxTitles = 50;
const int _maxAuthors = 20;
const int _maxLinkedIds = 16;

/// An id space name in `linkedIds`: `mal` or a site id.
final RegExp _idTypePattern = RegExp(r'^[a-z0-9]{2,32}$');

/// A plugin's subject (spec §3 `Subject`) in the core's shapes: [book] for
/// manga and novels, [anime] for anime, [game] for games.
final class TrackingPluginSubject {
  const TrackingPluginSubject._({
    required this.kind,
    this.book,
    this.anime,
    this.game,
    this.singleVolume = false,
    this.altName,
  });

  /// [TrackingKind.anime], [TrackingKind.manga], [TrackingKind.novel] or
  /// [TrackingKind.game].
  final TrackingKind kind;

  /// Set for manga and novels.
  final TrackingBookSubject? book;

  /// Set for anime.
  final TrackingLinkedSubject? anime;

  /// Set for games (id and name only).
  final TrackingLinkedSubject? game;

  /// The subject is one book: finishing the item finishes it (spec
  /// 2026-11-11 §2.3). Only read for manga and novels.
  final bool singleVolume;

  /// The second title (the first of `titles` after the name), for display.
  final String? altName;

  int get subjectId => book?.subjectId ?? anime?.subjectId ?? game!.subjectId;
  String get name => book?.name ?? anime?.name ?? game!.name;
}

/// Trimmed and capped; null when not a string or empty.
String? _textOf(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > _maxTextLength
      ? trimmed.substring(0, _maxTextLength)
      : trimmed;
}

/// Distinct non-empty strings of [value] (a list), at most [limit].
List<String> _textsOf(Object? value, int limit, {String? first}) {
  final List<String> result = <String>[?first];
  if (value is List) {
    for (final Object? item in value) {
      if (result.length >= limit) break;
      final String? text = _textOf(item);
      if (text != null && !result.contains(text)) result.add(text);
    }
  }
  return List<String>.unmodifiable(result);
}

/// A known total: a count above 0 (0 says nothing about a work).
int? _totalOf(Object? value) {
  final int? count = _countOf(value);
  return count == null || count == 0 ? null : count;
}

/// Parses one subject a plugin returned, applying the caps of spec §4.
/// Returns null (the subject is dropped) without a positive integer `id`, a
/// non-empty `name`, or a `kind` of `anime` / `manga` / `novel` / `game`.
///
/// Titles always include the name first; at most 50 titles and 20 authors of
/// at most 500 characters each. Bad counts become unknown. `linkedIds` keeps
/// at most 16 entries whose key is an id space name and whose value is a
/// positive integer. Only `finished: true` marks the work complete.
TrackingPluginSubject? parseTrackingSubject(Object? json) {
  if (json is! Map) return null;
  final int? id = _countOf(json['id']);
  final String? name = _textOf(json['name']);
  final TrackingKind? kind = switch (json['kind']) {
    'anime' => TrackingKind.anime,
    'manga' => TrackingKind.manga,
    'novel' => TrackingKind.novel,
    'game' => TrackingKind.game,
    _ => null,
  };
  if (id == null || id == 0 || name == null || kind == null) return null;
  final List<String> titles = _textsOf(json['titles'], _maxTitles, first: name);
  final String? altName = titles.length > 1 ? titles[1] : null;
  if (kind == TrackingKind.anime) {
    return TrackingPluginSubject._(
      kind: kind,
      altName: altName,
      anime: TrackingLinkedSubject(
        subjectId: id,
        name: name,
        episodeCount: _totalOf(json['totalEpisodes']),
      ),
    );
  }
  if (kind == TrackingKind.game) {
    return TrackingPluginSubject._(
      kind: kind,
      altName: altName,
      game: TrackingLinkedSubject(subjectId: id, name: name),
    );
  }
  final Map<String, int> linkedIds = <String, int>{};
  final Object? rawLinks = json['linkedIds'];
  if (rawLinks is Map) {
    for (final MapEntry<Object?, Object?> link in rawLinks.entries) {
      if (linkedIds.length >= _maxLinkedIds) break;
      final Object? key = link.key;
      final int? value = _countOf(link.value);
      if (key is! String ||
          !_idTypePattern.hasMatch(key) ||
          value == null ||
          value == 0) {
        continue;
      }
      linkedIds[key] = value;
    }
  }
  return TrackingPluginSubject._(
    kind: kind,
    altName: altName,
    singleVolume: json['singleVolume'] == true,
    book: TrackingBookSubject(
      subjectId: id,
      name: name,
      kind: kind,
      titles: titles,
      authors: _textsOf(json['authors'], _maxAuthors),
      totalChapters: _totalOf(json['totalChapters']),
      finalVolume: _totalOf(json['finalVolume']),
      isFinished: json['finished'] == true,
      linkedIds: Map<String, int>.unmodifiable(linkedIds),
    ),
  );
}

/// One entry of the user's list on a site (spec 2026-11-11 §2.5 `ListItem`).
final class TrackingListItem {
  const TrackingListItem({
    required this.subject,
    required this.status,
    required this.progress,
    this.progressVolume,
    this.updatedAt,
  });

  final TrackingPluginSubject subject;
  final TrackingEntryStatus status;

  /// Episodes (anime) or chapters.
  final int progress;
  final int? progressVolume;

  /// When the user last changed the entry on the site; null when not given.
  final DateTime? updatedAt;
}

/// One `trackingList` answer: the items, and the offset of the next page
/// (null = last page).
final class TrackingListPage {
  const TrackingListPage({required this.items, this.next});

  final List<TrackingListItem> items;
  final int? next;

  /// Parses `{items: [ListItem], next?}`. Items with an unusable subject, an
  /// unknown status or a bad count are dropped. Throws [FormatException] when
  /// there is no items list.
  static TrackingListPage fromJson(Object? json) {
    final Object? items = json is Map ? json['items'] : null;
    if (items is! List) {
      throw const FormatException('trackingList result has no items list');
    }
    final List<TrackingListItem> parsed = <TrackingListItem>[];
    for (final Object? raw in items) {
      if (raw is! Map) continue;
      final TrackingPluginSubject? subject = parseTrackingSubject(
        raw['subject'],
      );
      final TrackingEntryStatus? status = TrackingEntryStatus.tryParse(
        raw['status'],
      );
      final int? progress = _countOf(raw['progress']);
      if (subject == null || status == null || progress == null) continue;
      final Object? updated = raw['updatedAt'];
      parsed.add(
        TrackingListItem(
          subject: subject,
          status: status,
          progress: progress,
          progressVolume: _countOf(raw['progressVolume']),
          updatedAt: updated is String ? DateTime.tryParse(updated) : null,
        ),
      );
    }
    final int? next = json is Map ? _countOf(json['next']) : null;
    return TrackingListPage(
      items: List<TrackingListItem>.unmodifiable(parsed),
      next: next,
    );
  }
}

/// Optional extra for a [TrackingProvider]: reads the user's entry for one
/// subject (the Bangumi chapter companion takes its chapter baseline from it).
abstract interface class TrackingEntryReader {
  /// The user's entry for [subjectId] of [kind]; null when it is not on the
  /// list. Throws on network trouble.
  Future<TrackingSiteEntry?> readEntry(int subjectId, TrackingKind kind);
}

/// Optional extra for a [TrackingProvider]: reads the user's list by status
/// (for "View all watched anime").
abstract interface class TrackingListReader {
  /// The site can list entries at all.
  bool get canListEntries;

  /// The user's entries of [kind] with [status]. Throws on network trouble.
  Future<List<TrackingListItem>> listEntries(
    TrackingKind kind,
    TrackingEntryStatus status,
  );
}
