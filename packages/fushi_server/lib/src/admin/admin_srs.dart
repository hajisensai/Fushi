/// admin API 的复习（SRS）端点（docs/specs/2026-11-05-server-srs-design.md §4.1 / §4.5）：
///
/// - `GET  /api/admin/srs`           状态（各份 profile、调度器、AnkiConnect 监听）+ 当前配置；
/// - `PUT  /api/admin/srs`           改配置（只改给了的字段）：`profiles`（整份）/ `addProfiles` / `removeProfiles`、
///                                   `defaultProfile`、`rolloverHour`、
///                                   `miningTarget`、`miningDecks`、`ankiConnect: {enabled, bind, port, apiKey,
///                                   profileKeys, corsOrigins}`；
/// - `GET  /api/admin/srs/profiles`  同步目录里能选的 profile（名字、设备、笔记数、是否已提供）；
/// - `POST /api/admin/srs/sync`      立即同步（正文 `{"profile": uid}` 只同步那份）。
///
/// AnkiConnect 的 key 是凭据：读的时候只报「设没设」，不回显；写的时候空串 = 清掉，不给 = 不动。
library;

import 'dart:convert';

import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_ankiconnect.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:shelf/shelf.dart' as shelf;

const String kAdminSrsPath = '/api/admin/srs';

/// profile uid 的形状（同步目录名 `fushi-srs/<uid>/`）。
final RegExp _uid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

class AdminSrs {
  AdminSrs(this.ctx);

  final AdminContext ctx;

  Future<shelf.Response?> route(
    String method,
    String path,
    shelf.Request request,
  ) async {
    switch ((method, path)) {
      case ('GET', kAdminSrsPath):
        return _json(status());
      case ('PUT', kAdminSrsPath):
        return _put(await _body(request));
      case ('GET', '$kAdminSrsPath/profiles'):
        return _json(<String, Object?>{'profiles': await profiles()});
      case ('POST', '$kAdminSrsPath/sync'):
        final Object? uid = (await _body(request))['profile'];
        final ServerSrs? srs = ctx.host.srs;
        if (srs == null) return _err(409, 'srs_unavailable');
        if (uid != null && (uid is! String || srs.profile(uid) == null)) {
          return _err(404, 'profile_not_served');
        }
        await srs.syncNow(uid as String?);
        return _json(status());
    }
    return null;
  }

  /// `GET /api/admin/srs` 的回包（`ctl srs status` 也用它）。
  Map<String, Object?> status() {
    final ServerSrsConfig cfg = ctx.config.srs;
    final ServerAnkiConnectConfig ac = ctx.config.ankiConnect;
    final ServerAnkiConnect? listener = ctx.host.ankiConnect;
    return <String, Object?>{
      ...?ctx.host.srs?.status(),
      'enabled': cfg.enabled,
      'config': <String, Object?>{
        'profiles': cfg.profiles,
        'defaultProfile': cfg.defaultProfile,
        'rolloverHour': cfg.rolloverHour,
        'miningTarget': cfg.miningTarget.wire,
        'miningDecks': cfg.miningDecks,
      },
      'ankiConnect': <String, Object?>{
        'enabled': ac.enabled,
        'bind': ac.bind,
        'port': ac.port,
        'apiKeySet': ac.apiKey.isNotEmpty,
        'profileKeysSet': <String, bool>{
          for (final MapEntry<String, String> e in ac.profileKeys.entries)
            e.key: e.value.isNotEmpty,
        },
        'corsOrigins': ac.corsOrigins,
        'listening': listener?.listening ?? false,
        'listeningPort': listener?.port,
        'lastError':
            listener?.lastError ?? (ac.enabled ? ac.startProblem : null),
      },
    };
  }

  /// 同步目录里的 profile，标上已不已提供（`ctl srs profiles` 也用它）。
  Future<List<Map<String, Object?>>> profiles() async {
    final ServerSrs? srs = ctx.host.srs;
    final List<SrsRemoteProfile> found = srs == null
        ? const <SrsRemoteProfile>[]
        : await srs.discoverProfiles();
    final Set<String> served = ctx.config.srs.profiles.toSet();
    final Set<String> listed = <String>{};
    return <Map<String, Object?>>[
      for (final SrsRemoteProfile r in found)
        if (listed.add(r.uid))
          <String, Object?>{
            'uid': r.uid,
            'name': r.displayName,
            'devices': r.devices,
            'updatedAt': r.updatedAt,
            'noteCount': r.noteCount,
            'hasNotes': r.hasNotes,
            'served': served.contains(r.uid),
          },
      // 配置里选了、同步目录里却已经没有的（被别的设备清掉 / 换了目录）：照样列出来，好让管理员取消。
      for (final String uid in served)
        if (!listed.contains(uid))
          <String, Object?>{'uid': uid, 'served': true, 'missing': true},
    ];
  }

  Future<shelf.Response> _put(Map<String, dynamic> body) async {
    final ServerSrsConfig cur = ctx.config.srs;
    final List<String>? profiles = _uidList(body['profiles']);
    final List<String> add = _uidList(body['addProfiles']) ?? const <String>[];
    final Set<String> remove =
        (_uidList(body['removeProfiles']) ?? const <String>[]).toSet();
    final List<String> nextProfiles = <String>[
      for (final String uid in <String>{...(profiles ?? cur.profiles), ...add})
        if (!remove.contains(uid)) uid,
    ];
    final Object? def = body['defaultProfile'];
    if (def != null && def is! String) {
      throw const FormatException('defaultProfile must be a string');
    }
    if (def is String && def.isNotEmpty && !nextProfiles.contains(def)) {
      throw const FormatException('defaultProfile must be one of profiles');
    }
    final Object? hour = body['rolloverHour'];
    if (hour != null && (hour is! int || hour < 0 || hour > 23)) {
      throw const FormatException('rolloverHour must be an integer 0-23');
    }
    final Object? target = body['miningTarget'];
    if (target != null &&
        !ServerMiningTarget.values.any(
          (ServerMiningTarget t) => t.wire == target,
        )) {
      throw const FormatException('miningTarget must be auto / anki / review');
    }
    final Map<String, String>? decks = _uidMap(
      body['miningDecks'],
      'miningDecks',
    );
    final ServerSrsConfig nextSrs = cur.copyWith(
      profiles: nextProfiles,
      // 默认那份被取消了：清空（= 列表第一份），别留一个不再提供的 uid。
      defaultProfile:
          def as String? ??
          (nextProfiles.contains(cur.defaultProfile) ? null : ''),
      rolloverHour: hour as int?,
      miningTarget: target == null
          ? null
          : ServerMiningTarget.parse(target as String),
      // 整份替换；空串 = 那份用内置默认牌组。
      miningDecks: decks == null
          ? null
          : <String, String>{
              for (final MapEntry<String, String> e in decks.entries)
                if (e.value.isNotEmpty) e.key: e.value,
            },
    );
    final ServerAnkiConnectConfig nextAc = _ankiConnect(
      body['ankiConnect'],
      ctx.config.ankiConnect,
    );
    if (nextAc.enabled) {
      final String? problem = nextAc.startProblem;
      if (problem != null) {
        return _json(<String, Object?>{
          'error': problem,
          'reason': 'ankiconnect_invalid',
        }, status: 409);
      }
    }
    final ServerConfig next = ctx.config.copyWith(
      srs: nextSrs,
      ankiConnect: nextAc,
    );
    await ctx.updateConfig(next);
    return _json(status());
  }

  ServerAnkiConnectConfig _ankiConnect(
    Object? raw,
    ServerAnkiConnectConfig cur,
  ) {
    if (raw == null) return cur;
    if (raw is! Map) {
      throw const FormatException('ankiConnect must be an object');
    }
    final Object? enabled = raw['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException('ankiConnect.enabled must be a boolean');
    }
    final Object? port = raw['port'];
    if (port != null && (port is! int || port < 1 || port > 65535)) {
      throw const FormatException('ankiConnect.port must be 1-65535');
    }
    final Object? bind = raw['bind'];
    if (bind != null && (bind is! String || bind.trim().isEmpty)) {
      throw const FormatException('ankiConnect.bind must be a host address');
    }
    final Object? apiKey = raw['apiKey'];
    if (apiKey != null && apiKey is! String) {
      throw const FormatException('ankiConnect.apiKey must be a string');
    }
    final Map<String, String>? keys = _uidMap(
      raw['profileKeys'],
      'ankiConnect.profileKeys',
    );
    final Object? origins = raw['corsOrigins'];
    if (origins != null &&
        (origins is! List || origins.any((Object? o) => o is! String))) {
      throw const FormatException('ankiConnect.corsOrigins must be strings');
    }
    return cur.copyWith(
      enabled: enabled as bool?,
      bind: (bind as String?)?.trim(),
      port: port as int?,
      apiKey: (apiKey as String?)?.trim(),
      // 空串 = 清掉那份的 key。
      profileKeys: keys == null
          ? null
          : <String, String>{
              for (final MapEntry<String, String> e in <String, String>{
                ...cur.profileKeys,
                ...keys,
              }.entries)
                if (e.value.isNotEmpty) e.key: e.value,
            },
      corsOrigins: origins == null
          ? null
          : <String>[
              for (final Object? o in origins as List)
                if ((o as String).trim().isNotEmpty) o.trim(),
            ],
    );
  }
}

List<String>? _uidList(Object? raw) {
  if (raw == null) return null;
  if (raw is! List) throw const FormatException('profiles must be a list');
  final List<String> out = <String>[];
  for (final Object? v in raw) {
    if (v is! String || !_uid.hasMatch(v)) {
      throw FormatException('not a profile uid: $v');
    }
    if (!out.contains(v)) out.add(v);
  }
  return out;
}

Map<String, String>? _uidMap(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! Map) throw FormatException('$field must be an object');
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<Object?, Object?> e in raw.entries) {
    final Object? k = e.key;
    final Object? v = e.value;
    if (k is! String || !_uid.hasMatch(k) || v is! String) {
      throw FormatException('$field: bad entry $k');
    }
    out[k] = v.trim();
  }
  return out;
}

Future<Map<String, dynamic>> _body(shelf.Request request) async {
  final String raw = await request.readAsString();
  if (raw.trim().isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('body must be a JSON object');
  }
  return Map<String, dynamic>.from(decoded);
}

shelf.Response _json(Map<String, Object?> body, {int status = 200}) =>
    shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );

shelf.Response _err(int status, String reason) =>
    _json(<String, Object?>{'error': reason, 'reason': reason}, status: status);
