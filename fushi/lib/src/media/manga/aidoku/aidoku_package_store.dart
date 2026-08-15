import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/storage/app_paths.dart';

const int kMaximumAidokuPackageBytes = 128 * 1024 * 1024;

class AidokuInstalledPackage {
  const AidokuInstalledPackage({
    required this.id,
    required this.name,
    required this.version,
    required this.languages,
    required this.requiresWebView,
    required this.packagePath,
    required this.installedAt,
    this.enabled = true,
  });

  factory AidokuInstalledPackage.fromJson(
    Map<String, Object?> json,
    String packagePath,
  ) {
    final Object? languages = json['languages'];
    return AidokuInstalledPackage(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      languages: languages is List<Object?>
          ? languages.map((Object? value) => value.toString()).toList()
          : const <String>[],
      requiresWebView: json['requiresWebView'] == true,
      packagePath: packagePath,
      installedAt: DateTime.tryParse(json['installedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      enabled: json['enabled'] != false,
    );
  }

  factory AidokuInstalledPackage.fromInspection(
    AidokuPackageInspection inspection,
    String packagePath,
  ) {
    final Map<String, Object?> info = inspection.sourceInfo;
    final Object? languages = info['languages'];
    return AidokuInstalledPackage(
      id: info['id']!.toString(),
      name: info['name']!.toString(),
      version: (info['version'] as num).toInt(),
      languages: languages is List<Object?>
          ? languages.map((Object? value) => value.toString()).toList()
          : const <String>[],
      requiresWebView: inspection.requiresWebView,
      packagePath: packagePath,
      installedAt: DateTime.now().toUtc(),
      enabled: true,
    );
  }

  final String id;
  final String name;
  final int version;
  final List<String> languages;
  final bool requiresWebView;
  final String packagePath;
  final DateTime installedAt;
  final bool enabled;

  AidokuInstalledPackage copyWith({bool? enabled}) => AidokuInstalledPackage(
        id: id,
        name: name,
        version: version,
        languages: languages,
        requiresWebView: requiresWebView,
        packagePath: packagePath,
        installedAt: installedAt,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'id': id,
        'name': name,
        'version': version,
        'languages': languages,
        'requiresWebView': requiresWebView,
        'installedAt': installedAt.toIso8601String(),
        'enabled': enabled,
      };
}

class AidokuPackageStore {
  AidokuPackageStore(this.directory);

  static Future<AidokuPackageStore> open() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return AidokuPackageStore(
      Directory(p.join(supportRoot.path, 'manga_extensions', 'aidoku')),
    );
  }

  final Directory directory;

  static final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);

  /// Cross-page invalidation for the kept-alive Sources and Browse tabs.
  static Stream<void> get changes => _changes.stream;

  Future<List<AidokuInstalledPackage>> listInstalled() async {
    if (!await directory.exists()) return const <AidokuInstalledPackage>[];
    final List<AidokuInstalledPackage> packages = <AidokuInstalledPackage>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      try {
        final Object? decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map<Object?, Object?>) continue;
        final String stem = p.basenameWithoutExtension(entity.path);
        final String packagePath = p.join(directory.path, '$stem.aix');
        if (!await File(packagePath).exists()) continue;
        final AidokuInstalledPackage package = AidokuInstalledPackage.fromJson(
          decoded.cast<String, Object?>(),
          packagePath,
        );
        if (package.id.isEmpty || package.name.isEmpty) continue;
        packages.add(package);
      } on Object {
        // A damaged metadata sidecar must not hide other installed sources. It
        // can be replaced by importing that source again.
      }
    }
    packages.sort(
      (AidokuInstalledPackage a, AidokuInstalledPackage b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return packages;
  }

  Future<AidokuInstalledPackage> install(
    File source,
    AidokuPackageInspection inspection,
  ) async {
    final int length = await source.length();
    if (length <= 0 || length > kMaximumAidokuPackageBytes) {
      throw const AidokuRuntimeException(
        'PACKAGE_SIZE',
        'Aidoku package is empty or exceeds the 128 MiB limit',
      );
    }
    final Map<String, Object?> info = inspection.sourceInfo;
    final String id = info['id']?.toString().trim() ?? '';
    final String name = info['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty || info['version'] is! num) {
      throw const AidokuRuntimeException(
        'INVALID_MANIFEST',
        'Aidoku package manifest is missing its identity or version',
      );
    }

    await directory.create(recursive: true);
    final String stem = sha256.convert(utf8.encode(id)).toString();
    final File target = File(p.join(directory.path, '$stem.aix'));
    final File metadata = File(p.join(directory.path, '$stem.json'));
    final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final File stagedPackage =
        File(p.join(directory.path, '.$stem.$nonce.aix'));
    final File stagedMetadata =
        File(p.join(directory.path, '.$stem.$nonce.json'));
    final File backupPackage =
        File(p.join(directory.path, '.$stem.$nonce.aix.bak'));
    final File backupMetadata =
        File(p.join(directory.path, '.$stem.$nonce.json.bak'));
    final bool hadPackage = await target.exists();
    final bool hadMetadata = await metadata.exists();

    final AidokuInstalledPackage installed =
        AidokuInstalledPackage.fromInspection(inspection, target.path);
    try {
      await source.copy(stagedPackage.path);
      final int stagedLength = await stagedPackage.length();
      if (stagedLength <= 0 || stagedLength > kMaximumAidokuPackageBytes) {
        throw const AidokuRuntimeException(
          'PACKAGE_SIZE',
          'Aidoku package is empty or exceeds the 128 MiB limit',
        );
      }
      await stagedMetadata.writeAsString(
        jsonEncode(installed.toJson()),
        flush: true,
      );
      if (hadPackage) await target.rename(backupPackage.path);
      if (hadMetadata) await metadata.rename(backupMetadata.path);
      await stagedPackage.rename(target.path);
      await stagedMetadata.rename(metadata.path);
    } on Object {
      if (await stagedPackage.exists()) await stagedPackage.delete();
      if (await stagedMetadata.exists()) await stagedMetadata.delete();
      if (await backupPackage.exists()) {
        if (await target.exists()) await target.delete();
        await backupPackage.rename(target.path);
      } else if (!hadPackage && await target.exists()) {
        await target.delete();
      }
      if (await backupMetadata.exists()) {
        if (await metadata.exists()) await metadata.delete();
        await backupMetadata.rename(metadata.path);
      } else if (!hadMetadata && await metadata.exists()) {
        await metadata.delete();
      }
      rethrow;
    }
    // Backup cleanup is deliberately outside the transaction: a stale backup
    // is harmless, while rolling back a successful install because cleanup
    // failed would discard the user's newly imported package.
    try {
      if (await backupPackage.exists()) await backupPackage.delete();
      if (await backupMetadata.exists()) await backupMetadata.delete();
    } on FileSystemException {
      // A later import uses a fresh nonce and is unaffected by stale backups.
    }
    _changes.add(null);
    return installed;
  }

  Future<AidokuInstalledPackage> setEnabled(
    AidokuInstalledPackage package,
    bool enabled,
  ) async {
    if (package.enabled == enabled) return package;
    final String stem = sha256.convert(utf8.encode(package.id)).toString();
    final File metadata = File(p.join(directory.path, '$stem.json'));
    if (!await metadata.exists()) {
      throw const AidokuRuntimeException(
        'PACKAGE_MISSING',
        'The installed Aidoku package metadata is missing',
      );
    }
    final AidokuInstalledPackage updated = package.copyWith(enabled: enabled);
    final File staged = File('${metadata.path}.tmp');
    await staged.writeAsString(jsonEncode(updated.toJson()), flush: true);
    await staged.rename(metadata.path);
    _changes.add(null);
    return updated;
  }

  Future<void> remove(AidokuInstalledPackage package) async {
    final String stem = sha256.convert(utf8.encode(package.id)).toString();
    final File storedPackage = File(p.join(directory.path, '$stem.aix'));
    final File metadata = File(p.join(directory.path, '$stem.json'));
    if (await storedPackage.exists()) await storedPackage.delete();
    if (await metadata.exists()) await metadata.delete();
    _changes.add(null);
  }
}
