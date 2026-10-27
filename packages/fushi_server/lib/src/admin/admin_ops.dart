/// 服务端自己的操作目录（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.5 / D8）：用与 app 同一套 [FushiOp] / [OpDescription] 描述 `/api/admin/*` 的
/// 一部分，给远端 AI 助手会话当工具集（手机把「下载执行设备」设成服务端时）。
///
/// - **handler 不写业务逻辑**：每条操作的路由都把调用原样转给 [AdminApi.handle]（进程
///   内一次 shelf 调用，与 WebUI / `fushi_server ctl` 走同一个方法）。
/// - 规则同 app 侧护轮：非 read 操作要么声明 [OpUndo]（执行前抓快照、按载荷撤销，
///   执行后又被手动改过就报 superseded 不覆盖），要么标成 [OpRisk.irreversible] 且带
///   表态参数 `confirm`——它由 AI 运行时只在用户点了确认卡片后注入，这里的转发层
///   缺它一律 422，不进 admin API。
/// - **不描述**的（远端 AI 不该碰）：配对 / 撤销对端（安全边界，peer 不该经 AI 拿到
///   管理员能力）、AnkiWeb 登录登出与资源索引器 / AI 提供商 / qBittorrent 等带凭据的
///   设置、监听地址 / 端口 / TLS 这类要重启的设置、上传、互联代调、配置方案寄存、日志
///   （可能含路径与令牌片段）。不追求与 app 的操作一一对应。
library;

import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 进程内调 admin API 的入口（生产是 `AdminApi.handle`）。
typedef AdminDispatch = Future<shelf.Response> Function(shelf.Request request);

/// 不可逆操作的表态参数名。
const String kServerOpConfirmGate = 'confirm';

const OpParam _confirmGate = OpParam.userGate(
  kServerOpConfirmGate,
  description: 'The user confirmed this irreversible operation in the app.',
);

/// `server.download.add-with-trackers` 的表态参数：用户在确认卡片上看过完整的磁力链接。
const String kServerOpTrustMagnetAddressesGate = 'trustMagnetAddresses';

/// 磁力链接里让 BT 客户端去请求的地址参数（BEP 9 / 19：tracker、web seed、exact /
/// acceptable source、peer 地址；`tr.1` 这类编号写法同样算）。
const List<String> kMagnetAddressParams = <String>[
  'tr',
  'ws',
  'xs',
  'as',
  'x.pe',
];

/// [magnet] 带不带地址参数（见 [kMagnetAddressParams]）。解析不了的一律按带了算。
bool magnetHasAddressParams(String magnet) {
  final int q = magnet.indexOf('?');
  if (q < 0) return false;
  for (final String pair in magnet.substring(q + 1).split('&')) {
    final int eq = pair.indexOf('=');
    final String rawKey = eq < 0 ? pair : pair.substring(0, eq);
    final String key;
    try {
      key = Uri.decodeQueryComponent(rawKey).toLowerCase();
    } on FormatException {
      return true;
    }
    for (final String p in kMagnetAddressParams) {
      if (key == p || key.startsWith('$p.')) return true;
    }
  }
  return false;
}

const List<OpParam> _downloadAddParams = <OpParam>[
  OpParam.string('magnet', description: 'Magnet URI.', required: true),
  OpParam.string(
    'title',
    description: 'Work title (used for organizing and scraping).',
    required: true,
  ),
  OpParam.string(
    'mediaKind',
    description: 'movie or tv.',
    enumValues: <String>['movie', 'tv'],
  ),
  OpParam.integer('year', description: 'Release year, when known.'),
  OpParam.string(
    'metadataProvider',
    description: 'Identity provider, given together with externalId.',
    enumValues: <String>['anidb', 'mal', 'tmdb'],
  ),
  OpParam.string(
    'externalId',
    description: 'Positive integer id at metadataProvider.',
  ),
  OpParam.string(
    'subtitlePolicy',
    description: 'Subtitle fetching policy.',
    enumValues: <String>['none', 'bestEffort', 'required'],
  ),
];

/// 设置里 AI 可以改的项（都能写回旧值；凭据 / 要重启的项不在其中）。
const List<String> kServerAgentSettingKeys = <String>[
  'subtitleLanguage',
  'metadataLocale',
  'scanPrune',
  'scanScrape',
];

/// 把一次 [CtlCall] 原样转给 admin API。[gated] = 不可逆操作：body 里的 `confirm`
/// 必须是 true（运行时只在用户点了确认卡片后注入），转发前剥掉。
CtlRouteHandler _forward(
  AdminDispatch Function() dispatch, {
  bool gated = false,
}) => (CtlCall call) async {
  final Map<String, Object?> body = Map<String, Object?>.of(call.body);
  if (gated && body.remove(kServerOpConfirmGate) != true) {
    throw const CtlFailure.rejected('confirmation_required');
  }
  return adminCall(dispatch(), call.method, call.path, body: body);
};

/// 进程内调一次 admin API，回 JSON；>= 400 抛 [CtlFailure]（短码按状态码，消息取
/// 错误体的 `error`）。GET / DELETE 的参数走 query。
Future<Object?> adminCall(
  AdminDispatch dispatch,
  String method,
  String path, {
  Map<String, Object?> body = const <String, Object?>{},
}) async {
  final bool hasBody = method == 'POST' || method == 'PUT';
  Uri uri = Uri.parse('http://localhost$path');
  if (!hasBody && body.isNotEmpty) {
    uri = uri.replace(
      queryParameters: <String, String>{
        for (final MapEntry<String, Object?> e in body.entries)
          if (e.value != null) e.key: '${e.value}',
      },
    );
  }
  final shelf.Response response = await dispatch(
    shelf.Request(
      method,
      uri,
      body: hasBody ? jsonEncode(body) : null,
      headers: hasBody
          ? const <String, String>{'Content-Type': 'application/json'}
          : const <String, String>{},
    ),
  );
  final String text = await response.readAsString();
  Object? decoded;
  try {
    decoded = text.isEmpty ? null : jsonDecode(text);
  } on FormatException {
    decoded = text;
  }
  if (response.statusCode >= 400) {
    final String message = decoded is Map && decoded['error'] != null
        ? '${decoded['error']}'
        : text;
    throw CtlFailure(response.statusCode, switch (response.statusCode) {
      400 => 'bad_request',
      403 => 'forbidden',
      404 => 'not_found',
      409 => 'conflict',
      422 => 'rejected',
      503 => 'unavailable',
      _ => 'internal',
    }, message);
  }
  return decoded ?? const <String, Object?>{'ok': true};
}

Future<Map<String, Object?>> _getMap(
  AdminDispatch dispatch,
  String path,
) async {
  final Object? result = await adminCall(dispatch, 'GET', path);
  return result is Map
      ? Map<String, Object?>.from(result)
      : <String, Object?>{};
}

Future<Map<String, Object?>?> _downloadJob(
  AdminDispatch dispatch,
  String id,
) async {
  final Object? jobs = (await _getMap(
    dispatch,
    '/api/admin/downloads',
  ))['jobs'];
  if (jobs is! List) return null;
  for (final Object? job in jobs) {
    if (job is Map && job['jobId'] == id) return Map<String, Object?>.from(job);
  }
  return null;
}

Future<Map<String, Object?>?> _subscription(
  AdminDispatch dispatch,
  String id,
) async {
  final Object? subs = (await _getMap(
    dispatch,
    '/api/admin/subscriptions',
  ))['subscriptions'];
  if (subs is! List) return null;
  for (final Object? s in subs) {
    if (s is Map && s['subscriptionId'] == id) {
      return Map<String, Object?>.from(s);
    }
  }
  return null;
}

Future<Map<String, Object?>?> _library(
  AdminDispatch dispatch,
  String id,
) async {
  final Object? libs = (await _getMap(
    dispatch,
    '/api/admin/libraries',
  ))['libraries'];
  if (libs is! List) return null;
  for (final Object? l in libs) {
    if (l is Map && l['id'] == id) return Map<String, Object?>.from(l);
  }
  return null;
}

String _enc(Object? id) => Uri.encodeComponent('$id');

/// 服务端操作目录的描述 + 路由（路由 handler 全是 [_forward]）。
({List<CtlRoute> routes, List<OpDescription> descriptions}) buildServerAdminOps(
  AdminDispatch Function() dispatch,
) {
  final List<CtlRoute> routes = <CtlRoute>[];
  final List<OpDescription> descriptions = <OpDescription>[];

  void op(
    OpDescription description, {
    bool gated = false,
    CtlRouteHandler? handler,
    bool addRoute = true,
  }) {
    if (addRoute) {
      routes.add(
        CtlRoute(
          description.method,
          description.pattern,
          handler ?? _forward(dispatch, gated: gated),
        ),
      );
    }
    descriptions.add(description);
  }

  void read(
    String id,
    String path,
    String summary, {
    List<OpParam> params = const <OpParam>[],
  }) => op(
    OpDescription(
      id: id,
      method: 'GET',
      pattern: path,
      summary: summary,
      params: params,
    ),
  );

  void irreversible(
    String id,
    String method,
    String path,
    String summary, {
    List<OpParam> params = const <OpParam>[],
    bool longRunning = false,
  }) => op(
    OpDescription(
      id: id,
      method: method,
      pattern: path,
      summary: summary,
      risk: OpRisk.irreversible,
      longRunning: longRunning,
      params: <OpParam>[...params, _confirmGate],
    ),
    gated: true,
  );

  const OpParam pathId = OpParam.string(
    'id',
    description: 'Id from the matching list operation.',
    required: true,
    inPath: true,
  );

  // ── 只读 ───────────────────────────────────────────────────────────
  read(
    'server.status',
    '/api/admin/status',
    'Server overview: device name, uptime, library / video / book counts, scan state, download and subscription capability, OCR model status.',
  );
  read(
    'server.library.list',
    '/api/admin/libraries',
    'List the library roots the server scans (id, path, kind, whether the folder exists).',
  );
  read(
    'server.job.list',
    '/api/admin/jobs',
    'List background jobs (ASR / OCR / subtitle) on the server.',
  );
  read(
    'server.download.list',
    '/api/admin/downloads',
    'List download jobs on the server with lifecycle, stage and progress.',
  );
  read(
    'server.download.subtitles',
    '/api/admin/downloads/:id/subtitles',
    'List the subtitle files fetched for one download job.',
    params: const <OpParam>[pathId],
  );
  read(
    'server.subscription.list',
    '/api/admin/subscriptions',
    'List content subscriptions (auto-download of new episodes) with item counts.',
  );
  read(
    'server.scrape.pending',
    '/api/admin/scrape/pending',
    'List video works whose metadata scrape is still pending (not identified).',
  );
  read(
    'server.settings.get',
    '/api/admin/settings',
    'Read server settings. Secrets are reported only as "set or not". Only subtitleLanguage, metadataLocale, scanPrune and scanScrape can be changed via server.settings.set.',
  );
  read(
    'server.model.list',
    '/api/admin/models',
    'List ASR / OCR models on the server and whether each is downloaded.',
  );
  read(
    'server.anki.status',
    '/api/admin/anki',
    'Anki landing status: account, sync state, pending / failed mined cards, deck and note type settings.',
  );

  // ── 可撤销的写 ─────────────────────────────────────────────────────
  op(
    OpDescription(
      id: 'server.library.add',
      method: 'POST',
      pattern: '/api/admin/libraries',
      summary:
          'Add a library root folder on the server (created if missing). Undo removes it again (the folder and its files stay).',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'path',
          description: 'Absolute folder path on the server.',
          required: true,
        ),
        OpParam.string(
          'kind',
          description: 'What the folder holds.',
          enumValues: <String>['video', 'book'],
        ),
        OpParam.string(
          'id',
          description: 'Optional stable id; generated when omitted.',
        ),
      ],
      undo: OpUndo(
        capture: (CtlCall call) async => <String, Object?>{
          'ids': <String>[
            for (final Object? l
                in ((await _getMap(
                          dispatch(),
                          '/api/admin/libraries',
                        ))['libraries']
                        as List? ??
                    const <Object?>[]))
              if (l is Map) '${l['id']}',
          ],
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) {
          final Set<String> old = <String>{
            for (final Object? id
                in before['ids'] as List? ?? const <Object?>[])
              '$id',
          };
          String? added;
          final Object? libs = result is Map ? result['libraries'] : null;
          if (libs is List) {
            for (final Object? l in libs) {
              if (l is Map && !old.contains('${l['id']}')) added = '${l['id']}';
            }
          }
          return OpUndoRecord(
            payload: <String, Object?>{'id': added},
            after: '${call.body['path']}',
          );
        },
        revert: (Map<String, Object?> payload) async {
          final Object? id = payload['id'];
          if (id == null || await _library(dispatch(), '$id') == null) {
            return const OpUndoOutcome.superseded('library already removed');
          }
          await adminCall(
            dispatch(),
            'DELETE',
            '/api/admin/libraries/${_enc(id)}',
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.library.remove',
      method: 'DELETE',
      pattern: '/api/admin/libraries/:id',
      summary:
          'Stop scanning a library root (config only; no files are deleted, indexed items stay). Undo adds it back.',
      risk: OpRisk.write,
      params: const <OpParam>[pathId],
      undo: OpUndo(
        capture: (CtlCall call) async {
          final Map<String, Object?>? lib = await _library(
            dispatch(),
            call.params['id'] ?? '',
          );
          if (lib == null) {
            throw CtlFailure.notFound('unknown library ${call.params['id']}');
          }
          return <String, Object?>{
            'id': lib['id'],
            'path': lib['path'],
            'kind': lib['kind'],
          };
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(payload: before, before: '${before['path']}'),
        revert: (Map<String, Object?> payload) async {
          if (await _library(dispatch(), '${payload['id']}') != null) {
            return const OpUndoOutcome.superseded('library was added back');
          }
          await adminCall(
            dispatch(),
            'POST',
            '/api/admin/libraries',
            body: <String, Object?>{
              'id': payload['id'],
              'path': payload['path'],
              'kind': payload['kind'],
            },
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  final OpUndo downloadAddUndo = OpUndo(
    record: (CtlCall call, Map<String, Object?> before, Object? result) =>
        OpUndoRecord(
          payload: <String, Object?>{
            'jobId': result is Map ? result['jobId'] : null,
          },
          after: '${call.body['title']}',
        ),
    revert: (Map<String, Object?> payload) async {
      final Object? id = payload['jobId'];
      final Map<String, Object?>? job = id == null
          ? null
          : await _downloadJob(dispatch(), '$id');
      if (job == null) {
        return const OpUndoOutcome.failed('download job no longer exists');
      }
      switch (job['lifecycle']) {
        case 'completed':
          return const OpUndoOutcome.superseded(
            'download already finished; files are kept',
          );
        case 'cancelled':
          return const OpUndoOutcome.done();
      }
      await adminCall(
        dispatch(),
        'POST',
        '/api/admin/downloads/${_enc(id)}/cancel',
      );
      return const OpUndoOutcome.done();
    },
  );
  // 磁力链接里的 tr= / ws= / xs= / as= / x.pe= 是 BT 客户端随后会去请求的地址：模型
  // 自己拼的 tracker URL 能把它看到的任何数据带出去，这一下出站撤销不了（spec §5.2）。
  // 不带这些参数的磁力（纯 DHT）直接执行、可撤销；带了的必须走先确认的那条，确认卡片
  // 上能看到完整链接。判据是「有没有地址参数」而不是「是不是已知 tracker」：服务端这层
  // 没有可信的 tracker 白名单，按主机名放行也挡不住 `udp://known:1337/announce?<数据>`。
  OpDescription downloadAdd({required bool withAddresses}) => OpDescription(
    id: withAddresses
        ? 'server.download.add-with-trackers'
        : 'server.download.add',
    method: 'POST',
    pattern: '/api/admin/downloads',
    summary: withAddresses
        ? 'Queue a torrent download whose magnet link carries tracker / web '
              'seed addresses (tr=, ws=, xs=, as=, x.pe=). The client contacts '
              'those addresses, so the user confirms the full link first. Undo '
              'cancels the job unless it already finished.'
        : 'Queue a torrent download (magnet link) on the server into its '
              'managed library. Magnets with tracker / web seed addresses '
              '(tr=, ws=…) are refused here: use '
              'server.download.add-with-trackers. Undo cancels the job unless '
              'it already finished.',
    risk: OpRisk.write,
    confirm: withAddresses,
    longRunning: true,
    params: <OpParam>[
      ..._downloadAddParams,
      if (withAddresses)
        const OpParam.userGate(
          kServerOpTrustMagnetAddressesGate,
          description: 'The user confirmed the magnet link with its addresses.',
        ),
    ],
    undo: downloadAddUndo,
  );
  op(
    downloadAdd(withAddresses: false),
    handler: (CtlCall call) async {
      final Map<String, Object?> body = Map<String, Object?>.of(call.body);
      final bool trusted =
          body.remove(kServerOpTrustMagnetAddressesGate) == true;
      if (!trusted && magnetHasAddressParams('${body['magnet'] ?? ''}')) {
        throw const CtlFailure.rejected(
          'magnet_has_addresses: the magnet carries tracker / web seed '
          'addresses; use server.download.add-with-trackers (the user '
          'confirms the link)',
        );
      }
      return adminCall(dispatch(), call.method, call.path, body: body);
    },
  );
  op(downloadAdd(withAddresses: true), addRoute: false);
  op(
    OpDescription(
      id: 'server.download.cancel',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/cancel',
      summary:
          'Cancel a running download job (downloaded data is kept). Undo retries it.',
      risk: OpRisk.write,
      params: const <OpParam>[pathId],
      undo: OpUndo(
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(
              payload: <String, Object?>{'jobId': call.params['id']},
            ),
        revert: (Map<String, Object?> payload) async {
          final Map<String, Object?>? job = await _downloadJob(
            dispatch(),
            '${payload['jobId']}',
          );
          if (job == null) {
            return const OpUndoOutcome.failed('download job no longer exists');
          }
          if (job['lifecycle'] != 'cancelled') {
            return const OpUndoOutcome.superseded();
          }
          await adminCall(
            dispatch(),
            'POST',
            '/api/admin/downloads/${_enc(payload['jobId'])}/retry',
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.download.retry',
      method: 'POST',
      pattern: '/api/admin/downloads/:id/retry',
      summary: 'Retry a failed or stuck download job. Undo cancels it again.',
      risk: OpRisk.write,
      params: const <OpParam>[pathId],
      undo: OpUndo(
        capture: (CtlCall call) async {
          final Map<String, Object?>? job = await _downloadJob(
            dispatch(),
            call.params['id'] ?? '',
          );
          if (job == null) {
            throw CtlFailure.notFound(
              'unknown download job ${call.params['id']}',
            );
          }
          return <String, Object?>{
            'jobId': job['jobId'],
            'lifecycle': job['lifecycle'],
          };
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(payload: before, before: '${before['lifecycle']}'),
        revert: (Map<String, Object?> payload) async {
          final Map<String, Object?>? job = await _downloadJob(
            dispatch(),
            '${payload['jobId']}',
          );
          if (job == null) {
            return const OpUndoOutcome.failed('download job no longer exists');
          }
          if (job['lifecycle'] == 'completed') {
            return const OpUndoOutcome.superseded(
              'download already finished; files are kept',
            );
          }
          if (job['lifecycle'] == 'cancelled') {
            return const OpUndoOutcome.done();
          }
          await adminCall(
            dispatch(),
            'POST',
            '/api/admin/downloads/${_enc(payload['jobId'])}/cancel',
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.subscription.create',
      method: 'POST',
      pattern: '/api/admin/subscriptions',
      summary:
          'Create a content subscription that auto-downloads matching releases on the server. Undo deletes it.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string('title', description: 'Work title.', required: true),
        OpParam.string(
          'searchQuery',
          description: 'Query sent to the resource provider.',
          required: true,
        ),
        OpParam.string(
          'mediaKind',
          description: 'movie or tv.',
          required: true,
          enumValues: <String>['movie', 'tv'],
        ),
        OpParam.string(
          'resourceProvider',
          description:
              'Resource provider id (see server.status subscriptions capability).',
          required: true,
        ),
        OpParam.string(
          'mode',
          description: 'oneShot or ongoing.',
          enumValues: <String>['oneShot', 'ongoing'],
        ),
        OpParam.string(
          'metadataProvider',
          description: 'Identity provider, given together with externalId.',
          enumValues: <String>['anidb', 'mal', 'tmdb'],
        ),
        OpParam.string('externalId', description: 'Id at metadataProvider.'),
        OpParam.integer('year', description: 'Release year.'),
        OpParam.integer('season', description: 'Season number.'),
        OpParam.integer(
          'startAfterEpisode',
          description: 'Only fetch episodes after this one.',
        ),
        OpParam.string(
          'subtitlePolicy',
          description: 'Subtitle policy.',
          enumValues: <String>['none', 'bestEffort', 'required'],
        ),
      ],
      undo: OpUndo(
        record: (CtlCall call, Map<String, Object?> before, Object? result) {
          final Object? sub = result is Map ? result['subscription'] : null;
          return OpUndoRecord(
            payload: <String, Object?>{
              'id': sub is Map ? sub['subscriptionId'] : null,
            },
            after: '${call.body['title']}',
          );
        },
        revert: (Map<String, Object?> payload) async {
          final Object? id = payload['id'];
          if (id == null || await _subscription(dispatch(), '$id') == null) {
            return const OpUndoOutcome.superseded(
              'subscription already deleted',
            );
          }
          await adminCall(
            dispatch(),
            'DELETE',
            '/api/admin/subscriptions/${_enc(id)}',
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.subscription.enable',
      method: 'POST',
      pattern: '/api/admin/subscriptions/:id/enable',
      summary:
          'Enable or pause a subscription. Undo restores the previous state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        pathId,
        OpParam.boolean(
          'enabled',
          description: 'true = enabled, false = paused.',
          required: true,
        ),
      ],
      undo: OpUndo(
        capture: (CtlCall call) async {
          final Map<String, Object?>? sub = await _subscription(
            dispatch(),
            call.params['id'] ?? '',
          );
          if (sub == null) {
            throw CtlFailure.notFound(
              'unknown subscription ${call.params['id']}',
            );
          }
          return <String, Object?>{
            'id': sub['subscriptionId'],
            'old': sub['enabled'] == true,
          };
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(
              payload: <String, Object?>{
                ...before,
                'new': call.body['enabled'] == true,
              },
              before: '${before['old']}',
              after: '${call.body['enabled'] == true}',
            ),
        revert: (Map<String, Object?> payload) async {
          final Map<String, Object?>? sub = await _subscription(
            dispatch(),
            '${payload['id']}',
          );
          if (sub == null) {
            return const OpUndoOutcome.failed('subscription no longer exists');
          }
          if ((sub['enabled'] == true) != (payload['new'] == true)) {
            return const OpUndoOutcome.superseded();
          }
          await adminCall(
            dispatch(),
            'POST',
            '/api/admin/subscriptions/${_enc(payload['id'])}/enable',
            body: <String, Object?>{'enabled': payload['old'] == true},
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.settings.set',
      method: 'PUT',
      pattern: '/api/admin/settings',
      summary:
          'Change server settings: subtitleLanguage, metadataLocale (restart required), scanPrune, scanScrape. Undo writes the old values back.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.string(
          'subtitleLanguage',
          description: 'Preferred subtitle language code, e.g. ja, en, zh.',
        ),
        OpParam.string(
          'metadataLocale',
          description:
              'Metadata language tag, e.g. ja-JP, zh-CN (takes effect after restart).',
        ),
        OpParam.boolean(
          'scanPrune',
          description:
              'Remove index entries whose files disappeared during scans.',
        ),
        OpParam.boolean(
          'scanScrape',
          description: 'Scrape metadata for new works after each scan.',
        ),
      ],
      undo: OpUndo(
        capture: (CtlCall call) async {
          final Map<String, Object?> current = await _getMap(
            dispatch(),
            '/api/admin/settings',
          );
          return <String, Object?>{
            'old': <String, Object?>{
              for (final String key in kServerAgentSettingKeys)
                if (call.body.containsKey(key)) key: current[key],
            },
          };
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) {
          final Map<String, Object?> old = Map<String, Object?>.from(
            before['old'] as Map? ?? const <String, Object?>{},
          );
          final Map<String, Object?> next = <String, Object?>{
            for (final String key in old.keys) key: call.body[key],
          };
          return OpUndoRecord(
            payload: <String, Object?>{'old': old, 'new': next},
            before: jsonEncode(old),
            after: jsonEncode(next),
          );
        },
        revert: (Map<String, Object?> payload) async {
          final Map<String, Object?> old = Map<String, Object?>.from(
            payload['old'] as Map? ?? const <String, Object?>{},
          );
          final Map<String, Object?> next = Map<String, Object?>.from(
            payload['new'] as Map? ?? const <String, Object?>{},
          );
          final Map<String, Object?> current = await _getMap(
            dispatch(),
            '/api/admin/settings',
          );
          for (final MapEntry<String, Object?> e in next.entries) {
            if (current[e.key] != e.value) {
              return const OpUndoOutcome.superseded();
            }
          }
          old.removeWhere((String _, Object? v) => v == null);
          if (old.isNotEmpty) {
            await adminCall(
              dispatch(),
              'PUT',
              '/api/admin/settings',
              body: old,
            );
          }
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );
  op(
    OpDescription(
      id: 'server.anki.landing',
      method: 'POST',
      pattern: '/api/admin/anki/landing',
      summary:
          'Turn automatic landing of cards mined by paired devices into the server Anki collection on or off. Undo restores the previous state.',
      risk: OpRisk.write,
      params: const <OpParam>[
        OpParam.boolean(
          'enabled',
          description: 'true = land mined cards automatically.',
          required: true,
        ),
      ],
      undo: OpUndo(
        capture: (CtlCall call) async {
          final Object? landing = (await _getMap(
            dispatch(),
            '/api/admin/anki',
          ))['landing'];
          return <String, Object?>{
            'old': landing is Map && landing['enabled'] == true,
          };
        },
        record: (CtlCall call, Map<String, Object?> before, Object? result) =>
            OpUndoRecord(
              payload: <String, Object?>{
                ...before,
                'new': call.body['enabled'] == true,
              },
              before: '${before['old']}',
              after: '${call.body['enabled'] == true}',
            ),
        revert: (Map<String, Object?> payload) async {
          final Object? landing = (await _getMap(
            dispatch(),
            '/api/admin/anki',
          ))['landing'];
          final bool current = landing is Map && landing['enabled'] == true;
          if (current != (payload['new'] == true)) {
            return const OpUndoOutcome.superseded();
          }
          await adminCall(
            dispatch(),
            'POST',
            '/api/admin/anki/landing',
            body: <String, Object?>{'enabled': payload['old'] == true},
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
  );

  // ── 不可逆（用户在确认卡片上点了才跑）──────────────────────────────
  irreversible(
    'server.scan',
    'POST',
    '/api/admin/scan',
    'Scan all library roots now. With pruning (the configured default) index entries whose files are gone are deleted.',
    params: const <OpParam>[
      OpParam.boolean(
        'prune',
        description: 'Override the configured prune behaviour for this scan.',
      ),
    ],
    longRunning: true,
  );
  irreversible(
    'server.scrape.sweep',
    'POST',
    '/api/admin/scrape/sweep',
    'Scrape metadata for all pending video works now (writes identified metadata into the index).',
    longRunning: true,
  );
  irreversible(
    'server.scrape.ai-identify',
    'POST',
    '/api/admin/scrape/ai-identify',
    "Identify one pending video work with the server's AI provider and write the result into the index.",
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Pending work id from server.scrape.pending.',
        required: true,
      ),
    ],
    longRunning: true,
  );
  irreversible(
    'server.subscription.check',
    'POST',
    '/api/admin/subscriptions/check',
    'Check all subscriptions for new releases now; matches are queued as downloads.',
  );
  irreversible(
    'server.subscription.check-one',
    'POST',
    '/api/admin/subscriptions/:id/check',
    'Check one subscription for new releases now; matches are queued as downloads.',
    params: const <OpParam>[pathId],
  );
  irreversible(
    'server.subscription.delete',
    'DELETE',
    '/api/admin/subscriptions/:id',
    'Delete a subscription and its matched-item history.',
    params: const <OpParam>[pathId],
  );
  irreversible(
    'server.download.delete',
    'DELETE',
    '/api/admin/downloads/:id',
    'Delete a download job; the server also deletes its downloaded data.',
    params: const <OpParam>[pathId],
  );
  irreversible(
    'server.job.delete',
    'DELETE',
    '/api/admin/jobs/:id',
    'Delete a background job record and its output.',
    params: const <OpParam>[pathId],
  );
  irreversible(
    'server.anki.sync',
    'POST',
    '/api/admin/anki/sync',
    'Sync the server Anki collection with AnkiWeb now.',
  );
  irreversible(
    'server.model.pull',
    'POST',
    '/api/admin/models/pull',
    'Download an ASR or OCR model onto the server (large download).',
    params: const <OpParam>[
      OpParam.string(
        'model',
        description:
            'ASR language tag (optionally "@mixedAudio"), "ocr", or "ocr:<key>" from server.model.list.',
        required: true,
      ),
    ],
    longRunning: true,
  );

  return (routes: routes, descriptions: descriptions);
}

/// 服务端操作目录（远端 AI 助手的工具集）。
OpCatalog buildServerAdminOpCatalog(AdminDispatch Function() dispatch) {
  final ({List<CtlRoute> routes, List<OpDescription> descriptions}) ops =
      buildServerAdminOps(dispatch);
  return OpCatalog.build(ops.routes, ops.descriptions);
}
