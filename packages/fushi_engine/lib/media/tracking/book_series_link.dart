/// Series-level book links: one link on a series card (`book_collection`)
/// covers every volume of the card, the ones added later too.
///
/// Rules (maintainer decision board item pr4196, option c):
/// - a volume's number comes from the book (OPF series index, then the number
///   in its title); the card position is used only when no volume of the card
///   has a number at all;
/// - a volume with its own link on the same site is left to that link (the
///   more specific link wins), a volume on the do-not-track list or marked
///   private is not counted;
/// - a volume without a number in a numbered series, or one whose title names
///   another series than the rest of the card (a spin-off grouped in by
///   mistake), is not counted and waits for the user;
/// - the sent value is the highest finished volume, or the volume before the
///   one being read: the per-volume rule applied to the maximum, so it never
///   goes down.
library;

/// Why a volume of a series card is or is not counted by the series link.
enum TrackingSeriesMemberState {
  /// Counted by the series link.
  counted,

  /// On the do-not-track list ("Don't count this volume").
  excluded,

  /// Has its own link on the site; that link counts it.
  ownLink,

  /// Marked private: never searched for or sent.
  private,

  /// Another format than the link's kind (a novel in a manga card).
  otherKind,

  /// The series is numbered but this volume has no number.
  noNumber,

  /// Its title names another series than the rest of the card.
  otherSeries,
}

/// What is known about one volume of a series card, for one site.
final class TrackingSeriesMemberFacts {
  const TrackingSeriesMemberFacts({
    required this.bookKey,
    required this.title,
    this.volume,
    this.seriesKey,
    this.started = false,
    this.finished = false,
    this.evidenceAt = 0,
    this.excluded = false,
    this.private = false,
    this.otherKind = false,
    this.ownLink = false,
  });

  final String bookKey;
  final String title;

  /// The book's own volume number (whole, ≥ 1); null when it has none.
  final int? volume;

  /// The series name in the title, folded ([parseBookSeriesKey]); null when
  /// the title carries no recognisable series name.
  final String? seriesKey;

  /// Reading started (a saved position, or finished).
  final bool started;
  final bool finished;

  /// Newest local reading time (ms): catch-up evidence.
  final int evidenceAt;
  final bool excluded;
  final bool private;
  final bool otherKind;
  final bool ownLink;
}

/// One volume of a series card as the series link sees it.
final class TrackingSeriesMember {
  const TrackingSeriesMember({
    required this.bookKey,
    required this.title,
    required this.state,
    this.volume,
    this.started = false,
    this.finished = false,
  });

  final String bookKey;
  final String title;
  final TrackingSeriesMemberState state;

  /// The volume number the series link counts it as (from the card position
  /// when [TrackingSeriesCoverage.numberedByPosition]); null when unknown.
  final int? volume;
  final bool started;
  final bool finished;

  bool get counted => state == TrackingSeriesMemberState.counted;
}

/// What a series link sends: [progress] volumes, [completed] = the volume
/// that gives the number is finished (the site completes the entry only when
/// that is its final volume of a finished work).
typedef TrackingSeriesProgress = ({
  int progress,
  bool completed,
  int evidenceAt,
});

/// Every volume of a series card and what the series link sends for it.
final class TrackingSeriesCoverage {
  const TrackingSeriesCoverage({
    required this.members,
    this.numberedByPosition = false,
    this.progress,
  });

  static const TrackingSeriesCoverage empty = TrackingSeriesCoverage(
    members: <TrackingSeriesMember>[],
  );

  /// In card order.
  final List<TrackingSeriesMember> members;

  /// No volume of the card has a number: they count by card position.
  final bool numberedByPosition;

  /// Null when no counted volume was started (nothing to send).
  final TrackingSeriesProgress? progress;

  /// The entry of [bookKey]; null when it is not on the card.
  TrackingSeriesMember? memberOf(String bookKey) {
    for (final TrackingSeriesMember member in members) {
      if (member.bookKey == bookKey) return member;
    }
    return null;
  }

  int countOf(TrackingSeriesMemberState state) => members
      .where((TrackingSeriesMember member) => member.state == state)
      .length;
}

/// The series link's view of a card whose volumes are [facts], in card order.
TrackingSeriesCoverage planSeriesCoverage(
  List<TrackingSeriesMemberFacts> facts,
) {
  final String? mainSeries = _mainSeriesKey(facts);
  TrackingSeriesMemberState? stateOf(TrackingSeriesMemberFacts member) {
    if (member.excluded) return TrackingSeriesMemberState.excluded;
    if (member.private) return TrackingSeriesMemberState.private;
    if (member.otherKind) return TrackingSeriesMemberState.otherKind;
    if (member.ownLink) return TrackingSeriesMemberState.ownLink;
    if (mainSeries != null &&
        member.seriesKey != null &&
        member.seriesKey != mainSeries) {
      return TrackingSeriesMemberState.otherSeries;
    }
    return null; // Counted, once it has a number.
  }

  final List<TrackingSeriesMemberState?> states = <TrackingSeriesMemberState?>[
    for (final TrackingSeriesMemberFacts member in facts) stateOf(member),
  ];
  // Card position counts only when no volume of the series (spin-offs and
  // other kinds left out) has a number of its own.
  bool inSeries(int i) =>
      states[i] != TrackingSeriesMemberState.otherSeries &&
      states[i] != TrackingSeriesMemberState.otherKind;
  final bool byPosition = !<int>[
    for (int i = 0; i < facts.length; i++)
      if (inSeries(i)) i,
  ].any((int i) => facts[i].volume != null);

  final List<TrackingSeriesMember> members = <TrackingSeriesMember>[];
  int position = 0;
  int best = -1;
  bool bestCompleted = false;
  int evidenceAt = 0;
  for (int i = 0; i < facts.length; i++) {
    final TrackingSeriesMemberFacts member = facts[i];
    int? volume = member.volume;
    if (byPosition && inSeries(i)) {
      position++;
      volume = position;
    }
    TrackingSeriesMemberState state =
        states[i] ??
        (volume == null
            ? TrackingSeriesMemberState.noNumber
            : TrackingSeriesMemberState.counted);
    members.add(
      TrackingSeriesMember(
        bookKey: member.bookKey,
        title: member.title,
        state: state,
        volume: volume,
        started: member.started,
        finished: member.finished,
      ),
    );
    if (state != TrackingSeriesMemberState.counted || volume == null) continue;
    if (!member.started && !member.finished) continue;
    final int value = member.finished ? volume : volume - 1;
    evidenceAt = evidenceAt > member.evidenceAt
        ? evidenceAt
        : member.evidenceAt;
    if (value > best || (value == best && member.finished)) {
      best = value;
      bestCompleted = member.finished;
    }
  }
  return TrackingSeriesCoverage(
    members: members,
    numberedByPosition: byPosition,
    progress: best < 0
        ? null
        : (progress: best, completed: bestCompleted, evidenceAt: evidenceAt),
  );
}

/// The series name most volumes of the card carry; null when none carries
/// one, or when no name is carried by more volumes than any other (no
/// majority to tell a spin-off from the series).
String? _mainSeriesKey(List<TrackingSeriesMemberFacts> facts) {
  final Map<String, int> counts = <String, int>{};
  for (final TrackingSeriesMemberFacts member in facts) {
    final String? key = member.seriesKey;
    if (key == null || key.isEmpty) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final List<MapEntry<String, int>> ranked = counts.entries.toList()
    ..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );
  if (ranked.length > 1 && ranked[0].value == ranked[1].value) return null;
  return ranked.first.key;
}
