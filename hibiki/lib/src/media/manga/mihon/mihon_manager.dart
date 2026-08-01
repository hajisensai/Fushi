import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';

class MihonManager extends ChangeNotifier {
  MihonManager({
    required this.database,
    required this.rootDirectory,
    required this.runtime,
    MihonExtensionStoreClient? storeClient,
  }) : _storeClient = storeClient ?? MihonExtensionStoreClient() {
    if (Platform.isWindows || Platform.isMacOS) {
      _exitShutdown =
          ExitFlushRegistry.instance.register(shutdownRuntimeForExit);
    }
  }

  final HibikiDatabase database;
  final Directory rootDirectory;
  final MihonRuntime runtime;
  final MihonExtensionStoreClient _storeClient;

  List<MangaExtensionStoreRow> stores = const <MangaExtensionStoreRow>[];
  List<MangaExtensionRow> installed = const <MangaExtensionRow>[];
  List<MangaOnlineSourceRow> sources = const <MangaOnlineSourceRow>[];
  List<MihonAvailableExtension> available = const <MihonAvailableExtension>[];
  bool loading = false;
  String? error;
  bool _disposed = false;
  Future<void>? _initialising;
  Future<void>? _runtimeShutdown;
  ExitFlushCallback? _exitShutdown;

  /// Desktop window close ends in a process-level fast exit, so ordinary
  /// ChangeNotifier/widget disposal is not guaranteed to run. Register this
  /// bounded callback with the app exit barrier to stop the exact retained
  /// sidecar process before the Flutter process terminates.
  Future<void> shutdownRuntimeForExit() =>
      _runtimeShutdown ??= runtime.dispose();

  Future<void> initialise() {
    final Future<void>? current = _initialising;
    if (current != null) return current;
    final Future<void> future = _initialise();
    _initialising = future;
    return future;
  }

  Future<void> _initialise() async {
    loading = true;
    _notify();
    try {
      await rootDirectory.create(recursive: true);
      await Directory(p.join(rootDirectory.path, 'extensions'))
          .create(recursive: true);
      await Directory(p.join(rootDirectory.path, 'tmp'))
          .create(recursive: true);
      await reload();
      await _refreshStores();
    } catch (exception) {
      error = '$exception';
      rethrow;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> reload() async {
    stores = await database.getMangaExtensionStores();
    installed = await database.getMangaExtensions();
    sources = await database.getMangaOnlineSources();
    _notify();
  }

  Future<void> addStore(
    String url, {
    bool allowInsecure = false,
  }) async {
    await _guarded(() async {
      final MihonStoreFetchResult fetched = await _storeClient.fetchStore(
        url,
        allowInsecure: allowInsecure,
      );
      final MihonStore store = fetched.store!;
      final List<MihonAvailableExtension> extensions =
          await _storeClient.fetchExtensions(
        store,
        allowInsecure: allowInsecure,
      );
      final int sortOrder = stores.isEmpty
          ? 0
          : stores
                  .map((MangaExtensionStoreRow row) => row.sortOrder)
                  .reduce((int a, int b) => a > b ? a : b) +
              1;
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: store.indexUrl,
          name: store.name,
          format: store.format.name,
          badgeLabel: Value(store.badgeLabel),
          signingKey: Value(store.signingKey),
          contactJson: Value(jsonEncode(store.contact)),
          extensionListUrl: Value(store.extensionListUrl),
          sortOrder: Value(sortOrder),
          etag: Value(fetched.etag),
          lastModified: Value(fetched.lastModified),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      available = <MihonAvailableExtension>[
        ...available.where(
            (MihonAvailableExtension item) => item.storeUrl != store.indexUrl),
        ...extensions,
      ];
      await reload();
    });
  }

  Future<void> refreshStores() async {
    await _guarded(_refreshStores);
  }

  Future<void> _refreshStores() async {
    final List<MihonAvailableExtension> next = <MihonAvailableExtension>[];
    for (final MangaExtensionStoreRow row in stores) {
      if (!row.enabled) continue;
      final List<MihonAvailableExtension> cachedExtensions = available
          .where(
            (MihonAvailableExtension item) => item.storeUrl == row.indexUrl,
          )
          .toList(growable: false);
      try {
        final bool insecure = Uri.parse(row.indexUrl).scheme == 'http';
        // Current JSON/protobuf repositories embed the complete catalogue in
        // the index response. After a process restart that catalogue is not in
        // memory, so a conditional 304 would leave the page permanently empty.
        // Only validate an embedded index when its parsed catalogue is still
        // reusable; repositories with an external list can always re-fetch it.
        final bool hasReusableCatalogue =
            row.extensionListUrl != null || cachedExtensions.isNotEmpty;
        final MihonStoreFetchResult fetched = await _storeClient.fetchStore(
          row.indexUrl,
          etag: hasReusableCatalogue ? row.etag : null,
          lastModified: hasReusableCatalogue ? row.lastModified : null,
          allowInsecure: insecure,
        );
        final MihonStore store =
            fetched.notModified ? _storeFromRow(row) : fetched.store!;
        // A current protobuf/JSON store can embed its complete extension
        // list. A 304 response intentionally has no body, so reconstructing
        // the store from the DB cannot reconstruct that list. Retain the
        // already parsed list in that case; external/legacy indexes can
        // still be fetched independently from extensionListUrl.
        final List<MihonAvailableExtension> extensions =
            fetched.notModified && store.extensionListUrl == null
                ? cachedExtensions
                : await _storeClient.fetchExtensions(
                    store,
                    allowInsecure: insecure,
                  );
        next.addAll(extensions);
        await database.upsertMangaExtensionStore(
          MangaExtensionStoresCompanion.insert(
            indexUrl: store.indexUrl,
            name: store.name,
            format: store.format.name,
            badgeLabel: Value(store.badgeLabel),
            signingKey: Value(store.signingKey),
            contactJson: Value(jsonEncode(store.contact)),
            extensionListUrl: Value(store.extensionListUrl),
            enabled: Value(row.enabled),
            sortOrder: Value(row.sortOrder),
            etag: Value(fetched.etag ?? row.etag),
            lastModified: Value(fetched.lastModified ?? row.lastModified),
            lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
            lastError: const Value(null),
          ),
        );
      } catch (exception) {
        // A manual refresh must not blank an already visible catalogue merely
        // because this request failed. Cold start has no in-memory catalogue,
        // but installed extensions still come from the database via reload().
        next.addAll(cachedExtensions);
        await database.upsertMangaExtensionStore(
          MangaExtensionStoresCompanion.insert(
            indexUrl: row.indexUrl,
            name: row.name,
            format: row.format,
            badgeLabel: Value(row.badgeLabel),
            signingKey: Value(row.signingKey),
            contactJson: Value(row.contactJson),
            extensionListUrl: Value(row.extensionListUrl),
            enabled: Value(row.enabled),
            sortOrder: Value(row.sortOrder),
            etag: Value(row.etag),
            lastModified: Value(row.lastModified),
            lastSyncAt: Value(row.lastSyncAt),
            lastError: Value('$exception'),
          ),
        );
      }
    }
    available = next;
    await reload();
  }

  Future<void> removeStore(String indexUrl) async {
    await database.deleteMangaExtensionStore(indexUrl);
    available = available
        .where((MihonAvailableExtension item) => item.storeUrl != indexUrl)
        .toList(growable: false);
    await reload();
  }

  Future<MihonInstallProposal> prepareStoreInstall(
    MihonAvailableExtension extension,
  ) async {
    final MangaExtensionStoreRow? store = stores
        .where(
            (MangaExtensionStoreRow row) => row.indexUrl == extension.storeUrl)
        .firstOrNull;
    if (store == null) {
      throw const MihonRuntimeException(
        'STORE_MISSING',
        'The extension store is no longer configured',
      );
    }
    // 明文放行的授权必须来自**用户当初确认过的那个仓库地址**，绝不能来自 APK
    // 直链自己的 scheme —— 后者等于「因为你是 http，所以允许你走 http」，把
    // `_validatedUri` 的 HTTPS 策略自我否决掉：一个 https 仓库可以在索引里塞一条
    // http 直链，用户看不到任何提示就被中间人换掉安装包。仓库地址在 addStore 时
    // 已经过 `_confirmInsecureUrl` 明示同意，继承它才是正确的信任传递。
    final Uint8List bytes = await _storeClient.downloadApk(
      extension.apkUrl,
      allowInsecure: Uri.parse(store.indexUrl).scheme == 'http',
    );
    return _prepareInstallBytes(
      bytes,
      expected: extension,
      expectedSigningKey: store.signingKey,
    );
  }

  Future<MihonInstallProposal> prepareLocalInstall(String apkPath) async {
    final File file = File(apkPath);
    final int length = await file.length();
    if (length > mihonExtensionApkMaxBytes) {
      throw const MihonRuntimeException(
        'DOWNLOAD_TOO_LARGE',
        'Extension APK exceeds the 100 MiB limit',
      );
    }
    return _prepareInstallBytes(await file.readAsBytes());
  }

  Future<MihonInstallProposal> _prepareInstallBytes(
    Uint8List bytes, {
    MihonAvailableExtension? expected,
    String? expectedSigningKey,
  }) async {
    final String sha = sha256.convert(bytes).toString();
    final File temp = File(p.join(
      rootDirectory.path,
      'tmp',
      'extension-$sha.apk.part',
    ));
    await temp.writeAsBytes(bytes, flush: true);
    try {
      final MihonExtensionInspection inspection =
          await runtime.inspectExtension(temp.path);
      if (inspection.libVersion != '1.4' && inspection.libVersion != '1.6') {
        throw MihonRuntimeException(
          'UNSUPPORTED_LIB',
          'Extension lib ${inspection.libVersion} is not supported',
        );
      }
      if (expected != null) {
        if (inspection.packageName != expected.packageName ||
            inspection.versionCode != expected.versionCode) {
          throw const MihonRuntimeException(
            'METADATA_MISMATCH',
            'Downloaded APK does not match the extension store metadata',
          );
        }
      }
      final String expectedSigner =
          _normalizeFingerprint(expectedSigningKey ?? '');
      final String actualSigner =
          _normalizeFingerprint(inspection.signerSha256);
      if (expectedSigner.isNotEmpty && expectedSigner != actualSigner) {
        throw const MihonRuntimeException(
          'SIGNATURE_MISMATCH',
          'APK signer does not match the extension store signing key',
        );
      }
      final MangaExtensionRow? current =
          await database.getMangaExtension(inspection.packageName);
      if (current != null) {
        if (inspection.versionCode < current.versionCode) {
          throw const MihonRuntimeException(
            'DOWNGRADE_REJECTED',
            'Extension downgrade is not allowed',
          );
        }
        if (_normalizeFingerprint(current.signerSha256) != actualSigner) {
          throw const MihonRuntimeException(
            'SIGNATURE_CHANGED',
            'Extension update signer does not match the installed version',
          );
        }
      }
      final bool trusted = await database.isMangaSignerTrusted(actualSigner);
      return MihonInstallProposal(
        tempPath: temp.path,
        apkSha256: sha,
        inspection: inspection,
        expected: expected,
        current: current,
        signerTrusted: trusted,
      );
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> commitInstall(
    MihonInstallProposal proposal, {
    required bool trustSigner,
  }) async {
    final String signer =
        _normalizeFingerprint(proposal.inspection.signerSha256);
    if (!proposal.signerTrusted && !trustSigner) {
      throw const MihonRuntimeException(
        'SIGNER_NOT_TRUSTED',
        'The extension signer has not been trusted',
      );
    }
    await _guarded(() async {
      if (!proposal.signerTrusted) {
        await database.trustMangaSigner(
          MangaTrustedSignersCompanion.insert(
            fingerprint: signer,
            label: proposal.inspection.name,
            origin: proposal.expected?.storeUrl ?? 'local',
            trustedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      final String packageName = proposal.inspection.packageName;
      final File target = File(p.join(
        rootDirectory.path,
        'extensions',
        '$packageName.apk',
      ));
      final File backup = File('${target.path}.previous');
      final bool desktop = Platform.isWindows || Platform.isMacOS;
      if (desktop) {
        if (await backup.exists()) await backup.delete();
        if (await target.exists()) await target.rename(backup.path);
        try {
          await File(proposal.tempPath).rename(target.path);
        } on FileSystemException {
          await File(proposal.tempPath).copy(target.path);
          await File(proposal.tempPath).delete();
        }
      }
      String runtimePath = desktop
          ? target.path
          : await runtime.installPrivateExtension(proposal.tempPath);
      try {
        final MihonExtensionRef extension = MihonExtensionRef(
          packageName: packageName,
          apkPath: runtimePath,
        );
        final List<MihonSource> loaded = await runtime.listSources(extension);
        if (loaded.isEmpty) {
          throw const MihonRuntimeException(
            'NO_SOURCES',
            'Extension did not expose any manga sources',
          );
        }
        final String storedPath =
            p.join('extensions', '$packageName.${desktop ? 'apk' : 'ext'}');
        await database.upsertMangaExtension(
          MangaExtensionsCompanion.insert(
            packageName: packageName,
            storeUrl: Value(proposal.expected?.storeUrl),
            name: proposal.inspection.name,
            versionCode: proposal.inspection.versionCode,
            versionName: proposal.inspection.versionName,
            libVersion: proposal.inspection.libVersion,
            language: proposal.expected?.language ??
                loaded
                    .map((MihonSource item) => item.language)
                    .toSet()
                    .join(','),
            contentWarning: Value(proposal.expected?.contentWarning ?? 0),
            apkPath: storedPath,
            apkSha256: proposal.apkSha256,
            signerSha256: signer,
            installedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await database.replaceMangaOnlineSources(
          packageName,
          loaded.map(
            (MihonSource source) => MangaOnlineSourcesCompanion.insert(
              extensionPackage: packageName,
              sourceId: source.id,
              name: source.name,
              language: source.language,
              baseUrl: Value(source.baseUrl),
            ),
          ),
        );
        if (await backup.exists()) await backup.delete();
        if (await File(proposal.tempPath).exists()) {
          await File(proposal.tempPath).delete();
        }
      } catch (_) {
        if (desktop) {
          if (await target.exists()) await target.delete();
          if (await backup.exists()) await backup.rename(target.path);
        }
        rethrow;
      }
      await runtime.invalidateExtension(packageName);
      await reload();
    });
  }

  Future<void> uninstallExtension(
    MangaExtensionRow extension, {
    bool clearData = false,
  }) async {
    await _guarded(() async {
      await runtime.uninstallPrivateExtension(extension.packageName);
      if (Platform.isWindows || Platform.isMacOS) {
        final File file = File(resolveApkPath(extension));
        if (await file.exists()) await file.delete();
      }
      if (clearData) {
        for (final MangaOnlineSourceRow source in sources.where(
          (MangaOnlineSourceRow row) =>
              row.extensionPackage == extension.packageName,
        )) {
          await database.clearMangaSourcePreferences(
            source.extensionPackage,
            source.sourceId,
          );
        }
      }
      await database.deleteMangaExtension(extension.packageName);
      await runtime.invalidateExtension(extension.packageName);
      await reload();
    });
  }

  Future<void> setExtensionEnabled(
    MangaExtensionRow extension,
    bool enabled,
  ) async {
    await database.setMangaExtensionEnabled(extension.packageName, enabled);
    await reload();
  }

  Future<void> updateSourceSettings(
    MangaOnlineSourceRow source, {
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) async {
    await database.updateMangaOnlineSourceSettings(
      extensionPackage: source.extensionPackage,
      sourceId: source.sourceId,
      enabled: enabled,
      pinned: pinned,
      sortOrder: sortOrder,
    );
    await reload();
  }

  Future<List<MihonPreference>> getPreferences(
    MangaOnlineSourceRow source,
  ) async {
    final MangaExtensionRow extension = installed.firstWhere(
      (MangaExtensionRow row) => row.packageName == source.extensionPackage,
    );
    final List<MihonPreference> persisted =
        await _readPersistedPreferences(source);
    return runtime.getPreferences(
      extensionRef(extension),
      sourceModel(source),
      persisted: persisted,
    );
  }

  Future<List<MihonPreference>> setPreference(
    MangaOnlineSourceRow source,
    MihonPreference preference,
  ) async {
    final MangaExtensionRow extension = installed.firstWhere(
      (MangaExtensionRow row) => row.packageName == source.extensionPackage,
    );
    final List<MihonPreference> persisted =
        await _readPersistedPreferences(source);
    final List<MihonPreference> updated = await runtime.setPreference(
      extensionRef(extension),
      sourceModel(source),
      preference,
      persisted: persisted,
    );
    for (final MihonPreference item in updated) {
      await database.upsertMangaSourcePreference(
        MangaSourcePreferencesCompanion.insert(
          extensionPackage: source.extensionPackage,
          sourceId: source.sourceId,
          preferenceKey: item.key,
          preferenceType: item.kind.name,
          valueJson: item.encodeValue(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return updated;
  }

  Future<void> clearSourceData(MangaOnlineSourceRow source) async {
    final MangaExtensionRow extension = installed.firstWhere(
      (MangaExtensionRow row) => row.packageName == source.extensionPackage,
    );
    await runtime.clearSourceData(
      extensionRef(extension),
      sourceModel(source),
    );
    await database.clearMangaSourcePreferences(
      source.extensionPackage,
      source.sourceId,
    );
  }

  Future<MihonSourceContext> contextForSource(
    MangaOnlineSourceRow source,
  ) async {
    final MangaExtensionRow extension = installed.firstWhere(
      (MangaExtensionRow row) =>
          row.packageName == source.extensionPackage && row.enabled,
      orElse: () => throw const MihonRuntimeException(
        'EXTENSION_DISABLED',
        'The manga source extension is not installed or is disabled',
      ),
    );
    return MihonSourceContext(
      extension: extensionRef(extension),
      source: sourceModel(source),
      preferences: await _readPersistedPreferences(source),
    );
  }

  MihonExtensionRef extensionRef(MangaExtensionRow extension) =>
      MihonExtensionRef(
        packageName: extension.packageName,
        apkPath: resolveApkPath(extension),
      );

  MihonSource sourceModel(MangaOnlineSourceRow source) => MihonSource(
        extensionPackage: source.extensionPackage,
        id: source.sourceId,
        name: source.name,
        language: source.language,
        baseUrl: source.baseUrl,
      );

  String resolveApkPath(MangaExtensionRow extension) {
    if (Platform.isAndroid) return extension.apkPath;
    return p.normalize(p.join(rootDirectory.path, extension.apkPath));
  }

  Future<List<MihonPreference>> _readPersistedPreferences(
    MangaOnlineSourceRow source,
  ) async {
    final List<MangaSourcePreferenceRow> rows =
        await database.getMangaSourcePreferences(
      source.extensionPackage,
      source.sourceId,
    );
    return rows.map((MangaSourcePreferenceRow row) {
      final MihonPreferenceKind kind = MihonPreferenceKind.values.firstWhere(
        (MihonPreferenceKind value) => value.name == row.preferenceType,
        orElse: () => MihonPreferenceKind.unsupported,
      );
      return MihonPreference(
        key: row.preferenceKey,
        kind: kind,
        title: row.preferenceKey,
        value: jsonDecode(row.valueJson),
      );
    }).toList(growable: false);
  }

  MihonStore _storeFromRow(MangaExtensionStoreRow row) => MihonStore(
        indexUrl: row.indexUrl,
        name: row.name,
        badgeLabel: row.badgeLabel ?? row.name,
        signingKey: row.signingKey ?? '',
        contact: row.contactJson == null
            ? const <String, String?>{}
            : (jsonDecode(row.contactJson!) as Map<Object?, Object?>)
                .map<String, String?>(
                (Object? key, Object? value) => MapEntry<String, String?>(
                    key.toString(), value?.toString()),
              ),
        format: MihonStoreFormat.values.firstWhere(
          (MihonStoreFormat value) => value.name == row.format,
          orElse: () => MihonStoreFormat.currentJson,
        ),
        extensionListUrl: row.extensionListUrl,
      );

  Future<void> _guarded(Future<void> Function() action) async {
    loading = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (exception) {
      error = '$exception';
      rethrow;
    } finally {
      loading = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ExitFlushCallback? exitShutdown = _exitShutdown;
    _exitShutdown = null;
    if (exitShutdown != null) {
      ExitFlushRegistry.instance.unregister(exitShutdown);
    }
    _storeClient.close();
    unawaited(shutdownRuntimeForExit());
    super.dispose();
  }

  static String _normalizeFingerprint(String value) =>
      value.replaceAll(RegExp('[^0-9a-fA-F]'), '').toLowerCase();
}

@immutable
class MihonInstallProposal {
  const MihonInstallProposal({
    required this.tempPath,
    required this.apkSha256,
    required this.inspection,
    required this.expected,
    required this.current,
    required this.signerTrusted,
  });

  final String tempPath;
  final String apkSha256;
  final MihonExtensionInspection inspection;
  final MihonAvailableExtension? expected;
  final MangaExtensionRow? current;
  final bool signerTrusted;
}

@immutable
class MihonSourceContext {
  const MihonSourceContext({
    required this.extension,
    required this.source,
    required this.preferences,
  });

  final MihonExtensionRef extension;
  final MihonSource source;
  final List<MihonPreference> preferences;
}
