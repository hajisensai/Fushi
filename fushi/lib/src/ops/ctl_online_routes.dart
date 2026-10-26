import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        EpubBookRow,
        MangaDownloadJobRow,
        MangaDownloadJobStatus,
        MangaExtensionRow,
        MangaExtensionStoreRow,
        MangaOnlineSourceRow;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart'
    show ExternalProviderFailure;
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show resolveSubtitleDownloadLanguage;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        RemoteVideoInfo,
        videoRemotePositionEpisodeAtPrefKey,
        videoRemotePositionEpisodePrefKey;

import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_updates.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show fushiBooksProvider, srtBooksProvider;
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/media/video/online/video_online_sources_gate.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart'
    show startDiscoveryItemDownload;
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeActiveTabs, homeShellTabNotifier;
import 'package:fushi/src/ops/ctl_ai_download_routes.dart';
import 'package:fushi/src/ops/ctl_online_downloads.dart';
import 'package:fushi/src/ops/ctl_online_filters.dart';
import 'package:fushi/src/ops/ctl_online_support.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/media/video/video_library_delete.dart'
    show VideoLibraryDeleteResult;
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart'
    show
        canDeleteCompletedDownloadFiles,
        deleteCompletedInterconnectDownloadFiles;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/utils.dart' show createAppHttpClient, t;

/// online 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/online_commands.dart`）。
///
/// 五组：扩展（`/extensions`）、在线源（`/sources`）、发现（`/discovery`）、
/// 播放遥控（`/playback`）、页面导航（`/navigation`）。每条路由只调 app 里 UI
/// 按钮背后的那个现成方法，门控与 UI 同一判据（合规门 + 平台宿主门）。
List<CtlRoute> buildOnlineCtlRoutes(OpContext context) {
  final _OnlineCtl ctl = _OnlineCtl(context);
  return <CtlRoute>[
    // ── 扩展仓库 / 扩展 ───────────────────────────────────────────────────
    CtlRoute.get('/api/admin/extensions/repos', ctl.listRepos),
    CtlRoute.post('/api/admin/extensions/repos', ctl.addRepo),
    CtlRoute.delete('/api/admin/extensions/repos', ctl.removeRepo),
    CtlRoute.post('/api/admin/extensions/repos/sync', ctl.syncRepos),
    CtlRoute.get('/api/admin/extensions', ctl.listExtensions),
    CtlRoute.post('/api/admin/extensions/install', ctl.installExtension),
    CtlRoute.post('/api/admin/extensions/update', ctl.updateExtensions),
    CtlRoute.delete('/api/admin/extensions/:id', ctl.removeExtension),
    CtlRoute.post('/api/admin/extensions/:id/enabled', ctl.setExtensionEnabled),
    // ── 在线源 ────────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/sources', ctl.listSources),
    CtlRoute.get('/api/admin/sources/:sourceId/search', ctl.searchSource),
    CtlRoute.get('/api/admin/sources/:sourceId/work', ctl.getWork),
    CtlRoute.post('/api/admin/sources/:sourceId/library', ctl.addWork),
    CtlRoute.post('/api/admin/sources/:sourceId/downloads', ctl.downloadWork),
    CtlRoute.get('/api/admin/online/tasks', ctl.listTasks),
    CtlRoute.get('/api/admin/online/tasks/:id', ctl.getTask),
    CtlRoute.post('/api/admin/online/tasks/:id/cancel', ctl.cancelTask),
    // ── 在线源下载任务：漫画章节队列 / 视频源剧集 ──────────────────────────
    CtlRoute.get('/api/admin/online/manga-downloads', ctl.listMangaDownloads),
    CtlRoute.delete(
      '/api/admin/online/manga-downloads',
      ctl.clearMangaDownloads,
    ),
    CtlRoute.post(
      '/api/admin/online/manga-downloads/:id/cancel',
      ctl.cancelMangaDownload,
    ),
    CtlRoute.post(
      '/api/admin/online/manga-downloads/:id/retry',
      ctl.retryMangaDownload,
    ),
    CtlRoute.delete(
      '/api/admin/online/manga-downloads/:id',
      ctl.removeMangaDownload,
    ),
    CtlRoute.get(
      '/api/admin/online/episode-downloads',
      ctl.listEpisodeDownloads,
    ),
    CtlRoute.get(
      '/api/admin/online/episode-downloads/:id',
      ctl.getEpisodeDownload,
    ),
    CtlRoute.post(
      '/api/admin/online/episode-downloads/:id/pause',
      ctl.pauseEpisodeDownload,
    ),
    CtlRoute.post(
      '/api/admin/online/episode-downloads/:id/resume',
      ctl.resumeEpisodeDownload,
    ),
    CtlRoute.delete(
      '/api/admin/online/episode-downloads/:id',
      ctl.removeEpisodeDownload,
    ),
    CtlRoute.post(
      '/api/admin/sources/:sourceId/settings',
      ctl.setSourceSettings,
    ),
    CtlRoute.get(
      '/api/admin/sources/:sourceId/preferences',
      ctl.listPreferences,
    ),
    CtlRoute.post(
      '/api/admin/sources/:sourceId/preferences',
      ctl.setPreference,
    ),
    CtlRoute.delete('/api/admin/sources/:sourceId/data', ctl.clearSourceData),
    CtlRoute.get('/api/admin/sources/:sourceId/filters', ctl.listFilters),
    CtlRoute.post('/api/admin/sources/:sourceId/browse', ctl.browseSource),
    // ── 发现 ──────────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/discovery/sources', ctl.listDiscoverySources),
    CtlRoute.get('/api/admin/discovery/search', ctl.searchDiscovery),
    CtlRoute.post('/api/admin/discovery/acquire', ctl.acquireDiscovery),
    // ── 播放遥控 ──────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/playback', ctl.playbackStatus),
    CtlRoute.post('/api/admin/playback/control', ctl.playbackControl),
    CtlRoute.post('/api/admin/playback/seek', ctl.playbackSeek),
    CtlRoute.post('/api/admin/playback/rate', ctl.playbackRate),
    // ── 页面导航 ──────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/navigation', ctl.listNavigation),
    CtlRoute.post('/api/admin/navigation', ctl.navigate),
    // ── AI 下载会话 ───────────────────────────────────────────────────────
    ...buildAiDownloadCtlRoutes(context),
  ];
}

/// 发现结果暂存（进程内，见 [CtlDiscoveryResultCache]）。
final CtlDiscoveryResultCache<DiscoveryResourceItem> _discoveryResults =
    CtlDiscoveryResultCache<DiscoveryResourceItem>();

class _OnlineCtl {
  _OnlineCtl(this.context);

  final OpContext context;

  AppModel get appModel => context.appModel;

  // ── 门控与 manager ──────────────────────────────────────────────────────

  /// 与 UI 同一判据：合规门（[StoreRestrictedCapability]）+ 宿主平台门。
  void _requireKind(OnlineCtlKind kind) {
    switch (kind) {
      case OnlineCtlKind.manga:
        if (!StoreRestrictedCapability.onlineMangaSource.isAvailable) {
          throw const CtlFailure.rejected('本平台构建不提供在线漫画源（商店合规）');
        }
        if (!MihonRuntimeFactory.isSupported) {
          throw const CtlFailure.unsupported('本平台没有 Mihon 扩展宿主');
        }
      case OnlineCtlKind.anime:
        if (!StoreRestrictedCapability.onlineVideoSource.isAvailable) {
          throw const CtlFailure.rejected('本平台构建不提供在线视频源（商店合规）');
        }
        if (!isVideoOnlineSourcesAvailable) {
          throw const CtlFailure.unsupported('本平台没有 Aniyomi 扩展宿主');
        }
      case OnlineCtlKind.novel:
        if (!StoreRestrictedCapability.onlineNovelSource.isAvailable) {
          throw const CtlFailure.rejected('本平台构建不提供在线小说源（商店合规）');
        }
        if (!isNovelOnlineSourcesAvailable) {
          throw const CtlFailure.unsupported('本平台没有 LNReader 插件运行时');
        }
    }
  }

  OnlineCtlKind _kind(CtlCall call) {
    final OnlineCtlKind kind = OnlineCtlKind.parse(call.optString('kind'));
    _requireKind(kind);
    return kind;
  }

  /// 取 Mihon manager 并等初始化（与扩展页 `unawaited(manager.initialise())` 同一入口）。
  ///
  /// 初始化里的仓库目录刷新失败只记在 `manager.error`，本地已装扩展照常可用——
  /// 扩展页对同一失败也只是在页头显示错误，不挡已装源。
  Future<MihonManager> _mihon(OnlineCtlKind kind) async {
    final MihonManager manager = kind == OnlineCtlKind.anime
        ? appModel.animeMihonManager
        : appModel.mihonManager;
    try {
      await manager.initialise();
    } on Object {
      // 见方法注释：错误已落 manager.error。
    }
    return manager;
  }

  Future<LnReaderManager> _lnReader() async {
    final LnReaderManager manager = appModel.lnReaderManager;
    await manager.initialise();
    return manager;
  }

  bool _confirmed(CtlCall call) => call.optBool('confirm') == true;

  void _requireConfirm(CtlCall call, String what) {
    if (!_confirmed(call)) {
      throw CtlFailure.badRequest('$what 是破坏性操作，需要 confirm=true');
    }
  }

  // ── 扩展仓库 ────────────────────────────────────────────────────────────

  Future<Object?> listRepos(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      return <String, Object?>{
        'kind': kind.name,
        'repos': <Map<String, Object?>>[
          for (final LnReaderStore store in manager.stores)
            <String, Object?>{
              'url': store.indexUrl,
              'name': store.name,
              'lastError': store.lastError,
            },
        ],
      };
    }
    final MihonManager manager = await _mihon(kind);
    return <String, Object?>{
      'kind': kind.name,
      'error': manager.error,
      'repos': <Map<String, Object?>>[
        for (final MangaExtensionStoreRow store in manager.stores)
          <String, Object?>{
            'url': store.indexUrl,
            'name': store.name,
            'enabled': store.enabled,
            'lastSyncAt': store.lastSyncAt,
            'lastError': store.lastError,
          },
      ],
    };
  }

  Future<Object?> addRepo(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String url = call.requireString('url');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      if (LnReaderManager.normaliseStoreUrl(url) == null) {
        throw CtlFailure.badRequest('仓库地址必须是 http(s)：$url');
      }
      await manager.addStore(url);
      return <String, Object?>{'kind': kind.name, 'url': url};
    }
    // 明文仓库：扩展页要用户在确认框里显式同意（_confirmInsecureUrl），这里对应
    // `allowInsecure: true`；没给就拒，不替用户放行。
    final bool insecure = Uri.tryParse(url)?.scheme == 'http';
    if (insecure && call.optBool('allowInsecure') != true) {
      throw CtlFailure.rejected('仓库是明文 http：确认信任后加 --insecure 重试（$url）');
    }
    final MihonManager manager = await _mihon(kind);
    await _mihonErrors(() => manager.addStore(url, allowInsecure: insecure));
    return <String, Object?>{'kind': kind.name, 'url': url};
  }

  Future<Object?> removeRepo(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String url = call.requireString('url');
    _requireConfirm(call, '删除仓库');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderStore? store = manager.stores
          .where((LnReaderStore s) => s.indexUrl == url)
          .firstOrNull;
      if (store == null) throw CtlFailure.notFound('没有这个仓库：$url');
      await manager.removeStore(store);
      return null;
    }
    final MihonManager manager = await _mihon(kind);
    if (!manager.stores.any((MangaExtensionStoreRow s) => s.indexUrl == url)) {
      throw CtlFailure.notFound('没有这个仓库：$url');
    }
    await _mihonErrors(() => manager.removeStore(url));
    return null;
  }

  Future<Object?> syncRepos(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      await manager.refreshStores();
      return <String, Object?>{
        'kind': kind.name,
        'available': manager.available.length,
        'errors': <String, String>{
          for (final LnReaderStore s in manager.stores)
            if (s.lastError != null) s.indexUrl: s.lastError!,
        },
      };
    }
    final MihonManager manager = await _mihon(kind);
    await _mihonErrors(manager.refreshStores);
    return <String, Object?>{
      'kind': kind.name,
      'available': manager.available.length,
      'errors': <String, String>{
        for (final MangaExtensionStoreRow s in manager.stores)
          if (s.lastError != null) s.indexUrl: s.lastError!,
      },
    };
  }

  // ── 扩展 ────────────────────────────────────────────────────────────────

  Future<Object?> listExtensions(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final bool withAvailable = call.optBool('available') ?? false;
    final String? query = call.optString('query')?.toLowerCase();
    final String? lang = call.optString('lang')?.toLowerCase();
    bool matches(String name, String id, String language) =>
        (query == null ||
            name.toLowerCase().contains(query) ||
            id.toLowerCase().contains(query)) &&
        (lang == null || language.toLowerCase().split(',').contains(lang));
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final Set<String> updatable = <String>{
        for (final LnReaderRepoPlugin p in manager.available)
          if (manager.hasUpdate(p)) p.id,
      };
      return <String, Object?>{
        'kind': kind.name,
        'installed': <Map<String, Object?>>[
          for (final LnReaderInstalledPlugin p in manager.installed)
            if (matches(p.name, p.id, p.lang))
              <String, Object?>{
                'id': p.id,
                'name': p.name,
                'version': p.version,
                'lang': p.lang,
                'site': p.site,
                'enabled': p.enabled,
                'hasUpdate': updatable.contains(p.id),
              },
        ],
        if (withAvailable)
          'available': <Map<String, Object?>>[
            for (final LnReaderRepoPlugin p in manager.available)
              if (matches(p.name, p.id, p.lang))
                <String, Object?>{
                  'id': p.id,
                  'name': p.name,
                  'version': p.version,
                  'lang': p.lang,
                  'site': p.site,
                  'repo': p.storeUrl,
                  'installed': manager.installedById(p.id) != null,
                  'downloads': p.downloadCount,
                },
          ],
      };
    }
    final MihonManager manager = await _mihon(kind);
    final Map<String, MihonExtensionUpdate> updates =
        <String, MihonExtensionUpdate>{
          for (final MihonExtensionUpdate u in mihonExtensionUpdates(
            available: manager.available,
            installed: manager.installed,
          ))
            u.packageName: u,
        };
    final Set<String> installedPackages = <String>{
      for (final MangaExtensionRow row in manager.installed) row.packageName,
    };
    return <String, Object?>{
      'kind': kind.name,
      'error': manager.error,
      'installed': <Map<String, Object?>>[
        for (final MangaExtensionRow row in manager.installed)
          if (matches(row.name, row.packageName, row.language))
            <String, Object?>{
              'id': row.packageName,
              'name': row.name,
              'version': row.versionName,
              'lang': row.language,
              'lib': row.libVersion,
              'enabled': row.enabled,
              'hasUpdate': updates.containsKey(row.packageName),
              if (updates[row.packageName] case final MihonExtensionUpdate u)
                'updateVersion': u.available.versionName,
            },
      ],
      if (withAvailable)
        'available': <Map<String, Object?>>[
          for (final MihonAvailableExtension e in manager.available)
            if (matches(e.name, e.packageName, e.language))
              <String, Object?>{
                'id': e.packageName,
                'name': e.name,
                'version': e.versionName,
                'lang': e.language,
                'lib': e.libVersion,
                'nsfw': e.contentWarning > 0,
                'repo': e.storeUrl,
                'installed': installedPackages.contains(e.packageName),
                'downloads': e.downloadCount,
              },
        ],
    };
  }

  Future<Object?> installExtension(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String id = call.requireString('id');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderRepoPlugin plugin = _lnReaderAvailable(manager, id);
      if (manager.isBusy(id)) throw CtlFailure.conflict('$id 正在安装');
      await manager.install(plugin);
      return <String, Object?>{
        'kind': kind.name,
        'id': id,
        'version': plugin.version,
      };
    }
    final MihonManager manager = await _mihon(kind);
    final MihonAvailableExtension target = _mihonAvailable(manager, id);
    if (!manager.tryBeginExtensionAction(id)) {
      throw CtlFailure.conflict('$id 正在安装或卸载');
    }
    try {
      // 与扩展页 `_install` 同一条：下载 + 校验 → 签名确认 → commit。签名确认在
      // CLI 上是显式的 `trustSigner`：没信任过的签名不替用户点「信任」。
      final MihonInstallProposal proposal = await _mihonErrors(
        () => manager.prepareStoreInstall(target),
      );
      final bool trust = call.optBool('trustSigner') ?? false;
      if (!proposal.signerTrusted && !trust) {
        await manager.discardProposal(proposal);
        throw CtlFailure.rejected(
          '签名者尚未受信任（${proposal.inspection.name}，SHA-256 '
          '${proposal.inspection.signerSha256}）；核对后加 --trust-signer 重试',
        );
      }
      try {
        await _mihonErrors(
          () => manager.commitInstall(proposal, trustSigner: trust),
        );
      } on Object {
        await manager.discardProposal(proposal);
        rethrow;
      }
      return <String, Object?>{
        'kind': kind.name,
        'id': id,
        'version': proposal.inspection.versionName,
        'signer': proposal.inspection.signerSha256,
      };
    } finally {
      manager.endExtensionAction(id);
    }
  }

  Future<Object?> updateExtensions(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String? id = call.optString('id');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final List<LnReaderRepoPlugin> targets = <LnReaderRepoPlugin>[
        for (final LnReaderRepoPlugin p in manager.available)
          if (manager.hasUpdate(p) && (id == null || p.id == id)) p,
      ];
      final List<String> updated = <String>[];
      final Map<String, String> failed = <String, String>{};
      for (final LnReaderRepoPlugin plugin in targets) {
        try {
          await manager.install(plugin);
          updated.add(plugin.id);
        } on Object catch (error) {
          failed[plugin.id] = '$error';
        }
      }
      return <String, Object?>{
        'kind': kind.name,
        'installed': updated,
        'skipped': const <String>[],
        'failed': failed,
      };
    }
    final MihonManager manager = await _mihon(kind);
    final List<MihonAvailableExtension> targets = <MihonAvailableExtension>[
      for (final MihonExtensionUpdate u in mihonExtensionUpdates(
        available: manager.available,
        installed: manager.installed,
      ))
        if (id == null || u.packageName == id) u.available,
    ];
    if (id != null &&
        targets.isEmpty &&
        !manager.installed.any((MangaExtensionRow r) => r.packageName == id)) {
      throw CtlFailure.notFound('没有安装这个扩展：$id');
    }
    // 与扩展页「一键更新」同一调用：签名换了的那条落进 failed（SIGNER_NOT_TRUSTED），
    // 不顺手信任新签名——要升级它得走单条 `ext install --trust-signer`。
    final MihonBulkInstallReport report = await manager.installMany(
      targets,
      trustSigner: false,
      upgrade: true,
    );
    return <String, Object?>{
      'kind': kind.name,
      'installed': report.installed,
      'skipped': report.skipped,
      'failed': report.failed,
    };
  }

  Future<Object?> removeExtension(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String id = call.params['id']!;
    _requireConfirm(call, '卸载扩展');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin? plugin = manager.installedById(id);
      if (plugin == null) throw CtlFailure.notFound('没有安装这个插件：$id');
      // 与 Mihon 同口径：默认保留插件存储（登录态），clearData=true 才删。
      await manager.uninstall(
        plugin,
        clearData: call.optBool('clearData') ?? false,
      );
      return null;
    }
    final MihonManager manager = await _mihon(kind);
    final MangaExtensionRow? row = manager.installed
        .where((MangaExtensionRow r) => r.packageName == id)
        .firstOrNull;
    if (row == null) throw CtlFailure.notFound('没有安装这个扩展：$id');
    if (!manager.tryBeginExtensionAction(id)) {
      throw CtlFailure.conflict('$id 正在安装或卸载');
    }
    try {
      await _mihonErrors(
        () => manager.uninstallExtension(
          row,
          clearData: call.optBool('clearData') ?? false,
        ),
      );
    } finally {
      manager.endExtensionAction(id);
    }
    return null;
  }

  LnReaderRepoPlugin _lnReaderAvailable(LnReaderManager manager, String id) {
    final LnReaderRepoPlugin? plugin = manager.available
        .where((LnReaderRepoPlugin p) => p.id == id)
        .lastOrNull;
    if (plugin == null) {
      throw CtlFailure.notFound(
        '仓库目录里没有插件 $id（先 `ext repo sync --kind novel`）',
      );
    }
    return plugin;
  }

  /// 同包多仓库时取版本最高的那条（与「有更新」角标同一口径）。
  MihonAvailableExtension _mihonAvailable(MihonManager manager, String id) {
    MihonAvailableExtension? best;
    for (final MihonAvailableExtension e in manager.available) {
      if (e.packageName != id) continue;
      if (best == null || e.extensionVersionCode > best.extensionVersionCode) {
        best = e;
      }
    }
    if (best == null) {
      throw CtlFailure.notFound('仓库目录里没有扩展 $id（先 `ext repo sync`，或检查 --kind）');
    }
    return best;
  }

  /// Mihon 运行时错误（稳定错误码）转成 422，别让它们变成 500。
  Future<T> _mihonErrors<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on MihonRuntimeException catch (error) {
      throw CtlFailure.rejected('${error.code}: ${error.message}');
    }
  }

  // ── 在线源 ──────────────────────────────────────────────────────────────

  Future<Object?> listSources(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      return <String, Object?>{
        'kind': kind.name,
        'sources': <Map<String, Object?>>[
          for (final LnReaderInstalledPlugin p in manager.installed)
            <String, Object?>{
              'id': p.id,
              'name': p.name,
              'lang': p.lang,
              'site': p.site,
              'enabled': p.enabled,
              'pinned': p.pinned,
            },
        ],
      };
    }
    final MihonManager manager = await _mihon(kind);
    final Set<String> enabled = <String>{
      for (final MangaOnlineSourceRow row in enabledMangaOnlineSources(manager))
        _mihonSourceKey(row),
    };
    return <String, Object?>{
      'kind': kind.name,
      'sources': <Map<String, Object?>>[
        for (final MangaOnlineSourceRow row in manager.sources)
          <String, Object?>{
            'id': row.sourceId,
            'name': row.name,
            'lang': row.language,
            'extension': row.extensionPackage,
            'baseUrl': row.baseUrl,
            'enabled': enabled.contains(_mihonSourceKey(row)),
            'pinned': row.pinned,
          },
      ],
    };
  }

  static String _mihonSourceKey(MangaOnlineSourceRow row) =>
      '${row.extensionPackage}:${row.sourceId}';

  /// `sourceId` 或 `扩展包名:sourceId`（同一 sourceId 出现在多个扩展里时用后者）。
  /// 只认已启用的源：停用的源在 UI 里也进不去。
  MangaOnlineSourceRow _mihonSourceRow(MihonManager manager, String raw) {
    final MangaOnlineSourceRow row = _mihonSourceRowAny(manager, raw);
    if (!enabledMangaOnlineSources(manager).any(
      (MangaOnlineSourceRow r) => _mihonSourceKey(r) == _mihonSourceKey(row),
    )) {
      throw CtlFailure.rejected('源 $raw 或其扩展已停用');
    }
    return row;
  }

  /// 同 [_mihonSourceRow]，但不看启用状态（启停 / 置顶 / 偏好这些管理动作用）。
  MangaOnlineSourceRow _mihonSourceRowAny(MihonManager manager, String raw) {
    final int split = raw.lastIndexOf(':');
    final String? package = split > 0 ? raw.substring(0, split) : null;
    final String sourceId = split > 0 ? raw.substring(split + 1) : raw;
    final List<MangaOnlineSourceRow> hits = <MangaOnlineSourceRow>[
      for (final MangaOnlineSourceRow row in manager.sources)
        if (row.sourceId == sourceId &&
            (package == null || row.extensionPackage == package))
          row,
    ];
    if (hits.isEmpty) throw CtlFailure.notFound('没有这个在线源：$raw');
    if (hits.length > 1) {
      throw CtlFailure.badRequest(
        '源 id $raw 有歧义，改用 <扩展包名>:<sourceId>：'
        '${hits.map(_mihonSourceKey).join(' / ')}',
      );
    }
    return hits.single;
  }

  Future<MihonSourceContext> _mihonContext(MihonManager manager, String raw) =>
      _mihonErrors(
        () => manager.contextForSource(_mihonSourceRow(manager, raw)),
      );

  LnReaderInstalledPlugin _lnReaderPlugin(LnReaderManager manager, String id) {
    final LnReaderInstalledPlugin? plugin = manager.installedById(id);
    if (plugin == null) throw CtlFailure.notFound('没有安装这个插件：$id');
    if (!plugin.enabled) throw CtlFailure.rejected('插件 $id 已停用');
    return plugin;
  }

  Future<Object?> searchSource(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final String query = call.requireString('q');
    final int page = call.optInt('page') ?? 1;
    if (page < 1) throw const CtlFailure.badRequest('page 从 1 开始');
    switch (kind) {
      case OnlineCtlKind.novel:
        final LnReaderManager manager = await _lnReader();
        final LnReaderInstalledPlugin plugin = _lnReaderPlugin(
          manager,
          sourceId,
        );
        await manager.load(plugin);
        final List<LnReaderNovelItem> items = await manager.runtime.search(
          plugin.id,
          query: query,
          page: page,
        );
        return <String, Object?>{
          'kind': kind.name,
          'source': plugin.id,
          'page': page,
          'items': <Map<String, Object?>>[
            for (final LnReaderNovelItem item in items)
              <String, Object?>{
                'url': item.path,
                'title': item.name,
                'cover': item.cover,
              },
          ],
        };
      case OnlineCtlKind.manga:
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        // 与源浏览页 `prepare` + `fetch` 同序：先取源的默认筛选器再搜。
        final List<MihonFilter> filters = await _mihonErrors(
          () => manager.runtime.getFilters(
            ctx.extension,
            ctx.source,
            preferences: ctx.preferences,
          ),
        );
        final MihonMangaPage result = await _mihonErrors(
          () => manager.runtime.search(
            ctx.extension,
            ctx.source,
            page: page,
            query: query,
            filters: filters,
            preferences: ctx.preferences,
          ),
        );
        return _catalogueJson(
          kind,
          sourceId,
          page,
          result.items,
          result.hasNextPage,
        );
      case OnlineCtlKind.anime:
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final List<MihonFilter> filters = await _mihonErrors(
          () => manager.animeRuntime.getAnimeFilters(
            ctx.extension,
            ctx.source,
            preferences: ctx.preferences,
          ),
        );
        final MihonAnimePage result = await _mihonErrors(
          () => manager.animeRuntime.searchAnime(
            ctx.extension,
            ctx.source,
            page: page,
            query: query,
            filters: filters,
            preferences: ctx.preferences,
          ),
        );
        return _catalogueJson(
          kind,
          sourceId,
          page,
          result.items,
          result.hasNextPage,
        );
    }
  }

  static Map<String, Object?> _catalogueJson(
    OnlineCtlKind kind,
    String sourceId,
    int page,
    List<MihonCatalogueEntry> items,
    bool hasNextPage,
  ) => <String, Object?>{
    'kind': kind.name,
    'source': sourceId,
    'page': page,
    'hasNextPage': hasNextPage,
    'items': <Map<String, Object?>>[
      for (final MihonCatalogueEntry item in items)
        <String, Object?>{
          'url': item.url,
          'title': item.title,
          'cover': item.coverUrl,
        },
    ],
  };

  /// 漫画作品：与作品页 / 「AI 下载」同一条——[MihonLibraryAdapter.refresh] 拉详情 + 章节。
  Future<OnlineMangaLibraryEntry> _fetchManga(
    MihonManager manager,
    MihonSourceContext ctx,
    String url,
  ) async {
    final OnlineMangaLibraryEntry seed = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: ctx.extension.packageName,
      sourceId: ctx.source.id,
      series: MihonLibraryAdapter.seriesOf(MihonManga(url: url, title: '')),
      chapters: const <OnlineMangaChapter>[],
    );
    final OnlineMangaRefreshResult refreshed = await _mihonErrors(
      () => MihonLibraryAdapter(manager, presetContext: ctx).refresh(seed),
    );
    return seed.copyWith(
      series: refreshed.series,
      chapters: refreshed.chapters,
    );
  }

  /// 视频作品：与 [AnimeSourceDetailPage] `_load` 同一条（详情 → 剧集 → 播放序）。
  /// 调用方负责 dispose 返回的 client。
  Future<AnimeSourceVideoClient> _fetchAnime(
    MihonManager manager,
    MihonSourceContext ctx,
    String url,
  ) async {
    final MihonAnime details = await _mihonErrors(
      () => manager.animeRuntime.getAnimeDetails(
        ctx.extension,
        ctx.source,
        MihonAnime(url: url, title: ''),
        preferences: ctx.preferences,
      ),
    );
    final MihonAnime anime = MihonAnime(
      url: url,
      title: '',
    ).mergedWithDetails(details);
    final List<MihonEpisode> episodes = await _mihonErrors(
      () => manager.animeRuntime.getEpisodes(
        ctx.extension,
        ctx.source,
        anime,
        preferences: ctx.preferences,
      ),
    );
    return AnimeSourceVideoClient(
      manager: manager,
      context: ctx,
      anime: anime,
      episodes: sortEpisodesForPlayback(episodes),
      subtitleLanguageResolver: () => resolveCtlSubtitleLanguage(appModel),
    );
  }

  /// 漫画章节的阅读序（旧 → 新）。源给的是新在前，与「下载全部」的 `.reversed` 同口径。
  static List<OnlineMangaChapter> _mangaReadingOrder(
    OnlineMangaLibraryEntry entry,
  ) => entry.chapters.reversed.toList(growable: false);

  Future<Object?> getWork(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final String url = call.requireString('url');
    switch (kind) {
      case OnlineCtlKind.novel:
        final LnReaderManager manager = await _lnReader();
        final LnReaderInstalledPlugin plugin = _lnReaderPlugin(
          manager,
          sourceId,
        );
        await manager.load(plugin);
        final LnReaderNovel novel = await manager.runtime.novel(plugin.id, url);
        final EpubBookRow? shelf = await _lnReaderLibrary(
          manager,
        ).findBook(plugin.id, novel.path);
        return <String, Object?>{
          'kind': kind.name,
          'source': plugin.id,
          'url': novel.path,
          'title': novel.name,
          'author': novel.author,
          'status': novel.status,
          'genres': novel.genres,
          'summary': novel.summary,
          'cover': novel.cover,
          'bookKey': shelf?.bookKey,
          'chapters': <Map<String, Object?>>[
            for (int i = 0; i < novel.chapters.length; i++)
              <String, Object?>{
                'index': i + 1,
                'name': novel.chapters[i].name,
                'url': novel.chapters[i].path,
                'released': novel.chapters[i].releaseTime,
              },
          ],
        };
      case OnlineCtlKind.manga:
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final OnlineMangaLibraryEntry entry = await _fetchManga(
          manager,
          ctx,
          url,
        );
        final EpubBookRow? shelf = await appModel
            .onlineMangaLibraryService(OnlineMangaRuntimeKind.mihon)
            .find(entry);
        final List<OnlineMangaChapter> chapters = _mangaReadingOrder(entry);
        return <String, Object?>{
          'kind': kind.name,
          'source': sourceId,
          'url': url,
          'title': entry.series.title,
          'author': entry.series.author,
          'summary': entry.series.description,
          'cover': entry.series.coverUrl,
          'bookKey': shelf?.bookKey,
          'chapters': <Map<String, Object?>>[
            for (int i = 0; i < chapters.length; i++)
              <String, Object?>{
                'index': i + 1,
                'name': chapters[i].name,
                'number': chapters[i].number,
                'locked': chapters[i].locked,
              },
          ],
        };
      case OnlineCtlKind.anime:
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final AnimeSourceVideoClient client = await _fetchAnime(
          manager,
          ctx,
          url,
        );
        try {
          final AnimeSourceEpisodeStatus status = await AnimeSourceLibrary(
            database: appModel.database,
          ).episodeStatus(client);
          final List<RemoteVideoInfo> videos = client.remoteVideos;
          return <String, Object?>{
            'kind': kind.name,
            'source': sourceId,
            'url': url,
            'title': client.anime.title,
            'author': client.anime.author,
            'summary': client.anime.description,
            'cover': client.anime.coverUrl,
            'episodes': <Map<String, Object?>>[
              for (int i = 0; i < videos.length; i++)
                <String, Object?>{
                  'index': i + 1,
                  'name': client.episodes[i].name,
                  'number': client.episodes[i].number,
                  'inLibrary': !status.missing.contains(videos[i].id),
                  'downloaded': status.downloaded.contains(videos[i].id),
                },
            ],
          };
        } finally {
          client.dispose();
        }
    }
  }

  LnReaderOnlineLibrary _lnReaderLibrary(LnReaderManager manager) =>
      LnReaderOnlineLibrary(
        manager: manager,
        database: appModel.database,
        download: _lnReaderDownload(manager),
      );

  LnReaderBookDownload _lnReaderDownload(LnReaderManager manager) =>
      LnReaderBookDownload(
        manager: manager,
        database: appModel.database,
        httpClientFactory: createAppHttpClient,
      );

  /// 书架列表随新书刷新（与小说作品页 `_ensureShelfBook` 同两条 invalidate）。
  void _refreshBookShelf() {
    context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    context.ref.invalidate(srtBooksProvider);
  }

  Future<Object?> addWork(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final String url = call.requireString('url');
    switch (kind) {
      case OnlineCtlKind.novel:
        // 作品页「加入书架」：占位 EPUB 入库，章节阅读时按需抓取。
        final LnReaderManager manager = await _lnReader();
        final LnReaderInstalledPlugin plugin = _lnReaderPlugin(
          manager,
          sourceId,
        );
        await manager.load(plugin);
        final LnReaderNovel novel = await manager.runtime.novel(plugin.id, url);
        if (novel.chapters.isEmpty) {
          throw const CtlFailure.rejected('作品没有章节，无法加入书架');
        }
        final String bookKey = await _lnReaderLibrary(manager).ensureBook(
          plugin: plugin,
          novel: novel,
          pendingText: t.novel_online_chapter_pending,
        );
        _refreshBookShelf();
        return <String, Object?>{
          'kind': kind.name,
          'bookKey': bookKey,
          'title': novel.name,
          'chapters': novel.chapters.length,
        };
      case OnlineCtlKind.manga:
        // 作品页「加入书架」：OnlineMangaLibraryService.add。
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final OnlineMangaLibraryEntry fetched = await _fetchManga(
          manager,
          ctx,
          url,
        );
        final EpubBookRow row = await appModel
            .onlineMangaLibraryService(OnlineMangaRuntimeKind.mihon)
            .add(fetched);
        return <String, Object?>{
          'kind': kind.name,
          'bookKey': row.bookKey,
          'title': fetched.series.title,
          'chapters': fetched.chapters.length,
        };
      case OnlineCtlKind.anime:
        // 作品页「加入媒体库」：每集一行在线行，归进作品合集。
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final AnimeSourceVideoClient client = await _fetchAnime(
          manager,
          ctx,
          url,
        );
        try {
          final int added = await AnimeSourceLibrary(
            database: appModel.database,
          ).addToLibrary(client);
          return <String, Object?>{
            'kind': kind.name,
            'title': client.anime.title,
            'added': added,
            'episodes': client.remoteVideos.length,
          };
        } finally {
          client.dispose();
        }
    }
  }

  Future<Object?> downloadWork(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final String url = call.requireString('url');
    final String? range = call.optString('chapters');
    switch (kind) {
      case OnlineCtlKind.novel:
        return _downloadNovel(sourceId, url, range);
      case OnlineCtlKind.manga:
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final OnlineMangaLibraryEntry fetched = await _fetchManga(
          manager,
          ctx,
          url,
        );
        // 与「AI 下载」/作品页「下载全部」同一服务：先进书架，再把选中的未锁章节入
        // 漫画下载队列（任务在「浏览 › 下载」可见可控）。
        final EpubBookRow row = await appModel
            .onlineMangaLibraryService(OnlineMangaRuntimeKind.mihon)
            .add(fetched);
        final OnlineMangaLibraryEntry entry =
            OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? fetched;
        final List<OnlineMangaChapter> ordered = _mangaReadingOrder(entry);
        final List<int> picked = parseCtlIndexRanges(range, ordered.length);
        final List<OnlineMangaChapter> pending = <OnlineMangaChapter>[
          for (final int i in picked)
            if (!ordered[i].locked) ordered[i],
        ];
        await appModel.mangaDownloadService.enqueueChapters(
          entry: entry,
          chapters: pending,
          autoOcr: appModel.mangaDownloadAutoOcr,
        );
        return <String, Object?>{
          'kind': kind.name,
          'bookKey': row.bookKey,
          'title': entry.series.title,
          'queued': pending.length,
          'lockedSkipped': picked.length - pending.length,
        };
      case OnlineCtlKind.anime:
        if (!StoreRestrictedCapability.downloads.isAvailable) {
          throw const CtlFailure.rejected('本平台构建不提供下载中心（商店合规）');
        }
        final MihonManager manager = await _mihon(kind);
        final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
        final AnimeSourceVideoClient client = await _fetchAnime(
          manager,
          ctx,
          url,
        );
        final List<RemoteVideoInfo> videos = client.remoteVideos;
        final List<int> picked;
        try {
          picked = parseCtlIndexRanges(range, videos.length);
        } on Object {
          client.dispose();
          rethrow;
        }
        final List<String> ids = <String>[
          for (final int i in picked) videos[i].id,
        ];
        // 作品页「下载」同一入口：交给 app 级下载管理器（任务在「浏览 › 下载」）。
        // 它在第一个 await 之前就用 copyForDownload 拿走了自己的副本，所以这份
        // template 可以随即释放（作品页退出时也是这样释放它的 client）。
        final Future<void> started = startAnimeEpisodeDownloads(
          manager: context.ref.read(interconnectDownloadManagerProvider),
          library: AnimeSourceLibrary(
            database: appModel.database,
            onlinePositionReader: (String id) =>
                readCtlAnimeOnlinePosition(appModel, id),
          ),
          template: client,
          episodeIds: ids,
        );
        client.dispose();
        unawaited(started);
        return <String, Object?>{
          'kind': kind.name,
          'title': client.anime.title,
          'queued': ids.length,
          // 任务键 = 剧集 id（`source anime-dl get/pause/resume/rm` 用）。
          'taskIds': ids,
          'episodes': <String>[for (final int i in picked) videos[i].title],
        };
    }
  }

  /// 小说整本下载：与作品页下载对话框同一个 [LnReaderBookDownload.run]，只是没有
  /// 对话框承载进度——放进 [CtlOnlineTaskRegistry]，用 `source task` 查。重名按
  /// 程序化入库口径留副本（[DuplicatePolicy.suffix]，与「加入书架」的占位书一致）。
  Future<Object?> _downloadNovel(
    String sourceId,
    String url,
    String? range,
  ) async {
    final LnReaderManager manager = await _lnReader();
    final LnReaderInstalledPlugin plugin = _lnReaderPlugin(manager, sourceId);
    await manager.load(plugin);
    final LnReaderNovel novel = await manager.runtime.novel(plugin.id, url);
    if (novel.chapters.isEmpty) {
      throw const CtlFailure.rejected('作品没有章节');
    }
    final List<int> picked = parseCtlIndexRanges(range, novel.chapters.length);
    final List<LnReaderChapter> chapters = <LnReaderChapter>[
      for (final int i in picked) novel.chapters[i],
    ];
    return startCtlNovelDownloadTask(
      download: _lnReaderDownload(manager),
      plugin: plugin,
      novel: novel,
      chapters: chapters,
      onShelfChanged: _refreshBookShelf,
    ).toJson();
  }

  Future<Object?> listTasks(CtlCall call) async => <String, Object?>{
    'tasks': <Map<String, Object?>>[
      for (final CtlOnlineTask task in CtlOnlineTaskRegistry.instance.tasks)
        task.toJson(),
    ],
  };

  Future<Object?> getTask(CtlCall call) async {
    final String id = call.params['id']!;
    final CtlOnlineTask? task = CtlOnlineTaskRegistry.instance.byId(id);
    if (task == null) throw CtlFailure.notFound('没有这个任务：$id');
    return task.toJson();
  }

  /// 取消 CLI 发起的小说下载：与下载对话框「取消」同一个检查点（章节之间）。
  Future<Object?> cancelTask(CtlCall call) async =>
      CtlOnlineTaskRegistry.instance.cancel(call.params['id']!).toJson();

  // ── 漫画章节下载队列（下载页「漫画」分区，MangaDownloadService）──────────

  void _requireMangaDownloads() {
    if (!StoreRestrictedCapability.onlineMangaSource.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供在线漫画源（商店合规）');
    }
  }

  Future<MangaDownloadJobRow> _requireMangaJob(String id) async {
    final MangaDownloadJobRow? row = await appModel.database
        .getMangaDownloadJob(id);
    if (row == null) throw CtlFailure.notFound('没有这个漫画下载任务：$id');
    return row;
  }

  Future<Object?> listMangaDownloads(CtlCall call) async {
    _requireMangaDownloads();
    final Set<String> statuses = call.stringList('status').toSet();
    final String? book = call.optString('book');
    final List<MangaDownloadJobRow> rows = await appModel.mangaDownloadService
        .listJobs(statuses: statuses);
    return <String, Object?>{
      'jobs': <Map<String, Object?>>[
        for (final MangaDownloadJobRow row in rows)
          if (book == null || row.bookKey == book) ctlMangaDownloadJobJson(row),
      ],
    };
  }

  /// 下载页漫画任务行「取消」：排队的直接改状态，正在下的中止并删半成品目录。
  Future<Object?> cancelMangaDownload(CtlCall call) async {
    _requireMangaDownloads();
    final String id = call.params['id']!;
    final MangaDownloadJobRow row = await _requireMangaJob(id);
    if (row.status != MangaDownloadJobStatus.queued &&
        row.status != MangaDownloadJobStatus.running) {
      throw CtlFailure.conflict('任务已结束，不能取消（当前：${row.status}）');
    }
    await appModel.mangaDownloadService.cancel(id);
    return ctlMangaDownloadJobJson(await _requireMangaJob(id));
  }

  /// 下载页漫画任务行「重试」：只对 failed / cancelled 成立。
  Future<Object?> retryMangaDownload(CtlCall call) async {
    _requireMangaDownloads();
    final String id = call.params['id']!;
    final MangaDownloadJobRow row = await _requireMangaJob(id);
    if (row.status != MangaDownloadJobStatus.failed &&
        row.status != MangaDownloadJobStatus.cancelled) {
      throw CtlFailure.conflict('只有失败 / 已取消的任务能重试（当前：${row.status}）');
    }
    await appModel.mangaDownloadService.retry(id);
    return ctlMangaDownloadJobJson(await _requireMangaJob(id));
  }

  /// 删任务行（正在下的先取消）；不删已下载的章节内容。
  Future<Object?> removeMangaDownload(CtlCall call) async {
    _requireMangaDownloads();
    final String id = call.params['id']!;
    _requireConfirm(call, '删除漫画下载任务');
    await _requireMangaJob(id);
    await appModel.mangaDownloadService.remove(id);
    return null;
  }

  /// 下载页「清除已完成」：删掉 done / failed / cancelled 的任务行。
  Future<Object?> clearMangaDownloads(CtlCall call) async {
    _requireMangaDownloads();
    if (call.optBool('finished') != true) {
      throw const CtlFailure.badRequest('只支持清除已结束的任务（finished=true）');
    }
    _requireConfirm(call, '清除已结束的漫画下载任务');
    await appModel.mangaDownloadService.clearFinished();
    return null;
  }

  // ── 视频源剧集下载（下载页「扩展源」分区，InterconnectDownloadManager）────

  InterconnectDownloadManager _episodeManager() {
    if (!StoreRestrictedCapability.downloads.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供下载中心（商店合规）');
    }
    return context.ref.read(interconnectDownloadManagerProvider);
  }

  Map<String, Object?> _episodeJson(
    InterconnectDownloadManager manager,
    InterconnectDownloadTask task,
  ) => ctlEpisodeDownloadTaskJson(
    task,
    canPause: manager.canPause(task.id),
    canRestart: manager.canRestart(task.id),
  );

  InterconnectDownloadTask _requireEpisode(
    InterconnectDownloadManager manager,
    String id,
  ) => manager.taskFor(id) ?? (throw CtlFailure.notFound('没有这个剧集下载任务：$id'));

  /// 缺省只列视频扩展源的剧集；`all=true` 连同互联设备 / 媒体服务器拉取的任务。
  Future<Object?> listEpisodeDownloads(CtlCall call) async {
    final InterconnectDownloadManager manager = _episodeManager();
    final bool all = call.optBool('all') ?? false;
    final List<InterconnectDownloadTask> tasks =
        manager.tasks.values
            .where(
              (InterconnectDownloadTask t) =>
                  all || t.origin == InterconnectDownloadOrigin.extension,
            )
            .toList()
          ..sort(
            (InterconnectDownloadTask a, InterconnectDownloadTask b) =>
                (b.startedAt ?? 0).compareTo(a.startedAt ?? 0),
          );
    return <String, Object?>{
      'tasks': <Map<String, Object?>>[
        for (final InterconnectDownloadTask t in tasks)
          _episodeJson(manager, t),
      ],
    };
  }

  Future<Object?> getEpisodeDownload(CtlCall call) async {
    final InterconnectDownloadManager manager = _episodeManager();
    return _episodeJson(manager, _requireEpisode(manager, call.params['id']!));
  }

  /// 下载页「暂停」：中止传输、保留 `.part`，之后 resume 续传。
  Future<Object?> pauseEpisodeDownload(CtlCall call) async {
    final InterconnectDownloadManager manager = _episodeManager();
    final String id = call.params['id']!;
    final InterconnectDownloadTask task = _requireEpisode(manager, id);
    if (!manager.canPause(id)) {
      throw CtlFailure.conflict('任务不能暂停（当前：${task.status.name}）');
    }
    manager.pause(id);
    return _episodeJson(manager, _requireEpisode(manager, id));
  }

  /// 下载页「继续」/「重试」：同一个 [InterconnectDownloadManager.resume]，它的
  /// future 要到任务结束才完成，所以不等；进度用 `source anime-dl get` 查。
  Future<Object?> resumeEpisodeDownload(CtlCall call) async {
    final InterconnectDownloadManager manager = _episodeManager();
    final String id = call.params['id']!;
    final InterconnectDownloadTask task = _requireEpisode(manager, id);
    if (!manager.canRestart(id)) {
      throw CtlFailure.conflict('任务不能继续（当前：${task.status.name}）');
    }
    unawaited(manager.resume(id));
    return _episodeJson(manager, _requireEpisode(manager, id));
  }

  /// 下载页「删除」：未完成任务 = 放弃（`deleteFiles` 时连 `.part` 删掉，否则只移出
  /// 列表、`.part` 留着续传）；已完成任务只清记录（成品删除走媒体库删除，那条链
  /// 还要处理库行与播放句柄）。在下的任务先暂停。
  Future<Object?> removeEpisodeDownload(CtlCall call) async {
    final InterconnectDownloadManager manager = _episodeManager();
    final String id = call.params['id']!;
    _requireConfirm(call, '删除剧集下载任务');
    final InterconnectDownloadTask task = _requireEpisode(manager, id);
    final bool deleteFiles = call.optBool('deleteFiles') ?? false;
    if (task.isRunning) {
      throw const CtlFailure.conflict('任务还在下载，先 pause 再删除');
    }
    if (task.status == InterconnectDownloadStatus.completed) {
      if (!deleteFiles) {
        manager.clearTask(id);
        return null;
      }
      if (!canDeleteCompletedDownloadFiles(task)) {
        throw const CtlFailure.badRequest(
          '这条已完成任务没有可删的成品（只有视频扩展源剧集可连文件删除），'
          '去掉 --delete-files 只清记录',
        );
      }
      // 下载页「删除并删文件」同一条：按文件找库行走媒体库删除链 / 只删孤儿文件，
      // 删掉了才移出记录；删不掉把原因回给 CLI。
      VideoLibraryDeleteResult? outcome;
      final bool done = await deleteCompletedInterconnectDownloadFiles(
        database: appModel.database,
        pipeline: appModel.videoDownloadPipelineService,
        manager: manager,
        task: task,
        report: (VideoLibraryDeleteResult result) => outcome = result,
      );
      if (!done) {
        throw CtlFailure.conflict(
          '成品没删掉，任务保留：${describeCtlVideoDeleteFailure(outcome)}',
        );
      }
      return <String, Object?>{
        'id': id,
        'deletedRows': outcome?.deleted ?? 0,
        'deletedFile': task.destPath,
      };
    }
    if (deleteFiles) {
      await manager.discard(id);
    } else {
      manager.clearTask(id);
    }
    return null;
  }

  // ── 扩展启停 / 源启停 · 置顶 · 偏好 · 筛选浏览 ───────────────────────────

  /// 扩展页扩展行的启用开关：Mihon `setExtensionEnabled`；LNReader 一个插件就是
  /// 一个源，开关落在插件上（`setEnabled`）。
  Future<Object?> setExtensionEnabled(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String id = call.params['id']!;
    final bool? enabled = call.optBool('enabled');
    if (enabled == null) throw const CtlFailure.badRequest('enabled 缺失');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin? plugin = manager.installedById(id);
      if (plugin == null) throw CtlFailure.notFound('没有安装这个插件：$id');
      await manager.setEnabled(plugin, enabled);
      return <String, Object?>{'kind': kind.name, 'id': id, 'enabled': enabled};
    }
    final MihonManager manager = await _mihon(kind);
    final MangaExtensionRow? row = manager.installed
        .where((MangaExtensionRow r) => r.packageName == id)
        .firstOrNull;
    if (row == null) throw CtlFailure.notFound('没有安装这个扩展：$id');
    await manager.setExtensionEnabled(row, enabled);
    return <String, Object?>{'kind': kind.name, 'id': id, 'enabled': enabled};
  }

  /// 「来源」列表一行的启用开关与置顶（Mihon `updateSourceSettings`；LNReader
  /// `setEnabled` / `setPinned`）。只给其中一项时另一项不动。
  Future<Object?> setSourceSettings(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final bool? enabled = call.optBool('enabled');
    final bool? pinned = call.optBool('pinned');
    if (enabled == null && pinned == null) {
      throw const CtlFailure.badRequest('enabled / pinned 至少给一项');
    }
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin? plugin = manager.installedById(sourceId);
      if (plugin == null) throw CtlFailure.notFound('没有安装这个插件：$sourceId');
      if (enabled != null) await manager.setEnabled(plugin, enabled);
      if (pinned != null) {
        await manager.setPinned(
          manager.installedById(sourceId) ?? plugin,
          pinned,
        );
      }
      final LnReaderInstalledPlugin updated =
          manager.installedById(sourceId) ?? plugin;
      return <String, Object?>{
        'kind': kind.name,
        'id': updated.id,
        'enabled': updated.enabled,
        'pinned': updated.pinned,
      };
    }
    final MihonManager manager = await _mihon(kind);
    final MangaOnlineSourceRow row = _mihonSourceRowAny(manager, sourceId);
    await manager.updateSourceSettings(row, enabled: enabled, pinned: pinned);
    final MangaOnlineSourceRow updated =
        manager.sources
            .where(
              (MangaOnlineSourceRow r) =>
                  _mihonSourceKey(r) == _mihonSourceKey(row),
            )
            .firstOrNull ??
        row;
    return <String, Object?>{
      'kind': kind.name,
      'id': updated.sourceId,
      'extension': updated.extensionPackage,
      'enabled': updated.enabled,
      'pinned': updated.pinned,
    };
  }

  void _requireMihonPreferences(OnlineCtlKind kind) {
    if (kind == OnlineCtlKind.novel) {
      throw const CtlFailure.unsupported(
        'LNReader 插件没有源偏好（筛选见 source filters，登录态清除见 source clear-data）',
      );
    }
  }

  /// 偏好弹窗打开时的读取（`MihonManager.getPreferences`：运行时定义 + 已存值）。
  Future<Object?> listPreferences(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    _requireMihonPreferences(kind);
    final String sourceId = call.params['sourceId']!;
    final MihonManager manager = await _mihon(kind);
    final MangaOnlineSourceRow row = _mihonSourceRowAny(manager, sourceId);
    final List<MihonPreference> preferences = await _mihonErrors(
      () => manager.getPreferences(row),
    );
    return <String, Object?>{
      'kind': kind.name,
      'source': sourceId,
      'preferences': ctlMihonPreferencesJson(preferences),
    };
  }

  /// 偏好弹窗改一项（`MihonManager.setPreference`，写穿运行时与数据库）。
  Future<Object?> setPreference(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    _requireMihonPreferences(kind);
    final String sourceId = call.params['sourceId']!;
    final String key = call.requireString('key');
    final Object? rawValue = call.body['value'] ?? call.query['value'];
    if (rawValue == null) throw const CtlFailure.badRequest('value 缺失');
    final MihonManager manager = await _mihon(kind);
    final MangaOnlineSourceRow row = _mihonSourceRowAny(manager, sourceId);
    final List<MihonPreference> current = await _mihonErrors(
      () => manager.getPreferences(row),
    );
    final MihonPreference changed = ctlMihonPreferenceWithValue(
      findCtlMihonPreference(current, key),
      '$rawValue',
    );
    final List<MihonPreference> updated = await _mihonErrors(
      () => manager.setPreference(row, changed),
    );
    return <String, Object?>{
      'kind': kind.name,
      'source': sourceId,
      'key': key,
      'preferences': ctlMihonPreferencesJson(updated),
    };
  }

  /// 「清除源数据」：Mihon `clearSourceData`（运行时数据 + 已存偏好）；LNReader
  /// `clearData`（插件的 `@libs/storage`：登录态 / token）。
  Future<Object?> clearSourceData(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    _requireConfirm(call, '清除源数据');
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin? plugin = manager.installedById(sourceId);
      if (plugin == null) throw CtlFailure.notFound('没有安装这个插件：$sourceId');
      await manager.clearData(plugin);
      return null;
    }
    final MihonManager manager = await _mihon(kind);
    final MangaOnlineSourceRow row = _mihonSourceRowAny(manager, sourceId);
    await _mihonErrors(() => manager.clearSourceData(row));
    return null;
  }

  /// 源浏览页「筛选」按钮背后的定义：Mihon `getFilters` / `getAnimeFilters`
  /// （只作用于搜索）；LNReader 插件自报的 `filters`（只作用于热门 / 最新）。
  Future<Object?> listFilters(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    if (kind == OnlineCtlKind.novel) {
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin plugin = _lnReaderPlugin(manager, sourceId);
      final LnReaderPluginInfo info = await manager.load(plugin);
      return <String, Object?>{
        'kind': kind.name,
        'source': plugin.id,
        'appliesTo': 'listing',
        'filters': ctlLnReaderFiltersJson(info.filters),
      };
    }
    final MihonManager manager = await _mihon(kind);
    final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
    return <String, Object?>{
      'kind': kind.name,
      'source': sourceId,
      'appliesTo': 'search',
      'filters': ctlMihonFiltersJson(await _mihonDefaultFilters(manager, ctx)),
    };
  }

  Future<List<MihonFilter>> _mihonDefaultFilters(
    MihonManager manager,
    MihonSourceContext ctx,
  ) => _mihonErrors(
    () => manager.kind == MihonMediaKind.anime
        ? manager.animeRuntime.getAnimeFilters(
            ctx.extension,
            ctx.source,
            preferences: ctx.preferences,
          )
        : manager.runtime.getFilters(
            ctx.extension,
            ctx.source,
            preferences: ctx.preferences,
          ),
  );

  static Map<String, String> _filterAssignments(CtlCall call) {
    final Object? raw = call.body['filters'];
    if (raw == null) return const <String, String>{};
    if (raw is! Map) {
      throw const CtlFailure.badRequest('filters 必须是 {筛选: 取值} 对象');
    }
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        '${e.key}': '${e.value ?? ''}',
    };
  }

  /// 源浏览页的一页：热门 / 最新 / 搜索 + 筛选，与 `_MihonCatalog.fetch` /
  /// `_LnReaderCatalog.fetch` 同一套调用。筛选只用在该生态允许的列表上：Mihon 只
  /// 作用于搜索（给了筛选没给关键词 = 空关键词搜索，同 UI 改筛选后的效果），
  /// LNReader 只作用于热门 / 最新。
  Future<Object?> browseSource(CtlCall call) async {
    final OnlineCtlKind kind = _kind(call);
    final String sourceId = call.params['sourceId']!;
    final String? listing = call.optString('listing')?.toLowerCase();
    final String? query = call.optString('query');
    final int page = call.optInt('page') ?? 1;
    if (page < 1) throw const CtlFailure.badRequest('page 从 1 开始');
    if (listing != null && listing != 'popular' && listing != 'latest') {
      throw CtlFailure.badRequest('未知 listing：$listing（popular | latest）');
    }
    if (listing != null && query != null) {
      throw const CtlFailure.badRequest('listing 与 query 二选一');
    }
    final Map<String, String> assignments = _filterAssignments(call);
    if (kind == OnlineCtlKind.novel) {
      if (query != null && assignments.isNotEmpty) {
        throw const CtlFailure.badRequest('LNReader 的筛选只作用于热门 / 最新，不能与关键词同用');
      }
      final LnReaderManager manager = await _lnReader();
      final LnReaderInstalledPlugin plugin = _lnReaderPlugin(manager, sourceId);
      final LnReaderPluginInfo info = await manager.load(plugin);
      final List<LnReaderNovelItem> items = query != null
          ? await manager.runtime.search(plugin.id, query: query, page: page)
          : await manager.runtime.popular(
              plugin.id,
              page: page,
              latest: listing == 'latest',
              // 与浏览页同口径：没动过筛选时让插件用它自己的默认值。
              filters: assignments.isEmpty
                  ? null
                  : lnReaderFilterValues(
                      applyCtlLnReaderFilters(info.filters, assignments),
                    ),
            );
      return <String, Object?>{
        'kind': kind.name,
        'source': plugin.id,
        'listing': query != null ? 'search' : (listing ?? 'popular'),
        'page': page,
        // LNReader 插件不报「还有下一页」：与浏览页同口径，一页有条目就认为还有。
        'hasNextPage': items.isNotEmpty,
        'items': <Map<String, Object?>>[
          for (final LnReaderNovelItem item in items)
            <String, Object?>{
              'url': item.path,
              'title': item.name,
              'cover': item.cover,
            },
        ],
      };
    }
    if (listing != null && assignments.isNotEmpty) {
      throw const CtlFailure.badRequest('Mihon 的筛选只作用于搜索，不能与热门 / 最新同用');
    }
    final MihonManager manager = await _mihon(kind);
    final MihonSourceContext ctx = await _mihonContext(manager, sourceId);
    final bool search = query != null || assignments.isNotEmpty;
    final List<MihonFilter> filters = search
        ? applyCtlMihonFilters(
            await _mihonDefaultFilters(manager, ctx),
            assignments,
          )
        : const <MihonFilter>[];
    final String text = query ?? '';
    final List<MihonCatalogueEntry> items;
    final bool hasNextPage;
    if (kind == OnlineCtlKind.anime) {
      final AnimeMihonRuntime runtime = manager.animeRuntime;
      final MihonAnimePage response = await _mihonErrors(
        () => search
            ? runtime.searchAnime(
                ctx.extension,
                ctx.source,
                page: page,
                query: text,
                filters: filters,
                preferences: ctx.preferences,
              )
            : listing == 'latest'
            ? runtime.getLatestAnime(
                ctx.extension,
                ctx.source,
                page: page,
                preferences: ctx.preferences,
              )
            : runtime.getPopularAnime(
                ctx.extension,
                ctx.source,
                page: page,
                preferences: ctx.preferences,
              ),
      );
      items = response.items;
      hasNextPage = response.hasNextPage;
    } else {
      final MihonRuntime runtime = manager.runtime;
      final MihonMangaPage response = await _mihonErrors(
        () => search
            ? runtime.search(
                ctx.extension,
                ctx.source,
                page: page,
                query: text,
                filters: filters,
                preferences: ctx.preferences,
              )
            : listing == 'latest'
            ? runtime.getLatest(
                ctx.extension,
                ctx.source,
                page: page,
                preferences: ctx.preferences,
              )
            : runtime.getPopular(
                ctx.extension,
                ctx.source,
                page: page,
                preferences: ctx.preferences,
              ),
      );
      items = response.items;
      hasNextPage = response.hasNextPage;
    }
    return <String, Object?>{
      ..._catalogueJson(kind, sourceId, page, items, hasNextPage),
      'listing': search ? 'search' : (listing ?? 'popular'),
    };
  }

  // ── 发现 ────────────────────────────────────────────────────────────────

  void _requireDiscovery() {
    if (!StoreRestrictedCapability.externalDiscovery.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供发现源（商店合规）');
    }
  }

  static DiscoveryMediaKind _discoveryKind(String? raw) {
    switch ((raw ?? 'novel').trim().toLowerCase()) {
      case 'book' || 'books' || 'novel':
        return DiscoveryMediaKind.novel;
      case 'audiobook':
        return DiscoveryMediaKind.audiobook;
      case 'manga':
        return DiscoveryMediaKind.manga;
      case 'game' || 'games':
        return DiscoveryMediaKind.game;
      case 'video' || 'anime':
        throw const CtlFailure.unsupported(
          '视频域的发现请用 fushi_cli video discover / video resources / video get',
        );
    }
    throw CtlFailure.badRequest(
      '未知 domain：$raw（book | audiobook | manga | game）',
    );
  }

  Future<Object?> listDiscoverySources(CtlCall call) async {
    _requireDiscovery();
    final String? domain = call.optString('domain');
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final Set<String> disabled = appModel.discoveryDisabledSourceIds;
    final List<MediaDiscoverySource> sources = domain == null
        ? service.sources
        : service.sourcesFor(_discoveryKind(domain));
    return <String, Object?>{
      'sources': <Map<String, Object?>>[
        for (final MediaDiscoverySource source in sources)
          <String, Object?>{
            'id': source.id,
            'name': source.displayName,
            'domains': <String>[
              for (final DiscoveryMediaKind k in source.capabilities.kinds)
                k.name,
            ],
            'search': source.capabilities.supportsSearch,
            'enabled': !disabled.contains(source.id),
          },
      ],
    };
  }

  Future<Object?> searchDiscovery(CtlCall call) async {
    _requireDiscovery();
    final DiscoveryMediaKind kind = _discoveryKind(call.optString('domain'));
    final String query = call.requireString('q');
    final String? sourceId = call.optString('source');
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    if (sourceId != null && service.sourceById(sourceId) == null) {
      throw CtlFailure.notFound('没有这个发现源：$sourceId');
    }
    // 与发现页 / 「AI 下载」同一调用与同一份「停用来源」偏好。
    final DiscoveryAggregateResult result = await service.load(
      DiscoveryRequest(kind: kind, query: query),
      sourceId: sourceId,
      disabledSourceIds: appModel.discoveryDisabledSourceIds,
    );
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    for (final DiscoverySourceSlice slice in result.slices) {
      final String label =
          service.sourceById(slice.sourceId)?.displayName ?? slice.sourceId;
      for (final DiscoveryEntry entry in slice.page.entries) {
        if (entry is! DiscoveryResourceItem) continue;
        items.add(<String, Object?>{
          'id': _discoveryResults.put(entry),
          'title': entry.title,
          'source': label,
          'sourceId': entry.sourceId,
          'domain': entry.kind.name,
          'payload': entry.payloadKind.name,
          'size': entry.sizeBytes,
          'seeders': entry.seeders,
          'date': entry.dateText,
          'note': entry.note,
          'downloadable': entry.isDownloadable,
        });
      }
    }
    return <String, Object?>{
      'domain': kind.name,
      'query': query,
      'items': items,
      'failures': <Map<String, Object?>>[
        for (final ExternalProviderFailure f in result.failures)
          <String, Object?>{'source': f.providerId, 'message': f.message},
      ],
    };
  }

  /// `discover get`：发现页「下载」按钮同一个 [startDiscoveryItemDownload]（torrent /
  /// 直链 → 下载中心 → 自动入库）。它可能弹出 app 内确认（如 torrent 选目标），所以
  /// 先把主窗口带到前台。
  Future<Object?> acquireDiscovery(CtlCall call) async {
    _requireDiscovery();
    if (!StoreRestrictedCapability.downloads.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供下载中心（商店合规）');
    }
    final String id = call.requireString('id');
    final DiscoveryResourceItem? item = _discoveryResults[id];
    if (item == null) {
      throw CtlFailure.notFound('没有结果 $id（结果只在本次 app 运行内有效，先 discover search）');
    }
    if (!item.isDownloadable) throw CtlFailure.rejected('结果 $id 不可下载');
    await context.focusMainWindow();
    final BuildContext? buildContext = context.navigator?.context;
    if (buildContext == null || !buildContext.mounted) {
      throw const CtlFailure.conflict('主窗口尚未就绪');
    }
    final DownloadStartResult result = await startDiscoveryItemDownload(
      context: buildContext,
      appModel: appModel,
      item: item,
    );
    return <String, Object?>{
      'id': id,
      'title': item.title,
      'started': result.started,
      if (result.started && result.summary != null) 'message': result.summary,
      if (result.failureReason != null) 'reason': result.failureReason,
    };
  }

  // ── 播放遥控 ────────────────────────────────────────────────────────────

  /// 可遥控的播放器有两种：视频播放页（页面在 initState 登记进
  /// [videoPlaybackRemotes]，叠加时最上层优先）与进程级有声书会话
  /// （[AppModel.audiobookSession]，脱离阅读器存活）。`target` 缺省时视频页开着就
  /// 控制视频（它盖在一切之上），否则有声书；见 [resolveCtlPlaybackTarget]。
  CtlPlaybackTarget? _playbackTarget(CtlCall call) => resolveCtlPlaybackTarget(
    requested: call.optString('target'),
    hasVideo: videoPlaybackRemotes.current.value != null,
    hasAudiobook: appModel.audiobookSession.controller != null,
  );

  AudiobookPlayerController _requirePlayer() {
    final AudiobookPlayerController? controller =
        appModel.audiobookSession.controller;
    if (controller == null) {
      throw const CtlFailure.conflict('没有正在播放的有声书');
    }
    return controller;
  }

  /// 视频页遥控面 + 就绪快照；没有视频页 / 控制器未就绪都是 409。
  (VideoPlaybackRemote, VideoPlaybackSnapshot) _requireVideo() {
    final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
    if (remote == null) throw const CtlFailure.conflict('没有打开的视频播放页');
    final VideoPlaybackSnapshot? snapshot = remote.snapshot();
    if (snapshot == null) {
      throw const CtlFailure.conflict('视频还在加载，稍后再试');
    }
    return (remote, snapshot);
  }

  /// 没指定 target 且两边都没有时的统一报错。
  CtlPlaybackTarget _requireTarget(CtlCall call) =>
      _playbackTarget(call) ??
      (throw const CtlFailure.conflict('没有正在播放的视频或有声书'));

  Future<Object?> playbackStatus(CtlCall call) async {
    switch (_playbackTarget(call)) {
      case null:
        return <String, Object?>{'active': false};
      case CtlPlaybackTarget.video:
        final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
        if (remote == null) {
          return <String, Object?>{'active': false, 'kind': 'video'};
        }
        return ctlVideoPlaybackJson(remote.snapshot());
      case CtlPlaybackTarget.audiobook:
        final AudiobookSession session = appModel.audiobookSession;
        final AudiobookPlayerController? controller = session.controller;
        if (controller == null) {
          return <String, Object?>{'active': false, 'kind': 'audiobook'};
        }
        return _playbackJson(session, controller);
    }
  }

  static Map<String, Object?> _playbackJson(
    AudiobookSession session,
    AudiobookPlayerController controller,
  ) => <String, Object?>{
    'active': true,
    'kind': 'audiobook',
    'bookKey': session.book?.bookKey,
    'title': session.book?.title,
    'playing': controller.isPlaying,
    'positionMs': controller.globalPosition.inMilliseconds,
    'durationMs': controller.totalDuration.inMilliseconds,
    'speed': controller.speed,
    'cue': controller.currentCue?.text,
  };

  static Never _unknownAction(String action) => throw CtlFailure.badRequest(
    '未知动作：$action（pause | resume | toggle | next | prev）',
  );

  Future<Object?> playbackControl(CtlCall call) async {
    final String action = call.requireString('action');
    if (_requireTarget(call) == CtlPlaybackTarget.video) {
      final (VideoPlaybackRemote remote, _) = _requireVideo();
      switch (action) {
        case 'pause':
          await remote.pause();
        case 'resume' || 'play':
          await remote.play();
        case 'toggle':
          await remote.toggle();
        case 'next':
          await remote.nextCue();
        case 'prev':
          await remote.previousCue();
        default:
          _unknownAction(action);
      }
      return ctlVideoPlaybackJson(remote.snapshot());
    }
    final AudiobookPlayerController controller = _requirePlayer();
    switch (action) {
      case 'pause':
        await controller.pause();
      case 'resume' || 'play':
        // play() 的 Future 在部分后端挂到暂停才 settle（BUG-1736），不能等。
        unawaited(controller.play());
      case 'toggle':
        if (controller.isPlaying) {
          await controller.pause();
        } else {
          unawaited(controller.play());
        }
      case 'next':
        await controller.skipToNextCue();
      case 'prev':
        await controller.skipToPrevCue();
      default:
        _unknownAction(action);
    }
    return _playbackJson(appModel.audiobookSession, controller);
  }

  Future<Object?> playbackSeek(CtlCall call) async {
    final Object? raw = call.body['seconds'] ?? call.query['seconds'];
    final double? seconds = raw is num
        ? raw.toDouble()
        : double.tryParse('$raw');
    if (seconds == null) throw const CtlFailure.badRequest('seconds 必须是数字');
    final bool relative = call.optBool('relative') ?? false;
    final int deltaMs = (seconds * 1000).round();
    if (_requireTarget(call) == CtlPlaybackTarget.video) {
      final (VideoPlaybackRemote remote, VideoPlaybackSnapshot snapshot) =
          _requireVideo();
      if (relative) {
        // 与快捷键 ←/→ 同一入口（controller.seekRelative，含连按基准累积）。
        await remote.seekByMs(deltaMs);
      } else {
        final int total = snapshot.durationMs ?? 0;
        await remote.seekToMs(
          total > 0 ? deltaMs.clamp(0, total) : (deltaMs < 0 ? 0 : deltaMs),
        );
      }
      return ctlVideoPlaybackJson(remote.snapshot());
    }
    final AudiobookPlayerController controller = _requirePlayer();
    final int targetMs = relative
        ? controller.globalPosition.inMilliseconds + deltaMs
        : deltaMs;
    final int total = controller.totalDuration.inMilliseconds;
    // 有声书面板整书进度条同一入口（跨文件拆分在控制器里做）。
    await controller.seekGlobalMs(
      total > 0 ? targetMs.clamp(0, total) : (targetMs < 0 ? 0 : targetMs),
    );
    return _playbackJson(appModel.audiobookSession, controller);
  }

  Future<Object?> playbackRate(CtlCall call) async {
    final Object? raw = call.body['rate'] ?? call.query['rate'];
    final double? rate = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (rate == null || rate < 0.25 || rate > 4) {
      throw const CtlFailure.badRequest('rate 必须在 0.25–4 之间');
    }
    if (_requireTarget(call) == CtlPlaybackTarget.video) {
      final (VideoPlaybackRemote remote, _) = _requireVideo();
      // 页内倍速菜单同一入口（夹取 + 按 bookUid 持久化）。
      await remote.setRate(rate);
      return ctlVideoPlaybackJson(remote.snapshot());
    }
    final AudiobookPlayerController controller = _requirePlayer();
    await controller.setSpeed(rate);
    return _playbackJson(appModel.audiobookSession, controller);
  }

  // ── 页面导航 ────────────────────────────────────────────────────────────

  Future<Object?> listNavigation(CtlCall call) async {
    final List<HomeTab> active = homeActiveTabs(appModel.moduleVisibility);
    return <String, Object?>{
      'current': ctlNavigationName(homeShellTabNotifier.value),
      'covered': context.navigator?.canPop() ?? false,
      'pages': <Map<String, Object?>>[
        for (final HomeTab tab in HomeTab.values)
          <String, Object?>{
            'name': ctlNavigationName(tab),
            'available': active.contains(tab),
            'current': homeShellTabNotifier.value == tab,
          },
      ],
    };
  }

  /// 切顶层页签：写 [homeShellTabNotifier]——dashboard 卡片 / 设置里的游戏入口用的
  /// 同一个程序化入口，HomePage 经 `_onShellTabRequested` 转交 `_selectTab`（模块
  /// 关掉的页签在那里被拒）。`pop` 时先退回首页外壳（等同连按返回）。
  Future<Object?> navigate(CtlCall call) async {
    final HomeTab tab = homeTabFromCtlName(call.requireString('page'));
    if (!homeActiveTabs(appModel.moduleVisibility).contains(tab)) {
      throw CtlFailure.rejected(
        '页面 ${ctlNavigationName(tab)} 在本平台不可用或已在「功能模块」里关闭',
      );
    }
    final NavigatorState? navigator = context.navigator;
    if (navigator == null) throw const CtlFailure.conflict('主窗口尚未就绪');
    if (call.optBool('pop') ?? false) {
      navigator.popUntil((Route<Object?> route) => route.isFirst);
    }
    homeShellTabNotifier.value = tab;
    await context.focusMainWindow();
    return <String, Object?>{
      'page': ctlNavigationName(tab),
      'covered': navigator.canPop(),
    };
  }
}

/// 视频源剧集的默认字幕语言：与作品页 `_preferredSubtitleLanguage` 同一条链
/// （字幕工作台默认语言 > 默认内容语言）。
String? resolveCtlSubtitleLanguage(AppModel appModel) =>
    resolveSubtitleDownloadLanguage(
      explicitSubtitlePreference: appModel.jimakuDefaultLanguage,
      globalDefaultContentLanguage: appModel.defaultContentLanguage,
    );

/// 一集的在线断点：与作品页 `_readOnlinePosition` 同一把键（播放页合集模式落盘的
/// `(成员 id, 0)`），下载完登记本地行时接过去。没有 / 近起点返回 null。
AnimeOnlinePosition? readCtlAnimeOnlinePosition(AppModel appModel, String id) {
  int readInt(String key) {
    final Object? raw = appModel.prefsRepo.getPref(key, defaultValue: 0);
    return raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;
  }

  final int positionMs = readInt(videoRemotePositionEpisodePrefKey(id, 0));
  if (positionMs <= 0) return null;
  return (
    positionMs: positionMs,
    playedAt: readInt(videoRemotePositionEpisodeAtPrefKey(id, 0)),
  );
}

/// CLI 发起的 LNReader 整本下载：与作品页下载对话框同一个 [LnReaderBookDownload.run]，
/// 只是没有对话框承载进度——登记进 [CtlOnlineTaskRegistry]，`source task` 查进度、
/// `source task <id> --cancel` 取消（章节之间的检查点，同对话框「取消」）。重名按
/// 程序化入库口径留副本（[DuplicatePolicy.suffix]，与「加入书架」的占位书一致）。
///
/// `source dl --kind novel` 与 AI 下载会话里确认的小说候选共用这一处。
CtlOnlineTask startCtlNovelDownloadTask({
  required LnReaderBookDownload download,
  required LnReaderInstalledPlugin plugin,
  required LnReaderNovel novel,
  required List<LnReaderChapter> chapters,
  required void Function() onShelfChanged,
  CtlOnlineTaskRegistry? registry,
}) {
  final CtlOnlineTaskRegistry tasks =
      registry ?? CtlOnlineTaskRegistry.instance;
  final CtlOnlineTask task = tasks.start(
    kind: OnlineCtlKind.novel.name,
    title: novel.name,
    total: chapters.length,
  );
  unawaited(() async {
    try {
      final String bookKey = await download.run(
        plugin: plugin,
        novel: novel,
        chapters: chapters,
        policy: const DuplicatePolicy.suffix(),
        onProgress: (int done, int total) => task.done = done,
        isCancelled: () => task.cancelRequested,
      );
      onShelfChanged();
      tasks.finish(task, status: 'done', resultKey: bookKey);
    } on LnReaderDownloadCancelled {
      tasks.finish(task, status: 'cancelled');
    } on LnReaderChapterDownloadException catch (error) {
      tasks.finish(
        task,
        status: 'failed',
        error: '${error.chapter.name}: ${error.cause}',
      );
    } on Object catch (error) {
      tasks.finish(task, status: 'failed', error: '$error');
    }
  }());
  return task;
}
