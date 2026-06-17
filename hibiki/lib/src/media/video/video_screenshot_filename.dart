import 'package:path/path.dart' as p;

const int _maxScreenshotSourceRunes = 80;

/// Builds the default JPEG basename for a video screenshot.
///
/// The source segment keeps Unicode titles readable while replacing characters
/// that are invalid in common desktop file systems.
String videoScreenshotBaseName({
  required String? sourcePathOrTitle,
  required int positionMs,
  required DateTime capturedAt,
}) {
  final String source = _safeScreenshotSourceStem(sourcePathOrTitle);
  return 'hibiki_${source}_at_${_playbackTimeToken(positionMs)}_'
      '${_captureTimeToken(capturedAt)}.jpg';
}

/// Returns [desiredName] or appends ` (n)` before the extension until it is new.
String uniqueVideoScreenshotBaseName(
  String desiredName, {
  required bool Function(String name) exists,
}) {
  if (!exists(desiredName)) return desiredName;
  final String stem = p.basenameWithoutExtension(desiredName);
  final String ext = p.extension(desiredName);
  for (int counter = 2; counter < 10000; counter++) {
    final String candidate = '$stem ($counter)$ext';
    if (!exists(candidate)) return candidate;
  }
  final int fallback = DateTime.now().millisecondsSinceEpoch;
  return '${stem}_$fallback$ext';
}

/// Returns [desiredPath] or a sibling path with a count suffix when occupied.
String uniqueVideoScreenshotPath(
  String desiredPath, {
  required bool Function(String path) exists,
}) {
  final String dir = p.dirname(desiredPath);
  final String desiredName = p.basename(desiredPath);
  final String uniqueName = uniqueVideoScreenshotBaseName(
    desiredName,
    exists: (String name) => exists(p.join(dir, name)),
  );
  return p.join(dir, uniqueName);
}

String _safeScreenshotSourceStem(String? sourcePathOrTitle) {
  final String raw = (sourcePathOrTitle ?? '').trim();
  final String leaf =
      raw.isEmpty ? '' : p.posix.basename(raw.replaceAll(r'\', '/'));
  final String stem = p.posix.basenameWithoutExtension(leaf);
  final String cleaned = stem
      .replaceAll(RegExp(r'[\x00-\x1F<>:"/\\|?*]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[_. ]+|[_. ]+$'), '');
  final String safe = _avoidReservedWindowsName(cleaned);
  final String fallback = safe.isEmpty ? 'video' : safe;
  return _takeRunes(fallback, _maxScreenshotSourceRunes);
}

String _avoidReservedWindowsName(String value) {
  const Set<String> reserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  return reserved.contains(value.toUpperCase()) ? '_$value' : value;
}

String _takeRunes(String value, int maxRunes) {
  final Runes runes = value.runes;
  if (runes.length <= maxRunes) return value;
  return String.fromCharCodes(runes.take(maxRunes));
}

String _playbackTimeToken(int positionMs) {
  final int safeMs = positionMs < 0 ? 0 : positionMs;
  final int hours = safeMs ~/ Duration.millisecondsPerHour;
  final int minutes =
      (safeMs % Duration.millisecondsPerHour) ~/ Duration.millisecondsPerMinute;
  final int seconds = (safeMs % Duration.millisecondsPerMinute) ~/
      Duration.millisecondsPerSecond;
  final int millis = safeMs % Duration.millisecondsPerSecond;
  return '${_two(hours)}h${_two(minutes)}m${_two(seconds)}s${_three(millis)}';
}

String _captureTimeToken(DateTime capturedAt) {
  final DateTime local = capturedAt.toLocal();
  return '${_four(local.year)}${_two(local.month)}${_two(local.day)}_'
      '${_two(local.hour)}${_two(local.minute)}${_two(local.second)}_'
      '${_three(local.millisecond)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
String _three(int value) => value.toString().padLeft(3, '0');
String _four(int value) => value.toString().padLeft(4, '0');
