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

class WindowsDetectedInstallLocation {
  const WindowsDetectedInstallLocation({
    required this.source,
    required this.path,
  });

  factory WindowsDetectedInstallLocation.fromJson(Map<String, dynamic> json) {
    return WindowsDetectedInstallLocation(
      source: json['source'] as String? ?? '',
      path: json['path'] as String? ?? '',
    );
  }

  final String source;
  final String path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source,
        'path': path,
      };
}

class WindowsProcessInfo {
  const WindowsProcessInfo({
    required this.pid,
    this.name,
    this.path,
  });

  factory WindowsProcessInfo.fromJson(Map<String, dynamic> json) {
    return WindowsProcessInfo(
      pid: _int(json['pid']) ?? 0,
      name: json['name'] as String?,
      path: json['path'] as String?,
    );
  }

  final int pid;
  final String? name;
  final String? path;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pid': pid,
        if (name != null && name!.isNotEmpty) 'name': name,
        if (path != null && path!.isNotEmpty) 'path': path,
      };

  WindowsProcessInfo copyWith({
    int? pid,
    String? name,
    String? path,
  }) {
    return WindowsProcessInfo(
      pid: pid ?? this.pid,
      name: name ?? this.name,
      path: path ?? this.path,
    );
  }
}

class WindowsInnoDeleteFileFailure {
  const WindowsInnoDeleteFileFailure({
    required this.path,
    required this.code,
    this.message,
  });

  factory WindowsInnoDeleteFileFailure.fromJson(Map<String, dynamic> json) {
    return WindowsInnoDeleteFileFailure(
      path: json['path'] as String? ?? '',
      code: _int(json['code']) ?? 0,
      message: json['message'] as String?,
    );
  }

  final String path;
  final int code;
  final String? message;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'code': code,
        if (message != null && message!.isNotEmpty) 'message': message,
      };
}

class WindowsInstallerDiagnostics {
  const WindowsInstallerDiagnostics({
    this.currentExecutablePath,
    this.currentInstallDir,
    this.targetInstallDir,
    this.detectedInstallLocations = const <WindowsDetectedInstallLocation>[],
    this.runningHibikiProcesses = const <WindowsProcessInfo>[],
    this.libmpvModuleHolders = const <WindowsProcessInfo>[],
    this.innoLogDeleteFileFailures = const <WindowsInnoDeleteFileFailure>[],
    this.pathMismatchWarning,
  });

  final String? currentExecutablePath;
  final String? currentInstallDir;
  final String? targetInstallDir;
  final List<WindowsDetectedInstallLocation> detectedInstallLocations;
  final List<WindowsProcessInfo> runningHibikiProcesses;
  final List<WindowsProcessInfo> libmpvModuleHolders;
  final List<WindowsInnoDeleteFileFailure> innoLogDeleteFileFailures;
  final String? pathMismatchWarning;

  bool get hasLockEvidence {
    if (libmpvModuleHolders.isNotEmpty) return true;
    return innoLogDeleteFileFailures.any(
      (WindowsInnoDeleteFileFailure failure) =>
          failure.code == 5 &&
          failure.path.toLowerCase().contains('libmpv-2.dll'),
    );
  }

  WindowsInstallerDiagnostics copyWith({
    String? currentExecutablePath,
    String? currentInstallDir,
    String? targetInstallDir,
    List<WindowsDetectedInstallLocation>? detectedInstallLocations,
    List<WindowsProcessInfo>? runningHibikiProcesses,
    List<WindowsProcessInfo>? libmpvModuleHolders,
    List<WindowsInnoDeleteFileFailure>? innoLogDeleteFileFailures,
    String? pathMismatchWarning,
  }) {
    return WindowsInstallerDiagnostics(
      currentExecutablePath:
          currentExecutablePath ?? this.currentExecutablePath,
      currentInstallDir: currentInstallDir ?? this.currentInstallDir,
      targetInstallDir: targetInstallDir ?? this.targetInstallDir,
      detectedInstallLocations:
          detectedInstallLocations ?? this.detectedInstallLocations,
      runningHibikiProcesses:
          runningHibikiProcesses ?? this.runningHibikiProcesses,
      libmpvModuleHolders: libmpvModuleHolders ?? this.libmpvModuleHolders,
      innoLogDeleteFileFailures:
          innoLogDeleteFileFailures ?? this.innoLogDeleteFileFailures,
      pathMismatchWarning: pathMismatchWarning ?? this.pathMismatchWarning,
    );
  }
}

class WindowsUpdateHandoffRecord {
  const WindowsUpdateHandoffRecord({
    required this.targetVersion,
    required this.installerPath,
    required this.innoLogPath,
    required this.startedAt,
    this.currentExecutablePath,
    this.currentInstallDir,
    this.targetInstallDir,
    this.detectedInstallLocations = const <WindowsDetectedInstallLocation>[],
    this.runningHibikiProcesses = const <WindowsProcessInfo>[],
    this.libmpvModuleHolders = const <WindowsProcessInfo>[],
    this.innoLogDeleteFileFailures = const <WindowsInnoDeleteFileFailure>[],
    this.pathMismatchWarning,
    this.installerLaunchSucceeded,
    this.installerLaunchedAt,
    this.installerPid,
    this.postLaunchObservedAt,
    this.installerProcessRunning,
    this.innoLogExists,
    this.innoLogSizeBytes,
    this.postLaunchObservationError,
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
      currentExecutablePath: json['currentExecutablePath'] as String?,
      currentInstallDir: json['currentInstallDir'] as String?,
      targetInstallDir: json['targetInstallDir'] as String?,
      detectedInstallLocations: _listOfMaps(json['detectedInstallLocations'])
          .map(WindowsDetectedInstallLocation.fromJson)
          .toList(growable: false),
      runningHibikiProcesses: _listOfMaps(json['runningHibikiProcesses'])
          .map(WindowsProcessInfo.fromJson)
          .where((WindowsProcessInfo process) => process.pid > 0)
          .toList(growable: false),
      libmpvModuleHolders: _listOfMaps(json['libmpvModuleHolders'])
          .map(WindowsProcessInfo.fromJson)
          .where((WindowsProcessInfo process) => process.pid > 0)
          .toList(growable: false),
      innoLogDeleteFileFailures: _listOfMaps(json['innoLogDeleteFileFailures'])
          .map(WindowsInnoDeleteFileFailure.fromJson)
          .where(
            (WindowsInnoDeleteFileFailure failure) =>
                failure.path.isNotEmpty && failure.code > 0,
          )
          .toList(growable: false),
      pathMismatchWarning: json['pathMismatchWarning'] as String?,
      installerLaunchSucceeded: json['installerLaunchSucceeded'] as bool?,
      installerLaunchedAt: _dateTime(json['installerLaunchedAt']),
      installerPid: _int(json['installerPid']),
      postLaunchObservedAt: _dateTime(json['postLaunchObservedAt']),
      installerProcessRunning: json['installerProcessRunning'] as bool?,
      innoLogExists: json['innoLogExists'] as bool?,
      innoLogSizeBytes: _int(json['innoLogSizeBytes']),
      postLaunchObservationError: json['postLaunchObservationError'] as String?,
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
  final String? currentExecutablePath;
  final String? currentInstallDir;
  final String? targetInstallDir;
  final List<WindowsDetectedInstallLocation> detectedInstallLocations;
  final List<WindowsProcessInfo> runningHibikiProcesses;
  final List<WindowsProcessInfo> libmpvModuleHolders;
  final List<WindowsInnoDeleteFileFailure> innoLogDeleteFileFailures;
  final String? pathMismatchWarning;
  final bool? installerLaunchSucceeded;
  final DateTime? installerLaunchedAt;
  final int? installerPid;
  final DateTime? postLaunchObservedAt;
  final bool? installerProcessRunning;
  final bool? innoLogExists;
  final int? innoLogSizeBytes;
  final String? postLaunchObservationError;
  final DateTime? installerLaunchFailedAt;
  final String? launchError;
  final String? lastPromptedAppVersion;
  final DateTime? lastPromptedAt;

  WindowsInstallerDiagnostics get diagnostics => WindowsInstallerDiagnostics(
        currentExecutablePath: currentExecutablePath,
        currentInstallDir: currentInstallDir,
        targetInstallDir: targetInstallDir,
        detectedInstallLocations: detectedInstallLocations,
        runningHibikiProcesses: runningHibikiProcesses,
        libmpvModuleHolders: libmpvModuleHolders,
        innoLogDeleteFileFailures: innoLogDeleteFileFailures,
        pathMismatchWarning: pathMismatchWarning,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'targetVersion': targetVersion,
        'installerPath': installerPath,
        'innoLogPath': innoLogPath,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (currentExecutablePath != null)
          'currentExecutablePath': currentExecutablePath,
        if (currentInstallDir != null) 'currentInstallDir': currentInstallDir,
        if (targetInstallDir != null) 'targetInstallDir': targetInstallDir,
        if (detectedInstallLocations.isNotEmpty)
          'detectedInstallLocations': detectedInstallLocations
              .map((WindowsDetectedInstallLocation location) =>
                  location.toJson())
              .toList(growable: false),
        if (runningHibikiProcesses.isNotEmpty)
          'runningHibikiProcesses': runningHibikiProcesses
              .map((WindowsProcessInfo process) => process.toJson())
              .toList(growable: false),
        if (libmpvModuleHolders.isNotEmpty)
          'libmpvModuleHolders': libmpvModuleHolders
              .map((WindowsProcessInfo process) => process.toJson())
              .toList(growable: false),
        if (innoLogDeleteFileFailures.isNotEmpty)
          'innoLogDeleteFileFailures': innoLogDeleteFileFailures
              .map((WindowsInnoDeleteFileFailure failure) => failure.toJson())
              .toList(growable: false),
        if (pathMismatchWarning != null)
          'pathMismatchWarning': pathMismatchWarning,
        if (installerLaunchSucceeded != null)
          'installerLaunchSucceeded': installerLaunchSucceeded,
        if (installerLaunchedAt != null)
          'installerLaunchedAt': installerLaunchedAt!.toUtc().toIso8601String(),
        if (installerPid != null) 'installerPid': installerPid,
        if (postLaunchObservedAt != null)
          'postLaunchObservedAt':
              postLaunchObservedAt!.toUtc().toIso8601String(),
        if (installerProcessRunning != null)
          'installerProcessRunning': installerProcessRunning,
        if (innoLogExists != null) 'innoLogExists': innoLogExists,
        if (innoLogSizeBytes != null) 'innoLogSizeBytes': innoLogSizeBytes,
        if (postLaunchObservationError != null)
          'postLaunchObservationError': postLaunchObservationError,
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
    String? currentExecutablePath,
    String? currentInstallDir,
    String? targetInstallDir,
    List<WindowsDetectedInstallLocation>? detectedInstallLocations,
    List<WindowsProcessInfo>? runningHibikiProcesses,
    List<WindowsProcessInfo>? libmpvModuleHolders,
    List<WindowsInnoDeleteFileFailure>? innoLogDeleteFileFailures,
    String? pathMismatchWarning,
    bool? installerLaunchSucceeded,
    DateTime? installerLaunchedAt,
    int? installerPid,
    DateTime? postLaunchObservedAt,
    bool? installerProcessRunning,
    bool? innoLogExists,
    int? innoLogSizeBytes,
    String? postLaunchObservationError,
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
      currentExecutablePath:
          currentExecutablePath ?? this.currentExecutablePath,
      currentInstallDir: currentInstallDir ?? this.currentInstallDir,
      targetInstallDir: targetInstallDir ?? this.targetInstallDir,
      detectedInstallLocations:
          detectedInstallLocations ?? this.detectedInstallLocations,
      runningHibikiProcesses:
          runningHibikiProcesses ?? this.runningHibikiProcesses,
      libmpvModuleHolders: libmpvModuleHolders ?? this.libmpvModuleHolders,
      innoLogDeleteFileFailures:
          innoLogDeleteFileFailures ?? this.innoLogDeleteFileFailures,
      pathMismatchWarning: pathMismatchWarning ?? this.pathMismatchWarning,
      installerLaunchSucceeded:
          installerLaunchSucceeded ?? this.installerLaunchSucceeded,
      installerLaunchedAt: installerLaunchedAt ?? this.installerLaunchedAt,
      installerPid: installerPid ?? this.installerPid,
      postLaunchObservedAt: postLaunchObservedAt ?? this.postLaunchObservedAt,
      installerProcessRunning:
          installerProcessRunning ?? this.installerProcessRunning,
      innoLogExists: innoLogExists ?? this.innoLogExists,
      innoLogSizeBytes: innoLogSizeBytes ?? this.innoLogSizeBytes,
      postLaunchObservationError:
          postLaunchObservationError ?? this.postLaunchObservationError,
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
    WindowsInstallerDiagnostics diagnostics =
        const WindowsInstallerDiagnostics(),
  }) {
    return _write(
      markerFile,
      WindowsUpdateHandoffRecord(
        targetVersion: targetVersion,
        installerPath: installerPath,
        innoLogPath: innoLogPath,
        startedAt: startedAt,
        currentExecutablePath: diagnostics.currentExecutablePath,
        currentInstallDir: diagnostics.currentInstallDir,
        targetInstallDir: diagnostics.targetInstallDir,
        detectedInstallLocations: diagnostics.detectedInstallLocations,
        runningHibikiProcesses: diagnostics.runningHibikiProcesses,
        libmpvModuleHolders: diagnostics.libmpvModuleHolders,
        innoLogDeleteFileFailures: diagnostics.innoLogDeleteFileFailures,
        pathMismatchWarning: diagnostics.pathMismatchWarning,
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
    int? installerPid,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        installerLaunchSucceeded: true,
        installerLaunchedAt: launchedAt,
        installerPid: installerPid,
        clearLaunchFailure: true,
      ),
    );
  }

  static Future<void> markPostLaunchObserved({
    required File markerFile,
    required DateTime observedAt,
    bool? installerProcessRunning,
    required bool innoLogExists,
    int? innoLogSizeBytes,
    String? observationError,
    List<WindowsInnoDeleteFileFailure> innoLogDeleteFileFailures =
        const <WindowsInnoDeleteFileFailure>[],
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        postLaunchObservedAt: observedAt,
        installerProcessRunning: installerProcessRunning,
        innoLogExists: innoLogExists,
        innoLogSizeBytes: innoLogSizeBytes,
        postLaunchObservationError: observationError,
        innoLogDeleteFileFailures: innoLogDeleteFileFailures.isEmpty
            ? null
            : innoLogDeleteFileFailures,
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

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

List<Map<String, dynamic>> _listOfMaps(Object? raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map(
        (Map value) => value.map(
          (Object? key, Object? value) => MapEntry<String, dynamic>(
            key.toString(),
            value,
          ),
        ),
      )
      .toList(growable: false);
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
