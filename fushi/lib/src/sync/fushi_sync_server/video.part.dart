part of '../fushi_sync_server.dart';

/// 视频域（B3 按域拆出）：视频清单 / 流 URL / 流 token 签发与上限、封面、内嵌字幕轨。
/// 方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerVideo on FushiSyncServer {
  Future<shelf.Response> _handleLibraryVideos(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    // GET /api/library/videos — 列表（需 Basic 鉴权，中间件已处理）
    if (reqPath == '/api/library/videos') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteVideoInfo v in list)
            _remoteVideoJsonForRequest(v, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // GET /api/library/videos/<id>/cover — 视频封面（需 Basic 鉴权）
    final String? coverId = _extractVideoId(reqPath, 'cover');
    if (coverId != null) {
      if (method != 'GET') return shelf.Response(405);
      final File? cover = await _resolveVideoCover(svc, coverId);
      if (cover == null) {
        return shelf.Response.notFound('Video cover not found');
      }
      return serveFileWithRange(cover, request);
    }

    // GET /api/library/videos/<id>/streamurl — 签发短时 token（需 Basic 鉴权）
    final String? streamUrlId = _extractVideoId(reqPath, 'streamurl');
    if (streamUrlId != null) {
      if (method != 'GET') return shelf.Response(405);
      // TODO-885: 远端播放列表按集——?episode=N 决定流式哪一集（DB-only 反查）。
      final int episodeIndex = _episodeIndexFromRequest(request);
      final File? file =
          await svc.resolveVideoFile(streamUrlId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      // BUG-1568：签发前先按 TTL 清过期，再把数量收束到 [_maxVideoStreamTokens] 内
      // （淘汰最旧者）。对照 audio token 的 BUG-908(a) 修法：消费侧（GET /stream）的
      // prune 等不到「只签发不取流」的调用者，上限必须在签发侧强制。
      _pruneVideoTokens();
      _enforceVideoTokenCap();
      final String tokenValue = _generateVideoToken();
      _videoStreamTokens[tokenValue] = _VideoStreamToken(
        videoId: streamUrlId,
        createdAt: _now(),
        episodeIndex: episodeIndex,
      );
      final String encodedId = Uri.encodeFull(streamUrlId);
      // stream / subtitle URL 都带 episode=N，让 client 取流 / 下字幕命中同一集。
      final Map<String, String> streamQuery = <String, String>{
        'token': tokenValue,
        if (episodeIndex > 0) 'episode': '$episodeIndex',
      };
      final Uri streamUri = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/stream',
        queryParameters: streamQuery,
      );
      // subtitle URL 不含 token（走 Basic 鉴权），但带 episode=N。
      final File? sub = await svc.resolveVideoSubtitle(streamUrlId,
          episodeIndex: episodeIndex);
      final Uri? subtitleUri = sub != null
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            )
          : null;
      final List<RemoteVideoEmbeddedSubtitleTrack> embeddedTracks =
          await _embeddedSubtitleTracksForRequest(
        file,
        request,
        streamUrlId,
        episodeIndex,
      );
      return jsonResponse(<String, dynamic>{
        'url': streamUri.toString(),
        'subtitleUrl': subtitleUri?.toString(),
        if (sub != null) 'subtitleFileName': p.basename(sub.path),
        if (embeddedTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track in embeddedTracks)
              track.toJson(),
          ],
      });
    }

    // GET /api/library/videos/<id>/stream — 流式传输（豁免 Basic，靠 token 鉴权）
    final String? streamId = _extractVideoId(reqPath, 'stream');
    if (streamId != null) {
      if (method != 'GET') return shelf.Response(405);
      _pruneVideoTokens();
      final String? tokenValue = request.url.queryParameters['token'];
      if (tokenValue == null || tokenValue.isEmpty) {
        return shelf.Response(401,
            body: 'Missing token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
      if (tok == null || tok.videoId != streamId) {
        return shelf.Response(403,
            body: 'Invalid or expired token',
            headers: <String, String>{'Content-Type': 'text/plain'});
      }
      // TODO-885: 用 token 绑定的集下标反查（token 是 streamurl 签发时定的，client 不能
      // 自己改集——?episode 只决定 streamurl 阶段，stream 阶段以 token 为准）。
      final File? file =
          await svc.resolveVideoFile(streamId, episodeIndex: tok.episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      return serveFileWithRange(file, request);
    }

    // GET /api/library/videos/<id>/subtitle — 字幕（需 Basic 鉴权，中间件已处理）
    // PUT 同路径 — client→host 上传该视频的外挂字幕 sidecar（BUG-964，随
    // syncVideoFiles live push）。后缀（`.srt` / `.ja.srt` …）经
    // X-Hibiki-Subtitle-Suffix header 上报，服务端白名单校验；老 host 无此分支
    // 对 PUT 回 405，client 据此优雅降级。
    final String? subtitleId = _extractVideoId(reqPath, 'subtitle');
    if (subtitleId != null) {
      if (method == 'PUT') {
        final String suffix =
            _decodeHeaderValue(request, 'x-hibiki-subtitle-suffix') ?? '';
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_subtitle_in');
        final File tmp = File(p.join(tmpDir.path, 'upload.bin'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importVideoSubtitle(tmp, id: subtitleId, suffix: suffix);
          return shelf.Response(200);
        } on ArgumentError catch (e) {
          return shelf.Response(400, body: 'Invalid subtitle upload: $e');
        } on StateError {
          return shelf.Response.notFound('Video not found');
        } catch (e) {
          return shelf.Response(500, body: 'Subtitle import failed: $e');
        } finally {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }
      }
      if (method != 'GET') return shelf.Response(405);
      final int episodeIndex = _episodeIndexFromRequest(request);
      final String? embeddedIndexText =
          request.url.queryParameters['embeddedStreamIndex'];
      final File? sub = embeddedIndexText == null
          ? await svc.resolveVideoSubtitle(subtitleId,
              episodeIndex: episodeIndex)
          : await _resolveEmbeddedVideoSubtitle(
              svc,
              subtitleId,
              int.tryParse(embeddedIndexText),
              episodeIndex,
            );
      if (sub == null) return shelf.Response.notFound('Subtitle not found');
      final int length = sub.lengthSync();
      return shelf.Response.ok(
        sub.openRead(),
        headers: <String, String>{
          'Content-Type': _guessContentType(sub.path),
          'Content-Length': '$length',
        },
      );
    }

    // GET/PUT /api/library/videos/<id>/position — 跨设备播放断点（TODO-653）
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    final String? positionId = _extractVideoId(reqPath, 'position');
    if (positionId != null) {
      final int episodeIndex = _episodeIndexFromRequest(request);
      // 先确认该视频 id（含集下标）在 host DB 真实存在，防止任意 id 写脏 prefs。
      final File? file =
          await svc.resolveVideoFile(positionId, episodeIndex: episodeIndex);
      if (file == null) return shelf.Response.notFound('Video not found');
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p = await svc
              .getVideoPosition(positionId, episodeIndex: episodeIndex);
          return jsonResponse(<String, dynamic>{
            'positionMs': p.positionMs,
            'positionUpdatedAtMs': p.updatedAtMs,
          });
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int posMs = (json['positionMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0;
          await svc.putVideoPosition(positionId, posMs, updatedAtMs,
              episodeIndex: episodeIndex);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    // GET/PUT /api/library/videos/<id>/playback — 播放偏好跨设备同步（BUG-1620
    // 调轴起步，播放偏好同步泛化批扩展为统一带戳字段模型：调轴/音轨/副字幕源/
    // 副字幕调轴；与 /position 分支对称）。GET 拉 host 生效状态；PUT 上报本端
    // 带戳字段（host 侧逐字段「严格较新时间戳者胜」+ clamp + 存在性闸门，见
    // [VideoPlaybackSyncHost]）。老 host 无此分支 → 404，client 上报 best-effort
    // 吞掉即可（本地 prefs 已持久化）。
    final String? playbackId = _extractVideoId(reqPath, 'playback');
    if (playbackId != null) {
      // 显式 `as`：[VideoPlaybackSyncHost] 不是 [FushiLibraryHostService] 的子
      // 类型，Dart 不做交集提升（与 [VideoDeletionHost] 的探测写法一致）。
      if (svc is! VideoPlaybackSyncHost) {
        return shelf.Response.notFound('Video playback sync not supported');
      }
      final VideoPlaybackSyncHost playbackHost = svc as VideoPlaybackSyncHost;
      // 存在性闸门（一次 DB 单行查询）：防任意 id 写脏 prefs / 枚举探测。
      if (!await svc.videoExists(playbackId)) {
        return shelf.Response.notFound('Video not found');
      }
      switch (method) {
        case 'GET':
          final VideoPlaybackSyncState s =
              await playbackHost.getVideoPlayback(playbackId);
          return jsonResponse(s.toJson());
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          await playbackHost.putVideoPlayback(
              playbackId, VideoPlaybackSyncState.fromJson(json));
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    // GET /api/library/videos/<id>/clipaudio?startMs=&endMs=&episode=&audioStreamIndex=
    //     &audioStreamCount=&ac=&bitrate= — BUG-1004：host 端本地裁 mining 句子音频段并回传。
    // 需 Basic 鉴权（中间件已处理，clipaudio 不在 /stream 豁免名单）。client ffmpeg 打不开
    // host 自签 https / token 流（移动端自编 ffmpeg-kit TLS pin 残余缺口）时改走此端点——host
    // 用本地文件裁、不经网络/TLS，只回传几十 KB 的成品音频，不做远端 seek。老 host 无此分支
    // 对该子路径的 GET 走下方兜底 → 404，client 据此回退直连 ffmpeg 抽取（Never break userspace）。
    final String? clipAudioId = _extractVideoId(reqPath, 'clipaudio');
    if (clipAudioId != null) {
      if (method != 'GET') return shelf.Response(405);
      final int episodeIndex = _episodeIndexFromRequest(request);
      final int? startMs =
          int.tryParse(request.url.queryParameters['startMs'] ?? '');
      final int? endMs =
          int.tryParse(request.url.queryParameters['endMs'] ?? '');
      if (startMs == null || endMs == null || endMs <= startMs) {
        return shelf.Response(400, body: 'Invalid clip range');
      }
      final int? audioStreamIndex =
          int.tryParse(request.url.queryParameters['audioStreamIndex'] ?? '');
      final int? audioStreamCount =
          int.tryParse(request.url.queryParameters['audioStreamCount'] ?? '');
      final int audioChannels =
          int.tryParse(request.url.queryParameters['ac'] ?? '') ?? 1;
      final String audioBitrate =
          request.url.queryParameters['bitrate'] ?? '64k';
      final File? clip = await svc.clipVideoAudio(
        clipAudioId,
        startMs: startMs,
        endMs: endMs,
        episodeIndex: episodeIndex,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        audioChannels: audioChannels,
        audioBitrate: audioBitrate,
      );
      if (clip == null) {
        return shelf.Response.notFound('Clip unavailable');
      }
      try {
        final Uint8List bytes = await clip.readAsBytes();
        return shelf.Response.ok(
          bytes,
          headers: <String, String>{'Content-Type': 'audio/aac'},
        );
      } finally {
        // 裁到独立临时目录，回传后连目录一并清（clipVideoAudio 建的 temp 目录）。
        try {
          clip.parent.deleteSync(recursive: true);
        } catch (_) {
          // best-effort
        }
      }
    }

    // PUT /api/library/videos/<id> — client→host 上传本地视频文件并注册进 host 视频库
    // （syncVideoFiles 开关驱动的 live push）。走到此处的 PUT 必是「裸 id 无 suffix」：
    // 所有带 suffix 的端点（cover/streamurl/stream/subtitle/position）已在上方消化（非
    // GET 的 suffix 请求返回 405，position 的 PUT 已被上面 switch 接管）。id 允许含 `/`
    // （bookUid 形如 video/xxx），但拒 `..` / `\`（路径穿越）。title / 原始文件名经
    // URL-encode 走 header（HTTP header 只收 ASCII，日文标题必须编码）。
    if (method == 'PUT' && reqPath.startsWith('/api/library/videos/')) {
      final String? id = _extractBareVideoId(reqPath);
      if (id == null) {
        return shelf.Response(400, body: 'Invalid video id');
      }
      final String title =
          _decodeHeaderValue(request, 'x-hibiki-video-title') ?? id;
      final String? fileName =
          _decodeHeaderValue(request, 'x-hibiki-video-filename');
      final Directory tmpDir =
          Directory.systemTemp.createTempSync('hibiki_video_in');
      final File tmp = File(p.join(tmpDir.path, 'upload.bin'));
      final IOSink sink = tmp.openWrite();
      try {
        await request.read().forEach(sink.add);
        await sink.close();
        await svc.importVideo(tmp,
            id: id, title: title, originalFileName: fileName);
        return shelf.Response(200);
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {
          // best-effort
        }
        return shelf.Response(500, body: 'Video import failed: $e');
      } finally {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {
          // best-effort
        }
      }
    }

    // DELETE /api/library/videos/<id> — client→host 删除远端视频。两个来源：远端视频卡
    // 长按「删除」，以及本机删除时选了「从所有设备删除」后同步把墓碑推给 host。
    // 与 PUT 同样只接「裸 id 无 suffix」（带 suffix 的端点已在上方消化）。
    //
    // host 未实现 [VideoDeletionHost]（旧版本 app / 测试 fake）时**不接管**，落到下方
    // 404 —— 这正是 client 侧的能力探测信号，[InterconnectSyncBackend.deleteRemoteVideo]
    // 按 404/405 判「该 host 不支持」并优雅降级，不报错给用户。
    // 204 与其它资产链的 DELETE（[_serveAssetPackage]）保持同一成功码。
    if (method == 'DELETE' && reqPath.startsWith('/api/library/videos/')) {
      final String? id = _extractBareVideoId(reqPath);
      if (id == null) {
        return shelf.Response(400, body: 'Invalid video id');
      }
      // 显式 `as` 而不是靠类型提升：[VideoDeletionHost] 不是 [FushiLibraryHostService]
      // 的子类型，Dart 不做交集提升（写 `svc.deleteVideo` 会报未定义）。与
      // [DeletionTombstoneHost] 的探测写法一致。
      if (svc is! VideoDeletionHost) {
        return shelf.Response.notFound('Video deletion not supported');
      }
      try {
        await (svc as VideoDeletionHost).deleteVideo(id);
        return shelf.Response(204);
      } catch (e) {
        return shelf.Response(500, body: 'Video delete failed: $e');
      }
    }

    return shelf.Response.notFound('Not found');
  }

  Map<String, Object?> _remoteVideoJsonForRequest(
    RemoteVideoInfo video,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = video.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(video.coverPath) != null) {
      final String encodedId = Uri.encodeFull(video.id);
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        path: '/api/library/videos/$encodedId/cover',
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<List<RemoteVideoEmbeddedSubtitleTrack>>
      _embeddedSubtitleTracksForRequest(
    File videoFile,
    shelf.Request request,
    String videoId,
    int episodeIndex,
  ) async {
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    final String encodedId = Uri.encodeFull(videoId);
    final String videoStem = p.basenameWithoutExtension(videoFile.path);
    return <RemoteVideoEmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack track in tracks)
        _remoteEmbeddedSubtitleTrackForRequest(
          track,
          request,
          encodedId,
          videoStem,
          episodeIndex,
        ),
    ];
  }

  RemoteVideoEmbeddedSubtitleTrack _remoteEmbeddedSubtitleTrackForRequest(
    EmbeddedSubtitleTrack track,
    shelf.Request request,
    String encodedId,
    String videoStem,
    int episodeIndex,
  ) {
    final String? extension = subtitleExtensionForCodec(track.codec);
    final bool isText = extension != null;
    return RemoteVideoEmbeddedSubtitleTrack(
      streamIndex: track.streamIndex,
      codec: track.codec,
      language: track.language,
      title: track.title,
      isText: isText,
      url: isText
          ? request.requestedUri.replace(
              path: '/api/library/videos/$encodedId/subtitle',
              queryParameters: <String, String>{
                'embeddedStreamIndex': '${track.streamIndex}',
                if (episodeIndex > 0) 'episode': '$episodeIndex',
              },
            ).toString()
          : null,
      fileName: isText
          ? '${_safeDownloadStem(videoStem)}.embedded.${track.streamIndex}$extension'
          : null,
    );
  }

  Future<File?> _resolveEmbeddedVideoSubtitle(
    FushiLibraryHostService service,
    String id,
    int? streamIndex,
    int episodeIndex,
  ) async {
    if (streamIndex == null || streamIndex < 0) return null;
    final File? videoFile =
        await service.resolveVideoFile(id, episodeIndex: episodeIndex);
    if (videoFile == null) return null;
    final List<EmbeddedSubtitleTrack> tracks =
        await listEmbeddedSubtitleTracks(videoFile.path);
    for (final EmbeddedSubtitleTrack track in tracks) {
      if (track.streamIndex != streamIndex) continue;
      if (subtitleFormatForCodec(track.codec) == null) return null;
      return extractEmbeddedSubtitleTrackFile(
        videoPath: videoFile.path,
        streamIndex: track.streamIndex,
        codec: track.codec,
      );
    }
    return null;
  }

  Future<File?> _resolveVideoCover(
    FushiLibraryHostService service,
    String id,
  ) async {
    // 单行直查（videoCoverPath = 1 次 DB 查询 + stat）。旧实现每张封面请求重跑
    // 整份 listVideos()（每行一次目录扫描 + 多次 DB 查询），N 张封面 = O(N²)，
    // 500 视频的封面墙一次浏览拖成分钟级——这是「互联视频极慢」的主根因。
    return _coverFile(await service.videoCoverPath(id));
  }

  String _generateVideoToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneVideoTokens() {
    // 视频播放时间长，token 有效期设为 6 小时
    final DateTime cutoff = _now().subtract(const Duration(hours: 6));
    _videoStreamTokens.removeWhere(
      (String _, _VideoStreamToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  /// BUG-1568：守住视频流 token 上限。TTL prune 之后仍达到 [_maxVideoStreamTokens]
  /// 时，按 createdAt 淘汰最旧者直到回到上限内（对照 [RemoteAudioTokenStore]）。
  /// 签发前调用，使插入新 token 后总数 <= [_maxVideoStreamTokens]。
  void _enforceVideoTokenCap() {
    while (_videoStreamTokens.length >= _maxVideoStreamTokens) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, _VideoStreamToken> e
          in _videoStreamTokens.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _videoStreamTokens.remove(oldestKey);
    }
  }
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

/// BUG-1568（BUG-908(a) 的视频同形问题）：视频流 token 的数量上限。签发侧
/// （GET /streamurl）先按 TTL prune、再淘汰最旧者收束到上限内。此前 prune 只挂在
/// GET /stream 消费侧——只 GET /streamurl 却从不取流的调用者会让
/// [_videoStreamTokens] 无界堆积（6 小时 TTL 内每次签发都是净增长）。
const int _maxVideoStreamTokens = 128;

// ── 视频端点（P4-2）──────────────────────────────────────────────────────────

/// 从视频子路径提取视频 id。
///
/// [reqPath] 已经过 Uri.decodeFull 解码（含前导 `/`）。
/// 格式为 `/api/library/videos/<id>/<suffix>`，其中：
/// - [suffix] 为 `stream`、`streamurl`、`subtitle` 或 `cover`
/// - id 允许包含 `/`（如 `video/my_film`），但不允许 `..`（路径穿越）
///
/// 解析失败（id 为空或含 `..`）时返回 null。
/// 解析 `?episode=N` query 成集下标（TODO-885）；缺省 / 非法 / 负数都回退 0
/// （= 当前集 / 单视频，向后兼容）。
int _episodeIndexFromRequest(shelf.Request request) {
  final String? raw = request.url.queryParameters['episode'];
  if (raw == null) return 0;
  final int? n = int.tryParse(raw);
  if (n == null || n < 0) return 0;
  return n;
}

/// 裸视频 id（`/api/library/videos/<id>`，**无** suffix）的提取 + 穿越校验。
///
/// PUT（client→host 上传）与 DELETE（client→host 删除）共用这一处：两者都只接
/// 「裸 id」，带 suffix 的子路由（cover / streamurl / stream / subtitle / position /
/// clipaudio）在上方已被 [_extractVideoId] 消化掉。
///
/// 收敛成函数而不是在每个端点里手抄穿越判断——安全闸门靠复制粘贴维持，抄漏一处
/// 就是真漏洞（同 [_rejectUnsafeAssetId] 的教训，守卫见
/// `test/sync/fushi_sync_server_asset_gate_test.dart`，它按纯文本计数穿越判断的
/// 出现次数，所以正文注释里也不要写那个字面量）。视频域不能用那道资产闸门是因为
/// 它禁 `/`，而视频 bookUid 合法含 `/`。
String? _extractBareVideoId(String reqPath) {
  const String prefix = '/api/library/videos/';
  if (!reqPath.startsWith(prefix)) return null;
  final String id = reqPath.substring(prefix.length);
  if (id.isEmpty) return null;
  if (id.contains('..') || id.contains('\\')) return null;
  return id;
}

String _safeDownloadStem(String value) {
  final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  return safe.isEmpty ? 'video' : safe;
}
