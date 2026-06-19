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

class WindowsInstallerFailureSummary {
  const WindowsInstallerFailureSummary({
    required this.type,
    required this.message,
  });

  final String type;
  final String message;
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
    this.launcherStartedAt,
    this.launcherPid,
    this.parentProcessId,
    this.parentExitObserved,
    this.parentExitObservedAt,
    this.installerLaunchSucceeded,
    this.installerLaunchedAt,
    this.installerPid,
    this.innoLogExists,
    this.innoLogSizeBytes,
    this.innoLogModifiedAt,
    this.installerFailureType,
    this.installerFailureSummary,
    this.installerLaunchFailedAt,
    this.launchError,
    this.failureFingerprint,
    this.lastPromptedAppVersion,
    this.lastPromptedFailureFingerprint,
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
      launcherStartedAt: _dateTime(json['launcherStartedAt']),
      launcherPid: _int(json['launcherPid']),
      parentProcessId: _int(json['parentProcessId']),
      parentExitObserved: json['parentExitObserved'] as bool?,
      parentExitObservedAt: _dateTime(json['parentExitObservedAt']),
      installerLaunchSucceeded: json['installerLaunchSucceeded'] as bool?,
      installerLaunchedAt: _dateTime(json['installerLaunchedAt']),
      installerPid: _int(json['installerPid']),
      innoLogExists: json['innoLogExists'] as bool?,
      innoLogSizeBytes: _int(json['innoLogSizeBytes']),
      innoLogModifiedAt: _dateTime(json['innoLogModifiedAt']),
      installerFailureType: json['installerFailureType'] as String?,
      installerFailureSummary: json['installerFailureSummary'] as String?,
      installerLaunchFailedAt: _dateTime(json['installerLaunchFailedAt']),
      launchError: json['launchError'] as String?,
      failureFingerprint: json['failureFingerprint'] as String?,
      lastPromptedAppVersion: json['lastPromptedAppVersion'] as String?,
      lastPromptedFailureFingerprint:
          json['lastPromptedFailureFingerprint'] as String?,
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
  final DateTime? launcherStartedAt;
  final int? launcherPid;
  final int? parentProcessId;
  final bool? parentExitObserved;
  final DateTime? parentExitObservedAt;
  final bool? installerLaunchSucceeded;
  final DateTime? installerLaunchedAt;
  final int? installerPid;
  final bool? innoLogExists;
  final int? innoLogSizeBytes;
  final DateTime? innoLogModifiedAt;
  final String? installerFailureType;
  final String? installerFailureSummary;
  final DateTime? installerLaunchFailedAt;
  final String? launchError;
  final String? failureFingerprint;
  final String? lastPromptedAppVersion;
  final String? lastPromptedFailureFingerprint;
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
        if (launcherStartedAt != null)
          'launcherStartedAt': launcherStartedAt!.toUtc().toIso8601String(),
        if (launcherPid != null) 'launcherPid': launcherPid,
        if (parentProcessId != null) 'parentProcessId': parentProcessId,
        if (parentExitObserved != null)
          'parentExitObserved': parentExitObserved,
        if (parentExitObservedAt != null)
          'parentExitObservedAt':
              parentExitObservedAt!.toUtc().toIso8601String(),
        if (installerLaunchSucceeded != null)
          'installerLaunchSucceeded': installerLaunchSucceeded,
        if (installerLaunchedAt != null)
          'installerLaunchedAt': installerLaunchedAt!.toUtc().toIso8601String(),
        if (installerPid != null) 'installerPid': installerPid,
        if (innoLogExists != null) 'innoLogExists': innoLogExists,
        if (innoLogSizeBytes != null) 'innoLogSizeBytes': innoLogSizeBytes,
        if (innoLogModifiedAt != null)
          'innoLogModifiedAt': innoLogModifiedAt!.toUtc().toIso8601String(),
        if (installerFailureType != null)
          'installerFailureType': installerFailureType,
        if (installerFailureSummary != null)
          'installerFailureSummary': installerFailureSummary,
        if (installerLaunchFailedAt != null)
          'installerLaunchFailedAt':
              installerLaunchFailedAt!.toUtc().toIso8601String(),
        if (launchError != null) 'launchError': launchError,
        if (failureFingerprint != null)
          'failureFingerprint': failureFingerprint,
        if (lastPromptedAppVersion != null)
          'lastPromptedAppVersion': lastPromptedAppVersion,
        if (lastPromptedFailureFingerprint != null)
          'lastPromptedFailureFingerprint': lastPromptedFailureFingerprint,
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
    DateTime? launcherStartedAt,
    int? launcherPid,
    int? parentProcessId,
    bool? parentExitObserved,
    DateTime? parentExitObservedAt,
    bool? installerLaunchSucceeded,
    DateTime? installerLaunchedAt,
    int? installerPid,
    bool? innoLogExists,
    int? innoLogSizeBytes,
    DateTime? innoLogModifiedAt,
    String? installerFailureType,
    String? installerFailureSummary,
    DateTime? installerLaunchFailedAt,
    String? launchError,
    String? failureFingerprint,
    String? lastPromptedAppVersion,
    String? lastPromptedFailureFingerprint,
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
      launcherStartedAt: launcherStartedAt ?? this.launcherStartedAt,
      launcherPid: launcherPid ?? this.launcherPid,
      parentProcessId: parentProcessId ?? this.parentProcessId,
      parentExitObserved: parentExitObserved ?? this.parentExitObserved,
      parentExitObservedAt: parentExitObservedAt ?? this.parentExitObservedAt,
      installerLaunchSucceeded:
          installerLaunchSucceeded ?? this.installerLaunchSucceeded,
      installerLaunchedAt: installerLaunchedAt ?? this.installerLaunchedAt,
      installerPid: installerPid ?? this.installerPid,
      innoLogExists: innoLogExists ?? this.innoLogExists,
      innoLogSizeBytes: innoLogSizeBytes ?? this.innoLogSizeBytes,
      innoLogModifiedAt: innoLogModifiedAt ?? this.innoLogModifiedAt,
      installerFailureType: installerFailureType ?? this.installerFailureType,
      installerFailureSummary:
          installerFailureSummary ?? this.installerFailureSummary,
      installerLaunchFailedAt: clearLaunchFailure
          ? null
          : installerLaunchFailedAt ?? this.installerLaunchFailedAt,
      launchError: clearLaunchFailure ? null : launchError ?? this.launchError,
      failureFingerprint: failureFingerprint ?? this.failureFingerprint,
      lastPromptedAppVersion:
          lastPromptedAppVersion ?? this.lastPromptedAppVersion,
      lastPromptedFailureFingerprint:
          lastPromptedFailureFingerprint ?? this.lastPromptedFailureFingerprint,
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

  static Future<void> markLauncherStarted({
    required File markerFile,
    required DateTime startedAt,
    required int parentProcessId,
    int? launcherPid,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        launcherStartedAt: startedAt,
        launcherPid: launcherPid,
        parentProcessId: parentProcessId,
      ),
    );
  }

  static Future<void> markParentExitObserved({
    required File markerFile,
    required DateTime observedAt,
    required bool observed,
  }) async {
    final WindowsUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return;
    await _write(
      markerFile,
      record.copyWith(
        parentExitObserved: observed,
        parentExitObservedAt: observedAt,
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

    final WindowsUpdateHandoffRecord enriched =
        await _enrichFailureDiagnostics(record);
    if (enriched.lastPromptedAppVersion == currentVersion &&
        enriched.lastPromptedFailureFingerprint ==
            enriched.failureFingerprint) {
      return null;
    }
    final WindowsUpdateHandoffRecord prompted = enriched.copyWith(
      lastPromptedAppVersion: currentVersion,
      lastPromptedFailureFingerprint: enriched.failureFingerprint,
      lastPromptedAt: now ?? DateTime.now(),
    );
    await _write(markerFile, prompted);
    return WindowsUpdateHandoffResult(
      status: prompted.installerLaunchSucceeded == false
          ? WindowsUpdateHandoffStatus.launchFailed
          : WindowsUpdateHandoffStatus.incomplete,
      record: prompted,
    );
  }

  static Future<WindowsUpdateHandoffRecord> _enrichFailureDiagnostics(
    WindowsUpdateHandoffRecord record,
  ) async {
    final _WindowsInnoLogSnapshot log = await _readInnoLog(record.innoLogPath);
    final List<WindowsInnoDeleteFileFailure> deleteFailures =
        log.contents == null
            ? record.innoLogDeleteFileFailures
            : parseWindowsInnoDeleteFileFailures(log.contents!);
    final WindowsInstallerFailureSummary summary =
        summarizeWindowsInstallerFailure(
      record: record.copyWith(
        innoLogDeleteFileFailures: deleteFailures,
        innoLogExists: log.exists,
        innoLogSizeBytes: log.sizeBytes,
        innoLogModifiedAt: log.modifiedAt,
      ),
      innoLogContents: log.contents,
    );
    final String fingerprint = windowsInstallerFailureFingerprint(
      record: record.copyWith(
        innoLogDeleteFileFailures: deleteFailures,
        innoLogExists: log.exists,
        innoLogSizeBytes: log.sizeBytes,
        innoLogModifiedAt: log.modifiedAt,
        installerFailureType: summary.type,
        installerFailureSummary: summary.message,
      ),
    );
    return record.copyWith(
      innoLogDeleteFileFailures: deleteFailures,
      innoLogExists: log.exists,
      innoLogSizeBytes: log.sizeBytes,
      innoLogModifiedAt: log.modifiedAt,
      installerFailureType: summary.type,
      installerFailureSummary: summary.message,
      failureFingerprint: fingerprint,
    );
  }

  static Future<_WindowsInnoLogSnapshot> _readInnoLog(String path) async {
    try {
      final File log = File(path);
      if (!await log.exists()) {
        return const _WindowsInnoLogSnapshot(exists: false);
      }
      final FileStat stat = await log.stat();
      return _WindowsInnoLogSnapshot(
        exists: true,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        contents: await log.readAsString(),
      );
    } catch (_) {
      return const _WindowsInnoLogSnapshot(exists: false);
    }
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

class _WindowsInnoLogSnapshot {
  const _WindowsInnoLogSnapshot({
    required this.exists,
    this.sizeBytes,
    this.modifiedAt,
    this.contents,
  });

  final bool exists;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? contents;
}

WindowsInstallerFailureSummary summarizeWindowsInstallerFailure({
  required WindowsUpdateHandoffRecord record,
  String? innoLogContents,
}) {
  final String? launchError = record.launchError;
  if (launchError != null && launchError.trim().isNotEmpty) {
    return WindowsInstallerFailureSummary(
      type: 'launch_error',
      message: 'The update launcher could not start the installer: '
          '${launchError.trim()}',
    );
  }

  final List<WindowsInnoDeleteFileFailure> deleteFailures =
      record.innoLogDeleteFileFailures;
  WindowsInnoDeleteFileFailure? code5;
  for (final WindowsInnoDeleteFileFailure failure in deleteFailures) {
    if (failure.code == 5) {
      code5 = failure;
      break;
    }
  }
  if (code5 != null) {
    return WindowsInstallerFailureSummary(
      type: 'deletefile_code_5',
      message: 'The installer could not replace ${code5.path} because Windows '
          'reported access denied (DeleteFile code 5). Close Hibiki and any '
          'process using that file, then run the installer again.',
    );
  }

  if (deleteFailures.isNotEmpty) {
    final WindowsInnoDeleteFileFailure failure = deleteFailures.first;
    return WindowsInstallerFailureSummary(
      type: 'deletefile_failed',
      message: 'The installer could not replace ${failure.path} '
          '(DeleteFile code ${failure.code}).',
    );
  }

  final String? log = innoLogContents;
  if (log == null || record.innoLogExists == false) {
    return const WindowsInstallerFailureSummary(
      type: 'missing_log',
      message: 'The installer log was not created, so Hibiki could not confirm '
          'that Inno Setup started. This usually means the handoff launcher '
          'failed before the installer began.',
    );
  }

  final String lower = log.toLowerCase();
  final bool mentionsRunningApp = lower.contains('currently running') ||
      lower.contains('is running') ||
      lower.contains('appmutex') ||
      lower.contains('mutex') ||
      lower.contains('another instance');
  final bool hasEAbort = lower.contains('eabort');
  final bool looksCanceled = lower.contains('cancel') ||
      lower.contains('aborted') ||
      lower.contains('abort');
  if (mentionsRunningApp) {
    return WindowsInstallerFailureSummary(
      type: 'app_mutex_running',
      message: 'Inno Setup reported that Hibiki was still running. The '
          'installer is guarded by HibikiSingleInstanceMutex, so every active '
          'hibiki.exe process must be closed before the silent installer can '
          'continue.',
    );
  }
  if (hasEAbort || looksCanceled) {
    return const WindowsInstallerFailureSummary(
      type: 'silent_cancel',
      message: 'Inno Setup canceled in silent mode. With /VERYSILENT and '
          '/SUPPRESSMSGBOXES, a blocked prompt becomes a cancel instead of an '
          'interactive dialog.',
    );
  }

  return const WindowsInstallerFailureSummary(
    type: 'installer_incomplete',
    message: 'The installer ran, but Hibiki restarted with the previous '
        'version. Check the installer log for the full Inno Setup details.',
  );
}

String windowsInstallerFailureFingerprint({
  required WindowsUpdateHandoffRecord record,
}) {
  final List<String> parts = <String>[
    record.targetVersion,
    record.installerPath,
    record.innoLogPath,
    record.installerFailureType ?? 'unknown',
    record.launchError ?? '',
    '${record.innoLogSizeBytes ?? -1}',
    record.innoLogModifiedAt?.toUtc().toIso8601String() ?? '',
  ];
  return parts.map(_fingerprintPart).join('|');
}

List<WindowsInnoDeleteFileFailure> parseWindowsInnoDeleteFileFailures(
  String output,
) {
  final List<String> lines = const LineSplitter().convert(output);
  final List<WindowsInnoDeleteFileFailure> failures =
      <WindowsInnoDeleteFileFailure>[];
  String? previousPath;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String? pathOnLine = _extractWindowsPath(line);
    if (pathOnLine != null) previousPath = pathOnLine;

    final RegExpMatch? codeMatch = RegExp(
      r'DeleteFile failed[^0-9]*code\s+([0-9]+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (codeMatch == null) continue;

    final int? code = int.tryParse(codeMatch.group(1)!);
    if (code == null) continue;
    final String? nextPath =
        i + 1 < lines.length ? _extractWindowsPath(lines[i + 1]) : null;
    final String path = pathOnLine ?? previousPath ?? nextPath ?? '';
    failures.add(
      WindowsInnoDeleteFileFailure(
        path: path,
        code: code,
        message: line.trim(),
      ),
    );
  }
  return failures
      .where((WindowsInnoDeleteFileFailure failure) => failure.path.isNotEmpty)
      .toList(growable: false);
}

String _fingerprintPart(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

String? _extractWindowsPath(String line) {
  final RegExpMatch? match = RegExp(r'[A-Za-z]:\\[^"\r\n]+').firstMatch(line);
  if (match == null) return null;
  return match.group(0)!.replaceFirst(RegExp(r'[\s.;,]+$'), '').trim();
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
