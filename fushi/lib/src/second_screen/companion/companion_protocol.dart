/// Messages between the main engine (the single source of truth, top screen)
/// and the companion panel on the second display (its own engine and process,
/// render only).
///
/// Everything crosses as one JSON object per message, `{"type": ..., ...}`,
/// through [SecondScreenHost.post] / `SecondScreenPanelMode.companion` and a
/// `SecondScreenPipe` (big messages spill to a file). Keep messages coarse:
/// one per state change or user action, never per frame.
///
/// - Main → panel ([CompanionHostMessage]): the top screen's context, the
///   context's module snapshot (S3), the daily summary, what is playing, a
///   lookup (S3), "preferences / library changed" pings, replies to the
///   panel's requests, and on "ready" the panel's last UI state
///   ([CompanionUiRestoreMessage]).
/// - Panel → main ([CompanionPanelMessage]): ready (resend everything), module
///   commands (S3), playback toggles, "open this on the main screen" links,
///   requests (settings / library queries, S4 / S5), the lookup panel's
///   state (S3 / S6) and its UI state ([CompanionUiStateMessage]).
///
/// Requests are generic ([CompanionRequestMessage] `method` + JSON args,
/// answered by a [CompanionReplyMessage] with the same id), so later steps add
/// methods without touching the codec: the main side registers a handler per
/// method, the panel awaits the reply value.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

const String _typeKey = 'type';

/// [CompanionRequestMessage] methods. Later steps add theirs here (S4
/// settings list / get / set, S5 library queries) and register a handler on
/// the main side (`CompanionBridge.registerRequestHandler`).
abstract final class CompanionRequestMethods {
  /// Collect and push the daily summary again (the panel's retry). Replies
  /// null.
  static const String refreshSummary = 'summary.refresh';

  /// The Settings tab (S4): see `modules/settings_companion_schema.dart`.
  static const String settingsList = 'settings.list';
  static const String settingsGet = 'settings.get';
  static const String settingsSet = 'settings.set';
  static const String settingsOpenOnMain = 'settings.openOnMain';

  /// The Library tab (S5): see `modules/library_companion_schema.dart`.
  static const String libraryHome = 'library.home';
  static const String libraryList = 'library.list';
  static const String librarySearch = 'library.search';
  static const String libraryDetails = 'library.details';
  static const String libraryOpen = 'library.open';
  static const String libraryMarkFinished = 'library.markFinished';
  static const String libraryCover = 'library.cover';
  static const String libraryOpenOnMain = 'library.openOnMain';
}

/// Actions of [CompanionLookupActionMessage] (S6 controller lookup mode): the
/// top screen's controller drives the companion's open lookup.
abstract final class CompanionLookupActions {
  /// Mine the first entry (the popup's own mining bridge).
  static const String mine = 'mine';

  /// Play the first entry's word audio.
  static const String playAudio = 'playAudio';

  /// Focus the next / previous dictionary entry.
  static const String nextEntry = 'nextEntry';
  static const String prevEntry = 'prevEntry';

  /// Scroll the lookup by `dy` logical pixels (positive = down).
  static const String scroll = 'scroll';

  /// Close the lookup (its nested layers first, like Back).
  static const String close = 'close';

  /// [scroll] argument.
  static const String dy = 'dy';
}

/// Steps of [CompanionPanelNavMessage] (S6 R1 panel drive): while R1 is held
/// on the controller, D-pad / A / B move the companion's own focus.
abstract final class CompanionPanelNav {
  /// R1 went down with a panel button: the panel shows its focus ring.
  static const String begin = 'begin';

  /// R1 went up: the panel keeps its focus position, hides the ring.
  static const String end = 'end';
  static const String up = 'up';
  static const String down = 'down';
  static const String left = 'left';
  static const String right = 'right';

  /// A: activate the focused control.
  static const String activate = 'activate';

  /// B: Back in the companion (close the lookup / pop the tab's history).
  static const String back = 'back';

  static const List<String> values = <String>[
    begin,
    end,
    up,
    down,
    left,
    right,
    activate,
    back,
  ];
}

Map<String, Object?> _decodeObject(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('companion message is not an object');
  }
  return Map<String, Object?>.from(decoded);
}

Map<String, Object?> _objectOf(Object? value) => value is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in value.entries)
          if (e.key is String) e.key! as String: e.value,
      }
    : const <String, Object?>{};

String? _string(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is String ? value : null;
}

int _int(Map<String, Object?> json, String key, {int fallback = 0}) {
  final Object? value = json[key];
  return value is int ? value : fallback;
}

double? _double(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is num ? value.toDouble() : null;
}

String _requireString(Map<String, Object?> json, String key) {
  final String? value = _string(json, key);
  if (value == null) throw FormatException('missing string "$key"');
  return value;
}

int _requireInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) throw FormatException('missing int "$key"');
  return value;
}

// ---------------------------------------------------------------------------
// Shared values
// ---------------------------------------------------------------------------

/// What the top screen shows, as far as the companion cares.
enum CompanionContextKind {
  /// Something the companion has no panel for (dictionary tab, browse, a
  /// pushed page nobody claimed).
  none,

  /// The home dashboard.
  home,

  /// A library tab ([CompanionContext.library] says which).
  library,

  settings,
  reader,
  video,
  manga,
  audiobook,
  music,

  /// The review (SRS) module.
  srs,

  /// The game stream (its own panel mode takes the screen while streaming;
  /// the companion sees this context around it).
  gameStream;

  String get wire => name;

  /// Media is open on top: the Now tab shows that context's panel instead of
  /// the daily summary.
  bool get isMedia => switch (this) {
    reader || video || manga || audiobook || music || srs || gameStream => true,
    none || home || library || settings => false,
  };

  static CompanionContextKind fromWire(Object? value) {
    for (final CompanionContextKind kind in CompanionContextKind.values) {
      if (kind.wire == value) return kind;
    }
    return CompanionContextKind.none;
  }
}

/// Which library a [CompanionContextKind.library] context is.
enum CompanionLibraryKind {
  books,
  manga,
  video,
  music,
  games;

  String get wire => name;

  static CompanionLibraryKind? fromWire(Object? value) {
    for (final CompanionLibraryKind kind in CompanionLibraryKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// The top screen's context.
@immutable
class CompanionContext {
  const CompanionContext(
    this.kind, {
    this.library,
    this.title,
    this.settingsCategory,
  });

  static const CompanionContext none = CompanionContext(
    CompanionContextKind.none,
  );

  factory CompanionContext.fromJson(Map<String, Object?> json) =>
      CompanionContext(
        CompanionContextKind.fromWire(json['kind']),
        library: CompanionLibraryKind.fromWire(json['library']),
        title: _string(json, 'title'),
        settingsCategory: _string(json, 'settingsCategory'),
      );

  final CompanionContextKind kind;

  /// Only for [CompanionContextKind.library].
  final CompanionLibraryKind? library;

  /// What is open (book / video / series title) when the page knows it.
  final String? title;

  /// Only for [CompanionContextKind.settings]: the settings category open on
  /// top (`SettingsDestinationId.name`); null on the category list.
  final String? settingsCategory;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    if (library != null) 'library': library!.wire,
    if (title != null) 'title': title,
    if (settingsCategory != null) 'settingsCategory': settingsCategory,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionContext &&
      other.kind == kind &&
      other.library == library &&
      other.title == title &&
      other.settingsCategory == settingsCategory;

  @override
  int get hashCode => Object.hash(kind, library, title, settingsCategory);

  @override
  String toString() =>
      'CompanionContext($kind, $library, $title, $settingsCategory)';
}

/// Today's due cards in the built-in review (top-level deck counts, the same
/// numbers the deck list shows).
@immutable
class CompanionSrsDue {
  const CompanionSrsDue({
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
  });

  factory CompanionSrsDue.fromJson(Map<String, Object?> json) =>
      CompanionSrsDue(
        newCount: _int(json, 'new'),
        learnCount: _int(json, 'learn'),
        reviewCount: _int(json, 'review'),
      );

  final int newCount;
  final int learnCount;
  final int reviewCount;

  int get total => newCount + learnCount + reviewCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'new': newCount,
    'learn': learnCount,
    'review': reviewCount,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionSrsDue &&
      other.newCount == newCount &&
      other.learnCount == learnCount &&
      other.reviewCount == reviewCount;

  @override
  int get hashCode => Object.hash(newCount, learnCount, reviewCount);
}

/// What a [CompanionContinueItem] is.
enum CompanionContinueKind {
  book,
  manga,
  video;

  String get wire => name;

  static CompanionContinueKind? fromWire(Object? value) {
    for (final CompanionContinueKind kind in CompanionContinueKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// The one item the daily summary offers to continue.
@immutable
class CompanionContinueItem {
  const CompanionContinueItem({
    required this.kind,
    required this.title,
    required this.link,
    this.subtitle = '',
    this.progress,
    this.coverPath = '',
  });

  /// Null for anything the panel cannot show (unknown kind, no link).
  static CompanionContinueItem? fromJson(Map<String, Object?> json) {
    final CompanionContinueKind? kind = CompanionContinueKind.fromWire(
      json['kind'],
    );
    final String? title = _string(json, 'title');
    final String? link = _string(json, 'link');
    if (kind == null || title == null || link == null || link.isEmpty) {
      return null;
    }
    return CompanionContinueItem(
      kind: kind,
      title: title,
      link: link,
      subtitle: _string(json, 'subtitle') ?? '',
      progress: _double(json, 'progress'),
      coverPath: _string(json, 'cover') ?? '',
    );
  }

  final CompanionContinueKind kind;
  final String title;

  /// Author / series line; empty when unknown.
  final String subtitle;

  /// 0..1; null when unknown (the panel hides the bar).
  final double? progress;

  /// Local cover file both processes can read; empty when there is none.
  final String coverPath;

  /// `fushi://widget/continue?...` deep link the main screen opens.
  final String link;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'title': title,
    'link': link,
    if (subtitle.isNotEmpty) 'subtitle': subtitle,
    if (progress != null) 'progress': progress,
    if (coverPath.isNotEmpty) 'cover': coverPath,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionContinueItem &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.progress == progress &&
      other.coverPath == coverPath &&
      other.link == link;

  @override
  int get hashCode =>
      Object.hash(kind, title, subtitle, progress, coverPath, link);
}

/// The Now tab's content while no media is open on top. Every number comes
/// from data Fushi already has (study segments, the review decks, the
/// libraries' progress); a part with no data is null and the panel hides it.
@immutable
class CompanionDailySummary {
  const CompanionDailySummary({
    required this.dayKey,
    this.readingMs = 0,
    this.watchingMs = 0,
    this.listeningMs = 0,
    this.gamesMs = 0,
    this.srsDue,
    this.continueItem,
  });

  factory CompanionDailySummary.fromJson(Map<String, Object?> json) {
    final Object? srs = json['srs'];
    final Object? next = json['continue'];
    return CompanionDailySummary(
      dayKey: _string(json, 'day') ?? '',
      readingMs: _int(json, 'readingMs'),
      watchingMs: _int(json, 'watchingMs'),
      listeningMs: _int(json, 'listeningMs'),
      gamesMs: _int(json, 'gamesMs'),
      srsDue: srs is Map ? CompanionSrsDue.fromJson(_objectOf(srs)) : null,
      continueItem: next is Map
          ? CompanionContinueItem.fromJson(_objectOf(next))
          : null,
    );
  }

  /// Statistics day the times belong to (`FushiDatabase.statDateKeyOf`).
  final String dayKey;

  /// Today's time per study category (the home widget's categories: books
  /// incl. manga and audiobooks, music, video, games).
  final int readingMs;
  final int watchingMs;
  final int listeningMs;
  final int gamesMs;

  /// Null when the built-in review is not where cards go (module off, or
  /// cards go to Anki, whose counts the app cannot read).
  final CompanionSrsDue? srsDue;

  /// Null when nothing is in progress.
  final CompanionContinueItem? continueItem;

  Map<String, Object?> toJson() => <String, Object?>{
    'day': dayKey,
    'readingMs': readingMs,
    'watchingMs': watchingMs,
    'listeningMs': listeningMs,
    'gamesMs': gamesMs,
    if (srsDue != null) 'srs': srsDue!.toJson(),
    if (continueItem != null) 'continue': continueItem!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionDailySummary &&
      other.dayKey == dayKey &&
      other.readingMs == readingMs &&
      other.watchingMs == watchingMs &&
      other.listeningMs == listeningMs &&
      other.gamesMs == gamesMs &&
      other.srsDue == srsDue &&
      other.continueItem == continueItem;

  @override
  int get hashCode => Object.hash(
    dayKey,
    readingMs,
    watchingMs,
    listeningMs,
    gamesMs,
    srsDue,
    continueItem,
  );
}

/// What is playing on top, for the now-playing bar.
enum CompanionNowPlayingKind {
  music,
  audiobook,
  video;

  String get wire => name;

  static CompanionNowPlayingKind? fromWire(Object? value) {
    for (final CompanionNowPlayingKind kind in CompanionNowPlayingKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

@immutable
class CompanionNowPlaying {
  const CompanionNowPlaying({
    required this.kind,
    required this.title,
    required this.playing,
    this.subtitle = '',
  });

  static CompanionNowPlaying? fromJson(Map<String, Object?> json) {
    final CompanionNowPlayingKind? kind = CompanionNowPlayingKind.fromWire(
      json['kind'],
    );
    final String? title = _string(json, 'title');
    if (kind == null || title == null) return null;
    return CompanionNowPlaying(
      kind: kind,
      title: title,
      playing: json['playing'] == true,
      subtitle: _string(json, 'subtitle') ?? '',
    );
  }

  final CompanionNowPlayingKind kind;
  final String title;

  /// Artist / author; empty when unknown.
  final String subtitle;
  final bool playing;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'title': title,
    'playing': playing,
    if (subtitle.isNotEmpty) 'subtitle': subtitle,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionNowPlaying &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(kind, title, subtitle, playing);
}

// ---------------------------------------------------------------------------
// Main engine → panel
// ---------------------------------------------------------------------------

@immutable
sealed class CompanionHostMessage {
  const CompanionHostMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static CompanionHostMessage decode(String raw) {
    final Map<String, Object?> json = _decodeObject(raw);
    return switch (json[_typeKey]) {
      CompanionContextMessage.type => CompanionContextMessage(
        CompanionContext.fromJson(_objectOf(json['context'])),
      ),
      CompanionSnapshotMessage.type => CompanionSnapshotMessage(
        kind: CompanionContextKind.fromWire(json['kind']),
        data: _objectOf(json['data']),
      ),
      CompanionSummaryMessage.type => CompanionSummaryMessage(
        json['summary'] is Map
            ? CompanionDailySummary.fromJson(_objectOf(json['summary']))
            : null,
      ),
      CompanionNowPlayingMessage.type => CompanionNowPlayingMessage(
        json['nowPlaying'] is Map
            ? CompanionNowPlaying.fromJson(_objectOf(json['nowPlaying']))
            : null,
      ),
      CompanionLookupMessage.type => CompanionLookupMessage(
        text: _requireString(json, 'text'),
        charIndex: _int(json, 'charIndex', fallback: -1),
        sentence: _string(json, 'sentence'),
      ),
      CompanionPrefsChangedMessage.type => const CompanionPrefsChangedMessage(),
      CompanionLibraryChangedMessage.type =>
        const CompanionLibraryChangedMessage(),
      CompanionSettingsChangedMessage.type =>
        const CompanionSettingsChangedMessage(),
      CompanionLookupActionMessage.type => CompanionLookupActionMessage(
        _requireString(json, 'action'),
        args: _objectOf(json['args']),
      ),
      CompanionPanelNavMessage.type => CompanionPanelNavMessage(
        _requireString(json, 'action'),
      ),
      CompanionReplyMessage.type => CompanionReplyMessage(
        id: _requireInt(json, 'id'),
        value: json['value'],
        error: _string(json, 'error'),
      ),
      CompanionUiRestoreMessage.type => CompanionUiRestoreMessage(
        CompanionPanelUiState.fromJson(_objectOf(json['state'])),
      ),
      final Object? other => throw FormatException(
        'unknown companion host message "$other"',
      ),
    };
  }
}

/// The top screen's context changed. Replaces the context and drops the last
/// module snapshot (the new owner publishes its own).
class CompanionContextMessage extends CompanionHostMessage {
  const CompanionContextMessage(this.context);

  static const String type = 'context';

  final CompanionContext context;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'context': context.toJson(),
  };
}

/// Full state of the context's module (replaces the last one). The data
/// shape belongs to each module panel (S3).
class CompanionSnapshotMessage extends CompanionHostMessage {
  const CompanionSnapshotMessage({required this.kind, required this.data});

  static const String type = 'snapshot';

  final CompanionContextKind kind;
  final Map<String, Object?> data;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'kind': kind.wire,
    'data': data,
  };
}

/// The daily summary; null when the main engine could not collect it.
class CompanionSummaryMessage extends CompanionHostMessage {
  const CompanionSummaryMessage(this.summary);

  static const String type = 'summary';

  final CompanionDailySummary? summary;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'summary': summary?.toJson(),
  };
}

/// What is playing on top; null when nothing is.
class CompanionNowPlayingMessage extends CompanionHostMessage {
  const CompanionNowPlayingMessage(this.nowPlaying);

  static const String type = 'nowPlaying';

  final CompanionNowPlaying? nowPlaying;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'nowPlaying': nowPlaying?.toJson(),
  };
}

/// Look this up on the companion: [text] is the source line, [charIndex] the
/// tapped UTF-16 index in it (-1 = the whole text), [sentence] the sentence
/// for mining (defaults to [text]).
class CompanionLookupMessage extends CompanionHostMessage {
  const CompanionLookupMessage({
    required this.text,
    this.charIndex = -1,
    this.sentence,
  });

  static const String type = 'lookup';

  final String text;
  final int charIndex;
  final String? sentence;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'text': text,
    'charIndex': charIndex,
    if (sentence != null) 'sentence': sentence,
  };
}

/// Preferences changed in the main process (theme, locale, dictionary
/// settings, profile switch): the panel reloads its popup AppModel's prefs.
class CompanionPrefsChangedMessage extends CompanionHostMessage {
  const CompanionPrefsChangedMessage();

  static const String type = 'prefsChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// Library data changed in the main process: lists the panel reads refresh.
class CompanionLibraryChangedMessage extends CompanionHostMessage {
  const CompanionLibraryChangedMessage();

  static const String type = 'libraryChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// A setting may have changed in the main process (a preference write, a
/// write from the companion): the Settings tab reloads what it shows.
class CompanionSettingsChangedMessage extends CompanionHostMessage {
  const CompanionSettingsChangedMessage();

  static const String type = 'settingsChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// The top screen's controller acts on the companion's open lookup (S6
/// controller lookup mode): [action] is one of [CompanionLookupActions].
class CompanionLookupActionMessage extends CompanionHostMessage {
  const CompanionLookupActionMessage(
    this.action, {
    this.args = const <String, Object?>{},
  });

  static const String type = 'lookupAction';

  final String action;
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'action': action,
    'args': args,
  };
}

/// One step of R1 panel drive (S6): [action] is one of [CompanionPanelNav].
class CompanionPanelNavMessage extends CompanionHostMessage {
  const CompanionPanelNavMessage(this.action);

  static const String type = 'panelNav';

  final String action;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'action': action,
  };
}

/// Answer to the panel's [CompanionRequestMessage] [id]: [value] (JSON) or
/// [error] when the request failed.
class CompanionReplyMessage extends CompanionHostMessage {
  const CompanionReplyMessage({required this.id, this.value, this.error});

  static const String type = 'reply';

  final int id;
  final Object? value;
  final String? error;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'value': value,
    if (error != null) 'error': error,
  };
}

/// The panel's last UI state, handed back on "ready": the panel finishes
/// whenever the top activity stops (file picker, Home) and a new one starts
/// when it comes back; the main engine outlives it and keeps what the old
/// one reported ([CompanionUiStateMessage]).
class CompanionUiRestoreMessage extends CompanionHostMessage {
  const CompanionUiRestoreMessage(this.state);

  static const String type = 'uiRestore';

  final CompanionPanelUiState state;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'state': state.toJson(),
  };
}

/// Where the user is on the companion panel: what a relaunched panel
/// restores. Values are wire names (`CompanionTab`, `CompanionLibraryMode`,
/// `CompanionLibrarySection`, settings category ids); unknown names restore
/// as the default. Kept in the main engine's memory only (not on disk).
@immutable
class CompanionPanelUiState {
  const CompanionPanelUiState({
    this.tab,
    this.libraryMode,
    this.librarySection,
    this.libraryQuery = '',
    this.settingsCategory,
    this.settingsQuery = '',
  });

  factory CompanionPanelUiState.fromJson(Map<String, Object?> json) =>
      CompanionPanelUiState(
        tab: _string(json, 'tab'),
        libraryMode: _string(json, 'libraryMode'),
        librarySection: _string(json, 'librarySection'),
        libraryQuery: _string(json, 'libraryQuery') ?? '',
        settingsCategory: _string(json, 'settingsCategory'),
        settingsQuery: _string(json, 'settingsQuery') ?? '',
      );

  /// The selected tab; null = Now.
  final String? tab;

  /// The Library mode the user picked; null = follow the top screen.
  final String? libraryMode;

  /// Browse mode's section chip; null = Home.
  final String? librarySection;

  /// Browse mode's search field.
  final String libraryQuery;

  /// The category page open on the Settings tab; null = its overview.
  final String? settingsCategory;

  /// The Settings tab's search field.
  final String settingsQuery;

  CompanionPanelUiState copyWith({
    String? Function()? tab,
    String? Function()? libraryMode,
    String? Function()? librarySection,
    String? libraryQuery,
    String? Function()? settingsCategory,
    String? settingsQuery,
  }) => CompanionPanelUiState(
    tab: tab == null ? this.tab : tab(),
    libraryMode: libraryMode == null ? this.libraryMode : libraryMode(),
    librarySection: librarySection == null
        ? this.librarySection
        : librarySection(),
    libraryQuery: libraryQuery ?? this.libraryQuery,
    settingsCategory: settingsCategory == null
        ? this.settingsCategory
        : settingsCategory(),
    settingsQuery: settingsQuery ?? this.settingsQuery,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'tab': ?tab,
    'libraryMode': ?libraryMode,
    'librarySection': ?librarySection,
    if (libraryQuery.isNotEmpty) 'libraryQuery': libraryQuery,
    'settingsCategory': ?settingsCategory,
    if (settingsQuery.isNotEmpty) 'settingsQuery': settingsQuery,
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionPanelUiState &&
      other.tab == tab &&
      other.libraryMode == libraryMode &&
      other.librarySection == librarySection &&
      other.libraryQuery == libraryQuery &&
      other.settingsCategory == settingsCategory &&
      other.settingsQuery == settingsQuery;

  @override
  int get hashCode => Object.hash(
    tab,
    libraryMode,
    librarySection,
    libraryQuery,
    settingsCategory,
    settingsQuery,
  );

  @override
  String toString() => 'CompanionPanelUiState(${toJson()})';
}

// ---------------------------------------------------------------------------
// Panel → main engine
// ---------------------------------------------------------------------------

@immutable
sealed class CompanionPanelMessage {
  const CompanionPanelMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static CompanionPanelMessage decode(String raw) {
    final Map<String, Object?> json = _decodeObject(raw);
    return switch (json[_typeKey]) {
      CompanionReadyMessage.type => const CompanionReadyMessage(),
      CompanionCommandMessage.type => CompanionCommandMessage(
        kind: CompanionContextKind.fromWire(json['kind']),
        action: _requireString(json, 'action'),
        args: _objectOf(json['args']),
      ),
      CompanionPlaybackMessage.type => CompanionPlaybackMessage(
        CompanionPlaybackAction.fromWire(json['action']),
      ),
      CompanionOpenOnMainMessage.type => CompanionOpenOnMainMessage(
        _requireString(json, 'link'),
      ),
      CompanionRequestMessage.type => CompanionRequestMessage(
        id: _requireInt(json, 'id'),
        method: _requireString(json, 'method'),
        args: _objectOf(json['args']),
      ),
      CompanionLookupCountedMessage.type =>
        const CompanionLookupCountedMessage(),
      CompanionLookupStateMessage.type => CompanionLookupStateMessage(
        open: json['open'] == true,
        term: _string(json, 'term'),
        mined: json['mined'] == true,
      ),
      CompanionUiStateMessage.type => CompanionUiStateMessage(
        CompanionPanelUiState.fromJson(_objectOf(json['state'])),
      ),
      final Object? other => throw FormatException(
        'unknown companion panel message "$other"',
      ),
    };
  }
}

/// The panel's Dart side is listening: send it everything again.
class CompanionReadyMessage extends CompanionPanelMessage {
  const CompanionReadyMessage();

  static const String type = 'ready';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// A control on a module panel ([kind] = the context it was made for, so a
/// command for a context that has gone meanwhile is dropped). [action] and
/// [args] belong to the module (S3).
class CompanionCommandMessage extends CompanionPanelMessage {
  const CompanionCommandMessage({
    required this.kind,
    required this.action,
    this.args = const <String, Object?>{},
  });

  static const String type = 'command';

  final CompanionContextKind kind;
  final String action;
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'kind': kind.wire,
    'action': action,
    'args': args,
  };
}

/// Playback control of whatever plays on top (the now-playing bar).
enum CompanionPlaybackAction {
  toggle;

  String get wire => name;

  static CompanionPlaybackAction fromWire(Object? value) {
    for (final CompanionPlaybackAction action
        in CompanionPlaybackAction.values) {
      if (action.wire == value) return action;
    }
    throw FormatException('unknown playback action "$value"');
  }
}

class CompanionPlaybackMessage extends CompanionPanelMessage {
  const CompanionPlaybackMessage(this.action);

  static const String type = 'playback';

  final CompanionPlaybackAction action;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'action': action.wire,
  };
}

/// Open [link] on the main screen. Only `fushi://widget/...` deep links (the
/// home-screen widget's link set: continue an item, start reviews, a tab, a
/// settings page...) are followed.
class CompanionOpenOnMainMessage extends CompanionPanelMessage {
  const CompanionOpenOnMainMessage(this.link);

  static const String type = 'openOnMain';

  final String link;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'link': link,
  };
}

/// A request the main engine answers with a [CompanionReplyMessage] of the
/// same [id]. [method] names a handler registered on the main side.
class CompanionRequestMessage extends CompanionPanelMessage {
  const CompanionRequestMessage({
    required this.id,
    required this.method,
    this.args = const <String, Object?>{},
  });

  static const String type = 'request';

  final int id;
  final String method;
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'id': id,
    'method': method,
    'args': args,
  };
}

/// The companion's lookup panel opened / closed ([mined]: a card was just
/// added), so the top screen's controller mapping can switch.
class CompanionLookupStateMessage extends CompanionPanelMessage {
  const CompanionLookupStateMessage({
    required this.open,
    this.term,
    this.mined = false,
  });

  static const String type = 'lookupState';

  final bool open;
  final String? term;
  final bool mined;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'open': open,
    if (term != null) 'term': term,
    'mined': mined,
  };
}

/// The companion's lookup started one dictionary lookup (a main-screen lookup,
/// a nested one, a line tapped on a module panel). The main engine counts it
/// through the page that owns the context (its own lookup counter, the one
/// its in-page popup uses), so the companion's lookups show up in that
/// media's statistics. The panel itself writes no counter.
class CompanionLookupCountedMessage extends CompanionPanelMessage {
  const CompanionLookupCountedMessage();

  static const String type = 'lookupCounted';

  @override
  Map<String, Object?> toJson() => <String, Object?>{_typeKey: type};
}

/// The panel's UI state changed (a tab, the Library mode / section / search,
/// the Settings category / search): the main engine keeps the latest and
/// hands it to the next panel ([CompanionUiRestoreMessage]).
class CompanionUiStateMessage extends CompanionPanelMessage {
  const CompanionUiStateMessage(this.state);

  static const String type = 'uiState';

  final CompanionPanelUiState state;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    _typeKey: type,
    'state': state.toJson(),
  };
}
