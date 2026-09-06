part of '../fushi_sync_server.dart';

/// 库 REST 域（B3 按域拆出）：资产 id 穿越闸门、资产包下载、词典 / 书 / 本地音频 / 有声书清单与下载。
/// 视频在 video.part.dart；方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerLibrary on FushiSyncServer {
  /// HBK-AUDIT-012 路径穿越闸门：资产名绝不能含路径分隔符或 `..`，否则能逃出 host
  /// 的资产根目录（DELETE 最危险）。合法返回 null；非法直接返回要回给客户端的响应。
  ///
  /// 此前这段判断在四个域 + 三个 position/progress 子路由里逐字重复了 7 遍。安全闸门
  /// 靠复制粘贴维持，抄漏一处就是真漏洞——收敛成一处后新端点只能显式调用它。
  ///
  /// 注意：视频域**不用**本闸门——视频 id 形如 `video/xxx`，合法地含 `/`，它有自己的
  /// `_extractVideoId` 校验。不要把视频接进来。
  shelf.Response? _rejectUnsafeAssetId(String id, String label) {
    if (id.isEmpty) return shelf.Response.notFound('Missing $label');
    if (id.contains('/') || id.contains('\\') || id.contains('..')) {
      return shelf.Response.forbidden('Invalid $label');
    }
    return null;
  }

  /// 「按名字取 / 存 / 删一个资产包」端点的共同骨架：词典 / 书 / 本地音频 / 有声书
  /// 四个域在这一层**逐字相同**，只差叫什么名字、临时文件用什么扩展名、调 service
  /// 的哪三个方法。
  ///
  /// 此前是四份约 60 行的复制粘贴（TODO-2120），加一个新媒体域就要再抄一遍——而这
  /// 段代码里含导出缓存 + ETag/Range 续传、上传临时目录的必清理、IOSink 的双重关闭
  /// 保护，抄漏任何一处都是真事故（泄漏临时目录 / 续传验证器失效 / socket 不回收）。
  ///
  /// [id] 必须已经过 [_rejectUnsafeAssetId]。
  Future<shelf.Response> _serveAssetPackage(
    shelf.Request request,
    String method, {
    required String id,
    required String cacheKind,
    required String notFoundMessage,
    required String tempPrefix,
    required String tempExtension,
    required Future<File> Function() export,
    required Future<void> Function(File tmp) import,
    required Future<void> Function() delete,
  }) async {
    switch (method) {
      case 'GET':
        // 经导出缓存 + Range/If-Range：TTL 内的续传钉在同一份字节上（ETag 作验证器）；
        // 旧 client 不发 Range 收到 200 全量，行为不变。扩展名保留 → Content-Type
        // 仍由 _guessContentType 按扩展名判定。
        File file;
        try {
          file = await _exportCache.obtain(cacheKind, id, export);
        } on StateError {
          return shelf.Response.notFound(notFoundMessage);
        }
        return serveFileWithRange(file, request,
            etag: ExportPackageCache.etagFor(file));

      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync(tempPrefix);
        final File tmp = File(p.join(tmpDir.path, '$id$tempExtension'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await import(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {
            // best-effort
          }
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {
            // best-effort
          }
        }

      case 'DELETE':
        await delete();
        return shelf.Response(204);

      default:
        return shelf.Response(405);
    }
  }

  Future<shelf.Response> _handleLibraryDictionaries(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/dictionaries') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteDictionaryInfo d in list) d.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    // 原先的 Uri.decodeComponent 调用会对已解码的 CJK 字符再次解析，
    // 导致 "Illegal percent encoding in URI"（Dart 不接受非 ASCII 作为
    // decodeComponent 输入）。直接 substring 即可得到正确的词典名。
    final String name = reqPath.substring('/api/library/dictionaries/'.length);
    // HBK-AUDIT-012 路径穿越闸门（收敛到 _rejectUnsafeAssetId），覆盖下面三个方法。
    final shelf.Response? unsafe =
        _rejectUnsafeAssetId(name, 'dictionary name');
    if (unsafe != null) return unsafe;

    return _serveAssetPackage(
      request,
      method,
      id: name,
      cacheKind: 'dict',
      notFoundMessage: 'Dictionary not found',
      tempPrefix: 'fushi_dict_in',
      tempExtension: '.fushidict',
      export: () => svc.exportDictionary(name),
      import: svc.importDictionary,
      delete: () => svc.deleteDictionary(name),
    );
  }

  Future<shelf.Response> _handleLibraryBooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/books') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteBookInfo> list = await svc.listBooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteBookInfo b in list)
            _remoteBookJsonForRequest(b, request)
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    const String bookPrefix = '/api/library/books/';
    const String coverSuffix = '/cover';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(coverSuffix)) {
      if (method != 'GET') return shelf.Response(405);
      final String coverBookId = reqPath.substring(
          bookPrefix.length, reqPath.length - coverSuffix.length);
      final shelf.Response? unsafeCoverBookId =
          _rejectUnsafeAssetId(coverBookId, 'book title');
      if (unsafeCoverBookId != null) return unsafeCoverBookId;
      final File? cover = await _resolveBookCover(svc, coverBookId);
      if (cover == null) return shelf.Response.notFound('Book cover not found');
      return serveFileWithRange(cover, request);
    }

    // GET/PUT /api/library/books/<bookKey>/progress — 跨设备阅读进度（TODO-767）。
    // GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度（host 取较新者）。
    // 与 video /position 分支对称，但落 host 自己的 reader_positions DB（非 prefs）。
    const String progressSuffix = '/progress';
    if (reqPath.startsWith(bookPrefix) && reqPath.endsWith(progressSuffix)) {
      final String progressBookKey = reqPath.substring(
          bookPrefix.length, reqPath.length - progressSuffix.length);
      final shelf.Response? unsafeProgressBookKey =
          _rejectUnsafeAssetId(progressBookKey, 'book key');
      if (unsafeProgressBookKey != null) return unsafeProgressBookKey;
      switch (method) {
        case 'GET':
          final RemoteBookProgress progress =
              await svc.getBookProgress(progressBookKey);
          return shelf.Response.ok(
            jsonEncode(progress.toJson()),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          await svc.putBookProgress(
            progressBookKey,
            RemoteBookProgress.fromJson(json.cast<String, Object?>()),
          );
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    final String bookId = reqPath.substring(bookPrefix.length);
    final shelf.Response? unsafe = _rejectUnsafeAssetId(bookId, 'book title');
    if (unsafe != null) return unsafe;

    // 注：`.epub` 扩展名保留 → Content-Type 仍是 application/epub+zip
    // （见 _guessContentType）。
    return _serveAssetPackage(
      request,
      method,
      id: bookId,
      cacheKind: 'book',
      notFoundMessage: 'Book not found',
      tempPrefix: 'hibiki_book_in',
      tempExtension: '.epub',
      export: () => svc.exportBook(bookId),
      // BUG-1503：body 是裸 .epub，推送方用户改的书名走 header 随行（视频推送的
      // `X-Hibiki-Video-Title` 同一先例）。旧 client 不发 → 两参 null/0 → 与
      // 原来的 `svc.importBook` tear-off 逐字同行为，故不必动
      // [_serveAssetPackage] 的四域共用签名。
      import: (File epubFile) => svc.importBook(
        epubFile,
        displayTitle: _decodeHeaderValue(request, kBookDisplayTitleHeader),
        displayTitleAt: int.tryParse(
              request.headers[kBookDisplayTitleAtHeader] ?? '',
            ) ??
            0,
      ),
      delete: () => svc.deleteBook(bookId),
    );
  }

  Map<String, Object?> _remoteBookJsonForRequest(
    RemoteBookInfo book,
    shelf.Request request,
  ) {
    final Map<String, Object?> json = book.toJson()
      ..remove('coverUrl')
      ..remove('hasCover');
    if (_coverFile(book.coverPath) != null) {
      json['hasCover'] = true;
      json['coverUrl'] = request.requestedUri.replace(
        pathSegments: <String>[
          'api',
          'library',
          'books',
          book.downloadId,
          'cover',
        ],
        queryParameters: <String, String>{},
      ).toString();
    }
    return json;
  }

  Future<File?> _resolveBookCover(
    FushiLibraryHostService service,
    String bookId,
  ) async {
    // 单行直查（bookCoverPath 按 bookKey 优先、title 兜底），不再每张封面重跑
    // 整份 listBooks()（逐书标签/有声书/合集重活），与 [_resolveVideoCover] 对称。
    return _coverFile(await service.bookCoverPath(bookId));
  }

  Future<shelf.Response> _handleLibraryLocalAudio(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/localaudio') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteLocalAudioInfo> list = await svc.listLocalAudio();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteLocalAudioInfo a in list) a.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    final String displayName =
        reqPath.substring('/api/library/localaudio/'.length);
    final shelf.Response? unsafe =
        _rejectUnsafeAssetId(displayName, 'displayName');
    if (unsafe != null) return unsafe;

    return _serveAssetPackage(
      request,
      method,
      id: displayName,
      cacheKind: 'localaudio',
      notFoundMessage: 'Local audio not found',
      tempPrefix: 'hibiki_localaudio_in',
      tempExtension: '.localaudio',
      export: () => svc.exportLocalAudio(displayName),
      import: svc.importLocalAudio,
      delete: () => svc.deleteLocalAudio(displayName),
    );
  }

  Future<shelf.Response> _handleLibraryAudiobooks(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/audiobooks') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteAudiobookInfo ab in list) ab.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    // reqPath 已在 _handleRequest 经 Uri.decodeFull 解码，此处无需再解码。
    // GET/PUT /api/library/audiobooks/<bookKey>/position — 跨设备有声书播放断点
    // (BUG-471)。GET 让 client 拉取 host 真相源进度；PUT 让 client 上报本端进度
    // (host 取较新者)。与 video /position 分支对称。必须在下面的整包 bookKey 提取
    // 之前匹配，否则 `<key>/position` 会被当成含 `/` 的非法 bookKey 拒绝。
    const String audiobookPrefix = '/api/library/audiobooks/';
    const String positionSuffix = '/position';
    if (reqPath.startsWith(audiobookPrefix) &&
        reqPath.endsWith(positionSuffix)) {
      final String positionBookKey = reqPath.substring(
          audiobookPrefix.length, reqPath.length - positionSuffix.length);
      final shelf.Response? unsafePositionBookKey =
          _rejectUnsafeAssetId(positionBookKey, 'bookKey');
      if (unsafePositionBookKey != null) return unsafePositionBookKey;
      // 先确认该有声书在 host DB 真实存在，防任意 key 写脏 prefs；与视频 position
      // 先 resolveVideoFile 同语义。BUG-471a：改用廉价的 audiobookExists（单次 DB
      // 查询）替代旧的 exportAudiobook 打包探测——旧实现每次 GET/PUT position 都把整
      // 本有声书音频/字幕/封面打成 .fushiaudio 临时文件再删，live sweep 对每本共享
      // 有声书每轮触发一次造成大量无谓 zip I/O + CPU。
      try {
        if (!await svc.audiobookExists(positionBookKey)) {
          return shelf.Response.notFound('Audiobook not found');
        }
      } on ArgumentError {
        return shelf.Response.forbidden('Invalid bookKey');
      }
      switch (method) {
        case 'GET':
          final ({int positionMs, int updatedAtMs}) p =
              await svc.getAudiobookPosition(positionBookKey);
          return shelf.Response.ok(
            jsonEncode(<String, Object?>{
              'positionMs': p.positionMs,
              'positionUpdatedAtMs': p.updatedAtMs,
            }),
            headers: <String, String>{'Content-Type': 'application/json'},
          );
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
          await svc.putAudiobookPosition(positionBookKey, posMs, updatedAtMs);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    // GET/PUT /api/library/audiobooks/<identity>/delay — 有声书调轴跨设备同步
    // （互联完整支持批次；与视频 /delay、上面的 /position 分支对称）。同样必须在
    // 整包 bookKey 提取之前匹配。老 host 无此分支 → 404，client best-effort 降级。
    const String delaySuffix = '/delay';
    if (reqPath.startsWith(audiobookPrefix) && reqPath.endsWith(delaySuffix)) {
      final String delayIdentity = reqPath.substring(
          audiobookPrefix.length, reqPath.length - delaySuffix.length);
      final shelf.Response? unsafeDelayIdentity =
          _rejectUnsafeAssetId(delayIdentity, 'bookKey');
      if (unsafeDelayIdentity != null) return unsafeDelayIdentity;
      if (svc is! AudiobookDelayHost) {
        return shelf.Response.notFound('Audiobook delay not supported');
      }
      final AudiobookDelayHost delayHost = svc as AudiobookDelayHost;
      try {
        if (!await svc.audiobookExists(delayIdentity)) {
          return shelf.Response.notFound('Audiobook not found');
        }
      } on ArgumentError {
        return shelf.Response.forbidden('Invalid bookKey');
      }
      switch (method) {
        case 'GET':
          final ({int delayMs, int updatedAtMs}) d =
              await delayHost.getAudiobookDelay(delayIdentity);
          return jsonResponse(<String, dynamic>{
            'delayMs': d.delayMs,
            'delayUpdatedAtMs': d.updatedAtMs,
          });
        case 'PUT':
          final String body = await request.readAsString();
          Map<String, dynamic> json;
          try {
            json = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return shelf.Response(400, body: 'Invalid JSON');
          }
          final int delayMs = (json['delayMs'] as num?)?.toInt() ?? 0;
          final int updatedAtMs =
              (json['delayUpdatedAtMs'] as num?)?.toInt() ?? 0;
          await delayHost.putAudiobookDelay(
              delayIdentity, delayMs, updatedAtMs);
          return shelf.Response(200);
        default:
          return shelf.Response(405);
      }
    }

    final String bookKey = reqPath.substring('/api/library/audiobooks/'.length);
    final shelf.Response? unsafe = _rejectUnsafeAssetId(bookKey, 'bookKey');
    if (unsafe != null) return unsafe;

    // 有声书包是 Range 续传的最大受益者（包最大）。导入要带 bookKeyOverride：
    // 落地时必须钉在 URL 上的这个 key，不能让包里的自述 key 改写身份（BUG-414）。
    return _serveAssetPackage(
      request,
      method,
      id: bookKey,
      cacheKind: 'audiobook',
      notFoundMessage: 'Audiobook not found',
      tempPrefix: 'hibiki_audiobook_in',
      tempExtension: '.audiobook',
      export: () => svc.exportAudiobook(bookKey),
      import: (File tmp) => svc.importAudiobook(tmp, bookKeyOverride: bookKey),
      delete: () => svc.deleteAudiobook(bookKey),
    );
  }
}
