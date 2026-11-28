part of '../fushi_sync_server.dart';

/// 互联 host 的端点表（架构重构 A1）：服务器本体自带的每类功能各是一个 [InterconnectHostModule]，与经构造参数
/// 注入的模块排进同一张 [InterconnectModuleTable]。鉴权豁免、分发、`/api/capabilities` 都只读这张表；
/// `_handleRequest` 里不再有路径分支，表里没有的路径才落进 WebDAV 文件树。
///
/// **模块顺序就是 `/api/capabilities` 的顶层键序**（`interconnect_host_surface_test.dart` 逐字节钉住）。
/// 新功能：写一个模块（或在这里加一项），能力位、免 Basic 与否、方法集都在它自己的声明里，不再改别处。
final class _HostModule extends InterconnectHostModule {
  _HostModule(
    this.name, {
    this.routes = const <InterconnectRoute>[],
    this.capabilities = const <InterconnectCapability>[],
  });

  @override
  final String name;

  @override
  final List<InterconnectRoute> routes;

  @override
  final List<InterconnectCapability> capabilities;
}

/// `liveLibrary` 能力分组：成员即线上键序，每个成员由下面恰好一个库模块提供。
const InterconnectCapabilityGroup _kLiveLibraryGroup =
    InterconnectCapabilityGroup('liveLibrary', <String>[
      'dictionaries',
      'books',
      'audio',
      kLiveLibraryLocalAudioContentIdCapability,
      'videos',
      'manga',
      'videoMetadata',
      'tags',
      kLiveLibraryPdfBooksCapability,
      'mediaLinks',
      kLiveLibraryOnlineItemsCapability,
      kLiveLibraryStreamVideosCapability,
      kLiveLibraryDeletionTombstonesCapability,
      kLiveLibraryVideoDeletionCapability,
      'videoTranscode',
      'videoSubtitleDefault',
      'videoSubtitleDefaultEpisode',
      'videoSubtitleClear',
      kVideoSidecarSubtitlesCapability,
      kVideoSidecarAudioCapability,
      kDiscShareCapability,
      kVideoClipExportCapability,
      kVideoClipAudioDiscTitleCapability,
      kVideoClipAudioDiscTitleAngleCapability,
      kVideoClipAudioDiscTitleDvdCapability,
      kVideoClipAudioDiscTitleDvdAngleCapability,
      'videoSubtitleBackfill',
      'videoGraphicSubtitleTrack',
      'videoMetadataOrdering',
      'serviceConfig',
      kInterconnectSourceShareFeature,
      kInterconnectPluginRelayFeature,
      'profileTransfer',
    ]);

/// 只回 `true` 或「缺键」的能力位（老 client 以缺键判不支持）。
Object? _trueOrAbsent(bool on) => on ? true : null;

InterconnectRoute _route(
  InterconnectPath path,
  InterconnectHandler handler, {
  Set<String>? methods,
  InterconnectTrust trust = InterconnectTrust.credential,
}) => InterconnectRoute(path, methods: methods, trust: trust, handler: handler);

InterconnectCapability _live(String key, FutureOr<Object?> Function() value) =>
    InterconnectCapability.member(_kLiveLibraryGroup, key, value);

const Set<String> _kGet = <String>{'GET'};
const Set<String> _kGetHead = <String>{'GET', 'HEAD'};
const Set<String> _kPost = <String>{'POST'};

extension _FushiSyncServerHostRoutes on FushiSyncServer {
  /// 完整模块表的顺序。[injected] 是构造参数带进来的模块（漫画 OCR、任务、代下载、BT 引擎、订阅、助手、
  /// `modules`、章级进度），排在 `srsChangesV1` 之后、`lookup` 之前——与迁移前的键序相同。
  List<InterconnectHostModule> _hostModules(
    List<InterconnectHostModule> injected,
  ) {
    bool lib() => _libraryService != null;
    return <InterconnectHostModule>[
      // 复习同步的长轮询通知与参与状态。老 host 没有 `srsChangesV1`，客户端只按定时同步。
      _HostModule(
        'srsChanges',
        capabilities: <InterconnectCapability>[
          InterconnectCapability('srsChangesV1', () => true),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/srs/changes'),
            (InterconnectRequest r) => _handleSrsChanges(r.raw),
            methods: _kGet,
          ),
          _route(
            const InterconnectPath.exact(kSrsSyncStatusPath),
            (InterconnectRequest r) async => _handleSrsSyncStatus(),
            methods: _kGet,
          ),
        ],
      ),
      ...injected,
      // 查词 / 查词历史 / 词典媒体 / 浏览器扩展探活。能力位只说「懂不懂这条路由」，不代表此刻一定成功。
      _HostModule(
        'lookup',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            'lookup',
            () => <String, dynamic>{
              'dictionary': _remoteLookupService != null,
              'history': _historyService != null,
            },
          ),
        ],
        routes: <InterconnectRoute>[
          // 查词音频文件交给平台播放器裸 GET；门是 RemoteLookupRoutes 里的短时不透明 id。
          _route(
            const InterconnectPath.exact('/api/lookup/audio/file'),
            (InterconnectRequest r) =>
                _handleLookupApi(r.raw, r.upperMethod, r.path),
            methods: _kGetHead,
            trust: const InterconnectTrust.urlTicket('查词音频短时 id'),
          ),
          _route(
            const InterconnectPath.under('/api/lookup/'),
            (InterconnectRequest r) =>
                _handleLookupApi(r.raw, r.upperMethod, r.path),
          ),
          // TODO-1215：词典媒体由网页 <img src> 取，带不了 Authorization，改用 query 凭据；无效 / 缺省的
          // query 凭据落到 Basic（app 内 / Basic 客户端照常用）。
          _route(
            const InterconnectPath.exact('/api/media/dictionary'),
            (InterconnectRequest r) async =>
                _handleDictionaryMedia(r.raw, r.upperMethod == 'HEAD'),
            methods: _kGetHead,
            trust: InterconnectTrust.queryTicketOrCredential(
              _dictionaryMediaTokenValid,
            ),
          ),
          _route(
            const InterconnectPath.exact('/api/extension/status'),
            (InterconnectRequest r) async => _handleExtensionStatus(),
            methods: _kPost,
          ),
        ],
      ),
      // 制卡（含 Anki 笔记类型 / 来源笔记 / 媒体去重 / 查重）。
      _HostModule(
        'mining',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            'mining',
            () => activeRemoteMiningService(_miningService) != null,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/mine'),
            (InterconnectRequest r) => _lookupRoutes.handleMine(r.raw),
            methods: _kPost,
          ),
          // POST 与其它 /api/mine* 一致：客户端走同一条带钉扎的互联 POST 传输（请求体为空对象）。
          _route(
            const InterconnectPath.exact('/api/mine/targets'),
            (InterconnectRequest r) => _lookupRoutes.handleMiningTargets(r.raw),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.exact('/api/mine/forward'),
            (InterconnectRequest r) => _lookupRoutes.handleMineForward(r.raw),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.under('/api/anki/note-type/'),
            (InterconnectRequest r) =>
                _lookupRoutes.handleAnkiNoteType(r.raw, r.path),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.under('/api/anki/source/'),
            (InterconnectRequest r) =>
                _lookupRoutes.handleSourceNote(r.raw, r.path),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.under('/api/anki/media/dedup/'),
            (InterconnectRequest r) => _handleAnkiMediaDedup(r.raw, r.path),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.exact('/api/duplicate'),
            (InterconnectRequest r) => _lookupRoutes.handleDuplicate(r.raw),
            methods: _kPost,
          ),
        ],
      ),
      _HostModule(
        'gameStream',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            'gameStream',
            () => _gameStreamService != null,
          ),
        ],
        routes: <InterconnectRoute>[
          for (final InterconnectPath path in const <InterconnectPath>[
            InterconnectPath.subtree('/api/game-stream/sessions'),
            InterconnectPath.exact('/api/game-stream/join'),
            InterconnectPath.exact('/api/game-stream/signal'),
            InterconnectPath.exact('/api/game-stream/stop'),
            InterconnectPath.exact('/api/game-stream/mine'),
            InterconnectPath.exact('/api/game-stream/library'),
            InterconnectPath.exact('/api/game-stream/library/cover'),
            InterconnectPath.exact('/api/game-stream/launch'),
            InterconnectPath.exact('/api/game-stream/launch/status'),
          ])
            _route(
              path,
              (InterconnectRequest r) =>
                  _handleGameStream(r.raw, r.upperMethod, r.path),
            ),
        ],
      ),
      // 远程更新 host（反馈 Pp8XPyve0N）：client 据此决定是否显示「主机版本」行。
      _HostModule(
        'hostUpdate',
        capabilities: <InterconnectCapability>[
          InterconnectCapability('hostUpdate', () => hostSelfUpdater != null),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kHostUpdatePath),
            (InterconnectRequest r) => _handleHostUpdate(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 互联文件箱的同步根树列举（BUG-3743）：PROPFIND `Depth: infinity` 完整列出的层数。WebDAV 树本身是
      // 表外的兜底（`_handleRequest` 末尾），这里只声明它的能力位。
      _HostModule(
        'webdav',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            kInterconnectDavCapabilityGroup,
            () => <String, dynamic>{
              kInterconnectDavTreeListingLevelsField: kDavTreeListingMaxLevels,
            },
          ),
        ],
      ),
      _HostModule(
        'libraryDictionaries',
        capabilities: <InterconnectCapability>[_live('dictionaries', lib)],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.subtree('/api/library/dictionaries'),
            (InterconnectRequest r) =>
                _handleLibraryDictionaries(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'libraryBooks',
        capabilities: <InterconnectCapability>[
          _live('books', lib),
          // 能否收下对端推来的 PDF 书（反馈 Jq1_ujHa4t）。老 host 无此字段 → client 不推 PDF。
          _live(kLiveLibraryPdfBooksCapability, () {
            return switch (_libraryService) {
              final PdfBookImportHost host => host.acceptsPdfBooks,
              _ => false,
            };
          }),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kBookProgressBatchPath),
            (InterconnectRequest r) =>
                _handleLibraryBookProgressBatch(r.upperMethod),
          ),
          _route(
            const InterconnectPath.subtree('/api/library/books'),
            (InterconnectRequest r) =>
                _handleLibraryBooks(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'libraryLocalAudio',
        capabilities: <InterconnectCapability>[
          _live('audio', lib),
          // 本地音频清单带内容身份 contentId、单项端点认 contentId（拍板 pr3481）。
          _live(kLiveLibraryLocalAudioContentIdCapability, lib),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.subtree('/api/library/localaudio'),
            (InterconnectRequest r) =>
                _handleLibraryLocalAudio(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'libraryAudiobooks',
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.subtree('/api/library/audiobooks'),
            (InterconnectRequest r) =>
                _handleLibraryAudiobooks(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'libraryVideos',
        capabilities: <InterconnectCapability>[
          _live('videos', lib),
          // 流媒体书注册（`PUT /api/library/videos/<id>/streamentry`，拍板台 Z2OhxAjKVv）。
          _live(
            kLiveLibraryStreamVideosCapability,
            () => _libraryService is StreamVideoSyncHost,
          ),
          // 视频删除（`DELETE /api/library/videos/<id>`）。有位但 false → 不叫用户去升级对端。
          _live(
            kLiveLibraryVideoDeletionCapability,
            () => _libraryService is VideoDeletionHost,
          ),
          // 弱网实时转码：随用户开关与本机 ffmpeg 可用性实时变化；最终真相仍是 `/streamurl` 的 `transcoded`。
          _live('videoTranscode', () => lib() && _videoTranscodeEnabled),
          // 「设为这一集的默认字幕」（`X-Fushi-Subtitle-Default: 1`）。老 host 无此字段 → client 不上传
          // （BUG-2728）。
          _live(
            'videoSubtitleDefault',
            () => _libraryService is VideoSubtitleDefaultHost,
          ),
          // 同一端点带 `?episode=N`。老 host 无此字段 → client 对第 N 集不上传。
          _live(
            'videoSubtitleDefaultEpisode',
            () => _libraryService is VideoSubtitleDefaultHost,
          ),
          // `DELETE .../subtitle?which=` 与 `POST .../subtitle/backfill`。
          _live(
            'videoSubtitleClear',
            () => _libraryService is VideoSubtitleClearHost,
          ),
          // 列出一集的全部外挂字幕 + 按名下载（反馈 -CaVsioFhG）。
          _live(
            kVideoSidecarSubtitlesCapability,
            () => _libraryService is VideoSidecarSubtitleListHost,
          ),
          // 外挂音轨（`externalAudioTracks` + `.../sidecaraudio`，M9OEh1PeYH）。
          _live(
            kVideoSidecarAudioCapability,
            () => _libraryService is VideoSidecarAudioListHost,
          ),
          // 互联远端片段导出（`GET .../clipvideo`，反馈 6nBmSBj_2W）。
          _live(
            kVideoClipExportCapability,
            () => _libraryService is VideoClipExportHost,
          ),
          // `clipaudio?discTitle=`：按（盘, title）裁音频；角度成员路径、DVD title、DVD 角度三项同一实现。
          for (final String key in const <String>[
            kVideoClipAudioDiscTitleCapability,
            kVideoClipAudioDiscTitleAngleCapability,
            kVideoClipAudioDiscTitleDvdCapability,
            kVideoClipAudioDiscTitleDvdAngleCapability,
          ])
            _live(key, () => _libraryService is VideoDiscTitleAudioHost),
          _live(
            'videoSubtitleBackfill',
            () => lib() && videoSubtitleBackfill != null,
          ),
          // 图形字幕整轨回传（`GET .../graphicsubtitle?embeddedStreamIndex=`）。
          _live(
            'videoGraphicSubtitleTrack',
            () => lib() && graphicSubtitleTrackExporter != null,
          ),
        ],
        routes: <InterconnectRoute>[
          // 视频流 / HLS / 蓝光码流 / 外挂音轨：media_kit 拿裸 URL 播放，门是 URL 里的短时流 token。
          _route(
            const InterconnectPath.where(
              '/api/library/videos',
              _isVideoStreamPath,
            ),
            (InterconnectRequest r) =>
                _handleLibraryVideos(r.raw, r.upperMethod, r.path),
            methods: _kGet,
            trust: const InterconnectTrust.urlTicket('视频流 token'),
          ),
          _route(
            const InterconnectPath.subtree('/api/library/videos'),
            (InterconnectRequest r) =>
                _handleLibraryVideos(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      // 远端原盘的只读盘目录（整盘下载 + 流式原盘菜单）。
      _HostModule(
        'libraryDiscShare',
        capabilities: <InterconnectCapability>[
          _live(
            kDiscShareCapability,
            () => _libraryService is VideoDiscShareHost,
          ),
        ],
        routes: <InterconnectRoute>[
          // libbluray / libdvdnav 在 libmpv 里直接取文件，带不了 Authorization；门是路径里的会话 token
          // （handler 内校验、按空闲过期）。
          _route(
            const InterconnectPath.under(kDiscShareRoutePrefix),
            (InterconnectRequest r) =>
                _handleDiscShare(r.raw, r.upperMethod, r.path),
            methods: _kGet,
            trust: const InterconnectTrust.urlTicket('原盘会话 token'),
          ),
          _route(
            const InterconnectPath.under(kDiscShareRoutePrefix),
            (InterconnectRequest r) =>
                _handleDiscShare(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      // 互联漫画源（按页在线阅读）。老 host 无此字段 → client 把这一行标成「对端版本过低」。
      _HostModule(
        'libraryManga',
        capabilities: <InterconnectCapability>[
          _live('manga', () => _libraryService is MangaLibraryHost),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.under('/api/library/manga/'),
            (InterconnectRequest r) =>
                _handleLibraryManga(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      // 视频刮削元数据同步 / 远程刮削 / 代刮回写，以及 TMDB 备选排序（`/metadata/episode-group*`）。
      _HostModule(
        'libraryVideoMetadata',
        capabilities: <InterconnectCapability>[
          _live('videoMetadata', () => _libraryService is VideoMetadataHost),
          _live(
            'videoMetadataOrdering',
            () => _libraryService is VideoMetadataOrderingHost,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.subtree('/api/library/metadata'),
            (InterconnectRequest r) =>
                _handleLibraryVideoMetadata(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'libraryTags',
        capabilities: <InterconnectCapability>[
          _live('tags', () => _libraryService is TagSyncHost),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/library/tags'),
            (InterconnectRequest r) => _handleLibraryTags(r.raw, r.upperMethod),
          ),
        ],
      ),
      _HostModule(
        'libraryMediaLinks',
        capabilities: <InterconnectCapability>[
          _live('mediaLinks', () => _libraryService is MediaLinkSyncHost),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/library/media-links'),
            (InterconnectRequest r) =>
                _handleLibraryMediaLinks(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 在线源条目清单（拍板台 mY5VWg1nD-）。
      _HostModule(
        'libraryOnlineItems',
        capabilities: <InterconnectCapability>[
          _live(
            kLiveLibraryOnlineItemsCapability,
            () => _libraryService is OnlineLibrarySyncHost,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kOnlineLibraryItemsPath),
            (InterconnectRequest r) =>
                _handleLibraryOnlineItems(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 删除墓碑列举。老 host 无此位 → client 遇 404 时提示升级对端；有位但 false → 不叫用户去升级。
      _HostModule(
        'tombstones',
        capabilities: <InterconnectCapability>[
          _live(
            kLiveLibraryDeletionTombstonesCapability,
            () => _libraryService is DeletionTombstoneHost,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/tombstones'),
            (InterconnectRequest r) => _handleTombstones(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 聚合清单 / 活动 / 收藏集（没有自己的能力位：随 `liveLibrary` 一起存在）。
      _HostModule(
        'libraryState',
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/library/aggregate'),
            (InterconnectRequest r) =>
                _handleLibraryAggregate(r.raw, r.upperMethod, r.path),
          ),
          _route(
            const InterconnectPath.exact('/api/library/activity'),
            (InterconnectRequest r) =>
                _handleLibraryActivity(r.raw, r.upperMethod),
          ),
          _route(
            const InterconnectPath.exact('/api/library/collections'),
            (InterconnectRequest r) =>
                _handleLibraryCollections(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      // 统一流票（设计 2026-11-23 §4.3）：签发 / 释放要 Basic，取流免 Basic（门是 URL 里的短时票，handler
      // 内校验签发凭据仍有效）。
      _HostModule(
        'libraryMediaStreams',
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kLibraryMediaStreamPath),
            (InterconnectRequest r) => _serveLibraryMediaStream(r.raw),
            methods: _kGetHead,
            trust: const InterconnectTrust.urlTicket('统一流票'),
          ),
          _route(
            const InterconnectPath.exact(kLibraryMediaStreamUrlPath),
            (InterconnectRequest r) => _issueLibraryMediaStream(r.raw),
            methods: _kPost,
          ),
          _route(
            const InterconnectPath.exact(kLibraryMediaStreamReleasePath),
            (InterconnectRequest r) async => _releaseLibraryMediaStream(r.raw),
            methods: _kPost,
          ),
        ],
      ),
      _HostModule(
        'serviceConfig',
        capabilities: <InterconnectCapability>[
          _live(
            'serviceConfig',
            () =>
                _securityContext != null &&
                _libraryService is InterconnectServiceConfigHost,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact('/api/interconnect/service-config'),
            (InterconnectRequest r) =>
                _handleInterconnectServiceConfig(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 互联「来源共享」（服务器来源 + 插件包）：必须 TLS，端点另查开关与「我的设备」。
      _HostModule(
        'sourceShare',
        capabilities: <InterconnectCapability>[
          _live(kInterconnectSourceShareFeature, () => _sourceShareAvailable),
        ],
        routes: <InterconnectRoute>[
          for (final String path in const <String>[
            kInterconnectSourceSharePath,
            kInterconnectSourceSharePackagePath,
          ])
            _route(
              InterconnectPath.exact(path),
              (InterconnectRequest r) =>
                  _handleInterconnectSourceShare(r.raw, r.upperMethod, r.path),
            ),
        ],
      ),
      // 互联「插件中继」（替没有插件运行时的「我的设备」代跑插件）：同来源共享，必须 TLS。
      _HostModule(
        'pluginRelay',
        capabilities: <InterconnectCapability>[
          _live(kInterconnectPluginRelayFeature, () => _pluginRelayAvailable),
        ],
        routes: <InterconnectRoute>[
          // 插件中继的媒体流：播放器拿裸 URL 取流；门是路径里的流票，handler 再现查签发凭据
          // （仍是已配对的「我的设备」、host 开关开着）。
          _route(
            const InterconnectPath.where(
              kInterconnectPluginRelayPath,
              _isPluginRelayStreamPath,
            ),
            (InterconnectRequest r) =>
                _handleInterconnectPluginRelay(r.raw, r.upperMethod, r.path),
            methods: _kGetHead,
            trust: const InterconnectTrust.urlTicket('插件中继流票'),
          ),
          _route(
            const InterconnectPath.subtree(kInterconnectPluginRelayPath),
            (InterconnectRequest r) =>
                _handleInterconnectPluginRelay(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      // 互联「配置文件」（Profile）双向搬运：与 serviceConfig 同门槛（必须 TLS）。能力位只说「懂这个端点」，
      // 端点还会再查用户开关，关着时回 403。
      _HostModule(
        'profileTransfer',
        capabilities: <InterconnectCapability>[
          _live(
            'profileTransfer',
            () =>
                _securityContext != null &&
                _libraryService is InterconnectProfileHost,
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kInterconnectProfilePath),
            (InterconnectRequest r) =>
                _handleInterconnectProfile(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 配对、探活、能力表与地址集（TODO-961 M1 能力协商：老 client 读不到也不崩）。
      _HostModule(
        'pairing',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            'tls',
            () => <String, dynamic>{
              'enabled': _securityContext != null,
              if (_hostFingerprint != null) 'fingerprint': _hostFingerprint,
            },
          ),
          InterconnectCapability(
            'pairing',
            () => <String, dynamic>{'v2': true},
          ),
        ],
        routes: <InterconnectRoute>[
          // 配对：client 还没有 token——这正是它在获取的东西。门是 handler 里的配对窗口 / PIN proof +
          // host 人工确认（TODO-961 M1）。
          _route(
            const InterconnectPath.exact('/api/pair'),
            (InterconnectRequest r) => _handlePair(r.raw),
            methods: _kPost,
            trust: InterconnectTrust.pairingBootstrap,
          ),
          _route(
            const InterconnectPath.exact('/api/pair/v2'),
            (InterconnectRequest r) => _handlePairV2(r.raw),
            methods: _kPost,
            trust: InterconnectTrust.pairingBootstrap,
          ),
          _route(
            const InterconnectPath.exact('/api/pair/v2/confirm'),
            (InterconnectRequest r) => _handlePairConfirm(r.raw),
            methods: _kPost,
            trust: InterconnectTrust.pairingBootstrap,
          ),
          // TODO-963 M2：无鉴权轻量探测（配对前确认地址可达 + 取能力 / 指纹做 TOFU），只读。
          _route(
            const InterconnectPath.exact('/api/ping'),
            (InterconnectRequest r) async => _handlePing(),
            methods: _kGet,
            trust: InterconnectTrust.reachabilityProbe,
          ),
          _route(
            const InterconnectPath.exact('/api/capabilities'),
            (InterconnectRequest r) => _capabilitiesRoute(r.raw),
            methods: _kGet,
          ),
          _route(
            const InterconnectPath.exact('/api/host/addresses'),
            (InterconnectRequest r) => _handleHostAddresses(),
            methods: _kGet,
          ),
        ],
      ),
      _HostModule(
        'videoRemote',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            'videoRemoteControlV1',
            () => _trueOrAbsent(_videoRemoteService != null),
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.under('/api/video-remote/'),
            (InterconnectRequest r) =>
                _handleVideoRemote(r.raw, r.upperMethod, r.path),
          ),
        ],
      ),
      _HostModule(
        'leaderboardLink',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            kInterconnectLeaderboardLinkCapability,
            () => _trueOrAbsent(_leaderboardLinkAvailable),
          ),
        ],
        routes: <InterconnectRoute>[
          _route(
            const InterconnectPath.exact(kInterconnectLeaderboardLinkPath),
            (InterconnectRequest r) =>
                _handleInterconnectLeaderboardLink(r.raw, r.upperMethod),
          ),
        ],
      ),
      // 远程复习库：已配对设备不下载卡组，直接在本机的复习库上复习。
      _HostModule(
        'srsRemoteStore',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            kSrsRemoteStoreCapabilityV2,
            () => _trueOrAbsent(srsRemoteStoreProvider?.call() != null),
          ),
          InterconnectCapability(
            kSrsRemoteStoreCapability,
            () => _trueOrAbsent(srsRemoteStoreProvider?.call() != null),
          ),
        ],
        routes: <InterconnectRoute>[
          for (final String prefix in const <String>[
            kSrsRemoteStoreV2PathPrefix,
            kSrsRemoteStorePathPrefix,
          ])
            _route(
              InterconnectPath.under(prefix),
              (InterconnectRequest r) =>
                  _handleSrsRemoteStore(r.raw, r.upperMethod, r.path),
            ),
        ],
      ),
      // 截屏识字（Steam Deck 游戏内识字等）：处理逻辑在 fushi_screen_ocr_host.dart。
      _HostModule(
        'screenOcr',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            kScreenOcrCapability,
            () async => _trueOrAbsent(await _screenOcr?.isAvailable() ?? false),
          ),
        ],
        routes: <InterconnectRoute>[
          _route(const InterconnectPath.exact(kScreenOcrPath), (
            InterconnectRequest r,
          ) async {
            final ScreenOcrHost? screenOcr = _screenOcr;
            if (screenOcr == null) {
              return shelf.Response.notFound('Screen OCR off');
            }
            return screenOcr.handle(r.raw);
          }),
        ],
      ),
      _HostModule(
        'aiRelay',
        capabilities: <InterconnectCapability>[
          InterconnectCapability(
            kAiRelayCapability,
            () => _trueOrAbsent(_aiRelayAdvertised),
          ),
        ],
        routes: <InterconnectRoute>[
          _route(const InterconnectPath.under(kAiRelayPathPrefix), (
            InterconnectRequest r,
          ) async {
            final AiRelayHostService? relay = _aiRelay;
            if (relay == null) return shelf.Response.notFound('AI relay off');
            return handleAiRelayRequest(
              relay,
              r.raw,
              r.upperMethod,
              r.path,
              enabled: readInterconnectAiRelayEnabled(_prefs),
            );
          }),
        ],
      ),
    ];
  }

  /// 复习同步快速通道（设计 §6.3）：令牌变了立刻回，没变挂到下一次写入或超时。`own`：这段推进全是提问的
  /// 这台设备自己写 head 引起的（BUG-4382，见 [SrsChangePoll.ownOnly]）。
  Future<shelf.Response> _handleSrsChanges(shelf.Request request) async {
    final SrsChangePoll poll = await srsChanges.poll(
      int.tryParse(request.url.queryParameters['after'] ?? ''),
      reader: _pairedIdentity(request.headers['authorization']),
    );
    return jsonResponse(<String, dynamic>{
      'token': poll.token,
      'own': poll.ownOnly,
    });
  }

  /// 复习同步 v2 的参与状态（BUG-4320）：客户端一轮跑完问 host 自己加入了没有。
  shelf.Response _handleSrsSyncStatus() {
    final bool Function()? joined = srsSync2Joined;
    if (joined == null) {
      return shelf.Response.notFound('SRS sync status not reported');
    }
    return jsonResponse(<String, dynamic>{'joined': joined()});
  }

  Future<shelf.Response> _handleSrsRemoteStore(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final SrsRemoteStoreService? review = srsRemoteStoreProvider?.call();
    if (review == null) {
      // V2 端点回机读码：新客户端据「404 而没有机读码」判断对端是不认 V2 的旧主机，复习关着不能混进去。
      return reqPath.startsWith(kSrsRemoteStoreV2PathPrefix)
          ? shelf.Response(
              503,
              body: jsonEncode(<String, dynamic>{
                'error': SrsRemoteStoreError.unavailable,
              }),
              headers: const <String, String>{
                'Content-Type': 'application/json',
              },
            )
          : shelf.Response.notFound('SRS review off');
    }
    return handleSrsRemoteStoreRequest(review, request, method, reqPath);
  }

  shelf.Response _handleExtensionStatus() => jsonResponse(<String, dynamic>{
    'app': 'fushi',
    'ready': true,
    'port': port,
    // BUG-4394：能力位——扩展见到它才把词典图片 URL 的 token 换成派生 key。
    'dictionaryMediaKey': kDictionaryMediaKeyScheme,
  });

  /// 远端原盘的只读盘目录（会话 token 鉴权）。
  Future<shelf.Response> _handleDiscShare(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (_libraryService is! VideoDiscShareHost) {
      return shelf.Response.notFound('Disc share off');
    }
    return handleDiscShareRequest(
      _discShares,
      request,
      method,
      reqPath,
      issuerValid: _issuerStillValid,
    );
  }
}
