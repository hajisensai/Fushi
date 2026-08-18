import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';

/// 开箱即用的默认扩展仓库（用户指定）。没有它的话「漫画扩展」一节首次打开是空的，
/// 用户得先自己知道一个仓库地址才能开始——而这个仓库就是社区事实标准。
const String kMihonDefaultStoreIndexUrl =
    'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

/// 默认仓库在拉到真实索引之前的显示名。第一次成功刷新会用仓库自报的名字覆写。
const String kMihonDefaultStoreName = 'Keiyoushi';

/// 默认仓库**只自动装配一次**：置位后用户删掉它就不会被下次启动重新塞回来。
///
/// 置位的判据是「装配这一步做完了」，而装配现在是一次**本地** DB 写（见
/// [MihonManager._seedDefaultStore]），不依赖网络，所以不存在「置早了导致永不重试」
/// 的窗口。存量里 pref 仍为 false 的用户（旧代码下装配因断网失败过）下次启动即自愈。
const String kMihonDefaultStoreSeededPref = 'mihon_default_store_seeded';

class MihonManager extends ChangeNotifier {
  MihonManager({
    required this.database,
    required this.rootDirectory,
    required this.runtime,
    MihonExtensionStoreClient? storeClient,
    this.seedDefaultStore = false,
  }) : _storeClient = storeClient ?? MihonExtensionStoreClient() {
    coverCache = MihonCoverCache(
      Directory(p.join(rootDirectory.path, 'cache', 'covers')),
    );
    if (Platform.isWindows || Platform.isMacOS) {
      _exitShutdown =
          ExitFlushRegistry.instance.register(shutdownRuntimeForExit);
    }
  }

  final FushiDatabase database;
  final Directory rootDirectory;
  final MihonRuntime runtime;
  late final MihonCoverCache coverCache;
  final MihonExtensionStoreClient _storeClient;

  /// 是否在 [initialise] 里装配默认扩展仓库（见 [kMihonDefaultStoreIndexUrl]）。
  ///
  /// 默认 **false**，只有真实 app 启动那一处（`AppModel.mihonManager`）传 true。
  /// 装默认仓库是**应用启动策略**，不是「构造一个 manager」的语义：挂在
  /// [initialise] 上无条件执行，会让任何构造 manager 的单测都去真实网络拉
  /// keiyoushi 索引（1900+ 条），既慢又把测试结果绑在外网上——这正是本轮
  /// `mihon_manager_install_test` 那条 cold-start 用例变红的原因。
  final bool seedDefaultStore;

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
  final Set<String> _extensionActionPackages = <String>{};
  String? _activePreviewPackage;

  bool isExtensionActionBusy(String packageName) =>
      _extensionActionPackages.contains(packageName);

  /// Claims a package for the complete user-facing preview/install flow.
  /// This survives page rebuilds and navigation while a dialog is open.
  bool tryBeginExtensionAction(String packageName) {
    if (!_extensionActionPackages.add(packageName)) return false;
    _notify();
    return true;
  }

  void endExtensionAction(String packageName) {
    if (_extensionActionPackages.remove(packageName)) _notify();
  }

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
      // 必须在 reload 之后：判断孤儿要拿 installed 跟标记里的包名比对。
      await _recoverAbandonedPreview();
      await _clearStagedApks();
      // 种子必须在刷新**之前**：它只往本地写一行，写完紧接着的 _refreshStores
      // 就把它的目录一并拉下来——默认仓库从此和用户自己加的仓库走同一条路径。
      await _seedDefaultStore();
      await _refreshStores();
    } catch (exception) {
      error = '$exception';
      rethrow;
    } finally {
      loading = false;
      _notify();
    }
  }

  /// 首次启动把 [kMihonDefaultStoreIndexUrl] 落成一行本地仓库配置（见常量文档）。
  ///
  /// **纯本地写，不碰网络。** 早先这里调 [addStore]，于是「默认仓库存在」被绑死在
  /// 「首次启动能连上 github.com」上：连不上就一行都不写，用户看到的是一个空列表，
  /// 而且完全不知道本该有一个默认仓库——所谓「下次启动重试」在长期连不上的网络下
  /// 等于永远没有。仓库**配置**和仓库**目录**是两件事：配置该无条件落地，目录由
  /// 紧随其后的 [_refreshStores] 用和其它仓库完全相同的路径去拉，失败就照常写进
  /// `lastError` 让用户看见并可手动重试，而不是静默消失。
  ///
  /// 落地后即置位 [kMihonDefaultStoreSeededPref]：置位语义是「已经替用户装配过」，
  /// 不是「已经拉到过目录」——所以用户删掉它之后不会被下次启动塞回来。
  Future<void> _seedDefaultStore() async {
    if (!seedDefaultStore) return;
    final bool seeded = await database.getPrefTyped<bool>(
      kMihonDefaultStoreSeededPref,
      false,
    );
    if (seeded) return;
    // 用户自己先加过同一个地址：认下它，别用种子行覆盖掉他的排序/启用状态。
    if (!stores.any((MangaExtensionStoreRow row) =>
        row.indexUrl == kMihonDefaultStoreIndexUrl)) {
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: kMihonDefaultStoreIndexUrl,
          name: kMihonDefaultStoreName,
          // index.pb。真实格式由第一次成功刷新覆写，这里只是让「从未刷新过」的行
          // 也能被 _refreshStores 正常处理（etag/lastModified 都为空，不会走 304）。
          format: MihonStoreFormat.currentProtobuf.name,
          sortOrder: Value(_nextStoreSortOrder()),
        ),
      );
      await reload();
    }
    await database.setPrefTyped<bool>(kMihonDefaultStoreSeededPref, true);
  }

  int _nextStoreSortOrder() => stores.isEmpty
      ? 0
      : stores
              .map((MangaExtensionStoreRow row) => row.sortOrder)
              .reduce((int a, int b) => a > b ? a : b) +
          1;

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
      final int sortOrder = _nextStoreSortOrder();
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
    final bool insecure = Uri.parse(store.indexUrl).scheme == 'http';
    final MihonAvailableExtension target = await _resolveInstallTarget(
      store,
      extension,
      allowInsecure: insecure,
    );
    final Uint8List bytes = await _storeClient.downloadApk(
      target.apkUrl,
      allowInsecure: insecure,
    );
    return _prepareInstallBytes(
      bytes,
      expected: target,
      expectedSigningKey: store.signingKey,
    );
  }

  /// 安装前**重新解析一次仓库索引**，拿当次索引里的直链去下载。
  ///
  /// [available] 是远端索引的**内存快照**，只在进程冷启动的 [_refreshStores]
  /// 里刷一次（没有任何缓存表，重启即丢）。而快照里的 `apkUrl` 指向的是**短寿命
  /// 资源**：keiyoushi 把 APK 挂在 GitHub release 上，只保留最近 7 个 release，
  /// 旧 tag 连同资产一起被删（2026-08-18 实测：当时保留的 7 个 release 全部产于
  /// 08-16，即保留窗口只有两天）。手机上进程在后台活了几天再点安装，快照里的
  /// **每一条**直链都指向已删除的 tag——用户看到的就是 `STORE_HTTP_404`。
  ///
  /// 同一份快照还会让版本号漂移变成 `METADATA_MISMATCH`（下载到的 APK 比快照新，
  /// 被当成「与仓库元数据不符」拒掉）。两个症状同一个根因：**下载时刻的真相源
  /// 是索引，不是几天前的快照**。所以这里不是「404 了再重试一次」的补丁，而是把安装
  /// 的输入从快照换成当次索引。
  ///
  /// 刷不到索引就直接失败，不回退到快照：下一步本来就要联网下 APK，「索引拿不到
  /// 却假装能装」只会把同一个 404 推到下一步，还多一条分支。
  Future<MihonAvailableExtension> _resolveInstallTarget(
    MangaExtensionStoreRow store,
    MihonAvailableExtension snapshot, {
    required bool allowInsecure,
  }) async {
    final MihonStoreFetchResult fetched = await _storeClient.fetchStore(
      store.indexUrl,
      allowInsecure: allowInsecure,
    );
    final MihonStore resolved = fetched.store!;
    final List<MihonAvailableExtension> extensions =
        await _storeClient.fetchExtensions(
      resolved,
      allowInsecure: allowInsecure,
    );
    // 索引都重新拉了，顺手让目录跟上：卡片上的版本号不该跟马上要装的东西对不上。
    // `index_v2` 会让最终 indexUrl 与库里那行不同，两个地址的旧条目都要清。
    available = <MihonAvailableExtension>[
      ...available.where((MihonAvailableExtension item) =>
          item.storeUrl != store.indexUrl &&
          item.storeUrl != resolved.indexUrl),
      ...extensions,
    ];
    _notify();
    final MihonAvailableExtension? target = extensions
        .where((MihonAvailableExtension item) =>
            item.packageName == snapshot.packageName)
        .firstOrNull;
    if (target == null) {
      throw const MihonRuntimeException(
        'EXTENSION_GONE',
        'The extension is no longer listed in its repository',
      );
    }
    return target;
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

  /// 丢弃一个没有走到 [commitInstall] 的安装提案。
  ///
  /// [prepareStoreInstall] / [prepareLocalInstall] 成功后 APK 已经落在 `tmp/`，
  /// 用户在签名确认框点取消时那份文件就没人认领了（最大 100 MiB）。
  /// [_clearStagedApks] 会在下次启动兜底，但当场删掉才是对的。
  Future<void> discardProposal(MihonInstallProposal proposal) async {
    final File temp = File(proposal.tempPath);
    if (await temp.exists()) await temp.delete();
  }

  /// 开一次「装之前先看看这个源有什么漫画」的试用预览。
  ///
  /// Mihon 扩展是**代码**不是配置——站点怎么解析、封面在哪、翻页规则全在 APK 里，
  /// 所以预览内容必然要真跑它的代码。预览与安装的差别因此不在「有没有执行」，
  /// 而在**有没有在库里留下痕迹**：
  /// - 不写 `manga_extensions` / `manga_online_sources`，所以它不进已安装列表、
  ///   不出现在「浏览」视图、不参与任何续读；
  /// - 不把签名指纹写进受信任表（只有 [commitInstall] 才写）；
  /// - 放弃时把落地的文件删干净。
  ///
  /// 平台差异只在「代码从哪加载」：桌面 sidecar 直接吃任意路径的 APK 字节，
  /// staged 的临时文件就能跑；Android 的 `invoke` 只认 `filesDir/exts/<pkg>.ext`
  /// （Dart 传过去的 `apkPath` 在那条路径上是死字段），所以必须先
  /// [MihonRuntime.installPrivateExtension] 把文件放进私有目录——**那一步只是文件
  /// 落地，不构成本类意义上的「安装」**。
  ///
  /// 只对**未安装**的扩展开放：Android 的 native install 会覆盖 `exts/` 里同包名
  /// 的文件，对已装扩展做预览等于拿未经确认的版本顶掉用户正在用的那份。已装的
  /// 扩展本来就能从「浏览」进去看，不需要预览。
  Future<MihonPreviewSession> beginPreview(
    MihonInstallProposal proposal,
  ) async {
    if (proposal.current != null) {
      throw const MihonRuntimeException(
        'PREVIEW_ALREADY_INSTALLED',
        'Preview is only available for extensions that are not installed',
      );
    }
    final String packageName = proposal.inspection.packageName;
    if (_activePreviewPackage != null) {
      throw const MihonRuntimeException(
        'PREVIEW_IN_PROGRESS',
        'Another extension preview is already active',
      );
    }
    _activePreviewPackage = packageName;
    late final MihonPreviewSession session;
    try {
      await _guarded(() async {
        // 标记先于文件落地写：崩溃留下的孤儿只能靠它认出来（见 _recoverAbandonedPreview）。
        await _writePreviewMarker(packageName);
        try {
          final String runtimePath = Platform.isAndroid
              ? await runtime.installPrivateExtension(proposal.tempPath)
              : proposal.tempPath;
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
          session = MihonPreviewSession(
            proposal: proposal,
            extension: extension,
            sources: loaded,
          );
        } catch (_) {
          await _discardPreview(packageName, tempPath: proposal.tempPath);
          rethrow;
        }
      });
    } catch (_) {
      _activePreviewPackage = null;
      rethrow;
    }
    return session;
  }

  /// 结束预览。
  ///
  /// [keep] 为 true 表示用户看完决定装：落地的文件留给 [commitInstall] 复用
  /// （Android 上它已经在 `exts/` 里，桌面上 temp 文件还等着被 rename 过去），
  /// 这里只清运行时的已加载缓存，让安装后重新加载到同一份文件。
  /// 为 false 则把预览留下的一切删干净。
  Future<void> endPreview(
    MihonPreviewSession session, {
    required bool keep,
  }) async {
    final String packageName = session.proposal.inspection.packageName;
    try {
      if (keep) {
        await runtime.invalidateExtension(packageName);
        await _clearPreviewMarker();
        return;
      }
      await _guarded(
        () => _discardPreview(
          packageName,
          tempPath: session.proposal.tempPath,
        ),
      );
    } finally {
      if (_activePreviewPackage == packageName) {
        _activePreviewPackage = null;
      }
    }
  }

  Future<void> _discardPreview(
    String packageName, {
    required String tempPath,
  }) async {
    await runtime.invalidateExtension(packageName);
    if (Platform.isAndroid) {
      await runtime.uninstallPrivateExtension(packageName);
    }
    final File temp = File(tempPath);
    if (await temp.exists()) await temp.delete();
    await _clearPreviewMarker();
  }

  File get _previewMarker =>
      File(p.join(rootDirectory.path, 'tmp', 'preview-pending'));

  Future<void> _writePreviewMarker(String packageName) async {
    await _previewMarker.parent.create(recursive: true);
    await _previewMarker.writeAsString(packageName, flush: true);
  }

  Future<void> _clearPreviewMarker() async {
    if (await _previewMarker.exists()) await _previewMarker.delete();
  }

  /// 预览期间进程被杀，会在 Android 私有目录里留下一个没有任何 DB 记录的孤儿
  /// 扩展文件。它不会出现在任何列表里（列表读 DB），但会占空间，而且下次预览同
  /// 一个包时 native 的 install 会走「升级」分支去比对签名版本号，行为不可预期。
  ///
  /// 桌面端不需要动 runtime：那边预览用的是 `tmp/*.apk.part`，由 [_clearStagedApks]
  /// 统一清理，没有任何东西被放进常驻目录。
  Future<void> _recoverAbandonedPreview() async {
    if (!await _previewMarker.exists()) return;
    try {
      final String packageName = (await _previewMarker.readAsString()).trim();
      final bool reallyInstalled = installed.any(
        (MangaExtensionRow row) => row.packageName == packageName,
      );
      if (Platform.isAndroid && packageName.isNotEmpty && !reallyInstalled) {
        await runtime.invalidateExtension(packageName);
        await runtime.uninstallPrivateExtension(packageName);
      }
    } on Object {
      // 清不掉不能挡住整个扩展子系统启动：孤儿文件只占空间，不影响正确性。
    }
    await _clearPreviewMarker();
  }

  /// 清掉上次进程留下的半成品 APK。
  ///
  /// `tmp/extension-<sha>.apk.part` 是 [_prepareInstallBytes] 的落脚点，正常路径
  /// 上一定会被 [commitInstall] rename 掉或被失败分支删掉，只有进程在中途被杀才
  /// 会留下。它们没有任何长期意义，且每个最大 100 MiB。
  Future<void> _clearStagedApks() async {
    final Directory tmp = Directory(p.join(rootDirectory.path, 'tmp'));
    if (!await tmp.exists()) return;
    try {
      await for (final FileSystemEntity entity in tmp.list()) {
        if (entity is File && entity.path.endsWith('.apk.part')) {
          await entity.delete();
        }
      }
    } on Object {
      // 同上：清理是尽力而为，不能让它挡住启动。
    }
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

/// 一次进行中的扩展试用预览。
///
/// 持有 staged（已落地但未登记入库）的扩展引用和它暴露出来的源列表。生命周期由
/// [MihonManager.beginPreview] / [MihonManager.endPreview] 成对管理——**不要**自己
/// 拿 [extension] 去调 [MihonManager.commitInstall] 之外的写库路径，那会绕过
/// 「预览不留痕迹」的不变量。
@immutable
class MihonPreviewSession {
  const MihonPreviewSession({
    required this.proposal,
    required this.extension,
    required this.sources,
  });

  final MihonInstallProposal proposal;
  final MihonExtensionRef extension;
  final List<MihonSource> sources;

  /// 把预览里的某个源包装成浏览页能直接吃的上下文。
  ///
  /// 偏好恒为空：源偏好落在 `manga_source_preferences` 表且以
  /// `(extensionPackage, sourceId)` 为键，而预览的扩展根本没进库——读它只会拿到
  /// 空表，写它则会留下指向不存在扩展的孤儿行。预览就用扩展的内置默认值。
  MihonSourceContext contextFor(MihonSource source) => MihonSourceContext(
        extension: extension,
        source: source,
        preferences: const <MihonPreference>[],
      );
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
