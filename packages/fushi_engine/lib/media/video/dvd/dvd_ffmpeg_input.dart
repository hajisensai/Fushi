import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdDiscRootForTitlePath, dvdTitleNumberForPath, isDvdTitlePath;
import 'package:path/path.dart' as p;

/// A DVD-Video title as one FFmpeg input (docs/specs/2026-10-24-dvd-original-menu.md).
///
/// Clip export, screenshots and subtitle extraction read DVD titles through the
/// unified FFmpeg's `dvdvideo` demuxer (libdvdnav + libdvdread, the same copies
/// libmpv's `dvd://` links), never by opening `.VOB` files: an encrypted disc's
/// VOBs are ciphertext on disk, and a title can span several VOBs and jump
/// between cells. Callers name the title with [encodeDvdTitleInput]; the DVD
/// FFmpeg backend rewrites it into `-f dvdvideo -title N ... -i <disc>`.
class DvdTitleInput {
  DvdTitleInput({
    required this.disc,
    required this.title,
    this.chapterStart,
    this.chapterEnd,
    this.angle,
  }) {
    if (disc.isEmpty) {
      throw ArgumentError.value(disc, 'disc', 'Empty disc path');
    }
    _checkRange('title', title, 1, 99);
    if (chapterStart != null) _checkRange('chapterStart', chapterStart!, 1, 99);
    if (chapterEnd != null) _checkRange('chapterEnd', chapterEnd!, 1, 99);
    if (chapterStart != null &&
        chapterEnd != null &&
        chapterEnd! < chapterStart!) {
      throw ArgumentError(
        'chapterEnd $chapterEnd precedes chapterStart $chapterStart',
      );
    }
    if (angle != null) _checkRange('angle', angle!, 1, 9);
  }

  /// The disc: a folder containing `VIDEO_TS`, the `VIDEO_TS` folder itself,
  /// or an `.iso` image (libdvdread opens all three).
  final String disc;

  /// Global title number, 1-99 (libdvdnav / the DVD title table).
  final int title;

  /// First chapter (PTT) to read, 1-based; null = from the title start.
  final int? chapterStart;

  /// Last chapter (PTT) to read, inclusive; null = to the title end.
  final int? chapterEnd;

  /// Camera angle 1-9; null = the disc default (1).
  final int? angle;

  static void _checkRange(String name, int value, int min, int max) {
    if (value < min || value > max) {
      throw RangeError.range(value, min, max, name);
    }
  }

  /// The `dvdvideo` demuxer options that select this title, placed before the
  /// `-i` they belong to.
  List<String> get demuxerOptions => <String>[
    '-f',
    'dvdvideo',
    '-title',
    '$title',
    if (chapterStart != null) ...<String>['-chapter_start', '$chapterStart'],
    if (chapterEnd != null) ...<String>['-chapter_end', '$chapterEnd'],
    if (angle != null) ...<String>['-angle', '$angle'],
  ];

  /// libdvdread opens the folder that contains `VIDEO_TS` (or an image).
  /// Separators are kept as the caller wrote them.
  String get demuxerPath {
    final String trimmed = disc.replaceFirst(RegExp(r'[\\/]+$'), '');
    final int cut = trimmed.lastIndexOf(RegExp(r'[\\/]'));
    final String name = cut < 0 ? trimmed : trimmed.substring(cut + 1);
    return name.toUpperCase() == 'VIDEO_TS' && cut > 0
        ? trimmed.substring(0, cut)
        : disc;
  }

  @override
  bool operator ==(Object other) =>
      other is DvdTitleInput &&
      other.disc == disc &&
      other.title == title &&
      other.chapterStart == chapterStart &&
      other.chapterEnd == chapterEnd &&
      other.angle == angle;

  @override
  int get hashCode => Object.hash(disc, title, chapterStart, chapterEnd, angle);
}

/// URI scheme of an encoded [DvdTitleInput]. Not a real FFmpeg protocol: an
/// input that reaches FFmpeg unrewritten fails to open instead of silently
/// reading the wrong file.
const String dvdTitleInputScheme = 'fushi-dvd-title';

/// `fushi-dvd-title:?disc=<path>&title=N[&chapter_start=a][&chapter_end=b][&angle=k]`.
String encodeDvdTitleInput(DvdTitleInput input) => Uri(
  scheme: dvdTitleInputScheme,
  queryParameters: <String, String>{
    'disc': input.disc,
    'title': '${input.title}',
    if (input.chapterStart != null) 'chapter_start': '${input.chapterStart}',
    if (input.chapterEnd != null) 'chapter_end': '${input.chapterEnd}',
    if (input.angle != null) 'angle': '${input.angle}',
  },
).toString();

/// Parses [encodeDvdTitleInput]; null for anything else (ordinary paths and
/// URLs pass through the backend untouched). A `fushi-dvd-title:` value that
/// is malformed throws, so a broken caller is loud rather than reading
/// nothing.
DvdTitleInput? parseDvdTitleInput(String value) {
  // A library DVD title (`<disc>/VIDEO_TS/TITLE_nn.dvdtitle`, the
  // `VideoBooks.videoPath` of a DVD member) names the whole title.
  if (isDvdTitlePath(value)) {
    final String? disc = dvdDiscRootForTitlePath(value);
    final int? title = dvdTitleNumberForPath(value);
    if (disc == null || title == null) {
      throw FormatException('Malformed DVD title path: $value');
    }
    return DvdTitleInput(disc: disc, title: title);
  }
  if (!value.startsWith('$dvdTitleInputScheme:')) return null;
  final Uri uri = Uri.parse(value);
  final Map<String, String> query = uri.queryParameters;
  int? number(String key) {
    final String? raw = query[key];
    if (raw == null) return null;
    final int? parsed = int.tryParse(raw);
    if (parsed == null) {
      throw FormatException('DVD title input $key is not a number: $raw');
    }
    return parsed;
  }

  final String? disc = query['disc'];
  final int? title = number('title');
  if (disc == null || title == null) {
    throw FormatException('DVD title input needs disc and title: $value');
  }
  return DvdTitleInput(
    disc: disc,
    title: title,
    chapterStart: number('chapter_start'),
    chapterEnd: number('chapter_end'),
    angle: number('angle'),
  );
}

/// A `.VOB` inside a `VIDEO_TS` folder: part of a DVD title set, which may be
/// encrypted and is only meaningful through the DVD VM / title table.
/// `.vob` files elsewhere are ordinary MPEG-PS videos.
bool isDvdVideoTsVobPath(String path) {
  if (path.contains('://')) return false;
  final List<String> parts = path
      .split(RegExp(r'[\\/]+'))
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.length >= 2 &&
      p.extension(parts.last).toLowerCase() == '.vob' &&
      parts[parts.length - 2].toUpperCase() == 'VIDEO_TS';
}

/// Raised when a command would read a DVD title set `.VOB` directly.
class DvdFfmpegInputException implements Exception {
  const DvdFfmpegInputException(this.path);
  final String path;

  @override
  String toString() =>
      'DvdFfmpegInputException: $path is a DVD title set VOB; read it as a '
      'DVD title (encodeDvdTitleInput) through the dvdvideo demuxer';
}

/// Rewrites every DVD title input of an ffmpeg / ffprobe argument list.
///
/// `-i fushi-dvd-title:?...` becomes `<dvdvideo options> -i <disc>`, keeping
/// the caller's own input options (`-ss`, `-t`, ...) in front of it: they
/// apply to the title timeline the demuxer presents. For ffprobe ([probe])
/// the input may also be the bare last argument. Commands without DVD inputs
/// are returned unchanged; a direct `VIDEO_TS/*.VOB` input throws
/// [DvdFfmpegInputException].
List<String> prepareDvdFfmpegArgs(List<String> args, {bool probe = false}) {
  final List<String> result = <String>[];
  bool changed = false;
  for (int i = 0; i < args.length; i++) {
    final bool explicit = args[i] == '-i' && i + 1 < args.length;
    final bool bare =
        probe && i == args.length - 1 && (i == 0 || args[i - 1] != '-i');
    if (!explicit && !bare) {
      result.add(args[i]);
      continue;
    }
    final String value = explicit ? args[i + 1] : args[i];
    if (isDvdVideoTsVobPath(value)) throw DvdFfmpegInputException(value);
    final DvdTitleInput? input = parseDvdTitleInput(value);
    if (input == null) {
      result.add(args[i]);
      if (explicit) {
        result.add(args[i + 1]);
        i++;
      }
      continue;
    }
    changed = true;
    result
      ..addAll(input.demuxerOptions)
      ..addAll(<String>['-i', input.demuxerPath]);
    if (explicit) i++;
  }
  return changed ? result : args;
}
