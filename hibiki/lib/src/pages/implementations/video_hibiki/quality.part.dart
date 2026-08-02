// TODO-1158：HLS 画质（多码率 variant）选择域方法，part-of 抽出、共享私有作用域。
part of '../video_hibiki_page.dart';

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
extension _VideoQuality on _VideoHibikiPageState {
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

  /// 画质入口是否可见：HLS master（多档码率）或 YouTube 流（懒解析多档）。
  bool get _hasQualityMenu => _hlsVariants.isNotEmpty || _isYoutubeStream;

  /// 画质档数量（YouTube 优先，其次 HLS）。控件槽据此判是否显数字/入口。
  int get _qualityOptionCount => _youtubeVariants.isNotEmpty
      ? _youtubeVariants.length
      : _hlsVariants.length;

  /// 当前画质档标签（控件槽副标题）：YouTube > HLS；YouTube 尚未解析显「自动」占位。
  String? get _qualityCurrentLabel {
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
      final YoutubeVariantSet set = await resolveYoutubeVideoVariants(watch);
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
    final String videoUrl = _youtubeVariants[effectiveIndex].videoUrl;
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
      externalAudioTrackUrl: _youtubeVariantsAudioUrl,
      detectHls: false,
    );
    if (!mounted) return;
    final String label =
        index < 0 ? t.video_quality_auto : _youtubeVariants[index].label;
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
