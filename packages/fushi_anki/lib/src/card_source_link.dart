import 'dart:convert';
import 'dart:math';

/// Source identities are library UIDs, never device-local filenames.
enum CardSourceKind { book, manga, video }

/// Versioned, portable source locator embedded in a mined Anki note.
/// Character offsets use the reader's chapter anchor convention; all indices
/// are zero based and times are offsets on the original media timeline.
class CardSourceLink {
  CardSourceLink({
    required this.kind,
    required this.uid,
    required this.sourceId,
    this.chapterIndex,
    this.charOffset,
    this.charLength,
    this.pageIndex,
    this.episodeIndex,
    this.startMs,
    this.endMs,
    this.audioFileIndex,
    this.chapterId,
    this.fingerprint,
  }) {
    _validate();
  }

  final CardSourceKind kind;
  final String uid;
  final String sourceId;
  final int? chapterIndex;
  final int? charOffset;
  final int? charLength;
  final int? pageIndex;
  final int? episodeIndex;
  final int? startMs;
  final int? endMs;
  final int? audioFileIndex;
  final String? chapterId;

  /// SHA-256 of the complete source file; mandatory for video identities,
  /// whose existing library UID can otherwise collide across devices.
  final String? fingerprint;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static const int _maxInteger = 2147483647;
  static const Set<String> _keys = <String>{
    'v',
    'kind',
    'uid',
    'sourceId',
    'chapterIndex',
    'charOffset',
    'charLength',
    'pageIndex',
    'episodeIndex',
    'startMs',
    'endMs',
    'audioFileIndex',
    'chapterId',
    'fingerprint',
  };

  static String newSourceId() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final String hex =
        bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String markerForSourceId(String sourceId) {
    if (!_uuid.hasMatch(sourceId)) {
      throw const FormatException('Invalid card source ID');
    }
    return 'fushi_source_${sourceId.replaceAll('-', '')}';
  }

  String get markerTag => markerForSourceId(sourceId);

  CardSourceLink withSourceId(String value) => CardSourceLink(
        kind: kind,
        uid: uid,
        sourceId: value,
        chapterIndex: chapterIndex,
        charOffset: charOffset,
        charLength: charLength,
        pageIndex: pageIndex,
        episodeIndex: episodeIndex,
        startMs: startMs,
        endMs: endMs,
        audioFileIndex: audioFileIndex,
        chapterId: chapterId,
        fingerprint: fingerprint,
      );

  /// Reads only quoted source hrefs generated for note fields. The locator
  /// parser still validates every parameter after HTML attribute unescaping.
  static Iterable<CardSourceLink> fromHtml(String html) sync* {
    final RegExp href = RegExp(
      r'''href\s*=\s*["'](fushi://source/?\?[^"'<>]+)["']''',
      caseSensitive: false,
    );
    for (final RegExpMatch match in href.allMatches(html)) {
      final CardSourceLink? source = tryParse(
        match.group(1)!.replaceAll('&amp;', '&'),
      );
      if (source != null) yield source;
    }
  }

  void _validate() {
    markerForSourceId(sourceId);
    if (fingerprint != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint!)) {
      throw const FormatException('Invalid source file fingerprint');
    }
    // Existing video identities contain a relative namespace and the original
    // sanitized title (for example video/夏目友人帳 第1話 (2)). Treat them as
    // opaque database keys; never turn them into filenames or URI destinations.
    if (uid.trim().isEmpty ||
        uid.length > 1024 ||
        uid.startsWith('/') ||
        RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(uid) ||
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(uid) ||
        uid
            .split('/')
            .any((String segment) => segment == '.' || segment == '..')) {
      throw const FormatException('Invalid library UID');
    }
    for (final int? value in <int?>[
      chapterIndex,
      charOffset,
      charLength,
      pageIndex,
      episodeIndex,
      startMs,
      endMs,
      audioFileIndex,
    ]) {
      if (value != null && (value < 0 || value > _maxInteger)) {
        throw const FormatException('Source offset is out of range');
      }
    }
    if ((startMs == null) != (endMs == null) ||
        (startMs != null && endMs! < startMs!)) {
      throw const FormatException('Invalid source time range');
    }
    if (chapterId != null &&
        (chapterId!.isEmpty ||
            chapterId!.length > 512 ||
            RegExp(r'[\x00-\x1f\\]').hasMatch(chapterId!) ||
            chapterId!.startsWith('file:'))) {
      throw const FormatException('Invalid chapter identity');
    }
    switch (kind) {
      case CardSourceKind.book:
        if (chapterIndex == null ||
            charOffset == null ||
            pageIndex != null ||
            episodeIndex != null ||
            chapterId != null) {
          throw const FormatException(
            'Book requires a chapter and character anchor',
          );
        }
      case CardSourceKind.manga:
        if (pageIndex == null ||
            chapterIndex != null ||
            charOffset != null ||
            charLength != null ||
            episodeIndex != null ||
            startMs != null ||
            audioFileIndex != null) {
          throw const FormatException('Manga requires a page anchor');
        }
      case CardSourceKind.video:
        if (fingerprint == null ||
            episodeIndex == null ||
            startMs == null ||
            chapterIndex != null ||
            charOffset != null ||
            charLength != null ||
            pageIndex != null ||
            chapterId != null ||
            audioFileIndex != null) {
          throw const FormatException(
            'Video requires a file fingerprint, episode and time range',
          );
        }
    }
  }

  Uri toUri() => Uri(
        scheme: 'fushi',
        host: 'source',
        queryParameters: <String, String>{
          'v': '1',
          'kind': kind.name,
          'uid': uid,
          'sourceId': sourceId,
          if (chapterIndex != null) 'chapterIndex': '$chapterIndex',
          if (charOffset != null) 'charOffset': '$charOffset',
          if (charLength != null) 'charLength': '$charLength',
          if (pageIndex != null) 'pageIndex': '$pageIndex',
          if (episodeIndex != null) 'episodeIndex': '$episodeIndex',
          if (startMs != null) 'startMs': '$startMs',
          if (endMs != null) 'endMs': '$endMs',
          if (audioFileIndex != null) 'audioFileIndex': '$audioFileIndex',
          if (chapterId != null) 'chapterId': chapterId!,
          if (fingerprint != null) 'fingerprint': fingerprint!,
        },
      );

  String toHtml({String label = '↗ Fushi'}) =>
      '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(toUri().toString())}">${const HtmlEscape(HtmlEscapeMode.element).convert(label)}</a>';

  static CardSourceLink? tryParse(String raw) {
    try {
      return parse(raw);
    } on FormatException {
      return null;
    }
  }

  static CardSourceLink parse(String raw) {
    if (raw.length > 16384)
      throw const FormatException('Source URL is too long');
    final Uri uri = Uri.parse(raw);
    if (uri.scheme != 'fushi' ||
        uri.host != 'source' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        // Windows ShellExecute canonicalizes an empty authority path to '/'.
        // Both denote this endpoint; reject all other paths as before.
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasFragment) {
      throw const FormatException('Invalid source URL');
    }
    final Map<String, List<String>> all = uri.queryParametersAll;
    if (all.entries.any(
      (MapEntry<String, List<String>> entry) =>
          !_keys.contains(entry.key) || entry.value.length != 1,
    )) {
      throw const FormatException('Unknown or duplicate source parameter');
    }
    final Map<String, String> query = uri.queryParameters;
    if (query['v'] != '1')
      throw const FormatException('Unsupported source version');
    final CardSourceKind kind = switch (query['kind']) {
      'book' => CardSourceKind.book,
      'manga' => CardSourceKind.manga,
      'video' => CardSourceKind.video,
      _ => throw const FormatException('Unknown source kind'),
    };
    int? number(String key) {
      final String? value = query[key];
      if (value == null) return null;
      if (!RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(value)) {
        throw const FormatException('Invalid source offset');
      }
      return int.parse(value);
    }

    return CardSourceLink(
      kind: kind,
      uid: query['uid'] ?? '',
      sourceId: query['sourceId'] ?? '',
      chapterIndex: number('chapterIndex'),
      charOffset: number('charOffset'),
      charLength: number('charLength'),
      pageIndex: number('pageIndex'),
      episodeIndex: number('episodeIndex'),
      startMs: number('startMs'),
      endMs: number('endMs'),
      audioFileIndex: number('audioFileIndex'),
      chapterId: query['chapterId'],
      fingerprint: query['fingerprint'],
    );
  }
}

/// Immutable original fields, bound to an unambiguous source marker.
class AnkiSourceNote {
  AnkiSourceNote({
    required this.sourceId,
    required this.noteId,
    required Map<String, String> fields,
  }) : fields = Map<String, String>.unmodifiable(fields);

  final String sourceId;
  final int noteId;
  final Map<String, String> fields;
}
