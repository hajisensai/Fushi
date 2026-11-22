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
      // 有 client 在看视频清单（可能接着回跳 / 制卡）：顺手请预热跟上库的变化。
      _videoFingerprintWarmer?.request();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteVideoInfo v in list)
            _remoteVideoJsonForRequest(v, request),
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

    // GET /api/library/videos/<id>/disc — 远端原盘：签发盘目录共享会话（需 Basic
    // 鉴权）。<id> 是盘上任一条标题；不是原盘标题 → 404。
    final String? discId = _extractVideoId(reqPath, kDiscShareIssueSuffix);
    if (discId != null) {
      if (method != 'GET') return shelf.Response(405);
      if (svc is! VideoDiscShareHost) {
        return shelf.Response.notFound('Disc share off');
      }
      final String? root = await (svc as VideoDiscShareHost)
          .resolveVideoDiscRoot(discId);
      if (root == null) return shelf.Response.notFound('Not a disc title');
      final DiscShareManifest? manifest = await buildDiscShareManifest(root);
      if (manifest == null) {
        return shelf.Response.notFound('Disc structure unreadable');
      }
      // BUG-4393：会话记签发凭据，吊销即连带作废。签发路由要 Basic，取不到就是没鉴权。
      final String? issuer = _requestCredentialFingerprint(request);
      if (issuer == null) return shelf.Response(401);
      final String token = _discShares.issue(
        discRoot: root,
        manifest: manifest,
        issuer: issuer,
      );
      return jsonResponse(
        discShareIssueBody(
          token: token,
          requestedUri: request.requestedUri,
          manifest: manifest,
          titles: await (svc as VideoDiscShareHost).videoTitlesOnDisc(root),
        ),
      );
    }

    // GET /api/library/videos/<id>/streamurl — 签发短时 token（需 Basic 鉴权）
    final String? streamUrlId = _extractVideoId(reqPath, 'streamurl');
    if (streamUrlId != null) {
      if (method != 'GET') return shelf.Response(405);
      // TODO-885: 远端播放列表按集——?episode=N 决定流式哪一集（DB-only 反查）。
      final int episodeIndex = _episodeIndexFromRequest(request);
      final File? file = await svc.resolveVideoFile(
        streamUrlId,
        episodeIndex: episodeIndex,
      );
      if (file == null) return shelf.Response.notFound('Video not found');
      // BUG-4393：流 token 记签发凭据，取流时对照当前快照（吊销即连带作废）。
      final String? issuer = _requestCredentialFingerprint(request);
      if (issuer == null) return shelf.Response(401);
      // 弱网转码：client 报画质档（`?maxWidth=1280&maxBitrate=3000000`），host 决定
      // 认不认。四个闸门缺一不可——档位有效、用户没关开关、本机真能 exec ffmpeg
      // （移动端 host 的进程内 ffmpeg-kit 没有可接管的 stdout，见
      // [transcodeAvailable]）、以及探得出时长（HLS playlist 要按时长切段，探不出就
      // 没法生成）。任一不成立就静默退回原文件直传：client 收到的 `transcoded: false`
      // 会让它把画质档收起来，而不是播一个永远出不来的流。
      // 蓝光标题：`file` 是几 KB 的 `.mpls`，不是视频。直传时改下发段表（见下方
      // `discTitle`），转码时时长取 MPLS 的精确值，分段命令由共享蓝光输入改写处理。
      final BlurayTitleStreams? disc = await readBlurayTitleStreams(file.path);
      final VideoTranscodeProfile? requestedProfile =
          VideoTranscodeProfile.fromQuery(request.url.queryParameters);
      int? transcodeDurationMs;
      if (requestedProfile != null && _videoTranscodeEnabled) {
        transcodeDurationMs = disc != null
            ? disc.playlist.duration.inMilliseconds
            : await probeVideoDurationMs(file.path);
      }
      final VideoTranscodeProfile? transcodeProfile =
          transcodeDurationMs != null && transcodeDurationMs > 0
          ? requestedProfile
          : null;
      final int? transcodeAudioStreamIndex = transcodeProfile == null
          ? null
          : int.tryParse(request.url.queryParameters['audioStreamIndex'] ?? '');
      // BUG-1568：签发前先按 TTL 清过期，再把数量收束到 [_maxVideoStreamTokens] 内
      // （淘汰最旧者）。对照 audio token 的 BUG-908(a) 修法：消费侧（GET /stream）的
      // prune 等不到「只签发不取流」的调用者，上限必须在签发侧强制。
      _pruneVideoTokens();
      _enforceVideoTokenCap();
      final String tokenValue = _generateVideoToken();
      _videoStreamTokens[tokenValue] = _VideoStreamToken(
        videoId: streamUrlId,
        issuer: issuer,
        createdAt: _now(),
        episodeIndex: episodeIndex,
        transcodeProfile: transcodeProfile,
        transcodeAudioStreamIndex: transcodeAudioStreamIndex,
        transcodeDurationMs: transcodeProfile == null
            ? null
            : transcodeDurationMs,
      );
      final String encodedId = Uri.encodeFull(streamUrlId);
      // stream / subtitle URL 都带 episode=N，让 client 取流 / 下字幕命中同一集。
      final Map<String, String> streamQuery = <String, String>{
        'token': tokenValue,
        if (episodeIndex > 0) 'episode': '$episodeIndex',
      };
      // 蓝光标题直传：每段一个分段 URL（同一 token），client 用 EDL 拼回与本地播放
      // 逐 tick 相同的时间轴（bluray_remote_title.dart）。转码时不需要它——HLS 分段
      // 由 host 从播放列表直接转出。
      final BlurayRemoteTitle? discTitle =
          disc == null || transcodeProfile != null
          ? null
          : disc.remoteTitle(
              (int stream) => request.requestedUri
                  .replace(
                    path:
                        '/api/library/videos/$encodedId/'
                        '$kBlurayClipPathSuffix',
                    queryParameters: <String, String>{
                      ...streamQuery,
                      'n': '$stream',
                    },
                  )
                  .toString(),
            );
      // 光盘标题的制卡抽帧源：client 的 ffmpeg 打不开 `edl://`，host 能转码时另签一张
      // 低清 HLS 的 token 给它（与 YouTube 的 360p 制卡流同一个字段、同一种用途）；转
      // 不了就不给，client 制卡时没有画面而不是对着 EDL 报错。句子音频本来就走 host
      // 端裁切（`/clipaudio`），不依赖这条。
      Uri? miningUri;
      if (discTitle != null && _videoTranscodeEnabled) {
        _enforceVideoTokenCap();
        final String miningToken = _generateVideoToken();
        _videoStreamTokens[miningToken] = _VideoStreamToken(
          videoId: streamUrlId,
          issuer: issuer,
          createdAt: _now(),
          episodeIndex: episodeIndex,
          transcodeProfile: _kDiscMiningTranscodeProfile,
          transcodeDurationMs: disc!.playlist.duration.inMilliseconds,
          ticket: tokenValue,
        );
        miningUri = request.requestedUri.replace(
          path: '/api/library/videos/$encodedId/hls.m3u8',
          queryParameters: <String, String>{
            'token': miningToken,
            if (episodeIndex > 0) 'episode': '$episodeIndex',
          },
        );
      }
      // 转码时 client 拿到的是一张 HLS playlist（播放器自己再去取 init 段与各分段，
      // 那些 URL 由 playlist 内部用相对路径给出）；不转码时还是老的整文件流。
      final Uri streamUri = request.requestedUri.replace(
        path:
            '/api/library/videos/$encodedId/'
            '${transcodeProfile == null ? 'stream' : 'hls.m3u8'}',
        queryParameters: streamQuery,
      );
      // subtitle URL 不含 token（走 Basic 鉴权），但带 episode=N。
      final File? sub = await svc.resolveVideoSubtitle(
        streamUrlId,
        episodeIndex: episodeIndex,
      );
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
      // 这一集的全部外挂字幕（反馈 -CaVsioFhG）：旧单值 `subtitleUrl` /
      // `subtitleFileName` 照发给老 client，新 client 优先读这份列表。
      final List<RemoteVideoSidecarSubtitle> sidecarSubtitles =
          await _sidecarSubtitlesForRequest(
            svc,
            request,
            streamUrlId,
            episodeIndex,
            videoStem: p.basenameWithoutExtension(file.path),
            defaultSubtitle: sub,
          );
      // 源文件平均码率：client「自动」档拿它和实测链路带宽比，决定原画直传还是转码
      // （反馈 uaBRMzK_WM）。只在本机能转码时才算——转不了就没有可选的，client 也
      // 不会去比。蓝光标题的 `file` 是 `.mpls`，大小不代表视频，不报。
      final int? sourceBitrate = _videoTranscodeEnabled && disc == null
          ? await _sourceBitrateOf(file, knownDurationMs: transcodeDurationMs)
          : null;
      return jsonResponse(<String, dynamic>{
        // 蓝光标题给 EDL（各段地址都是 host 的 http(s) URL）：旧 client 不认
        // `discTitle`，原样交给 libmpv 也能播明文 http host；新 client 读 `discTitle`
        // 逐段过本地 TLS 中继后自己拼。
        'url': discTitle?.edlUri() ?? streamUri.toString(),
        // 流票（BUG-4461）：client 播放会话结束时拿它调 `/streamrelease`，host 立刻
        // 作废这次签的全部 token（含上面的制卡 token）并停掉它们的转码。旧 client
        // 不读，token 照旧按 TTL 过期。
        'ticket': tokenValue,
        if (discTitle != null) 'discTitle': discTitle.toJson(),
        if (miningUri != null) ...<String, dynamic>{
          'miningVideoUrl': miningUri.toString(),
          'miningVideoHasAudio': true,
        },
        'subtitleUrl': subtitleUri?.toString(),
        // 这条流是不是**转码流**（HLS）。client 据此显示画质档当前值，并知道内嵌
        // 字幕不在流里、要走 /subtitle 外挂下发。seek 不需要特殊处理——HLS 的进度条
        // 与定位由播放器原生支持。
        'transcoded': transcodeProfile != null,
        // 「这台 host 支不支持转码」——与当次有没有转码分开报。client 起播时默认走
        // 自动档（局域网里就是不转码），若只回 `transcoded: false`，它就永远无从得知
        // 画质档可不可选，画质菜单会一直不出现。
        'transcodeAvailable': _videoTranscodeEnabled,
        'sourceBitrate': ?sourceBitrate,
        // 既有字段语义（BUG-2590）：false = 流不是源容器原样，内嵌字幕不能指望
        // libmpv 自绘。转码把容器整个换掉了，必须如实报 false。
        'streamIsOriginalContainer': transcodeProfile == null,
        if (sub != null) 'subtitleFileName': p.basename(sub.path),
        if (embeddedTracks.isNotEmpty)
          'embeddedSubtitleTracks': <Map<String, Object?>>[
            for (final RemoteVideoEmbeddedSubtitleTrack track in embeddedTracks)
              track.toJson(),
          ],
        if (sidecarSubtitles.isNotEmpty)
          'sidecarSubtitles': <Map<String, Object?>>[
            for (final RemoteVideoSidecarSubtitle sidecar in sidecarSubtitles)
              sidecar.toJson(),
          ],
      });
    }

    // POST /api/library/videos/<id>/streamrelease?ticket=<t> — 释放流票（BUG-4461，
    // 需 Basic 鉴权：路径不以任何豁免后缀结尾）。幂等：票已不在也 204。
    final String? releaseId = _extractVideoId(reqPath, 'streamrelease');
    if (releaseId != null) {
      if (method != 'POST') return shelf.Response(405);
      final String? ticket = request.url.queryParameters['ticket'];
      if (ticket == null || ticket.isEmpty) {
        return shelf.Response(400, body: 'Missing ticket');
      }
      _releaseVideoTicket(releaseId, ticket);
      return shelf.Response(204);
    }

    // GET /api/library/videos/<id>/stream — 流式传输（豁免 Basic，靠 token 鉴权）
    final String? streamId = _extractVideoId(reqPath, 'stream');
    if (streamId != null) {
      if (method != 'GET') return shelf.Response(405);
      _pruneVideoTokens();
      final String? tokenValue = request.url.queryParameters['token'];
      if (tokenValue == null || tokenValue.isEmpty) {
        return shelf.Response(
          401,
          body: 'Missing token',
          headers: <String, String>{'Content-Type': 'text/plain'},
        );
      }
      final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
      if (tok == null || tok.videoId != streamId) {
        return shelf.Response(
          403,
          body: 'Invalid or expired token',
          headers: <String, String>{'Content-Type': 'text/plain'},
        );
      }
      if (!await _issuerStillValid(tok.issuer)) {
        return _revokedVideoToken(tokenValue);
      }
      // TODO-885: 用 token 绑定的集下标反查（token 是 streamurl 签发时定的，client 不能
      // 自己改集——?episode 只决定 streamurl 阶段，stream 阶段以 token 为准）。
      final File? file = await svc.resolveVideoFile(
        streamId,
        episodeIndex: tok.episodeIndex,
      );
      if (file == null) return shelf.Response.notFound('Video not found');
      // 带 ETag + 按需校验 If-Range：client 下载续传会带上次记下的验证器，文件在
      // host 上被替换时降级 200 全量；播放器的盲 Range（seek）不带 If-Range，照常
      // 206（ifRangeRequired: false）。
      // 全程 async stat：视频常在网络盘上，同步 stat 会冻结 host 所在 isolate（BUG-3756）。
      final String etag;
      try {
        etag = await videoFileEtag(file);
      } on FileSystemException {
        return shelf.Response.notFound('Video not found');
      }
      return serveFileWithRange(
        file,
        request,
        etag: etag,
        ifRangeRequired: false,
      );
    }

    // GET /api/library/videos/<id>/hls.m3u8         — 转码播放列表
    // GET /api/library/videos/<id>/hlsseg.ts?n=<i>  — 第 i 个分段（MPEG-TS）
    // 两条都豁免 Basic（播放器取 playlist / 分段都是裸 GET），门是 URL 里的短时
    // token；画质档绑在 token 上，不从 query 取——分段谁拿到 URL 谁能取，让它自带
    // 编码参数就等于把「在 host 上起一个任意参数的 ffmpeg」敞开给 URL 持有者。
    //
    // 两条路径**必须带 FFmpeg 认的扩展名**（BUG-2630）：FFmpeg 6.1.3+ / 7.1.1+ / 8.0
    // （2025 年安全加固回移）的 hls demuxer 对每个分段 URL 先查
    // `allowed_segment_extensions` 白名单（扩展名取 query 之前的路径尾，
    // `ff_match_url_ext`），不在名单上直接 `Invalid data found`——随包 libmpv 四端
    // （Android / iOS / macOS 6.1.6，Windows master 构建）都在门内，裸 `hlsseg?token=`
    // 让转码流一开就死。分段为什么是 TS 不是 fMP4 见 `live_transcode.dart` 文件头。
    // 守卫 `fushi/test/sync/fushi_sync_server_hls_segment_ext_guard_test.dart`。
    // GET /api/library/videos/<id>/bdclip.m2ts?token=&n=<i> — 蓝光标题第 i 个码流
    // （豁免 Basic，靠 token；加密盘先解密再发，支持 Range）。
    final String? clipId = _extractVideoId(reqPath, kBlurayClipPathSuffix);
    if (clipId != null) {
      if (method != 'GET') return shelf.Response(405);
      return _handleBlurayClip(svc, request, clipId);
    }

    for (final String suffix in const <String>[
      'hls.m3u8',
      kTranscodeSegmentPathSuffix,
    ]) {
      final String? hlsId = _extractVideoId(reqPath, suffix);
      if (hlsId == null) continue;
      if (method != 'GET') return shelf.Response(405);
      return _handleTranscodeHls(svc, request, hlsId, suffix);
    }

    // GET /api/library/videos/<id>/graphicsubtitle?embeddedStreamIndex=N[&episode=E][&part=header]
    // 图形字幕（PGS / VobSub / DVB）整轨回传：host 在本机把那一条字幕轨原样抽出来，
    // client 解析出逐句起止（制卡锚句 / 句子音频），不为字幕把整片再读一遍。需 Basic
    // 鉴权（不在 /stream 豁免名单）。embeddedStreamIndex 与 `/subtitle` 同义（ffmpeg
    // `0:s:N`，即 `embeddedSubtitleTracks[].streamIndex`）。文本轨走 `/subtitle`，这里 404。
    final String? graphicSubtitleId = _extractVideoId(
      reqPath,
      'graphicsubtitle',
    );
    if (graphicSubtitleId != null) {
      if (method != 'GET') return shelf.Response(405);
      return _handleGraphicSubtitleTrack(svc, request, graphicSubtitleId);
    }

    // POST /api/library/videos/<id>/subtitle/backfill  {language?}
    // 立即给这一个视频补字幕（刮削后自动补的同一条服务，单视频入口）。必须在
    // `/subtitle` 之前匹配：bookUid 允许含 `/`，`subtitle` 后缀匹配不到这条，但
    // 顺序写明白免得以后有人调换。
    final String? backfillId = _extractVideoId(reqPath, 'subtitle/backfill');
    if (backfillId != null) {
      if (method != 'POST') return shelf.Response(405);
      final VideoSubtitleBackfillRunner? runner = videoSubtitleBackfill;
      if (runner == null) {
        return shelf.Response(501, body: 'Subtitle backfill not available');
      }
      String? language;
      final String body = await readBoundedBodyString(request);
      if (body.trim().isNotEmpty) {
        final Object? decoded;
        try {
          decoded = jsonDecode(body);
        } on FormatException {
          return shelf.Response(400, body: 'Invalid JSON');
        }
        if (decoded is! Map) {
          return shelf.Response(400, body: 'JSON object body required');
        }
        final String lang = (decoded['language'] ?? '').toString().trim();
        if (lang.isNotEmpty) {
          if (!RegExp(
            r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]{1,8})*$',
          ).hasMatch(lang)) {
            return shelf.Response(400, body: 'Invalid language tag');
          }
          language = lang;
        }
      }
      final VideoSubtitleBackfillReport? report = await runner(
        backfillId,
        language: language,
      );
      if (report == null) return shelf.Response.notFound('Video not found');
      return jsonResponse(report.toJson());
    }

    // GET /api/library/videos/<id>/subtitle — 字幕（需 Basic 鉴权，中间件已处理）
    // PUT 同路径 — client→host 上传该视频的外挂字幕 sidecar（BUG-964，随
    // syncVideoFiles live push）。后缀（`.srt` / `.ja.srt` …）经
    // [kSubtitleSuffixHeader] 上报，服务端白名单校验；老 host 无此分支
    // 对 PUT 回 405，client 据此优雅降级。
    final String? subtitleId = _extractVideoId(reqPath, 'subtitle');
    if (subtitleId != null) {
      if (method == 'PUT') {
        final String suffix =
            _decodeHeaderValue(request, kSubtitleSuffixHeader) ?? '';
        final Directory tmpDir = await Directory.systemTemp.createTemp(
          'fushi_subtitle_in',
        );
        final File tmp = File(p.join(tmpDir.path, 'upload.bin'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          // [kSubtitleDefaultHeader]: 1 = 用户在远端播放时导入 / 重定时的字幕，要设成
          // 这一集的默认字幕（后缀由 host 按自己的学习语言定，旧的高优先级 sidecar
          // 改名让位，见 [VideoSubtitleDefaultHost]）。本 host 的库服务不支持该能力时
          // 回 409、**不落盘**：退回 importVideoSubtitle 会按 client 报的后缀覆盖同名
          // 旧字幕且不留备份（BUG-2728）。client 本该先看 capabilities 的
          // `liveLibrary.videoSubtitleDefault` 再上传（老 host 不认这个 header，只能靠
          // client 那一侧的门），这里是新 host 的第二道门。
          final bool asDefault =
              _decodeHeaderValue(request, kSubtitleDefaultHeader) == '1';
          if (asDefault) {
            if (svc is! VideoSubtitleDefaultHost) {
              return shelf.Response(
                409,
                body: 'Default subtitle import unsupported',
              );
            }
            final VideoSubtitleDefaultHost host =
                svc as VideoSubtitleDefaultHost;
            // `?episode=N`：播放列表第 N 集（client 先看
            // `liveLibrary.videoSubtitleDefaultEpisode` 才带）。
            final String placed = await host.importDefaultVideoSubtitle(
              tmp,
              id: subtitleId,
              // 不能用 p.extension：无语言标记的后缀就是 `.srt` 本身，按文件名规则
              // 那是「点开头、没有扩展名」，会得到空串而被判成「不是字幕格式」。
              format: suffix.substring(suffix.lastIndexOf('.') + 1),
              episodeIndex: _episodeIndexFromRequest(request),
            );
            // 新旧两个名字都回：改名前的 client 只读旧名，读不到会把这次成功的
            // 上传误报成「host 不支持」（见 kLegacyInterconnectHeaderNames）。
            return shelf.Response(
              200,
              headers: <String, String>{
                kSubtitleSuffixHeader: placed,
                kLegacyInterconnectHeaderNames[kSubtitleSuffixHeader]!: placed,
              },
            );
          }
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
            await tmpDir.delete(recursive: true);
          } catch (_) {
            // best-effort
          }
        }
      }
      // DELETE ?which=primary|secondary|all（缺省 primary）[&sidecars=all]：清字幕
      // 源（+ 主字幕 cue），本视频自己的 sidecar 改名备份，不删别处文件、不碰视频。
      if (method == 'DELETE') {
        if (svc is! VideoSubtitleClearHost) {
          return shelf.Response.notFound('Subtitle clearing not supported');
        }
        final String whichText =
            request.url.queryParameters['which'] ?? 'primary';
        final VideoSubtitleClearScope? which = VideoSubtitleClearScope.values
            .asNameMap()[whichText];
        if (which == null) {
          return shelf.Response(
            400,
            body: 'which must be primary, secondary or all',
          );
        }
        final String sidecars = request.url.queryParameters['sidecars'] ?? '';
        if (sidecars.isNotEmpty && sidecars != 'all') {
          return shelf.Response(400, body: 'sidecars must be all');
        }
        try {
          final VideoSubtitleClearResult result =
              await (svc as VideoSubtitleClearHost).clearVideoSubtitle(
                subtitleId,
                which: which,
                allSidecars: sidecars == 'all',
              );
          return jsonResponse(result.toJson());
        } on ArgumentError catch (e) {
          return shelf.Response(400, body: 'Invalid video id: ${e.message}');
        } on StateError {
          return shelf.Response.notFound('Video not found');
        } on VideoSubtitleSidecarBusy catch (e) {
          return shelf.Response(
            409,
            body: jsonEncode(e.toJson()),
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
            },
          );
        }
      }
      if (method != 'GET') return shelf.Response(405);
      final int episodeIndex = _episodeIndexFromRequest(request);
      final String? embeddedIndexText =
          request.url.queryParameters['embeddedStreamIndex'];
      // `?sidecar=<文件名>`：这一集的某一条外挂字幕（反馈 -CaVsioFhG）。只在
      // host 自己枚举出的 sidecar 里按 basename 精确匹配，不拼路径。
      final String? sidecarName =
          request.url.queryParameters[kVideoSidecarSubtitleQueryParam];
      final File? sub = sidecarName != null
          ? await _resolveSidecarVideoSubtitle(
              svc,
              subtitleId,
              sidecarName,
              episodeIndex,
            )
          : embeddedIndexText == null
          ? await svc.resolveVideoSubtitle(
              subtitleId,
              episodeIndex: episodeIndex,
            )
          : await _resolveEmbeddedVideoSubtitle(
              svc,
              subtitleId,
              int.tryParse(embeddedIndexText),
              episodeIndex,
            );
      if (sub == null) return shelf.Response.notFound('Subtitle not found');
      final int? length = await _regularFileLength(sub);
      if (length == null) return shelf.Response.notFound('Subtitle not found');
      return shelf.Response.ok(
        sub.openRead(),
        headers: <String, String>{
          'Content-Type': _guessContentType(sub.path),
          'Content-Length': '$length',
        },
      );
    }

    // GET /api/library/videos/<id>/danmakukey?episode=N — 弹弹play 匹配指纹
    // （BUG-3614）。client 远端流播时本机没有文件、算不出指纹，由 host 用自己的
    // 文件算好下发。不实现 [VideoDanmakuKeyHost] / 老 host → 404，client 当作没有
    // 弹幕来源。
    final String? danmakuKeyId = _extractVideoId(reqPath, 'danmakukey');
    if (danmakuKeyId != null) {
      if (method != 'GET') return shelf.Response(405);
      if (svc is! VideoDanmakuKeyHost) {
        return shelf.Response.notFound('Video danmaku key not supported');
      }
      final DandanplayFileKey? key = await (svc as VideoDanmakuKeyHost)
          .videoDanmakuKey(
            danmakuKeyId,
            episodeIndex: _episodeIndexFromRequest(request),
          );
      if (key == null) return shelf.Response.notFound('Video not found');
      return jsonResponse(key.toJson());
    }

    // GET/PUT /api/library/videos/<id>/position — 跨设备播放断点（TODO-653）
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    final String? positionId = _extractVideoId(reqPath, 'position');
    if (positionId != null) {
      final int episodeIndex = _episodeIndexFromRequest(request);
      // 存在性闸门：该视频 id（含集下标）在 host DB 真实存在，防止任意 id 写脏
      // prefs。与 /playback 同口径只认 DB 行，不用 [resolveVideoFile]——网络流书 /
      // `.strm` 行 host 没有媒体字节、resolveVideoFile 恒 null，旧闸门让它们的
      // 进度推不回 host（BUG-3875）；host 网络盘掉线时本地文件行也同样被误拒。
      if (!await svc.videoExists(positionId, episodeIndex: episodeIndex)) {
        return shelf.Response.notFound('Video not found');
      }
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p = await svc
              .getVideoPosition(positionId, episodeIndex: episodeIndex);
          return jsonResponse(<String, dynamic>{
            'positionMs': p.positionMs,
            'positionUpdatedAtMs': p.updatedAtMs,
          }).change(headers: _liveWriteHeaders(svc));
        case 'PUT':
          final String body = await readBoundedBodyString(request);
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int posMs = (json['positionMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['positionUpdatedAtMs'] as num?)?.toInt() ?? 0;
          // BUG-4431：回执 + 可选前置条件（见书进度 PUT 同段注释）。
          final Object liveHost = svc;
          if (liveHost is! LivePositionWriteHost) {
            await svc.putVideoPosition(
              positionId,
              posMs,
              updatedAtMs,
              episodeIndex: episodeIndex,
            );
            return shelf.Response(200);
          }
          final List<int>? expected;
          try {
            expected = parseLiveExpectedPositionsMs(
              json[kLiveExpectedPositionsKey],
            );
          } on FormatException catch (e) {
            return shelf.Response(400, body: e.message);
          }
          final LivePositionWriteOutcome outcome = await liveHost
              .putVideoPositionChecked(
                positionId,
                posMs,
                updatedAtMs,
                episodeIndex: episodeIndex,
                expectedPositionsMs: expected,
              );
          return _liveWriteResponse(outcome.result, outcome.toJson());
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
          final VideoPlaybackSyncState s = await playbackHost.getVideoPlayback(
            playbackId,
          );
          return jsonResponse(s.toJson());
        case 'PUT':
          final String body = await readBoundedBodyString(request);
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          await playbackHost.putVideoPlayback(
            playbackId,
            VideoPlaybackSyncState.fromJson(json),
          );
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    // GET /api/library/videos/<id>/fingerprint?episode=N — 卡片来源的字节身份（拍板台
    // IFCPPprIpT）。client 远程播放 host 的视频制卡时没有本地文件可算指纹，由 host 对
    // 它要串流的同一个文件（与 `/streamurl` 同一个 resolveVideoFile）算全文件 SHA-256，
    // 与本地播放制卡的 [VideoSourceFingerprint] 同一口径，卡片因此能跨设备回跳并核验。
    // 需 Basic 鉴权（不在 /stream 豁免名单）。老 host 无此分支 → 兜底 404，client 当作
    // 「host 不支持指纹」（制卡不带链接 / 回跳按 bookUid 放行），与此前行为一致。
    // 新 host 有这个端点、却担保不了这份字节（条目 / 文件不在、算的期间被改写）时回
    // [kVideoFingerprintUnavailableStatus] + JSON reason，绝不回 404——否则 client 会把它
    // 当成老 host 放行、绕过字节核验（BUG-4782）。
    final String? fingerprintId = _extractVideoId(reqPath, 'fingerprint');
    if (fingerprintId != null) {
      if (method != 'GET') return shelf.Response(405);
      final File? file = await svc.resolveVideoFile(
        fingerprintId,
        episodeIndex: _episodeIndexFromRequest(request),
      );
      if (file == null) {
        return _videoFingerprintUnavailable(kVideoFingerprintReasonNotFound);
      }
      // 拍板台 left3657：`wait=0`（卡片回跳）只答已算过的，没算过回 202 并在后台开算
      // ——同一文件随后的预热 / 制卡请求经在途去重复用这一次。
      final bool wait =
          request.url.queryParameters[kVideoFingerprintWaitQueryParam] != '0';
      try {
        final VideoSourceFingerprint fingerprints = _videoFingerprints;
        // 停机时取消（拍板台 host-stop-fingerprint-cancel）：本 host 发起的计算没有别的
        // 等待方时被打断，stop 不再被一个几 GB 的文件拖住。
        final VideoFingerprintCancellation cancel = _videoFingerprintCancel;
        final Future<String?>? lookup = wait
            ? _startVideoFingerprintWork(
                () => fingerprints.fingerprint(file.path, cancel: cancel),
              )
            : _startVideoFingerprintWork(() => fingerprints.known(file.path));
        if (lookup == null) return _videoFingerprintHostStopping();
        final String? digest = await lookup;
        if (digest == null) {
          final Future<String>? background = _startVideoFingerprintWork(
            () => fingerprints.fingerprint(file.path, cancel: cancel),
          );
          if (background == null) return _videoFingerprintHostStopping();
          unawaited(
            background.then<void>(
              (String _) {},
              onError: (Object error, StackTrace stack) {
                if (error is VideoFingerprintCancelledException) return;
                engineLog.log('video.fingerprint.background', error, stack);
              },
            ),
          );
          return shelf.Response(
            kVideoFingerprintPendingStatus,
            body: jsonEncode(<String, bool>{'pending': true}),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        }
        return jsonResponse(<String, Object?>{'fingerprint': digest});
      } on VideoFingerprintCancelledException {
        // host 停机打断了这次计算。
        return _videoFingerprintHostStopping();
      } on FileSystemException catch (error, stack) {
        // 文件不在 / 算指纹期间被改写：没有可担保的身份。
        engineLog.log('video.fingerprint', error, stack);
        return _videoFingerprintUnavailable(kVideoFingerprintReasonUnreadable);
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
      final int? startMs = int.tryParse(
        request.url.queryParameters['startMs'] ?? '',
      );
      final int? endMs = int.tryParse(
        request.url.queryParameters['endMs'] ?? '',
      );
      if (startMs == null || endMs == null || endMs <= startMs) {
        return shelf.Response(400, body: 'Invalid clip range');
      }
      final int? audioStreamIndex = int.tryParse(
        request.url.queryParameters['audioStreamIndex'] ?? '',
      );
      final int? audioStreamCount = int.tryParse(
        request.url.queryParameters['audioStreamCount'] ?? '',
      );
      final int audioChannels =
          int.tryParse(request.url.queryParameters['ac'] ?? '') ?? 1;
      final String audioBitrate =
          request.url.queryParameters['bitrate'] ?? '64k';
      // `?discTitle=BDMV/PLAYLIST/<名>.mpls`：同一张蓝光盘上的另一条 title（远端原盘
      // 会话，能力位 [kVideoClipAudioDiscTitleCapability]）。不与 `episode` 同给。
      final String? discTitle = request.url.queryParameters['discTitle'];
      final File? clip;
      if (discTitle != null && discTitle.isNotEmpty) {
        if (svc is! VideoDiscTitleAudioHost) {
          return shelf.Response.notFound('Disc title clip unsupported');
        }
        if (episodeIndex > 0) {
          return shelf.Response(400, body: 'episode and discTitle conflict');
        }
        clip = await (svc as VideoDiscTitleAudioHost).clipVideoDiscTitleAudio(
          clipAudioId,
          discTitle: discTitle,
          startMs: startMs,
          endMs: endMs,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
          audioChannels: audioChannels,
          audioBitrate: audioBitrate,
        );
      } else {
        clip = await svc.clipVideoAudio(
          clipAudioId,
          startMs: startMs,
          endMs: endMs,
          episodeIndex: episodeIndex,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
          audioChannels: audioChannels,
          audioBitrate: audioBitrate,
        );
      }
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
          await clip.parent.delete(recursive: true);
        } catch (_) {
          // best-effort
        }
      }
    }

    // GET /api/library/videos/<id>/clipvideo?startMs=&endMs=&episode=&audioStreamIndex=
    //     &audioStreamCount= — 反馈 6nBmSBj_2W：host 端本地逐帧精确裁出无字幕片段原料并
    // 回传，字幕由 client 用屏幕上那份 cue 烧录（见 [VideoClipExportHost]）。需 Basic 鉴权
    // （clipvideo 不在 /stream 豁免名单）。host 不实现该能力 → 404（能力位同时为 false）。
    final String? clipVideoId = _extractVideoId(reqPath, 'clipvideo');
    if (clipVideoId != null) {
      if (method != 'GET') return shelf.Response(405);
      if (svc is! VideoClipExportHost) {
        return shelf.Response.notFound('Clip export unsupported');
      }
      final VideoClipExportHost clipHost = svc as VideoClipExportHost;
      final int? startMs = int.tryParse(
        request.url.queryParameters['startMs'] ?? '',
      );
      final int? endMs = int.tryParse(
        request.url.queryParameters['endMs'] ?? '',
      );
      if (startMs == null || endMs == null || startMs < 0 || endMs <= startMs) {
        return shelf.Response(400, body: 'Invalid clip range');
      }
      final File? clip = await clipHost.clipVideoSegment(
        clipVideoId,
        startMs: startMs,
        endMs: endMs,
        episodeIndex: _episodeIndexFromRequest(request),
        audioStreamIndex: int.tryParse(
          request.url.queryParameters['audioStreamIndex'] ?? '',
        ),
        audioStreamCount: int.tryParse(
          request.url.queryParameters['audioStreamCount'] ?? '',
        ),
      );
      if (clip == null) {
        return shelf.Response.notFound('Clip unavailable');
      }
      // 片段可能有几十上百 MB：流式回传（不像 clipaudio 那样整段读进内存），传完或
      // 连接中断时连临时目录一并清（clipVideoSegment 建的 temp 目录）。
      final int length = await clip.length();
      return shelf.Response.ok(
        _streamThenDeleteDir(clip),
        headers: <String, String>{
          'Content-Type': 'video/mp4',
          'Content-Length': '$length',
        },
      );
    }

    // PUT /api/library/videos/<id>/streamentry — client→host 注册一本流媒体书（拍板台
    // Z2OhxAjKVv）：只有标题 + URL + 重开规格，不传字节。必须排在下面「裸 id 上传」
    // 之前；client 先看能力位 `liveLibrary.streamVideos` 再推（老 host 没有这一段，
    // 请求会落进裸 id 分支被当视频文件导入）。删除墓碑闸门与视频上传同一把。
    final String? streamEntryId = _extractVideoId(
      reqPath,
      kStreamVideoEntryPathSuffix,
    );
    if (streamEntryId != null) {
      if (svc is! StreamVideoSyncHost) {
        return shelf.Response.notFound('Stream video sync not supported');
      }
      if (method != 'PUT') return shelf.Response(405);
      if (await _peerPushVetoed(
        request,
        kinds: const <SyncTombstoneKind>[SyncTombstoneKind.video],
        itemKey: streamEntryId,
      )) {
        return _peerPushVetoedResponse(request);
      }
      final StreamVideoRegistration entry;
      try {
        entry = StreamVideoRegistration.fromJson(
          jsonDecode(await readBoundedBodyString(request)),
        );
      } on FormatException catch (e) {
        return shelf.Response(400, body: e.message);
      }
      try {
        final bool created = await (svc as StreamVideoSyncHost)
            .registerStreamVideo(streamEntryId, entry);
        return jsonResponse(<String, Object?>{'created': created});
      } on ArgumentError catch (e) {
        return shelf.Response(400, body: '${e.message}');
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
      // 删除墓碑闸门（反馈 Et3pmRzo0k，同 [_peerPushVetoed]）：视频身份 = bookUid。
      if (await _peerPushVetoed(
        request,
        kinds: const <SyncTombstoneKind>[SyncTombstoneKind.video],
        itemKey: id,
      )) {
        return _peerPushVetoedResponse(request);
      }
      final String title = _decodeHeaderValue(request, kVideoTitleHeader) ?? id;
      final String? fileName = _decodeHeaderValue(
        request,
        kVideoFilenameHeader,
      );
      final Directory tmpDir = await Directory.systemTemp.createTemp(
        'fushi_video_in',
      );
      final File tmp = File(p.join(tmpDir.path, 'upload.bin'));
      final IOSink sink = tmp.openWrite();
      try {
        await request.read().forEach(sink.add);
        await sink.close();
        await svc.importVideo(
          tmp,
          id: id,
          title: title,
          originalFileName: fileName,
        );
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
          await tmpDir.delete(recursive: true);
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
    // coverPath 由 host 服务出清单时已按「磁盘上真存在」解析好（见
    // [RemoteVideoInfo.coverPath]），这里不再逐条同步 stat：视频封面常在网络盘上，
    // 清单端点逐条 existsSync 会冻结 host 所在 isolate（BUG-3756）。清单之后被删掉
    // 的封面由封面端点自己 async 判 404。
    if (video.coverPath?.isNotEmpty ?? false) {
      final String encodedId = Uri.encodeFull(video.id);
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri
          .replace(
            path: '/api/library/videos/$encodedId/cover',
            queryParameters: <String, String>{},
          )
          .toString();
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
    final List<EmbeddedSubtitleTrack> tracks = await listEmbeddedSubtitleTracks(
      videoFile.path,
    );
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
          ? request.requestedUri
                .replace(
                  path: '/api/library/videos/$encodedId/subtitle',
                  queryParameters: <String, String>{
                    'embeddedStreamIndex': '${track.streamIndex}',
                    if (episodeIndex > 0) 'episode': '$episodeIndex',
                  },
                )
                .toString()
          : null,
      fileName: isText
          ? '${_safeDownloadStem(videoStem)}.embedded.${track.streamIndex}$extension'
          : null,
    );
  }

  /// 这一集可下发的全部外挂字幕文件：host 的同目录 sidecar
  /// （[VideoSidecarSubtitleListHost.listVideoSidecarSubtitles]）并上默认字幕
  /// [defaultSubtitle]（host 用户选定的字幕可能住在别处，此时排第一）。按路径去重。
  /// host 不支持该能力 → 空表（client 只有旧单值字段那一条）。
  Future<List<File>> _sidecarSubtitleFiles(
    FushiLibraryHostService service,
    String id,
    int episodeIndex, {
    required File? defaultSubtitle,
  }) async {
    if (service is! VideoSidecarSubtitleListHost) return const <File>[];
    final List<File> listed = await (service as VideoSidecarSubtitleListHost)
        .listVideoSidecarSubtitles(id, episodeIndex: episodeIndex);
    final File? def = defaultSubtitle;
    if (def == null ||
        listed.any((File f) => p.equals(f.path, def.path)) ||
        !isSidecarSubtitleSuffix(p.extension(def.path))) {
      return listed;
    }
    return <File>[def, ...listed];
  }

  /// `/streamurl` 的 `sidecarSubtitles[]`（反馈 -CaVsioFhG）。
  Future<List<RemoteVideoSidecarSubtitle>> _sidecarSubtitlesForRequest(
    FushiLibraryHostService service,
    shelf.Request request,
    String videoId,
    int episodeIndex, {
    required String videoStem,
    required File? defaultSubtitle,
  }) async {
    final List<File> files = await _sidecarSubtitleFiles(
      service,
      videoId,
      episodeIndex,
      defaultSubtitle: defaultSubtitle,
    );
    final String encodedId = Uri.encodeFull(videoId);
    final File? def = defaultSubtitle;
    return <RemoteVideoSidecarSubtitle>[
      for (final File file in files)
        RemoteVideoSidecarSubtitle(
          fileName: p.basename(file.path),
          format: p.extension(file.path).replaceFirst('.', '').toLowerCase(),
          language: sidecarSubtitleLanguageTag(
            videoStem,
            p.basename(file.path),
          ),
          sizeBytes: await _regularFileLength(file),
          isDefault: def != null && p.equals(file.path, def.path),
          url: request.requestedUri
              .replace(
                path: '/api/library/videos/$encodedId/subtitle',
                queryParameters: <String, String>{
                  kVideoSidecarSubtitleQueryParam: p.basename(file.path),
                  if (episodeIndex > 0) 'episode': '$episodeIndex',
                },
              )
              .toString(),
        ),
    ];
  }

  /// `GET .../subtitle?sidecar=<name>` 的解析：只在 [_sidecarSubtitleFiles] 里按
  /// basename 精确匹配（[name] 带路径分隔符 / 穿越时自然匹配不到），找不到 → null。
  Future<File?> _resolveSidecarVideoSubtitle(
    FushiLibraryHostService service,
    String id,
    String name,
    int episodeIndex,
  ) async {
    if (name.isEmpty || service is! VideoSidecarSubtitleListHost) return null;
    final List<File> files = await _sidecarSubtitleFiles(
      service,
      id,
      episodeIndex,
      defaultSubtitle: await service.resolveVideoSubtitle(
        id,
        episodeIndex: episodeIndex,
      ),
    );
    for (final File file in files) {
      if (p.basename(file.path) == name) return file;
    }
    return null;
  }

  Future<File?> _resolveEmbeddedVideoSubtitle(
    FushiLibraryHostService service,
    String id,
    int? streamIndex,
    int episodeIndex,
  ) async {
    if (streamIndex == null || streamIndex < 0) return null;
    final File? videoFile = await service.resolveVideoFile(
      id,
      episodeIndex: episodeIndex,
    );
    if (videoFile == null) return null;
    final List<EmbeddedSubtitleTrack> tracks = await listEmbeddedSubtitleTracks(
      videoFile.path,
    );
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

  /// `GET .../graphicsubtitle` 的处理：反查文件 → 按流号找轨（必须是图形轨）→ 交注入
  /// 的抽取实现 → 原样回传整轨字节。
  Future<shelf.Response> _handleGraphicSubtitleTrack(
    FushiLibraryHostService service,
    shelf.Request request,
    String id,
  ) async {
    final GraphicSubtitleTrackExporter? exporter = graphicSubtitleTrackExporter;
    if (exporter == null) {
      return shelf.Response(501, body: 'Graphic subtitle export not available');
    }
    final int? streamIndex = int.tryParse(
      request.url.queryParameters['embeddedStreamIndex'] ?? '',
    );
    if (streamIndex == null || streamIndex < 0) {
      return shelf.Response(400, body: 'embeddedStreamIndex required');
    }
    final int episodeIndex = _episodeIndexFromRequest(request);
    final File? videoFile = await service.resolveVideoFile(
      id,
      episodeIndex: episodeIndex,
    );
    if (videoFile == null) return shelf.Response.notFound('Video not found');
    EmbeddedSubtitleTrack? track;
    for (final EmbeddedSubtitleTrack candidate
        in await listEmbeddedSubtitleTracks(videoFile.path)) {
      if (candidate.streamIndex == streamIndex) {
        track = candidate;
        break;
      }
    }
    // 文本轨有 `/subtitle`（转出可查词的文字），这里只接图形轨。
    if (track == null || subtitleFormatForCodec(track.codec) != null) {
      return shelf.Response.notFound('Graphic subtitle track not found');
    }
    final GraphicSubtitleTrackExport? export;
    try {
      export = await exporter(
        videoPath: videoFile.path,
        streamIndex: track.streamIndex,
        codec: track.codec,
      );
    } on GraphicSubtitleTrackExportUnsupported catch (e) {
      return shelf.Response(
        415,
        body: 'Unsupported graphic subtitle: ${e.codec}',
      );
    } catch (e) {
      fushiDebugPrint('graphic subtitle export failed: $e');
      return shelf.Response(500, body: 'Graphic subtitle export failed');
    }
    if (export == null || !await export.file.exists()) {
      return shelf.Response(500, body: 'Graphic subtitle export failed');
    }
    // `?part=header`：轨头 JSON（VobSub 调色板 / DVB 页号等载荷里没有的 extradata）；
    // 这条轨没有轨头（PGS）时 404。缺省回载荷。两次请求命中抽取实现的同一份缓存。
    final bool wantsHeader = request.url.queryParameters['part'] == 'header';
    final File? file = wantsHeader ? export.headerFile : export.file;
    final int? fileLength = file == null
        ? null
        : await _regularFileLength(file);
    if (file == null || fileLength == null) {
      return shelf.Response.notFound('Graphic subtitle track header not found');
    }
    return shelf.Response.ok(
      file.openRead(),
      headers: <String, String>{
        'Content-Type': wantsHeader
            ? 'application/json'
            : 'application/octet-stream',
        'Content-Length': '$fileLength',
        'X-Fushi-Graphic-Subtitle-Format': export.format,
      },
    );
  }

  Future<File?> _resolveVideoCover(
    FushiLibraryHostService service,
    String id,
  ) async {
    // 单行直查（videoCoverPath = 1 次 DB 查询 + stat）。旧实现每张封面请求重跑
    // 整份 listVideos()（每行一次目录扫描 + 多次 DB 查询），N 张封面 = O(N²)，
    // 500 视频的封面墙一次浏览拖成分钟级——这是「互联视频极慢」的主根因。
    return await _coverFile(await service.videoCoverPath(id));
  }

  String _generateVideoToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  /// 签发凭据已被吊销的流 token：删掉并回 403（BUG-4393）。正在发送的单个直传
  /// 响应不被切断，下一次 Range / 下一个 HLS 分段即 403。
  shelf.Response _revokedVideoToken(String tokenValue) {
    _dropVideoToken(tokenValue);
    return shelf.Response(
      403,
      body: 'Token revoked',
      headers: <String, String>{'Content-Type': 'text/plain'},
    );
  }

  /// 释放流票 [ticket]（BUG-4461）：作废它本身与随它签发的 token（光盘制卡 token），
  /// 并取消它们名下排队 / 在跑的转码分段。只认 [videoId] 下的 token——拿别的视频
  /// 的路径释放不动这张票。全程同步：作废 token 与 [cancelTranscodeWork] 之间没有
  /// await，与分段请求「登记 → 判存活」的同步段互斥，不存在漏网窗口。
  ///
  /// TTL / 数量上限淘汰 token 时**不**走这里（不 kill 在跑的分段），排队中的分段
  /// 在拿到名额后的存活判定处放弃。
  void _releaseVideoTicket(String videoId, String ticket) {
    final List<String> keys = <String>[
      for (final MapEntry<String, _VideoStreamToken> e
          in _videoStreamTokens.entries)
        if (e.value.videoId == videoId &&
            (e.key == ticket || e.value.ticket == ticket))
          e.key,
    ];
    for (final String key in keys) {
      _dropVideoToken(key);
      cancelTranscodeWork(key);
      // 已被前台请求合流的预取也是这条流的工作，一并取消（等它的请求回 410）。
      _cancelTranscodePrefetches(key, (_TranscodePrefetch _) => true);
    }
  }

  /// 作废一张流 token：摘出登记表，并把它名下缓存的转码分段一并清掉（video-34）——
  /// 缓存的生命周期跟 token 走，作废后留着的段既取不到又占内存。所有删 token 的
  /// 路径（释放流票 / 吊销 / TTL / 上限淘汰）都经这里。
  void _dropVideoToken(String tokenValue) {
    _videoStreamTokens.remove(tokenValue);
    _transcodeSegments.evictStream(tokenValue);
    // 没人等的预取直接取消：token 没了，转出来也取不到。已被前台请求合流的与在跑
    // 的前台分段同口径（TTL / 上限淘汰不 kill 在跑的分段），只有释放流票时才取消。
    _cancelTranscodePrefetches(tokenValue, (_TranscodePrefetch p) => !p.joined);
  }

  /// 取消 [stream] 名下满足 [where] 的在途预取：先摘掉缓存里的合流登记（之后同段的
  /// 请求另起一次转码，不会合流到这次注定以取消结束的工作上），再按预取自己的 work
  /// key 取消（预取从不排队；在跑的 ffmpeg 被 SIGKILL）。全程同步。
  void _cancelTranscodePrefetches(
    String stream,
    bool Function(_TranscodePrefetch p) where,
  ) {
    final List<_TranscodePrefetch>? list = _transcodePrefetches[stream];
    if (list == null) return;
    for (final _TranscodePrefetch p in list.where(where).toList()) {
      list.remove(p);
      _transcodeSegments.abandonInflight(
        stream: stream,
        index: p.index,
        input: p.input,
      );
      cancelTranscodeWork(p.workKey);
    }
    if (list.isEmpty) _transcodePrefetches.remove(stream);
  }

  /// 前台请求了 [stream] 的第 [index] 段：
  /// - 正在预取的就是这一段 → 标成已合流（之后 seek 不再作废它）；
  /// - 别的段上没人等的预取 → 播放位置已经不在那儿了（seek），作废，把 CPU 还给前台。
  ///   下一段（[index] + 1）上的预取保留：那正是接下来要用的。
  void _noteForegroundTranscodeRequest(String stream, int index) {
    final List<_TranscodePrefetch>? list = _transcodePrefetches[stream];
    if (list == null) return;
    for (final _TranscodePrefetch p in list) {
      if (p.index == index) p.joined = true;
    }
    _cancelTranscodePrefetches(
      stream,
      (_TranscodePrefetch p) =>
          !p.joined && p.index != index && p.index != index + 1,
    );
  }

  /// host 预取下一段（拍板 design-nmv-transcode-prefetch）：前台在转第 n 段时，用
  /// **空闲**名额同时转第 n+1 段，转完进 [_transcodeSegments]，client 来取时直接命中
  /// （或合流到这次在途的转码）。
  ///
  /// 收益在弱 host：单段转码耗时接近或超过段长时，client 顺序取段会被逐段转码卡住；
  /// 两段并行转的吞吐实测是顺序转的 1.2～1.7 倍（PR #3779 的测量）。强 host 上它只是
  /// 提前一段，client 停止取段（缓冲满 / 暂停）时最多多转这一段。
  ///
  /// 名额：只用 [tryLeaseIdleTranscodeSlot] 给的空闲名额——没人排队、且拿走后仍给
  /// 前台留 [kTranscodeSlotsReservedForForeground] 个，否则不预取；预取从不排队。
  /// 已缓存 / 正在转的段不重复起。
  void _prefetchTranscodeSegment({
    required String stream,
    required _VideoStreamToken tok,
    required VideoTranscodeProfile profile,
    required int durationMs,
    required String input,
    required int index,
  }) {
    if (index >= transcodeSegmentCount(durationMs)) return;
    if (_transcodeSegments.contains(
      stream: stream,
      index: index,
      input: input,
    )) {
      return;
    }
    final TranscodeSlotLease? slot = tryLeaseIdleTranscodeSlot();
    if (slot == null) return;
    final _TranscodePrefetch record = _TranscodePrefetch(
      index: index,
      input: input,
      workKey: '$stream\u0000prefetch\u0000$index',
    );
    (_transcodePrefetches[stream] ??= <_TranscodePrefetch>[]).add(record);
    final Future<Uint8List> run = _transcodeSegments.obtain(
      stream: stream,
      index: index,
      input: input,
      compute: () => transcodeSegment(
        inputPath: input,
        profile: profile,
        index: index,
        durationMs: durationMs,
        audioStreamIndex: tok.transcodeAudioStreamIndex,
        workKey: record.workKey,
        isAlive: () => _videoStreamTokens.containsKey(stream),
        slot: slot,
      ),
    );
    // 上面判过「未缓存、未在途」，obtain 必然同步调了 compute、把名额交给了
    // transcodeSegment；这里兜住「没交出去」的情况，名额不泄漏（release 幂等）。
    if (!_transcodeSegments.contains(
      stream: stream,
      index: index,
      input: input,
    )) {
      slot.release();
    }
    late final Future<void> settled;
    settled = run
        .then<void>(
          (Uint8List _) {},
          onError: (Object e) {
            // 失败不入缓存，client 真来取这一段时前台会重新转、按原路径回 503 / 410；
            // 这里只留一行日志，不重试。
            if (e is! TranscodeCancelled) {
              fushiDebugPrint('transcode prefetch n=$index failed: $e');
            }
          },
        )
        .whenComplete(() {
          final List<_TranscodePrefetch>? list = _transcodePrefetches[stream];
          if (list != null && list.remove(record) && list.isEmpty) {
            _transcodePrefetches.remove(stream);
          }
          _transcodePrefetchRuns.remove(settled);
        });
    _transcodePrefetchRuns.add(settled);
  }

  void _pruneVideoTokens() {
    // 视频播放时间长，token 有效期设为 6 小时
    final DateTime cutoff = _now().subtract(const Duration(hours: 6));
    final List<String> expired = <String>[
      for (final MapEntry<String, _VideoStreamToken> e
          in _videoStreamTokens.entries)
        if (e.value.createdAt.isBefore(cutoff)) e.key,
    ];
    expired.forEach(_dropVideoToken);
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
      _dropVideoToken(oldestKey);
    }
  }

  /// 本 host 此刻认不认转码请求：用户开关 ∧ 本机能 exec ffmpeg 子进程。
  ///
  /// 每次请求实时读偏好（而不是启动时快照一次）——用户在设置里关掉之后不该还要重启
  /// 互联服务才生效。
  bool get _videoTranscodeEnabled =>
      readInterconnectTranscodeEnabled(_prefs) && transcodeAvailable();

  /// [file] 的平均码率（bps，体积 × 8 ÷ 时长）；探不出时长返回 null。
  ///
  /// [knownDurationMs] 是本次请求已经为转码探过的时长，有就不再跑 ffprobe。结果按
  /// 「路径 + 大小 + 修改时间」缓存，缓存上限 [_kSourceBitrateCacheCap] 条（满了整表
  /// 清掉重来：只是省一次 ffprobe 的缓存，不值得 LRU）。
  Future<int?> _sourceBitrateOf(File file, {int? knownDurationMs}) async {
    final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final String key =
        '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    if (_sourceBitrateCache.containsKey(key)) return _sourceBitrateCache[key];
    final int? durationMs =
        knownDurationMs ?? await probeVideoDurationMs(file.path);
    final int? bitrate = averageBitrateBps(
      sizeBytes: stat.size,
      durationMs: durationMs,
    );
    if (_sourceBitrateCache.length >= _kSourceBitrateCacheCap) {
      _sourceBitrateCache.clear();
    }
    _sourceBitrateCache[key] = bitrate;
    return bitrate;
  }

  /// 转码 HLS 的三条子路径：playlist / 初始化段 / 分段。
  ///
  /// 共用一次 token 校验与文件反查。token 里没有画质档 = 这条流当初就没按转码签发，
  /// 一律 404——不给「拿一个直传 token 去点转码」的路径。
  Future<shelf.Response> _handleTranscodeHls(
    FushiLibraryHostService svc,
    shelf.Request request,
    String videoId,
    String suffix,
  ) async {
    _pruneVideoTokens();
    final String? tokenValue = request.url.queryParameters['token'];
    if (tokenValue == null || tokenValue.isEmpty) {
      return shelf.Response(
        401,
        body: 'Missing token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
    if (tok == null || tok.videoId != videoId) {
      return shelf.Response(
        403,
        body: 'Invalid or expired token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    if (!await _issuerStillValid(tok.issuer)) {
      return _revokedVideoToken(tokenValue);
    }
    final VideoTranscodeProfile? profile = tok.transcodeProfile;
    final int durationMs = tok.transcodeDurationMs ?? 0;
    if (profile == null || durationMs <= 0) {
      return shelf.Response.notFound('Not a transcoded stream');
    }
    final File? file = await svc.resolveVideoFile(
      videoId,
      episodeIndex: tok.episodeIndex,
    );
    if (file == null) return shelf.Response.notFound('Video not found');

    if (suffix == 'hls.m3u8') {
      // 分段 URI 用相对形式：playlist 自己的路径是
      // `/api/library/videos/<id>/hls.m3u8`，于是 `hlsseg.ts?...` 会被播放器解析成
      // `/api/library/videos/<id>/hlsseg.ts?...`——不必在这里重建 host/端口/协议，
      // 也就不会在反代或多网卡后面拼出一个对端连不上的绝对地址。扩展名不可省
      // （见上面路由处的 BUG-2630 说明）。
      final String tokenQuery = 'token=${Uri.encodeQueryComponent(tokenValue)}';
      final String playlist = buildTranscodeHlsPlaylist(
        durationMs: durationMs,
        segmentUri: (int index) =>
            '$kTranscodeSegmentPathSuffix?$tokenQuery&n=$index',
      );
      return shelf.Response.ok(
        playlist,
        headers: <String, String>{
          'Content-Type': 'application/vnd.apple.mpegurl',
          'Cache-Control': 'no-store',
        },
      );
    }

    final int? index = int.tryParse(request.url.queryParameters['n'] ?? '');
    final int count = transcodeSegmentCount(durationMs);
    if (index == null || index < 0 || index >= count) {
      return shelf.Response.notFound('Segment out of range');
    }
    // 分段工作挂在签发它的 token 名下（BUG-4461）：流票被释放时
    // [_releaseVideoTicket] 按 token 取消排队 / 在跑的分段；token 在本请求反查文件
    // 期间已被释放或过期的，[isAlive] 在登记时就拦下，不起 ffmpeg。
    //
    // 同一条流同一段只转一次（video-34）：往回拖到 client 向后缓冲之外、重连后重新
    // 请求、或同一段的并发请求，都从 [_transcodeSegments] 取，不再起 ffmpeg。缓存
    // 键含 token，画质档 / 音轨都绑在 token 上，不会把一档的字节回给另一档。
    //
    // 先登记前台这一段（它先拿名额）再起下一段的预取：预取只吃剩下的空闲名额。整段
    // 同步，中间没有 await。
    _noteForegroundTranscodeRequest(tokenValue, index);
    final Future<Uint8List> pending = _transcodeSegments.obtain(
      stream: tokenValue,
      index: index,
      input: file.path,
      compute: () => transcodeSegment(
        inputPath: file.path,
        profile: profile,
        index: index,
        durationMs: durationMs,
        audioStreamIndex: tok.transcodeAudioStreamIndex,
        workKey: tokenValue,
        isAlive: () => _videoStreamTokens.containsKey(tokenValue),
      ),
    );
    _prefetchTranscodeSegment(
      stream: tokenValue,
      tok: tok,
      profile: profile,
      durationMs: durationMs,
      input: file.path,
      index: index + 1,
    );
    final Uint8List? segment;
    try {
      segment = await _runTranscode(() => pending);
    } on TranscodeCancelled {
      return shelf.Response(
        410,
        body: 'Stream released',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    if (segment == null) {
      return shelf.Response(503, body: 'Transcoder unavailable');
    }
    return _transcodedBytesResponse(segment);
  }

  /// 蓝光标题的第 n 个码流。token 绑定视频与集（与 `/stream` 同一张 token），段号
  /// 只能落在这条标题自己的段表里——URL 持有者拿不到盘上别的文件。
  Future<shelf.Response> _handleBlurayClip(
    FushiLibraryHostService svc,
    shelf.Request request,
    String videoId,
  ) async {
    _pruneVideoTokens();
    final String? tokenValue = request.url.queryParameters['token'];
    if (tokenValue == null || tokenValue.isEmpty) {
      return shelf.Response(
        401,
        body: 'Missing token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    final _VideoStreamToken? tok = _videoStreamTokens[tokenValue];
    if (tok == null || tok.videoId != videoId) {
      return shelf.Response(
        403,
        body: 'Invalid or expired token',
        headers: <String, String>{'Content-Type': 'text/plain'},
      );
    }
    if (!await _issuerStillValid(tok.issuer)) {
      return _revokedVideoToken(tokenValue);
    }
    final File? file = await svc.resolveVideoFile(
      videoId,
      episodeIndex: tok.episodeIndex,
    );
    if (file == null) return shelf.Response.notFound('Video not found');
    final BlurayTitleStreams? disc = await readBlurayTitleStreams(file.path);
    if (disc == null) return shelf.Response.notFound('Not a Blu-ray title');
    final int? index = int.tryParse(request.url.queryParameters['n'] ?? '');
    if (index == null || index < 0 || index >= disc.streamPaths.length) {
      return shelf.Response.notFound('Clip out of range');
    }
    final File stream = File(disc.streamPaths[index]);
    // 蓝光目录常在网络盘上：async 判存在（BUG-3756）。
    if (!await stream.exists()) return shelf.Response.notFound('Clip missing');

    final BlurayClipLease lease;
    try {
      lease = await _blurayClipRelays.acquire(tokenValue, stream.path);
    } on Object catch (e) {
      // 加密但缺密钥 / 盘型不支持 / iOS 不装配解密：如实报，不发密文。
      engineLog.logDiagnostic('FushiSyncServer.blurayClip', e);
      return shelf.Response(409, body: 'Blu-ray clip cannot be decrypted');
    }
    if (lease.source == stream.path) {
      lease.release();
      final String etag;
      try {
        etag = await videoFileEtag(stream);
      } on FileSystemException {
        return shelf.Response.notFound('Clip missing');
      }
      return serveFileWithRange(
        stream,
        request,
        etag: etag,
        ifRangeRequired: false,
      );
    }
    return _proxyDecryptedClip(lease, request);
  }

  /// 把分段请求转给本次播放的解密回环（Range 原样透传），响应体结束或播放器断开时
  /// 释放 [lease]。回环在本机，一律直连，不走应用代理。
  Future<shelf.Response> _proxyDecryptedClip(
    BlurayClipLease lease,
    shelf.Request request,
  ) async {
    final HttpClient client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 30);
    void finish() {
      client.close(force: true);
      lease.release();
    }

    final HttpClientResponse upstream;
    try {
      final HttpClientRequest forward = await client.getUrl(
        Uri.parse(lease.source),
      );
      final String? range = request.headers['range'];
      if (range != null) forward.headers.set(HttpHeaders.rangeHeader, range);
      upstream = await forward.close();
    } on Object catch (e) {
      finish();
      engineLog.logDiagnostic('FushiSyncServer.blurayClipProxy', e);
      return shelf.Response(502, body: 'Blu-ray clip relay unavailable');
    }
    // 回环读盘卡死（光驱停转、盘坏道）时截断这次响应，别让它永远占着本次播放的解密
    // 会话。播放器背压暂停读取时 `timeout` 会停表，不会误截正在播的流。
    Stream<List<int>> body() async* {
      try {
        yield* upstream.timeout(
          _kBlurayClipStallTimeout,
          onTimeout: (EventSink<List<int>> sink) => sink.close(),
        );
      } finally {
        finish();
      }
    }

    return shelf.Response(
      upstream.statusCode,
      body: body(),
      headers: <String, String>{
        'Content-Type': 'video/mp2t',
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-store',
        for (final String name in const <String>[
          HttpHeaders.contentLengthHeader,
          HttpHeaders.contentRangeHeader,
        ])
          if (upstream.headers.value(name) case final String value) name: value,
      },
    );
  }

  /// 跑一次转码，把「转码器自身出问题」收敛成 null（由调用方回 503）。
  ///
  /// 分成两类如实处理：[ProcessException] 是 ffmpeg 根本起不来（被删了 / 覆盖路径指
  /// 错），[TranscodeFailure] 是它起来了但退出码非 0（源文件装不进解码器之类）。两者
  /// 都不该把整个 host 请求处理拖垮，但也都不能装作成功返回空字节——空段在播放器那头
  /// 表现为黑屏转圈，没人能从中看出 host 缺 ffmpeg。
  Future<Uint8List?> _runTranscode(Future<Uint8List?> Function() body) async {
    try {
      return await body();
    } on ProcessException catch (e) {
      fushiDebugPrint('transcode: ffmpeg not launchable: ${e.message}');
      return null;
    } on TranscodeFailure catch (e) {
      fushiDebugPrint('transcode: $e');
      return null;
    }
  }

  shelf.Response _transcodedBytesResponse(Uint8List bytes) => shelf.Response.ok(
    bytes,
    headers: <String, String>{
      'Content-Type': 'video/mp2t',
      'Content-Length': '${bytes.length}',
      // 转码产物只在 host 内存里按流 token 缓存（[_transcodeSegments]），不落盘。
      // 给 no-store 是为了别让中间层缓存下一份「按某个画质档转出来的字节」再回给
      // 另一个档。
      'Cache-Control': 'no-store',
    },
  );
}

/// 一次在途的 host 预取（见 `_prefetchTranscodeSegment`）。
class _TranscodePrefetch {
  _TranscodePrefetch({
    required this.index,
    required this.input,
    required this.workKey,
  });

  /// 预取的段号。
  final int index;

  /// 反查到的输入路径（缓存键的一部分）。
  final String input;

  /// 这次预取自己的转码 work key：与前台分段（work key = 流 token）分开，seek 时
  /// 能单独取消它而不误伤前台。
  final String workKey;

  /// 已有前台请求合流到这次预取上（client 真的来取这一段了）：seek 不再作废它。
  bool joined = false;
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

/// BUG-1568（BUG-908(a) 的视频同形问题）：视频流 token 的数量上限。签发侧
/// （GET /streamurl）先按 TTL prune、再淘汰最旧者收束到上限内。此前 prune 只挂在
/// GET /stream 消费侧——只 GET /streamurl 却从不取流的调用者会让
/// [_videoStreamTokens] 无界堆积（6 小时 TTL 内每次签发都是净增长）。
const int _maxVideoStreamTokens = 128;

/// 蓝光加密段转发：解密回环在这么久里一个字节都没给出就截断本次响应。
const Duration _kBlurayClipStallTimeout = Duration(seconds: 60);

/// [FushiSyncServer._sourceBitrateOf] 缓存的条数上限。
const int _kSourceBitrateCacheCap = 512;

/// 光盘标题制卡抽帧用的低清转码档（制卡 GIF / 截图只要小图，见 `miningVideoUrl`）。
const VideoTranscodeProfile _kDiscMiningTranscodeProfile =
    VideoTranscodeProfile(maxWidth: 640, maxBitrate: 1000000);

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

/// 起服务后挂上视频指纹落盘缓存，并在 [FushiSyncServer._videoFingerprintWarmDelay]
/// 后开始后台低优先级预热（拍板台 left3657）。host 不提供媒体库时只挂缓存。
extension _FushiSyncServerVideoFingerprintWarmup on FushiSyncServer {
  void _startVideoFingerprintWarmup() {
    _videoFingerprintsClosed = false;
    _videoFingerprintCancel = VideoFingerprintCancellation();
    _videoFingerprints.store = _videoFingerprintStore;
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return;
    final VideoFingerprintWarmer warmer = VideoFingerprintWarmer(
      listPaths: () => _videoFingerprintWarmPaths(svc),
      fingerprints: _videoFingerprints,
    );
    _videoFingerprintWarmer = warmer;
    _videoFingerprintWarmStart = Timer(
      _videoFingerprintWarmDelay,
      warmer.request,
    );
  }

  /// 停机收尾：返回后本 host 发起的指纹计算全部结束（不再开着任何视频文件），落盘
  /// 缓存也不再被写（BUG-5078 / BUG-5087）。正在算的文件被打断（拍板台
  /// host-stop-fingerprint-cancel），最多等原生哈希读完当前 1 MiB；同一文件还有本机
  /// 制卡等别的等待方时计算归它们、继续算，本 host 不再等。
  Future<void> _stopVideoFingerprintWarmup() async {
    // 先关闸再排空：之后到达的端点请求不再开算，排空循环看到的就是全部在途计算。
    _videoFingerprintsClosed = true;
    _videoFingerprintCancel.cancel();
    _videoFingerprintWarmStart?.cancel();
    _videoFingerprintWarmStart = null;
    final VideoFingerprintWarmer? warmer = _videoFingerprintWarmer;
    _videoFingerprintWarmer = null;
    await warmer?.close();
    while (_videoFingerprintWork.isNotEmpty) {
      await Future.wait(_videoFingerprintWork.toList(growable: false));
    }
    if (identical(_videoFingerprints.store, _videoFingerprintStore)) {
      _videoFingerprints.store = null;
    }
    // 摘下之后才等：摘下前已拿到本缓存的写入（同进程别处的指纹计算）在这里收尾，
    // 摘下后再算完的读到 store == null，不会再写。
    await _videoFingerprintStore.idle();
  }

  /// 开一次 `/fingerprint` 端点的指纹计算并登记，[stop] 等它收尾；停机已开始时不开、
  /// 返回 null（调用方回 503）。闸门检查与开算 + 登记同步完成，与 [stop] 的「关闸 →
  /// 排空」之间没有空隙。返回的就是 [start] 的结果：成败照常交给调用方处理，登记的只是
  /// 「何时结束」。
  Future<T>? _startVideoFingerprintWork<T>(Future<T> Function() start) {
    if (_videoFingerprintsClosed) return null;
    final Future<T> work = start();
    final Future<void> settled = work.then<void>(
      (T _) {},
      onError: (Object error, StackTrace stack) {},
    );
    _videoFingerprintWork.add(settled);
    unawaited(
      settled.whenComplete(() => _videoFingerprintWork.remove(settled)),
    );
    return work;
  }

  /// host 正在停机：不再开新的指纹计算。503 = 暂时不可用，client 按网络错误处理、稍后
  /// 重试；不能回 [kVideoFingerprintUnavailableStatus]（那是「这份字节担保不了」）。
  shelf.Response _videoFingerprintHostStopping() =>
      shelf.Response(503, body: 'Host is stopping');
}

/// 预热要算的文件：对端能经 host 播放的每条视频的每一集，取与 `/streamurl`、
/// `/fingerprint` 同一个 [FushiLibraryHostService.resolveVideoFile] 解析出的本地文件。
Future<List<String>> _videoFingerprintWarmPaths(
  FushiLibraryHostService svc,
) async {
  final List<String> paths = <String>[];
  for (final RemoteVideoInfo video in await svc.listVideos()) {
    if (!video.peerPlayable) continue;
    final List<int> episodes = video.episodes.isEmpty
        ? const <int>[0]
        : <int>[for (final RemoteVideoEpisode e in video.episodes) e.index];
    for (final int episode in episodes) {
      final File? file = await svc.resolveVideoFile(
        video.id,
        episodeIndex: episode,
      );
      if (file != null && VideoSourceFingerprint.isLocalPath(file.path)) {
        paths.add(file.path);
      }
    }
  }
  return paths;
}

/// `/fingerprint` 担保不了字节时的应答（BUG-4782）：不是 404，免得 client 当成老 host。
shelf.Response _videoFingerprintUnavailable(String reason) => shelf.Response(
  kVideoFingerprintUnavailableStatus,
  body: jsonEncode(<String, String>{'reason': reason}),
  headers: <String, String>{'Content-Type': 'application/json'},
);

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
  // 以免鉴权流子路径结尾的不是裸 id（那条路径归 token 鉴权的流 handler），显式拒，
  // 不靠分支顺序保护。
  for (final String suffix in _kVideoStreamSuffixes) {
    if (reqPath.endsWith(suffix)) return null;
  }
  return id;
}

String _safeDownloadStem(String value) {
  final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  return safe.isEmpty ? 'video' : safe;
}
