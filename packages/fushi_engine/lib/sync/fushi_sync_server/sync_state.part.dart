part of '../fushi_sync_server.dart';

/// 同步状态域（B3 按域拆出）：活动流、聚合快照、合集、互联 service-config、Profile 传输、删除墓碑。
/// 方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerSyncState on FushiSyncServer {
  /// GET /api/library/activity — host 最近活动事件（新首页 Activity 面板的互联
  /// 数据源；display-only，client 不落库）。limit 参数钳制 1..500。老 client 不知
  /// 道此端点、老 host 对此路径 404（client 侧优雅降级为空列表）。
  Future<shelf.Response> _handleLibraryActivity(
    shelf.Request request,
    String method,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');
    if (method != 'GET') return shelf.Response(405);
    final int limit =
        (int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100)
            .clamp(1, 500);
    final List<RemoteActivityEvent> events =
        await svc.listActivityEvents(limit: limit);
    return shelf.Response.ok(
      jsonEncode(<Map<String, Object?>>[
        for (final RemoteActivityEvent e in events) e.toJson(),
      ]),
      headers: <String, String>{'Content-Type': 'application/json'},
    );
  }

  /// 聚合（统计 + 收藏）跨设备 live 端点（TODO-1056 phase C）。
  ///
  /// GET /api/library/aggregate — materialize host 自己的聚合快照（四张统计表 +
  /// 挖掘计数 + 收藏词 + 收藏句）返回 JSON，供 client 拉取 host 真相源。
  /// PUT /api/library/aggregate — client 上报（已在 client 端与 host 并集合并的）
  /// 快照，host 用 MAX / 并集 upsert 折叠进自己 DB（幂等，删除不跨端传播）。
  ///
  /// 鉴权：不在中间件豁免名单，故自动走 Basic token 全量校验（已配对 peer 才可访问）。
  /// 容错：坏 JSON → 400；service 未接线 → 404；apply 内部错误经 500 暴露（不静默）。
  Future<shelf.Response> _handleLibraryAggregate(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    switch (method) {
      case 'GET':
        final AggregateSnapshot snapshot = await svc.getAggregateSnapshot();
        return shelf.Response.ok(
          jsonEncode(snapshot.toJson()),
          // charset=utf-8 必带：快照里的书名/标题/义项含 CJK，client 用
          // package:http `.body` 默认按 latin1 解码会乱码（同 _jsonResponse）。
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      case 'PUT':
        final Map<String, dynamic>? json = await readJsonObjectBody(request);
        if (json == null) return shelf.Response(400, body: 'Invalid JSON');
        // fromJson 容错：未知高版本 / 缺字段 / 坏行降级为空或跳过，绝不抛。
        final AggregateSnapshot snapshot = AggregateSnapshot.fromJson(json);
        await svc.applyAggregateSnapshot(snapshot);
        return shelf.Response(200);
      default:
        return shelf.Response(405);
    }
  }

  /// 合集清单跨设备 live 端点（多端库联合视图 §2.3 任务5.2）。
  ///
  /// GET /api/library/collections — 返回 host 当前合集全量快照清单
  /// （[FushiLibraryHostService.getCollectionManifest] 的 canonicalJson），供 client
  /// 拉取 host 合集真相源做读-合并-写。
  /// POST /api/library/collections — client 上报本端合集清单，host 经
  /// [FushiLibraryHostService.mergeCollectionManifest] 并入自己 DB（成员并集 + 移出/
  /// 删除墓碑防复活 + 手动序整合集 LWW，语义在 CollectionSyncEngine），返回合并后清单。
  ///
  /// 鉴权：不在中间件豁免名单，故自动走 Basic token 全量校验（已配对 peer 才可访问，
  /// 与 aggregate 端点同纪律）。容错：坏 JSON / 非法/高版本清单 → 400（不静默按旧
  /// 语义误读新字段污染 host 数据，与 [CollectionManifest.fromJson] 的版本闸门一致）。
  Future<shelf.Response> _handleLibraryCollections(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    switch (method) {
      case 'GET':
        final CollectionManifest manifest = await svc.getCollectionManifest();
        return shelf.Response.ok(
          manifest.canonicalJson(),
          // charset=utf-8 必带：合集名含 CJK，client 用 package:http `.body` 默认按
          // latin1 解码会乱码（同 aggregate / _jsonResponse）。
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      case 'POST':
        final Map<String, dynamic>? json = await readJsonObjectBody(request);
        if (json == null) return shelf.Response(400, body: 'Invalid JSON');
        CollectionManifest incoming;
        try {
          incoming = CollectionManifest.fromJson(json);
        } on FormatException catch (e) {
          return shelf.Response(400, body: 'Invalid manifest: $e');
        }
        final CollectionManifest merged =
            await svc.mergeCollectionManifest(incoming);
        return shelf.Response.ok(
          merged.canonicalJson(),
          headers: <String, String>{
            'Content-Type': 'application/json; charset=utf-8'
          },
        );
      default:
        return shelf.Response(405);
    }
  }

  /// Host → paired child service configuration.
  ///
  /// This endpoint carries API keys and connection credentials, so its security
  /// boundary is intentionally narrower than the ordinary library API:
  /// HTTPS is mandatory, only a per-peer token is accepted, and no write method
  /// exists. The legacy shared server token remains valid elsewhere for
  /// compatibility but is explicitly rejected here.
  Future<shelf.Response> _handleInterconnectServiceConfig(
    shelf.Request request,
    String method,
  ) async {
    if (method != 'GET') return shelf.Response(405);
    if (_securityContext == null) {
      return shelf.Response.forbidden('HTTPS required for service config');
    }
    if (!await _validatePeerAuth(request.headers['authorization'])) {
      return shelf.Response.forbidden('Paired-device token required');
    }
    final FushiLibraryHostService? library = _libraryService;
    if (library is! InterconnectServiceConfigHost) {
      return shelf.Response.notFound('Service config capability off');
    }
    final InterconnectServiceConfigSnapshot snapshot =
        await (library as InterconnectServiceConfigHost)
            .getInterconnectServiceConfig();
    return shelf.Response.ok(
      jsonEncode(snapshot.toJson()),
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    );
  }

  /// GET / PUT `/api/interconnect/profile`：互联「配置文件」（Profile）双向搬运。
  ///
  /// 与 `service-config`（自动跟随的小白名单、单向下行）分工不同：这条是用户**显式点
  /// 一次**的整份 Profile 搬运，双向。安全门与 service-config 同级并更严一档：
  ///   * **必须 TLS**（`_securityContext != null`）——载荷是用户的整套设置，明文链路上
  ///     不给（同 BUG-1311 给 service-config 立的规矩）；
  ///   * **必须已配对 peer token**（`_validatePeerAuth`，未进鉴权豁免名单）；
  ///   * **host 侧用户开关**：默认关。没有这道门，入站 PUT 就是一条「无 UI 无开关的
  ///     隐形写入通道」，正是 BUG-988 点名要避免的形状。开关关着返回 403（而不是 404），
  ///     好让 client 把「host 不支持」与「host 关着」两种情况分开报。
  ///
  /// 载荷就是 Profile 的分享 JSON（`.fushiprofile.json` 的内容），凭据剔除与字体路径
  /// 剥离由 `ProfileRepository.exportProfileToJson` 负责，见
  /// [InterconnectProfileHost] 的文档。入站一律 `createNew` 导入，绝不覆盖 host 上任何
  /// 既有 Profile。
  Future<shelf.Response> _handleInterconnectProfile(
    shelf.Request request,
    String method,
  ) async {
    if (method != 'GET' && method != 'PUT') return shelf.Response(405);
    if (_securityContext == null) {
      return shelf.Response.forbidden('HTTPS required for profile transfer');
    }
    if (!await _validatePeerAuth(request.headers['authorization'])) {
      return shelf.Response.forbidden('Paired-device token required');
    }
    final FushiLibraryHostService? library = _libraryService;
    if (library is! InterconnectProfileHost) {
      return shelf.Response.notFound('Profile transfer capability off');
    }
    final InterconnectProfileHost host = library as InterconnectProfileHost;
    if (!await host.isInterconnectProfileTransferEnabled()) {
      return shelf.Response.forbidden('Profile transfer disabled on host');
    }
    if (method == 'GET') {
      final String json = await host.exportInterconnectProfile();
      return shelf.Response.ok(
        json,
        headers: const <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-store',
        },
      );
    }
    final String body = await request.readAsString();
    if (body.trim().isEmpty) {
      return shelf.Response(400, body: 'Empty profile payload');
    }
    try {
      final String name = await host.importInterconnectProfile(body);
      return jsonResponse(<String, dynamic>{'name': name});
    } on FormatException catch (e) {
      // 载荷不是合法的 Profile 导出（魔数/版本/结构不对）：400，且 host 侧 DB 零改动
      // （解析在写库之前，见 ProfileRepository.parseProfileExport）。
      return shelf.Response(400, body: 'Invalid profile payload: ${e.message}');
    }
  }

  /// GET `/api/tombstones`：列 host 全部删除墓碑为 JSON 数组，供 client 拉取后与本地
  /// 在库键求交、弹逐条确认删本地（显式确认式删除传播，host→client 消费方向）。走已配对
  /// peer 的 Basic token 校验（与 collections/aggregate 同纪律，未进鉴权豁免名单）。
  Future<shelf.Response> _handleTombstones(
    shelf.Request request,
    String method,
  ) async {
    if (method != 'GET') return shelf.Response(405);
    final FushiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');
    // 可选能力探测：host 未实现删除墓碑列举（老 host / 测试 fake）→ 404，client 侧
    // getRemoteDeletionTombstones 已优雅降级（不崩、跳过删除墓碑消费）。
    if (svc is! DeletionTombstoneHost) {
      return shelf.Response.notFound('No deletion tombstone capability');
    }
    final List<({String mediaType, String itemKey, int deletedAt})> rows =
        await (svc as DeletionTombstoneHost).listDeletionTombstones();
    final List<Map<String, Object?>> body = <Map<String, Object?>>[
      for (final r in rows)
        <String, Object?>{
          'mediaType': r.mediaType,
          'itemKey': r.itemKey,
          'deletedAt': r.deletedAt,
        },
    ];
    return shelf.Response.ok(
      jsonEncode(body),
      // charset=utf-8 必带：itemKey 可能含 CJK（书名派生 key），client 按 latin1 默认
      // 解码会乱码（同 collections / aggregate）。
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8'
      },
    );
  }
}
