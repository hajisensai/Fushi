import 'dart:convert';
import 'dart:io';

/// macOS 应用内自动更新的「跨重启握手」标记（Phase 3）。
///
/// 与 Windows 的 [WindowsUpdateHandoff] 同构但更精简：macOS 的替换发生在一段
/// **分离 shell 脚本**里（等本进程退出→替换 `/Applications/hibiki.app`→重启，见
/// `MacInstaller`），本进程 `exit(0)` 后无法直接观测替换结果。因此在退出前写一份
/// pending 标记（目标版本 + 目标 app 路径），脚本再把成功/失败写进一份 result 文件；
/// 下次启动 [reconcile] 据「当前版本是否已到目标」+ result 文件判定：
///  - 已到目标 → 替换成功、app 已以新版本重启 → 弹成功提示、删标记。
///  - 仍是旧版本 → 替换没落地 → 弹「更新未完成/失败」、**保留标记**（[shouldBackOffAutoInstall]
///    据此在同一版本上退避自动安装，改走手动确认，打断「装不成→重启→又自动装」死循环，
///    与 Windows 同策）；换成更新的目标版本会重置退避。
enum MacUpdateHandoffStatus { installed, incomplete }

class MacUpdateHandoffResult {
  const MacUpdateHandoffResult({
    required this.status,
    required this.record,
    this.message,
  });

  final MacUpdateHandoffStatus status;
  final MacUpdateHandoffRecord record;

  /// 失败/未完成时脚本写进 result 文件的可读原因（成功为 null/空）。
  final String? message;
}

class MacUpdateHandoffRecord {
  const MacUpdateHandoffRecord({
    required this.targetVersion,
    required this.targetAppPath,
    required this.startedAt,
    this.lastPromptedAppVersion,
    this.lastPromptedAt,
  });

  factory MacUpdateHandoffRecord.fromJson(Map<String, dynamic> json) {
    return MacUpdateHandoffRecord(
      targetVersion: json['targetVersion'] as String? ?? '',
      targetAppPath: json['targetAppPath'] as String? ?? '',
      startedAt: _dateTime(json['startedAt']) ?? DateTime.now().toUtc(),
      lastPromptedAppVersion: json['lastPromptedAppVersion'] as String?,
      lastPromptedAt: _dateTime(json['lastPromptedAt']),
    );
  }

  final String targetVersion;
  final String targetAppPath;
  final DateTime startedAt;
  final String? lastPromptedAppVersion;
  final DateTime? lastPromptedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'targetVersion': targetVersion,
        'targetAppPath': targetAppPath,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (lastPromptedAppVersion != null)
          'lastPromptedAppVersion': lastPromptedAppVersion,
        if (lastPromptedAt != null)
          'lastPromptedAt': lastPromptedAt!.toUtc().toIso8601String(),
      };

  MacUpdateHandoffRecord copyWith({
    String? lastPromptedAppVersion,
    DateTime? lastPromptedAt,
  }) {
    return MacUpdateHandoffRecord(
      targetVersion: targetVersion,
      targetAppPath: targetAppPath,
      startedAt: startedAt,
      lastPromptedAppVersion:
          lastPromptedAppVersion ?? this.lastPromptedAppVersion,
      lastPromptedAt: lastPromptedAt ?? this.lastPromptedAt,
    );
  }
}

abstract final class MacUpdateHandoff {
  static const String markerFileName = 'mac-update-handoff.json';
  static const String resultFileName = 'mac-update-result.json';

  static File markerFile(Directory updatesDir) =>
      File('${updatesDir.path}${Platform.pathSeparator}$markerFileName');

  static File resultFile(Directory updatesDir) =>
      File('${updatesDir.path}${Platform.pathSeparator}$resultFileName');

  static Future<void> writePending({
    required File markerFile,
    required String targetVersion,
    required String targetAppPath,
    required DateTime startedAt,
  }) async {
    // 写新 pending 前若已有指向**同一 target 版本**的旧标记，保留其 lastPrompted*
    // 字段（与 Windows 同策）：否则「装不成→重启→再装」每轮都清空提示戳，reconcile
    // 的幂等守卫失效，用户每次启动都再弹一次「更新未完成」。换成不同目标版本 → 不
    // 保留（是一次全新更新尝试，失败理应重新提示）。
    final MacUpdateHandoffRecord? existing = await read(markerFile);
    final bool sameTarget = existing != null &&
        _isSameHandoffTarget(existing.targetVersion, targetVersion);
    await _write(
      markerFile,
      MacUpdateHandoffRecord(
        targetVersion: targetVersion,
        targetAppPath: targetAppPath,
        startedAt: startedAt,
        lastPromptedAppVersion:
            sameTarget ? existing.lastPromptedAppVersion : null,
        lastPromptedAt: sameTarget ? existing.lastPromptedAt : null,
      ),
    );
  }

  static Future<MacUpdateHandoffRecord?> read(File markerFile) async {
    if (!await markerFile.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final MacUpdateHandoffRecord record =
          MacUpdateHandoffRecord.fromJson(decoded);
      if (record.targetVersion.isEmpty || record.targetAppPath.isEmpty) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  /// 磁盘上是否存在指向 [candidateVersion] **同一版本**的握手标记（= 上一轮对这个
  /// 确切版本的自动替换没落地，reconcile 成功会删标记）。调用方据此退回手动确认，
  /// 打断自动安装死循环。不同候选版本 / 标记缺失损坏 → false（fail-open，绝不
  /// 「一次失败永久不更新」）。
  static Future<bool> shouldBackOffAutoInstall({
    required File markerFile,
    required String candidateVersion,
  }) async {
    final MacUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return false;
    return _isSameHandoffTarget(record.targetVersion, candidateVersion);
  }

  /// 读脚本写的 result 文件（`{"status":"installed"|"failed","message":"..."}`）。
  /// 缺失/损坏 → null。
  static Future<_MacSwapResult?> _readResult(File resultFile) async {
    if (!await resultFile.exists()) return null;
    try {
      final Object? decoded = jsonDecode(await resultFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final String status = (decoded['status'] as String? ?? '').trim();
      if (status.isEmpty) return null;
      return _MacSwapResult(
        status: status,
        message: (decoded['message'] as String?)?.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<MacUpdateHandoffResult?> reconcile({
    required File markerFile,
    required File resultFile,
    required String currentVersion,
    DateTime? now,
  }) async {
    final MacUpdateHandoffRecord? record = await read(markerFile);
    if (record == null) return null;
    final _MacSwapResult? result = await _readResult(resultFile);
    final bool installed =
        _isVersionAtLeast(currentVersion, record.targetVersion);

    if (installed) {
      // 幂等守卫（镜像 Windows）：同一 app 版本已弹过成功提示就保持静默。仅靠删标记
      // 不可靠——删可能因权限/占用失败被吞，导致每次启动都弹成功框。
      if (record.lastPromptedAppVersion == currentVersion) {
        await _deleteQuietly(markerFile);
        await _deleteQuietly(resultFile);
        return null;
      }
      final MacUpdateHandoffRecord prompted = record.copyWith(
        lastPromptedAppVersion: currentVersion,
        lastPromptedAt: now ?? DateTime.now(),
      );
      // 先落幂等戳再删标记：即便删失败，下次启动也被上面的守卫静默。
      await _writeQuietly(markerFile, prompted);
      await _deleteQuietly(markerFile);
      await _deleteQuietly(resultFile);
      return MacUpdateHandoffResult(
        status: MacUpdateHandoffStatus.installed,
        record: prompted,
      );
    }

    // 仍是旧版本 = 替换没落地。幂等守卫：同一 app 版本只提示一次「更新未完成」。
    if (record.lastPromptedAppVersion == currentVersion) {
      return null;
    }
    final MacUpdateHandoffRecord prompted = record.copyWith(
      lastPromptedAppVersion: currentVersion,
      lastPromptedAt: now ?? DateTime.now(),
    );
    // **保留** marker（供 shouldBackOffAutoInstall 在同版本退避），只写回幂等戳；
    // result 文件已被消费，删掉。
    await _writeQuietly(markerFile, prompted);
    await _deleteQuietly(resultFile);
    return MacUpdateHandoffResult(
      status: MacUpdateHandoffStatus.incomplete,
      record: prompted,
      message: result?.message,
    );
  }

  static Future<void> _write(
    File markerFile,
    MacUpdateHandoffRecord record,
  ) async {
    await markerFile.parent.create(recursive: true);
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    await markerFile.writeAsString(
      encoder.convert(record.toJson()),
      flush: true,
    );
  }

  static Future<void> _writeQuietly(
    File markerFile,
    MacUpdateHandoffRecord record,
  ) async {
    try {
      await _write(markerFile, record);
    } catch (_) {
      // 幂等守卫已覆盖，写失败不影响给用户看到结果。
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best-effort。
    }
  }

  static bool _isSameHandoffTarget(String a, String b) {
    final String left = _stripLeadingV(a.trim());
    final String right = _stripLeadingV(b.trim());
    return left.isNotEmpty && left == right;
  }
}

class _MacSwapResult {
  const _MacSwapResult({required this.status, this.message});

  final String status;
  final String? message;
}

DateTime? _dateTime(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw);
}

bool _isVersionAtLeast(String current, String target) =>
    _compareVersions(current, target) >= 0;

/// 与 update_handoff.dart 的比较同语义：strip 前导 v + 剪 `+build`，逐段数值比，
/// 再按预发布段比（无预发布段 > 有预发布段）。debug 通道用 `-debug.<seq>` 区分，
/// 序号递增即更新。
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

List<int> _segments(String value) => value
    .split('.')
    .map((String part) => int.tryParse(part) ?? 0)
    .toList(growable: false);

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
