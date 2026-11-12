/// Cleaning a local book / manga title (often a file name): clean search
/// terms for a tracking site (`Ajin (HD Scan) Ajin 01` → `Ajin`,
/// `14 Sai no Koi [水谷フーカ] 14歳の恋 第01巻` → `14 Sai no Koi`, `14歳の恋`).
library;

import 'package:fushi_engine/media/collections/book_series_key.dart';

/// Hiragana or katakana.
bool isTitleKana(int code) =>
    (code >= 0x3041 && code <= 0x3096) || (code >= 0x30A1 && code <= 0x30FA);

/// CJK ideograph (Japanese kanji, Chinese hanzi).
bool isTitleHan(int code) =>
    (code >= 0x4E00 && code <= 0x9FFF) ||
    (code >= 0x3400 && code <= 0x4DBF) ||
    (code >= 0xF900 && code <= 0xFAFF);

bool _isLatinLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Splits a title into its Latin-script and CJK runs (words without letters,
/// like `14`, join the run after them). One run = nothing to split.
List<String> titleScriptRuns(String title) {
  final List<String> words = title
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  final List<List<String>> runs = <List<String>>[];
  final List<String> pending = <String>[];
  bool? lastCjk;
  for (final String word in words) {
    final List<int> runes = word.runes.toList();
    final bool cjk = runes.any((int c) => isTitleHan(c) || isTitleKana(c));
    final bool latin = runes.any(_isLatinLetter);
    if (!cjk && !latin) {
      pending.add(word);
      continue;
    }
    if (lastCjk != cjk || runs.isEmpty) {
      runs.add(<String>[]);
      lastCjk = cjk;
    }
    runs.last
      ..addAll(pending)
      ..add(word);
    pending.clear();
  }
  if (pending.isNotEmpty && runs.isNotEmpty) runs.last.addAll(pending);
  return <String>[for (final List<String> run in runs) run.join(' ')];
}

/// A file extension a book or video was imported from.
final RegExp _fileExtension = RegExp(
  r'\.(?:cbz|cbr|cb7|zip|rar|7z|epub|pdf|mobi|azw3?|kepub|txt|'
  r'mkv|mp4|m4v|avi|webm|mov|wmv|flv|ts|m2ts|rmvb)$',
  caseSensitive: false,
);

/// A release group glued to the end of a video file name after its tags:
/// `[HEVC]-GM-Team`, `(1080p)-ANDY`.
final RegExp _trailingGroup = RegExp(
  r'(?<=[\]\)】])\s*-\s*[A-Za-z0-9][A-Za-z0-9._-]*$',
);

/// Where the episode part of a video name starts: `S01E01`, `S1E2`, `1x01`,
/// `S1` / `Season 2` (a season only), `Episode 46`, `EP 12`, `Ep.3` and a
/// fansub ` - 12`. Everything from there on (episode title, tags) is not
/// the series title.
final RegExp _episodeMarker = RegExp(
  r'(?:^|(?<=[\s._\-]))(?:'
  r'S\d{1,2}\s?E\d{1,4}|\d{1,2}x\d{2,4}|S\d{1,2}|Season\s*\d{1,2}|'
  r'(?:Episode|Ep\.?)\s*\d{1,4}'
  r')(?![\p{L}\p{N}])'
  r'|\s-\s+\d{1,4}(?![\p{L}\p{N}.])',
  caseSensitive: false,
  unicode: true,
);

/// A bare resolution / codec / source tag of a scene-style video name
/// (`1080p`, `x265`, `HEVC`, `BDRip`, `WEB-DL`, `10bit`, `AAC2.0`):
/// the title ends before the first one.
final RegExp _bareReleaseTag = RegExp(
  r'(?:^|(?<=[\s._\-]))(?:'
  r'\d{3,4}p|4k|[xh]\.?26[45]|hevc|avc|aac(?:\s?\d\.\d)?|flac|ac3|'
  r'e-?ac-?3|dts|truehd|bd-?rip|blu-?ray|web-?dl|web-?rip|hdtv|dvd-?rip|'
  r'remux|10-?bit|8-?bit'
  r')(?![\p{L}\p{N}])',
  caseSensitive: false,
  unicode: true,
);

/// A year left at the end once a scene-style name is cut at its first tag
/// (`Movie Title 2019 1080p` → `Movie Title 2019`).
final RegExp _trailingYear = RegExp(r'\s(?:19|20)\d{2}$');

/// `[...]`, `【...】`, `〔...〕`, `{...}`: release groups, scanlators, authors,
/// CRC and quality tags. Never the title itself in a file name.
final RegExp _squareTag = RegExp(
  r'\s*(?:\[[^\[\]]*\]|【[^【】]*】|〔[^〔〕]*〕|\{[^{}]*\})\s*',
);

/// `(...)` / `（...）`; dropped only when [_releaseWords] says it is a release
/// tag (a parenthesis can be part of a real title).
final RegExp _roundTag = RegExp(r'\s*[(（]([^()（）]*)[)）]\s*');

/// Words that make a parenthesised tag a release / scan / edition tag.
final RegExp _releaseWords = RegExp(
  r'^(?:'
  r'(?:(?:hd|hq|lq|high[\s-]?quality|digital|web|raw|raws|official|'
  r'colou?red|full[\s-]?colou?r|c2c|scans?|scanlations?|scanlated|'
  r'complete|completed|batch|eng|english|jpn?|japanese|rip|webrip|'
  r'remaster(?:ed)?|uncensored|censored|fixed|repack|'
  r'4k|[xh]\.?26[45]|hevc|avc|aac|flac|ac3|dts|bd-?rip|blu-?ray|web-?dl|'
  r'web-?rip|hdtv|dvd-?rip|remux|10-?bit|8-?bit|'
  r'\d{3,4}p|v\d{1,2}|\d{4}|[0-9a-f]{8})[\s,._+&/-]*)+'
  r')$',
  caseSensitive: false,
);

/// A trailing chapter marker: `ch.12`, `Chapter 12`, `c012`, `第12話`.
final RegExp _chapterSuffix = RegExp(
  r'[\s_\-]*(?:ch(?:apter)?\.?\s*\d{1,4}(?:\.\d)?|c\d{2,4}|第\s*\d{1,4}\s*[話话回章])\s*$',
  caseSensitive: false,
);

/// One word, one hyphen, a number: `Catch-22` (see [localTitleSearchCandidates]).
final RegExp _singleHyphenNumber = RegExp(r'^[^\s\-_]+-\d{1,4}$');

final RegExp _edgeSeparators = RegExp(r'^[\s_\-:・~～|]+|[\s_\-:・~～|]+$');

String _collapse(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(_edgeSeparators, '')
    .trim();

/// `Ajin Ajin` → `Ajin`; `Ajin - Ajin` → `Ajin`. Null when not repeated.
String? _undoubled(String title) {
  final List<String> words = title
      .split(RegExp(r'\s+'))
      .where(
        (String w) => w.isNotEmpty && !RegExp(r'^[\-_:・|~～]+$').hasMatch(w),
      )
      .toList();
  if (words.length < 2 || words.length.isOdd) return null;
  final int half = words.length ~/ 2;
  for (int i = 0; i < half; i++) {
    if (words[i].toLowerCase() != words[half + i].toLowerCase()) return null;
  }
  return words.take(half).join(' ');
}

/// [s] without bracketed group / scan / author / CRC tags and without release
/// tags in parentheses (a parenthesis that is not a release tag stays).
String _withoutTags(String s) {
  String out = s;
  final String withoutSquare = _collapse(out.replaceAll(_squareTag, ' '));
  if (withoutSquare.isNotEmpty) out = withoutSquare;
  final String withoutRelease = _collapse(
    out.replaceAllMapped(
      _roundTag,
      (Match m) => _releaseWords.hasMatch(m.group(1)!.trim()) ? ' ' : m[0]!,
    ),
  );
  if (withoutRelease.isNotEmpty) out = withoutRelease;
  return out;
}

/// [s] cut before its episode part ([_episodeMarker]) or its first bare
/// release tag ([_bareReleaseTag]), whichever comes first; a year left at
/// the end of a cut scene name goes too. Unchanged when nothing would be
/// left (`S1`, `1080p`).
String _withoutVideoParts(String s) {
  final int episode = _episodeMarker.firstMatch(s)?.start ?? -1;
  final int tag = _bareReleaseTag.firstMatch(s)?.start ?? -1;
  final List<int> cuts = <int>[
    for (final int at in <int>[episode, tag])
      if (at > 0) at,
  ];
  if (cuts.isEmpty) return s;
  final int cut = cuts.reduce((int a, int b) => a < b ? a : b);
  String head = _collapse(s.substring(0, cut));
  if (cut == tag) {
    final String withoutYear = _collapse(head.replaceFirst(_trailingYear, ''));
    if (withoutYear.isNotEmpty) head = withoutYear;
  }
  return head.isEmpty ? s : head;
}

/// Search candidates for a local title, best first.
///
/// Drops file extensions, bracketed group / scan / author / CRC tags, release
/// tags in parentheses (`(HD Scan)`, `(Digital)`, `(v2)`, `(2025)`), the
/// episode part and release tags of a video file name (`S01E01 - Title`,
/// `Episode 46`, ` - 12`, `S1`, `1080p.WEB-DL.x265-GROUP`, `[HEVC]-GROUP`;
/// a scene name's dots read as spaces), trailing volume
/// (the same rule as [parseBookSeriesKey]) and chapter markers, and a series
/// name written twice. A title in two scripts (`14 Sai no Koi 14歳の恋`)
/// gives each part as a candidate.
///
/// Conservative: never empty, never an empty string, the trimmed original is
/// always the last candidate, and a parenthesis that is not a release tag is
/// kept. Plain titles (`86`, `Catch-22`) come back unchanged.
List<String> localTitleSearchCandidates(String title) {
  final String original = title.trim();
  if (original.isEmpty) return <String>[title];
  final List<String> out = <String>[];
  void add(String value) {
    final String clean = _collapse(value);
    if (clean.isNotEmpty && !out.contains(clean)) out.add(clean);
  }

  String s = original.replaceFirst(_fileExtension, '');
  if (!s.contains(' ') && s.contains('_')) s = s.replaceAll('_', ' ');
  if (!s.contains(' ') && '.'.allMatches(s).length >= 2) {
    s = s.replaceAll('.', ' ');
  }
  final String withoutGroup = _collapse(s.replaceFirst(_trailingGroup, ''));
  if (withoutGroup.isNotEmpty) s = withoutGroup;
  s = _withoutTags(s);
  s = _withoutVideoParts(s);
  final String withoutChapter = _collapse(s.replaceFirst(_chapterSuffix, ''));
  if (withoutChapter.isNotEmpty) s = withoutChapter;
  // The shelf reads a single word glued to a number by one hyphen as a
  // volume (`Series-02` slugs group on the shelf), but as a search term it is
  // far more often the title itself (`Catch-22`): no volume split for it.
  if (!_singleHyphenNumber.hasMatch(s)) {
    final String series = parseBookSeriesKey(s)?.seriesTitle ?? s;
    if (_collapse(series).isNotEmpty) s = _collapse(series);
  }
  s = _undoubled(s) ?? s;

  final List<String> runs = titleScriptRuns(s);
  final bool split =
      runs.length > 1 &&
      runs.every(
        (String run) => run.runes.where((int c) => c != 0x20).length >= 3,
      );
  if (split) {
    for (final String run in runs) {
      add(_undoubled(run) ?? run);
    }
  }
  add(s);
  out.remove(original);
  out.add(original);
  return out;
}
