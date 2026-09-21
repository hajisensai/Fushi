// TODO-1158：HLS 画质（多码率 variant）选择域方法，part-of 抽出、共享私有作用域。
part of '../video_fushi_page.dart';

/// HLS 画质选择域（TODO-1158）：当前视频若是 HLS **master** playlist（m3u8 直链，含
/// 多档码率 variant），给播放器一个「画质」入口，列出各档（1080p/720p/… 按
/// RESOLUTION+BANDWIDTH 标注）并切换。
///
/// 切换机制走 **换 variant URL 重载**（`player.open` 换流，保持当前播放位置 + 现有字幕
/// cue）：master 的 ABR 靠 libmpv 自适应挑档，用户想锁某一档时直接播那档的子 playlist
/// URL。不依赖 libmpv 是否把 HLS variant 暴露成可切换 video track（各后端不一致），也不
/// 依赖 YouTube itag（那条画质路阻塞在 TODO-1159）——只覆盖标准 HLS master m3u8 直链。
///
/// 探测（[_detectHlsVariantsForLoad]）在常规载入后异步 fetch master 内容判定；仅网络
/// `.m3u8`/`.m3u` 直链才 fetch（避开 YouTube/googlevideo 单次 token URL），best-effort：
/// 失败/超时/非 master 都静默降级为「无画质菜单」，绝不影响播放。
extension _VideoQuality on _VideoFushiPageState {
  /// 载入后探测当前流是否为 HLS master（多档画质），填充画质菜单状态。
  ///
  /// 先复位画质态（新片默认无菜单），再仅对网络 `.m3u8`/`.m3u` 直链 fetch 内容：是
  /// master 就解析 variant（高到低排序）填入；否则保持空态。用 [_hlsDetectSeq] 去重，
  /// 探测期间换片则丢弃迟到结果。
  Future<void> _detectHlsVariantsForLoad(String? mediaUri) async {
    final int seq = ++_hlsDetectSeq;
    if (mounted) {
      _rebuild(() {
        _hlsMasterUri = null;
        _hlsVariants = const <HlsVariant>[];
        _selectedHlsVariantIndex = -1;
      });
    }
    if (mediaUri == null || !_looksLikeM3u8Url(mediaUri)) return;
    final Uri? uri = Uri.tryParse(mediaUri);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    try {
      final Map<String, String> headers = _streamHttpHeaderFields;
      final http.Response resp = await http
          .get(uri, headers: headers.isEmpty ? null : headers)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      final String content = resp.body;
      if (!isHlsMasterPlaylist(content)) return;
      final List<HlsVariant> variants = sortedHlsVariantsByQualityDesc(
        parseM3u8Master(content: content, baseUrl: mediaUri),
      );
      if (variants.isEmpty) return;
      if (seq != _hlsDetectSeq || !mounted) return; // 探测期间换片：丢弃。
      _rebuild(() {
        _hlsMasterUri = mediaUri;
        _hlsVariants = variants;
        _selectedHlsVariantIndex = -1; // 默认自动（master ABR）。
      });
    } catch (_) {
      // best-effort：网络失败 / 超时 / 解析异常 → 无画质菜单，不影响播放。
    }
  }

  /// URI 路径是否以 `.m3u8` / `.m3u` 结尾（忽略 query）。只对这类直链探测 HLS，避开
  /// YouTube/googlevideo 等非 m3u8 的单次 token 流（那条画质路走 TODO-1159）。
  bool _looksLikeM3u8Url(String uri) {
    final Uri? parsed = Uri.tryParse(uri);
    if (parsed == null) return false;
    final String path = parsed.path.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// 当前是否为 YouTube 流（据 [UrlStreamVideoClient.youtubeCaptionsUrl] 存的 watch URL）。
  /// 非空即可懒解析画质档。
  String? get _currentYoutubeWatchUrl {
    final RemoteVideoClient? client = _effectiveRemoteClient;
    if (client is UrlStreamVideoClient) {
      final String? captions = client.youtubeCaptionsUrl;
      if (captions != null && isYoutubeUrl(captions)) return captions;
    }
    return null;
  }

  bool get _isYoutubeStream => _currentYoutubeWatchUrl != null;

  /// 服务端转码画质档能力：媒体服务器（Jellyfin / Emby 按 DeviceProfile + 码率上限
  /// 决定直播放还是转码）与互联 host（按档切段转码成 HLS）共用这一条。不支持的来源
  /// 为 null。
  RemoteVideoQualityLimit? get _mediaServerQuality {
    // 能力接口不是 RemoteVideoClient 的子类型，`is` 不能在 RemoteVideoClient 上提升，
    // 先退成 Object（与 _reportRemotePlaybackStopped 同款写法）。
    final Object? client = _effectiveRemoteClient;
    if (client is! RemoteVideoQualityLimit) return null;
    // 实现了接口不等于此刻有档可选：互联 client 恒实现它，但对端跑不了 ffmpeg
    // （移动端 host）或用户关了转码开关时档位表是空的。空表还显菜单，用户点进去
    // 只会看到一屏空白。
    return client.qualityPresets.isEmpty ? null : client;
  }

  /// 视频源扩展的「线路」能力：同一集多条候选（hoster × 画质），起播由 client 按
  /// 扩展的 `preferred` / 排序默认选，用户在画质菜单里换。非扩展来源为 null。
  RemoteVideoStreamVariants? get _streamVariantsClient {
    final Object? client = _effectiveRemoteClient;
    return client is RemoteVideoStreamVariants ? client : null;
  }

  /// 当前集的线路候选；只有一条时没有可换的，菜单不显。
  List<RemoteVideoStreamVariant> get _streamVariants {
    final List<RemoteVideoStreamVariant> variants =
        _streamVariantsClient?.streamVariants ??
            const <RemoteVideoStreamVariant>[];
    return variants.length > 1 ? variants : const <RemoteVideoStreamVariant>[];
  }

  /// 画质入口是否可见：HLS master（多档码率）、YouTube 流（懒解析多档）、媒体服务器
  /// （服务器侧转码档）或视频源扩展的多条线路。
  bool get _hasQualityMenu =>
      _hlsVariants.isNotEmpty ||
      _isYoutubeStream ||
      _mediaServerQuality != null ||
      _streamVariants.isNotEmpty;

  /// 画质档数量（媒体服务器 > 扩展线路 > YouTube > HLS）。控件槽据此判是否显数字/入口。
  int get _qualityOptionCount {
    final RemoteVideoQualityLimit? server = _mediaServerQuality;
    if (server != null) return server.qualityPresets.length;
    if (_streamVariants.isNotEmpty) return _streamVariants.length;
    return _youtubeVariants.isNotEmpty
        ? _youtubeVariants.length
        : _hlsVariants.length;
  }

  /// 当前画质档标签（控件槽副标题）：媒体服务器 > 扩展线路 > YouTube > HLS；YouTube
  /// 尚未解析显「自动」占位。
  String? get _qualityCurrentLabel {
    final RemoteVideoQualityLimit? server = _mediaServerQuality;
    if (server != null) {
      final int index = server.qualityPresetIndex;
      return index < 0 || index >= server.qualityPresets.length
          ? t.video_quality_auto
          : server.qualityPresets[index].label;
    }
    final List<RemoteVideoStreamVariant> variants = _streamVariants;
    if (variants.isNotEmpty) {
      final int index = _streamVariantsClient!.streamVariantIndex;
      return index < 0 || index >= variants.length
          ? null
          : variants[index].label;
    }
    if (_youtubeVariants.isNotEmpty) {
      return (_selectedYoutubeVariantIndex < 0 ||
              _selectedYoutubeVariantIndex >= _youtubeVariants.length)
          ? t.video_quality_auto
          : _youtubeVariants[_selectedYoutubeVariantIndex].label;
    }
    if (_hlsVariants.isNotEmpty) {
      return (_selectedHlsVariantIndex < 0 ||
              _selectedHlsVariantIndex >= _hlsVariants.length)
          ? t.video_quality_auto
          : _hlsVariants[_selectedHlsVariantIndex].qualityLabel;
    }
    return _isYoutubeStream ? t.video_quality_auto : null;
  }

  /// 打开画质侧栏（右键菜单 / 设置面板共用入口）。YouTube 流首次点开即**懒解析**各档
  /// （一次 getManifest；侧栏解析中显 spinner），避免每次开视频都预解析多档拖慢起播。
  void _showQualityMenu({VideoControlSlot? sourceSlot}) {
    if (_isYoutubeStream &&
        !_youtubeVariantsResolved &&
        !_youtubeVariantsLoading) {
      unawaited(_ensureYoutubeVariantsLoaded());
    }
    _showVideoSidePanel(
      _VideoSidePanelKind.quality,
      sourceSlot: sourceSlot,
    );
  }

  /// 懒解析当前 YouTube 视频的各档 video-only 流（用户点开画质菜单时调）。填
  /// [_youtubeVariants] / [_youtubeVariantsAudioUrl] / [_youtubeVariantsDefaultIndex]。
  /// best-effort：失败 / 无分离流（仅 muxed）弹一次 OSD，画质侧栏留占位（不影响播放）。
  ///
  /// getManifest 有数秒网络往返：解析期间用户可能换集（playlist），换集会复位画质态并
  /// bump [_episodeLoadSeq]。故 await 后除 `mounted` 外**必须重校验 seq**——否则 A 集迟到
  /// 的解析结果会覆盖 B 集状态，B 的画质菜单显 A 的档、切档播 A 的流（换集状态泄漏）。
  Future<void> _ensureYoutubeVariantsLoaded() async {
    final String? watch = _currentYoutubeWatchUrl;
    if (watch == null) return;
    if (_youtubeVariantsResolved || _youtubeVariantsLoading) return;
    final int seq = _episodeLoadSeq;
    _rebuild(() => _youtubeVariantsLoading = true);
    try {
      final YoutubeVariantSet set = await resolveYoutubeVideoVariants(watch,
          playbackTargetHeight: appModel.youtubeQualityTargetHeightOrNull);
      // 换集：丢弃迟到结果（新集已复位状态、bump seq），绝不覆盖新集画质态。
      if (!mounted || seq != _episodeLoadSeq) return;
      _rebuild(() {
        _youtubeVariants = set.variants;
        _youtubeVariantsAudioUrl = set.audioStreamUrl;
        _youtubeVariantsDefaultIndex = set.defaultIndex;
        _selectedYoutubeVariantIndex = -1; // 默认自动。
        _youtubeVariantsLoading = false;
        _youtubeVariantsResolved = true; // 已解析（含空档）——不再重复 getManifest。
      });
      if (set.variants.isEmpty) {
        _showOsd(t.video_quality_load_failed, severity: ToastSeverity.error);
      }
    } catch (_) {
      if (!mounted || seq != _episodeLoadSeq) return;
      _rebuild(() => _youtubeVariantsLoading = false);
      _showOsd(t.video_quality_load_failed, severity: ToastSeverity.error);
    }
  }

  /// 切到第 [index] 档 YouTube 画质（-1=自动=解析器默认最佳）：换 video-only URL + 同
  /// audio-only 音轨重载，保持当前播放位置与现有字幕 cue。同档早退；重载后弹 OSD。
  Future<void> _switchYoutubeVariant(int index) async {
    if (index >= _youtubeVariants.length) return;
    if (index == _selectedYoutubeVariantIndex) {
      _hideVideoSidePanel();
      return;
    }
    // 自动 → 解析器默认最佳档（[_youtubeVariantsDefaultIndex]）的 URL。
    final int effectiveIndex = index < 0 ? _youtubeVariantsDefaultIndex : index;
    if (effectiveIndex < 0 || effectiveIndex >= _youtubeVariants.length) {
      _hideVideoSidePanel();
      return;
    }
    // BUG-2507：googlevideo 直链只接受有界 Range，交给内核前换成本地分块中继地址
    // （与 [UrlStreamVideoClient.remoteVideoStreamUrls] 同一口径）。
    final Map<String, String> headers = _streamHttpHeaderFields;
    final String videoUrl = await relayYoutubeStreamUrl(
        _youtubeVariants[effectiveIndex].videoUrl, headers);
    final String? audioRaw = _youtubeVariantsAudioUrl;
    final String? audioUrl = audioRaw == null
        ? null
        : await relayYoutubeStreamUrl(audioRaw, headers);
    if (!mounted) return;
    final VideoPlayerController? controller = _controller;
    final int posMs = controller?.positionMs ?? 0;
    final List<AudioCue> cues = controller != null
        ? List<AudioCue>.of(controller.cues)
        : const <AudioCue>[];
    _hideVideoSidePanel();
    // 乐观更新选中档（-1 保留为「自动」显示）。
    _rebuild(() => _selectedYoutubeVariantIndex = index);
    // detectHls=false：googlevideo URL 非 m3u8，且不碰 YouTube 档列表。音轨保持同一
    // audio-only 流（切档只换画面清晰度）。字幕经现有 cue + 当前 source 保留。
    await _applyLoad(
      videoPath: null,
      mediaUri: videoUrl,
      cues: cues,
      title: _title ?? '',
      initialPositionMs: posMs,
      startIntent: EpisodeStartIntent.explicitCue,
      externalSubtitlePath: _currentSubtitleSource,
      externalAudioTrackUrl: audioUrl,
      detectHls: false,
    );
    if (!mounted) return;
    final String label =
        index < 0 ? t.video_quality_auto : _youtubeVariants[index].label;
    _showOsd(t.video_quality_switched(label: label), icon: Icons.high_quality);
  }

  /// 切到媒体服务器第 [index] 档（-1 = 自动）：偏好落库、写进 client，先关掉当前
  /// 会话（服务器上的转码任务随之停），再按新档重新协商起播、回到当前位置。
  // ── 互联「自动」档的自适应 ──────────────────────────────────────────────

  /// 当前远端 client 是不是支持自适应的互联 host（有档可选才谈得上自适应）。
  InterconnectSyncBackend? get _adaptiveQualityClient {
    final Object? client = _effectiveRemoteClient;
    if (client is! InterconnectSyncBackend) return null;
    return client.qualityPresets.isEmpty ? null : client;
  }

  /// 起播 / 换集后重新开始观察。
  ///
  /// 只在用户选「自动」时跑：显式选了某一档就是选定了，自动改掉它会让设置看起来
  /// 自己会动。
  void _restartAdaptiveQuality() {
    _stopAdaptiveQuality();
    final InterconnectSyncBackend? client = _adaptiveQualityClient;
    if (client == null) return;
    if (client.qualityPresetIndex >= 0) return;
    // 按 host 链路重算（换 peer / 从公网回到局域网都要重新起步），不是无脑 ??=。
    client.ensureAdaptiveQualityStart();
    _adaptiveQuality.reset();
    _adaptiveQualityTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickAdaptiveQuality(),
    );
  }

  void _stopAdaptiveQuality() {
    _adaptiveQualityTimer?.cancel();
    _adaptiveQualityTimer = null;
  }

  /// 一拍采样：把播放器的缓冲状态喂给决策器，它说换就换。
  void _tickAdaptiveQuality() {
    if (!mounted || _adaptiveQualitySwitching) return;
    final InterconnectSyncBackend? client = _adaptiveQualityClient;
    final VideoPlayerController? controller = _controller;
    if (client == null || controller == null) {
      _stopAdaptiveQuality();
      return;
    }
    // 用户在播放途中显式选了档 → 自动接管结束。
    if (client.qualityPresetIndex >= 0) {
      _stopAdaptiveQuality();
      return;
    }
    // 暂停时不评估：暂停本来就不下载，缓冲深度与卡顿都不反映网况。
    if (!controller.isPlaying) return;

    final AdaptiveQualityDecision? decision = _adaptiveQuality.tick(
      currentIndex: client.adaptiveQualityIndex ?? -1,
      buffering: controller.isBuffering,
      cacheSeconds: controller.networkCacheSeconds.value,
    );
    if (decision == null) return;
    unawaited(_applyAdaptiveQuality(client, decision));
  }

  /// 执行自适应换档：换的是「自动」策略下的当前取值，**不动用户偏好**。
  ///
  /// 重取流的流程与用户手动换档同一条（停旧会话 → 重新协商 → 回到原位置），差别只在
  /// 不写偏好、OSD 文案说明是自动调整的。
  Future<void> _applyAdaptiveQuality(
    InterconnectSyncBackend client,
    AdaptiveQualityDecision decision,
  ) async {
    _adaptiveQualitySwitching = true;
    try {
      final int posMs = _controller?.positionMs ?? 0;
      client.adaptiveQualityIndex = decision.targetIndex;
      await _reportRemotePlaybackStopped(
        info: _effectiveRemoteInfo,
        client: _effectiveRemoteClient,
        positionMs: posMs,
        generation: _remotePlaybackGeneration,
      );
      if (!mounted) return;
      await _loadRemoteEpisode(
        _currentEpisode < 0 ? 0 : _currentEpisode,
        // 与手动换档同理：必须是 explicitCue，否则 near-end 判据会把「快看完时换档」
        // 直接归零回片头。
        startIntent: EpisodeStartIntent.explicitCue,
        initialPositionMsOverride: posMs,
      );
      if (!mounted) return;
      // `qualityPresets` 在 host 不支持转码时是空表，而 `_hostTranscodeAvailable`
      // 正由上一行 `_loadRemoteEpisode` 内部的 /streamurl 响应重新赋值——换档期间
      // host 用户关掉「为对端转码视频」就足以让表变空。调用点是 unawaited，越界会
      // 变成未捕获的 zone error。
      final List<MediaServerQualityPreset> presets = client.qualityPresets;
      final String label = decision.targetIndex < 0 ||
              decision.targetIndex >= presets.length
          ? t.video_quality_auto
          : presets[decision.targetIndex].label;
      _showOsd(
        decision.reason == AdaptiveQualityReason.stall
            ? t.video_quality_auto_lowered(label: label)
            : t.video_quality_auto_raised(label: label),
        icon: Icons.network_check,
      );
    } finally {
      _adaptiveQualitySwitching = false;
    }
  }

  /// 画质档偏好的落点按来源分流。
  ///
  /// 互联与媒体服务器（Jellyfin/Emby）的档位阶梯**不同**（互联整体更低，它要解决的
  /// 是人在外面用手机网络），共用一个下标会让同一个数字在两边指向不同画质——用户在
  /// Emby 上选的 `2` 跑到互联上就成了另一档。
  int _readQualityPresetIndex(Object client) => client is InterconnectSyncBackend
      ? appModel.prefsRepo.interconnectQualityPresetIndex
      : appModel.prefsRepo.mediaServerQualityPresetIndex;

  Future<void> _writeQualityPresetIndex(Object client, int index) =>
      client is InterconnectSyncBackend
          ? appModel.prefsRepo.setInterconnectQualityPresetIndex(index)
          : appModel.prefsRepo.setMediaServerQualityPresetIndex(index);

  Future<void> _switchMediaServerQuality(int index) async {
    final RemoteVideoQualityLimit? server = _mediaServerQuality;
    if (server == null || index >= server.qualityPresets.length) return;
    final int target = index < 0 ? -1 : index;
    if (target == server.qualityPresetIndex) {
      _hideVideoSidePanel();
      return;
    }
    final int posMs = _controller?.positionMs ?? 0;
    _hideVideoSidePanel();
    await _writeQualityPresetIndex(server, target);
    if (!mounted) return;
    _rebuild(() => server.qualityPresetIndex = target);
    // 用户显式选档 = 自动接管结束；选回「自动」则把自适应的当前取值清掉，让它从
    // 起点判据重新开始，而不是接着上次自动降到的那一档跑。
    if (server is InterconnectSyncBackend) {
      if (target >= 0) {
        _stopAdaptiveQuality();
      } else {
        server.adaptiveQualityIndex = null;
      }
    }
    await _reportRemotePlaybackStopped(
      info: _effectiveRemoteInfo,
      client: _effectiveRemoteClient,
      positionMs: posMs,
      generation: _remotePlaybackGeneration,
    );
    if (!mounted) return;
    await _loadRemoteEpisode(
      _currentEpisode < 0 ? 0 : _currentEpisode,
      startIntent: EpisodeStartIntent.explicitCue,
      initialPositionMsOverride: posMs,
    );
    if (!mounted) return;
    final List<MediaServerQualityPreset> presets = server.qualityPresets;
    final String label = target < 0 || target >= presets.length
        ? t.video_quality_auto
        : presets[target].label;
    _showOsd(t.video_quality_switched(label: label), icon: Icons.high_quality);
  }

  /// 切到视频源扩展的第 [index] 条线路：选择记进 client（钉到当前集），再按当前集
  /// 重新取流起播、回到当前位置——与媒体服务器换档同一条路（[_loadRemoteEpisode]
  /// 会重新读 client 的防盗链头，这条线路的头随之下发）。同条早退；重载后弹 OSD。
  Future<void> _switchStreamVariant(int index) async {
    final RemoteVideoStreamVariants? client = _streamVariantsClient;
    if (client == null) return;
    final List<RemoteVideoStreamVariant> variants = client.streamVariants;
    if (index < 0 || index >= variants.length) return;
    if (index == client.streamVariantIndex) {
      _hideVideoSidePanel();
      return;
    }
    final int posMs = _controller?.positionMs ?? 0;
    final String label = variants[index].label;
    _hideVideoSidePanel();
    client.streamVariantIndex = index;
    await _loadRemoteEpisode(
      _currentEpisode < 0 ? 0 : _currentEpisode,
      startIntent: EpisodeStartIntent.explicitCue,
      initialPositionMsOverride: posMs,
    );
    if (!mounted) return;
    _showOsd(t.video_quality_switched(label: label), icon: Icons.high_quality);
  }

  /// 切到第 [index] 档画质（-1=自动/master ABR）：换 variant URL 重载，保持当前播放位置
  /// 与现有字幕 cue。同档早退；重载后弹 OSD。
  Future<void> _switchHlsVariant(int index) async {
    final String? master = _hlsMasterUri;
    if (master == null) return;
    if (index >= _hlsVariants.length) return;
    if (index == _selectedHlsVariantIndex) {
      _hideVideoSidePanel();
      return;
    }
    final String target = index < 0 ? master : _hlsVariants[index].url;
    final VideoPlayerController? controller = _controller;
    final int posMs = controller?.positionMs ?? 0;
    final List<AudioCue> cues = controller != null
        ? List<AudioCue>.of(controller.cues)
        : const <AudioCue>[];
    _hideVideoSidePanel();
    // 乐观更新选中档（菜单高亮即时反映）。
    _rebuild(() => _selectedHlsVariantIndex = index);
    // explicitCue：不做近尾重置，精确 seek 回当前位置。detectHls=false：不拿
    // variant（media playlist）URL 重探测把档位列表清空。字幕经现有 cue + 当前 source
    // 保留（externalSubtitlePath 非空即让 controller 跳过内嵌自动抽取，避免重复）。
    await _applyLoad(
      videoPath: null,
      mediaUri: target,
      cues: cues,
      title: _title ?? '',
      initialPositionMs: posMs,
      startIntent: EpisodeStartIntent.explicitCue,
      externalSubtitlePath: _currentSubtitleSource,
      detectHls: false,
    );
    if (!mounted) return;
    final String label =
        index < 0 ? t.video_quality_auto : _hlsVariants[index].qualityLabel;
    _showOsd(t.video_quality_switched(label: label), icon: Icons.high_quality);
  }

  /// 画质侧栏面板：「自动」+ 各档 variant（高到低），当前档打勾。YouTube 流优先显其懒解析
  /// 的各档（解析中显 spinner）；否则显 HLS 档；空态显示标题占位。
  Widget _buildQualitySidePanel(VideoPlayerController controller) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    // 媒体服务器分支：固定阶梯（自动 + 各档），当前档打勾。
    final RemoteVideoQualityLimit? server = _mediaServerQuality;
    if (server != null) {
      final List<MediaServerQualityPreset> presets = server.qualityPresets;
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          _buildMediaServerQualityTile(
            cs,
            icon: Icons.auto_awesome,
            label: t.video_quality_auto,
            index: -1,
            selected: server.qualityPresetIndex < 0,
          ),
          for (int i = 0; i < presets.length; i++)
            _buildMediaServerQualityTile(
              cs,
              icon: Icons.high_quality,
              label: presets[i].label,
              index: i,
              selected: server.qualityPresetIndex == i,
            ),
        ],
      );
    }
    // 视频源扩展分支：当前集的各条线路（扩展排好的顺序），正在播的打勾；线路本身
    // 是 HLS master 时把它的码率档接在下面（换线路与换档互不覆盖）。
    final List<RemoteVideoStreamVariant> streamVariants = _streamVariants;
    if (streamVariants.isNotEmpty) {
      final int current = _streamVariantsClient!.streamVariantIndex;
      final List<HlsVariant> hls = _hlsVariants;
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          for (int i = 0; i < streamVariants.length; i++)
            ListTile(
              key: ValueKey<String>('video-quality-stream-variant-$i'),
              dense: true,
              leading: const Icon(Icons.alt_route),
              title: Text(streamVariants[i].label),
              selected: current == i,
              selectedColor: cs.primary,
              trailing:
                  current == i ? Icon(Icons.check, color: cs.primary) : null,
              onTap: () => unawaited(_switchStreamVariant(i)),
            ),
          if (hls.isNotEmpty) ...<Widget>[
            const Divider(),
            _buildQualityTile(
              cs,
              icon: Icons.auto_awesome,
              label: t.video_quality_auto,
              index: -1,
            ),
            for (int i = 0; i < hls.length; i++)
              _buildQualityTile(
                cs,
                icon: Icons.high_quality,
                label: hls[i].qualityLabel,
                index: i,
              ),
          ],
        ],
      );
    }
    // YouTube 分支：懒解析。解析中显 spinner；已解析显各档；解析失败/无分离流留占位。
    if (_isYoutubeStream) {
      if (_youtubeVariants.isEmpty && _youtubeVariantsLoading) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  t.video_quality_loading,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      }
      if (_youtubeVariants.isNotEmpty) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: <Widget>[
            _buildYoutubeQualityTile(
              cs,
              icon: Icons.auto_awesome,
              label: t.video_quality_auto,
              index: -1,
            ),
            for (int i = 0; i < _youtubeVariants.length; i++)
              _buildYoutubeQualityTile(
                cs,
                icon: Icons.high_quality,
                label: _youtubeVariants[i].label,
                index: i,
              ),
          ],
        );
      }
      // UI 巡检 PR-4：空态用专属说明文案（此前复用面板标题「画质」当空态，
      // 看起来像面板坏了没加载出来）。
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.video_quality_empty,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    final List<HlsVariant> variants = _hlsVariants;
    if (variants.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.video_quality_empty,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        _buildQualityTile(
          cs,
          icon: Icons.auto_awesome,
          label: t.video_quality_auto,
          index: -1,
        ),
        for (int i = 0; i < variants.length; i++)
          _buildQualityTile(
            cs,
            icon: Icons.high_quality,
            label: variants[i].qualityLabel,
            index: i,
          ),
      ],
    );
  }

  Widget _buildQualityTile(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool selected = _selectedHlsVariantIndex == index;
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(label),
      selected: selected,
      selectedColor: cs.primary,
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () => unawaited(_switchHlsVariant(index)),
    );
  }

  Widget _buildMediaServerQualityTile(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required int index,
    required bool selected,
  }) {
    return ListTile(
      key: ValueKey<String>('video-quality-media-server-$index'),
      dense: true,
      leading: Icon(icon),
      title: Text(label),
      selected: selected,
      selectedColor: cs.primary,
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () => unawaited(_switchMediaServerQuality(index)),
    );
  }

  Widget _buildYoutubeQualityTile(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool selected = _selectedYoutubeVariantIndex == index;
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(label),
      selected: selected,
      selectedColor: cs.primary,
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () => unawaited(_switchYoutubeVariant(index)),
    );
  }
}
