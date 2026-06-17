import 'dart:convert';
import 'dart:io';

enum WindowsUpdateHandoffStatus {
  installed,
  incomplete,
  launchFailed,
}

class WindowsUpdateHandoffResult {
  const WindowsUpdateHandoffResult({
    required this.status,
    required this.record,
  });

  final WindowsUpdateHandoffStatus status;
  final WindowsUpdateHandoffRecord record;
}

class WindowsUpdateHandoffRecord {
  const WindowsUpdateHandoffRecord({
    required this.targetVersion,
    required this.installerPath,
    required this.innoLogPath,
    required this.startedAt,
    this.installerLaunchSucceeded,
    this.installerLaunchedAt,
    this.installerLaunchFailedAt,
    this.launchError,
    this.lastPromptedAppVersion,
    this.lastPromptedAt,
  });

  factory WindowsUpdateHandoffRecord.fromJson(Map<String, dynamic> json) {
    return WindowsUpdateHandoffRecord(
      targetVersion: json['targetVersion'] as String? ?? '',
      installerPath: json['installerPath'] as String? ?? '',
      innoLogPath: json['innoLogPath'] as String? ?? '',
      startedAt: _dateTime(json['startedAt']) ?? DateTime.now().toUtc(),
      installerLaunchSucceeded: json['installerLaunchSucceeded'] as bool?,
      installerLaunchedAt: _dateTime(json['installerLaunchedAt']),
      installerLaunchFailedAt: _dateTime(json['installerLaunchFailedAt']),
      launchError: json['launchError'] as String?,
      lastPromptedAppVersion: json['lastPromptedAppVersion'] as String?,
      lastPromptedAt: _dateTime(json['lastPromptedAt']),
    );
  }

  final String targetVersion;
  final String installerPath;
  final String innoLogPath;
  final DateTime startedAt;
  final bool? installerLaunchSucceeded;
  final DateTime? installerLaunchedAt;
  final DateTime? installerLaunchFailedAt;
  final String? launchError;
  final String? lastPromptedAppVersion;
  final DateTime? lastPromptedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'targetVersion': targetVersion,
        'installerPath': installerPath,
        'innoLogPath': innoLogPath,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (installerLaunchSucceeded != null)
          'installerLaunchSucceeded': installerLaunchSucceeded,
        if (installerLaunchedAt != null)
          'installerLaunchedAt': installerLaunchedAt!.toUtc().toIso8601String(),
        if (installerLaunchFailedAt != null)
          'installerLaunchFailedAt':
              installerLaunchFailedAt!.toUtc().toIso8601String(),
        if (launchError != null) 'launchError': launchError,
        if (lastPromptedAppVersion != null)
          'lastPromptedAppVersion': lastPromptedAppVersion,
        if (lastPromptedAt != null)
          'lastPromptedAt': lastPromptedAt!.toUtc().toIso8601String(),
      };

  WindowsUpdateHandoffRecord copyWith({
    String? targetVersion,
    String? installerPath,
    String? innoLogPath,
    DateTime? startedAt,
    bool? installerLaunchSucceeded,
    DateTime? installerLaunchedAt,
    DateTime? installerLaunchFailedAt,
    String? launchError,
    String? lastPromptedAppVersion,
    DateTime? lastPromptedAt,
    bool clearLaunchFailure = false,
  }) {
    return WindowsUpdateHandoffRecord(
      targetVersion: targetVersion ?? this.targetVersion,
      installerPath: installerPath ?? this.installerPath,
      innoLogPath: innoLogPath ?? this.innoLogPath,
      startedAt: startedAt ?? this.startedAt,
      installerLaunchSucceeded:
          installerLaunchSucceeded ?? this.installerLaunchSucceeded,
      installerLaunchedAt: installerLaunchedAt ?? this.installerLaunchedAt,
      installerLaunchFailedAt: clearLaunchFailure
          ? null
          : installerLaunchFailedAt ?? this.installerLaunchFailedAt,
      launchError: clearLaunchFailure ? null : launchError ?? this.launchError,
      lastPromptedAppVersion:
          lastPromptedAppVersion ?? this.lastPromptedAppVersion,
      lastPromptedAt: lastPromptedAt ?? this.lastPromptedAt,
    );
  }
}

abstract final class WindowsUpdateHandoff {
  static const String markerFileName = 'update-handoff.json';

  static File markerFile(Directory updatesDir) {
    return File('${updatesDir.path}${Platform.pathSeparator}$markerFileName');
  }

  static Future<void> writePending({
    required File markerFile,
    required String targetVersion,
    required String installerPath,
    required String innoLogPath,
    required DateTime startedAt,
  }) {
    return _write(
      markerFile,
      WindowsUpdateHandoffRecord(
        targetVersion: targetVersion,
        installerPath: installerPath,
        innoLogPath: innoLogPath,
        startedAt: startedAt,
      ),
    );
  }

  static Future<WindowsUpdateHandoffRecord?> read(File markerFile) async {
    if (!await markerFile.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final WindowsUpdateHandoffRecord record =
          WindowsUpdateHandoffRecord.fromJson(decoded);
      if (record.targetVersion.isEmpty ||
          record.installerPath.isEmpty ||
          record.innoLogPath.isEmpty) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  static Future<void> markLaunchSucceeded({
    required File markerFile,
    required DateTime launchedAt,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        installerLaunchSucceeded: true,
        installerLaunchedAt: launchedAt,
        clearLaunchFailure: true,
      ),
    );
  }

  static Future<void> markLaunchFailed({
    required File markerFile,
    required String error,
    required DateTime failedAt,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        installerLaunchSucceeded: false,
        installerLaunchFailedAt: failedAt,
        launchError: error,
      ),
    );
  }

  static Future<WindowsUpdateHandoffResult?> reconcile({
    required File markerFile,
    required String currentVersion,
    DateTime? now,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return null;
    if (_isVersionAtLeast(currentVersion, record.targetVersion)) {
      try {
        if (await markerFile.exists()) await markerFile.delete();
      } catch (_) {
        // Keep going: the user still deserves the success result.
      }
      return WindowsUpdateHandoffResult(
        status: WindowsUpdateHandoffStatus.installed,
        record: record,
      );
    }

    if (record.lastPromptedAppVersion == currentVersion) return null;
    final WindowsUpdateHandoffRecord prompted = record.copyWith(
      lastPromptedAppVersion: currentVersion,
      lastPromptedAt: now ?? DateTime.now(),
    );
    await _write(markerFile, prompted);
    return WindowsUpdateHandoffResult(
      status: record.installerLaunchSucceeded == false
          ? WindowsUpdateHandoffStatus.launchFailed
          : WindowsUpdateHandoffStatus.incomplete,
      record: prompted,
    );
  }

  static Future<void> _write(
    File markerFile,
    WindowsUpdateHandoffRecord record,
  ) async {
    await markerFile.parent.create(recursive: true);
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    await markerFile.writeAsString(
      encoder.convert(record.toJson()),
      flush: true,
    );
  }
}

DateTime? _dateTime(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw);
}

bool _isVersionAtLeast(String current, String target) {
  return _compareVersions(current, target) >= 0;
}

int _compareVersions(String a, String b) {
  final String left = _stripBuildMetadata(_stripLeadingV(a.trim()));
  final String right = _stripBuildMetadata(_stripLeadingV(b.trim()));
  final int base = _compareBase(_basePart(left), _basePart(right));
  if (base != 0) return base;

  final String? leftPre = _prereleasePart(left);
  final String? rightPre = _prereleasePart(right);
  if (leftPre == null && rightPre == null) return 0;
  if (leftPre == null) return 1;
  if (rightPre == null) return -1;
  return _comparePrerelease(leftPre, rightPre);
}

String _stripLeadingV(String value) => value.replaceFirst(RegExp(r'^[vV]'), '');

String _stripBuildMetadata(String value) => value.split('+').first;

String _basePart(String value) => value.split('-').first;

String? _prereleasePart(String value) {
  final int hyphen = value.indexOf('-');
  if (hyphen < 0 || hyphen == value.length - 1) return null;
  return value.substring(hyphen + 1);
}

int _compareBase(String a, String b) {
  final List<int> left = _segments(a);
  final List<int> right = _segments(b);
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i++) {
    final int lv = i < left.length ? left[i] : 0;
    final int rv = i < right.length ? right[i] : 0;
    if (lv != rv) return lv.compareTo(rv);
  }
  return 0;
}

List<int> _segments(String value) {
  return value
      .split('.')
      .map((String part) => int.tryParse(part) ?? 0)
      .toList(growable: false);
}

int _comparePrerelease(String a, String b) {
  final List<String> left = a.split('.');
  final List<String> right = b.split('.');
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i++) {
    if (i >= left.length) return -1;
    if (i >= right.length) return 1;
    final int part = _comparePrereleasePart(left[i], right[i]);
    if (part != 0) return part;
  }
  return 0;
}

int _comparePrereleasePart(String a, String b) {
  final int? ai = int.tryParse(a);
  final int? bi = int.tryParse(b);
  if (ai != null && bi != null) return ai.compareTo(bi);
  if (ai != null) return -1;
  if (bi != null) return 1;
  return a.compareTo(b);
}
